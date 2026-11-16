import CoreBluetooth
import Foundation
import IOBluetooth
import ObjectiveC
import AppKit
import os

struct AirPodsBattery: Equatable {
    let left:  Int?   // 0-100, nil = not visible (in case / unavailable)
    let right: Int?
    let `case`: Int?
    let leftCharging:  Bool
    let rightCharging: Bool
    let caseCharging:  Bool

    func isEqual(to other: AirPodsBattery?) -> Bool {
        guard let other else { return false }
        return left == other.left && right == other.right && self.case == other.case
            && leftCharging == other.leftCharging && rightCharging == other.rightCharging
            && caseCharging == other.caseCharging
    }
}

// Reads AirPods & Case battery via:
// 1. Apple daemon plist written by audioaccessoryd (high precision 1%, persists in-case & nearby readings)
// 2. BLE Proximity Pairing advertisements (Apple proprietary 0x004c 0x07)
// 3. Bluetooth Classic paired device monitoring
class AirPodsReader: NSObject, CBCentralManagerDelegate {
    private static let logger = Logger(subsystem: "me.yura.barttery", category: "AirPods")
    var onUpdate: ((AirPodsBattery?) -> Void)?
    var onConnect: ((String) -> Void)?

    private static let deviceStaleTimeout: TimeInterval = 14400.0 // 4 hours

    private var central: CBCentralManager?
    private var syncTimer: Timer?
    private var plistLevels: PlistLevels?
    private var lastBattery: AirPodsBattery?
    private var cachedBTDevice: IOBluetoothDevice?
    private(set) var isScanning = false

    // Known Bluetooth addresses identified as Apple Audio Accessories
    private static var knownAccessoryAddresses: Set<String> = []

    // Stable battery & charging persistence: hold readings across BLE packet drops and closed lid
    private var lastLeftBattery: Int?
    private var lastRightBattery: Int?
    private var lastCaseBattery: Int?
    private var lastCaseSeenDate: Date?
    private var lastCaseCharging: Bool?
    private var lastCaseChargingDate: Date?
    private var lastPodCharging: Bool?
    private var lastChargingSeenDate: Date?

    // Cached selectors for framework parsing
    private let selAlloc    = NSSelectorFromString("alloc")
    private let selInitData = NSSelectorFromString("initWithData:")
    private let selPayloads = NSSelectorFromString("payloads")
    private var advClass: NSObject.Type?

    private struct PlistLevels {
        let left: Int?
        let right: Int?
        let cas: Int?
        let leftCharging: Bool
        let rightCharging: Bool
        let caseCharging: Bool
        let lastSeen: Date
    }

    static func isAirPods(name: String?, address: String?) -> Bool {
        if let lower = name?.lowercased() {
            if lower.contains("airpod") || lower.contains("beats") || lower.contains("powerbeats") {
                return true
            }
        }
        if let addr = address?.replacingOccurrences(of: "-", with: ":").uppercased() {
            if knownAccessoryAddresses.contains(addr) {
                return true
            }
        }
        return false
    }

    func startMonitoring() {
        dlopen("/System/Library/PrivateFrameworks/AudioAccessoryServices.framework/AudioAccessoryServices", RTLD_NOW)
        advClass = NSClassFromString("AAManufacturerDataAdvertisement") as? NSObject.Type
        
        // Initial read of system audioaccessoryd state
        refreshPlist()
        watchPlist()
        
        cachedBTDevice = findPairedDevice()
        if let name = cachedBTDevice?.name {
            onConnect?(name)
        }

        central = CBCentralManager(delegate: self, queue: .main)
        IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(bluetoothDeviceConnected(_:device:)))
        if let device = btDevice(), device.isConnected() {
            device.register(forDisconnectNotification: self, selector: #selector(bluetoothDeviceDisconnected(_:device:)))
        }

        // Periodic sync to check plist every 30 seconds
        syncTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.refreshPlist()
            if let battery = self.lastBattery {
                self.onUpdate?(battery)
            }
        }
        syncTimer?.tolerance = 10

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(handleSleep), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(handleWake), name: NSWorkspace.didWakeNotification, object: nil)
    }

    @objc private func handleSleep() {
        stopScanning()
    }

    @objc private func handleWake() {
        cachedBTDevice = findPairedDevice()
        refreshPlist()
        startScanning()
    }

    func startScanning() {
        guard let central = central, central.state == .poweredOn, !isScanning else { return }
        isScanning = true
        central.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: true
        ])
    }

    func stopScanning() {
        guard let central = central, isScanning else { return }
        isScanning = false
        central.stopScan()
    }

    @objc private func bluetoothDeviceConnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard let name = device.name else { return }
        guard Self.isAirPods(name: name, address: device.addressString) else { return }
        Self.logger.notice("AirPods Bluetooth connected: \(name)")
        cachedBTDevice = device
        device.register(forDisconnectNotification: self, selector: #selector(bluetoothDeviceDisconnected(_:device:)))
        DispatchQueue.main.async { [weak self] in
            self?.onConnect?(name)
            self?.refreshPlist()
            self?.startScanning()
        }
    }

    @objc private func bluetoothDeviceDisconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        Self.logger.notice("AirPods Bluetooth disconnected: \(device.name ?? "Unknown")")
        cachedBTDevice = nil
        // Do not clear lastBattery! The AirPods are simply in the case or disconnected from audio.
        // Refresh plist to check for in-case battery updates.
        refreshPlist()
        if let battery = lastBattery {
            onUpdate?(battery)
        }
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            isScanning = false
            return
        }
        startScanning()
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        // -75 dBm: strong nearby proximity (placed right next to Mac)
        guard RSSI.intValue > -75 else { return }

        guard let mfr = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              mfr.count >= 10,
              mfr[0] == 0x4C, mfr[1] == 0x00,
              mfr[2] == 0x07
        else { return }

        let mfrCopy = mfr
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let lidClosed = self?.isLidClosed(mfrCopy) ?? false
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.handleAdvertisement(mfrCopy, lidClosed: lidClosed)
            }
        }
    }

    private func handleAdvertisement(_ mfr: Data, lidClosed: Bool) {
        // Only process if we have paired AirPods or plist data
        if !isConnected && findPairedDevice() == nil && plistLevels == nil {
            return
        }

        let status       = mfr[7]
        let flip         = (status & 0x20) != 0
        let pods         = mfr[8]
        let caseData     = mfr[9]

        let podHi        = Int((pods >> 4) & 0x0F)
        let podLo        = Int(pods & 0x0F)
        let caseV        = Int((caseData >> 4) & 0x0F)
        let chargingBits = Int(caseData & 0x0F)

        let leftRaw  = flip ? podHi : podLo
        let rightRaw = flip ? podLo : podHi

        if leftRaw < 0xF {
            lastLeftBattery = plistLevels?.left ?? min(leftRaw * 10, 100)
        }
        if rightRaw < 0xF {
            lastRightBattery = plistLevels?.right ?? min(rightRaw * 10, 100)
        }

        let now = Date()

        // Case presence & hysteresis:
        let caseInPacket = caseV < 0xF
        let chargingValid = chargingBits < 0xF

        if caseInPacket {
            let caseVal = plistLevels?.cas ?? min(caseV * 10, 100)
            lastCaseBattery = caseVal
            lastCaseSeenDate = now
        }

        if chargingValid {
            lastCaseCharging = (chargingBits & 0x04) != 0
            lastCaseChargingDate = now
            let podBits = (chargingBits & 0x03) != 0
            if podBits || lidClosed {
                lastPodCharging = true
                lastChargingSeenDate = now
            } else if caseInPacket {
                lastPodCharging = false
                lastChargingSeenDate = now
            }
        }

        let leftBat:  Int? = plistLevels?.left  ?? lastLeftBattery
        let rightBat: Int? = plistLevels?.right ?? lastRightBattery
        let caseBat:  Int? = plistLevels?.cas   ?? lastCaseBattery

        guard leftBat != nil || rightBat != nil || caseBat != nil else { return }

        let isPodCharging = lastPodCharging ?? (plistLevels?.leftCharging == true || plistLevels?.rightCharging == true)
        let leftCharging  = isPodCharging
        let rightCharging = isPodCharging
        let caseCharging  = lastCaseCharging ?? (plistLevels?.caseCharging == true)

        Self.logger.debug("AirPods packet: flip=\(flip) lidClosed=\(lidClosed) pods=\(String(format: "%02X", pods)) caseData=\(String(format: "%02X", caseData)) -> L:\(leftBat ?? -1) R:\(rightBat ?? -1) Case:\(caseBat ?? -1) Chg:\(isPodCharging)")

        let battery = AirPodsBattery(
            left: leftBat, right: rightBat, case: caseBat,
            leftCharging: leftCharging, rightCharging: rightCharging, caseCharging: caseCharging
        )
        guard !battery.isEqual(to: lastBattery) else { return }

        Self.logger.notice("AirPods state changed: L=\(leftBat.map(String.init) ?? "nil")%, R=\(rightBat.map(String.init) ?? "nil")%, Case=\(caseBat.map(String.init) ?? "nil")%, Charging=\(isPodCharging)")

        lastBattery = battery
        onUpdate?(battery)
    }

    // MARK: - Lid closed detection

    private func isLidClosed(_ mfr: Data) -> Bool {
        guard let cls = advClass else { return false }
        guard let obj = cls.perform(selAlloc)?.takeUnretainedValue() as? NSObject else { return false }
        guard let adv = obj.perform(selInitData, with: mfr as NSData)?.takeRetainedValue() as? NSObject else { return false }
        guard let payloads = adv.perform(selPayloads)?.takeUnretainedValue() as? [AnyObject],
              let payload = payloads.first else { return false }
        return (payload as AnyObject).value(forKey: "lidClosed") as? Int == 1
    }

    // MARK: - Plist (high-precision battery from audioaccessoryd)

    private let prefPath = NSHomeDirectory() + "/Library/Preferences/com.apple.AudioAccessory.plist"
    private var fileWatcher: DispatchSourceFileSystemObject?
    // Staleness: 4 hours (AirPods in closed case on desk can rest without losing reading)
    private let staleTimeout: TimeInterval = 14400

    private func watchPlist() {
        let fd = open(prefPath, O_RDONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in
            self?.refreshPlist()
            // File was atomically replaced — fd is now stale, re-open watcher on new inode
            self?.fileWatcher?.cancel()
            self?.fileWatcher = nil
            self?.watchPlist()
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        fileWatcher = src
    }

    func refreshPlist() {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: prefPath),
           let mod = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(mod) > staleTimeout {
            // Only drop if older than stale timeout
            return
        }

        guard let prefs = NSDictionary(contentsOfFile: prefPath) else { return }
        
        // Also extract known accessory addresses from lowBatteryDevices
        if let lowDevices = prefs["lowBatteryDevices"] as? [[String: Any]] {
            for d in lowDevices {
                if let addr = d["deviceAddress"] as? String {
                    Self.knownAccessoryAddresses.insert(addr.uppercased())
                }
            }
        }

        let outerData = (prefs["lastSeenBatteryInfosV3"] as? Data)
                     ?? (prefs["lastSeenBatteryInfosV2"] as? Data)
        guard let outerData else { return }

        if let levels = plistLevelsFromArchive(outerData) {
            plistLevels = levels
            if let l = levels.left { lastLeftBattery = l }
            if let r = levels.right { lastRightBattery = r }
            if let c = levels.cas {
                lastCaseBattery = c
                lastCaseSeenDate = Date()
            }
            lastCaseCharging = levels.caseCharging
            lastPodCharging = levels.leftCharging || levels.rightCharging

            let battery = AirPodsBattery(
                left: levels.left ?? lastLeftBattery,
                right: levels.right ?? lastRightBattery,
                case: levels.cas ?? lastCaseBattery,
                leftCharging: levels.leftCharging,
                rightCharging: levels.rightCharging,
                caseCharging: levels.caseCharging
            )
            if !battery.isEqual(to: lastBattery) {
                lastBattery = battery
                onUpdate?(battery)
            }
            return
        }
    }

    private func plistLevelsFromArchive(_ data: Data) -> PlistLevels? {
        guard let archive = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? NSDictionary,
              let objects = archive["$objects"] as? NSArray
        else { return nil }

        func uidIndex(_ v: Any?) -> Int? {
            guard let obj = v as? NSObject else { return nil }
            let desc = obj.description
            guard let s = desc.range(of: "{value = "),
                  let e = desc.range(of: "}", range: s.upperBound..<desc.endIndex)
            else { return nil }
            return Int(String(desc[s.upperBound..<e.lowerBound]).trimmingCharacters(in: .whitespaces))
        }
        func resolveObj(_ v: Any?) -> NSDictionary? {
            guard let idx = uidIndex(v), idx > 0, idx < objects.count else { return nil }
            return objects[idx] as? NSDictionary
        }
        func className(_ d: NSDictionary) -> String? {
            resolveObj(d["$class"])?["$classname"] as? String
        }

        var bestLstS: Double = 0
        var bestLevels: PlistLevels?

        for obj in objects {
            guard let d = obj as? NSDictionary,
                  className(d) == "AADeviceBatteryInfo"
            else { continue }

            // Extract Bluetooth address if present
            if let btaUID = uidIndex(d["bta"]), btaUID > 0, btaUID < objects.count,
               let btaStr = objects[btaUID] as? String {
                Self.knownAccessoryAddresses.insert(btaStr.uppercased())
            }

            var maxLstS: Double = 0
            var lv = [String: Double]()
            var chg = [String: Bool]()
            for field in ["bale", "bari", "baca"] {
                guard let bat = resolveObj(d[field]) else { continue }
                if let t = bat["lstS"] as? Double { maxLstS = max(maxLstS, t) }
                if let l = bat["btyl"] as? Double { lv[field] = l }
                if let aabs = bat["aabs"] as? Int { chg[field] = (aabs == 2) }
            }
            guard maxLstS > bestLstS else { continue }
            bestLstS = maxLstS

            func level(_ f: String) -> Int? {
                guard let v = lv[f], v > 0 else { return nil }
                return Int(ceil(v * 100)).clamped(to: 1...100)
            }
            bestLevels = PlistLevels(
                left: level("bale"),
                right: level("bari"),
                cas: level("baca"),
                leftCharging: chg["bale"] ?? false,
                rightCharging: chg["bari"] ?? false,
                caseCharging: chg["baca"] ?? false,
                lastSeen: Date(timeIntervalSinceReferenceDate: maxLstS)
            )
        }

        return bestLevels
    }

    // MARK: - Bluetooth connect / disconnect

    var isConnected:  Bool    { btDevice()?.isConnected() ?? false }
    var deviceName:   String? { btDevice()?.name ?? findPairedDevice()?.name }

    func connect()    { btDevice()?.openConnection()  }
    func disconnect() { btDevice()?.closeConnection() }

    private func btDevice() -> IOBluetoothDevice? {
        if let cached = cachedBTDevice, cached.isConnected() {
            return cached
        }
        cachedBTDevice = findPairedDevice()
        return cachedBTDevice
    }

    private func findPairedDevice() -> IOBluetoothDevice? {
        (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice])?.first {
            Self.isAirPods(name: $0.name, address: $0.addressString)
        }
    }
}

private extension Comparable {
    func clamped(to r: ClosedRange<Self>) -> Self {
        min(max(self, r.lowerBound), r.upperBound)
    }
}
