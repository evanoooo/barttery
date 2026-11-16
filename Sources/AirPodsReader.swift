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
    static let caseChargingStaleTimeout: TimeInterval = 300.0   // 5 minutes

    private var central: CBCentralManager?
    private let bleQueue = DispatchQueue(label: "me.yura.barttery.airpods.ble", qos: .utility)
    private var syncTimer: Timer?
    private var plistLevels: PlistLevels?
    private var lastBattery: AirPodsBattery?
    private var cachedBTDevice: IOBluetoothDevice?
    private var hasPairedAirPods = false
    private var isScanning = false
    private var dutyActive = false
    private var dutyGeneration = 0
    private var lastPlistModDate: Date?
    private var lastAdvByPeripheral: [UUID: (b7: UInt8, b8: UInt8, b9: UInt8, time: TimeInterval)] = [:]
    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotification: IOBluetoothUserNotification?

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
    private var knownProductID: UInt16?

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
        let caseLastSeen: Date?
        let productID: UInt16?
    }

    static func isValidProximityPairingPacket(_ mfr: Data, expectedPID: UInt16? = nil) -> Bool {
        guard mfr.count >= 10,
              mfr[0] == 0x4C, mfr[1] == 0x00,
              mfr[2] == 0x07,
              mfr[3] >= 0x06,
              mfr[4] == 0x01
        else { return false }
        if let expectedPID {
            let pktPID = UInt16(mfr[5]) | (UInt16(mfr[6]) << 8)
            guard pktPID == expectedPID else { return false }
        }
        return true
    }

    static func isCaseChargingFresh(observedAt: Date?, referenceDate: Date, now: Date = Date()) -> Bool {
        guard let observedAt else { return false }
        let age = now.timeIntervalSince(observedAt)
        guard age.isFinite, age >= -60, age <= caseChargingStaleTimeout else { return false }
        return referenceDate.timeIntervalSince(observedAt) <= 120
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
        hasPairedAirPods = (cachedBTDevice != nil)
        if let name = cachedBTDevice?.name {
            onConnect?(name)
        }

        central = CBCentralManager(delegate: self, queue: bleQueue,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: false])
        connectNotification = IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(bluetoothDeviceConnected(_:device:))
        )
        if let device = cachedBTDevice, device.isConnected() {
            disconnectNotification = device.register(
                forDisconnectNotification: self,
                selector: #selector(bluetoothDeviceDisconnected(_:device:))
            )
        }

        // Periodic sync to check plist every 30 seconds (skips parsing when mtime unchanged)
        syncTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refreshPlist()
            self?.expireStaleCaseCharging()
        }
        syncTimer?.tolerance = 10

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(handleSleep), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(handleWake), name: NSWorkspace.didWakeNotification, object: nil)
    }

    deinit {
        syncTimer?.invalidate()
        syncTimer = nil
        fileWatcher?.cancel()
        fileWatcher = nil
        connectNotification?.unregister()
        disconnectNotification?.unregister()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        let c = central
        bleQueue.async {
            c?.stopScan()
        }
    }

    @objc private func handleSleep() {
        stopScanning()
    }

    @objc private func handleWake() {
        cachedBTDevice = findPairedDevice()
        hasPairedAirPods = (cachedBTDevice != nil)
        refreshPlist()
        startScanning()
    }

    func startScanning() {
        bleQueue.async { [weak self] in
            self?.startScanningOnBLEQueue()
        }
    }

    func stopScanning() {
        bleQueue.async { [weak self] in
            self?.stopScanningOnBLEQueue()
        }
    }

    // Duty-cycled scanning keeps the Bluetooth radio mostly idle (≈ 8s on / 22s off).
    // Event-driven triggers (connect, wake, popup open) start a fresh window immediately.
    private static let scanWindow: TimeInterval = 8
    private static let scanPause: TimeInterval = 22

    private func startScanningOnBLEQueue() {
        guard let central = central, central.state == .poweredOn else { return }
        dutyActive = true
        guard !isScanning else { return }
        dutyGeneration &+= 1  // invalidates any pending "begin window" from a pause
        beginScanWindow(generation: dutyGeneration)
    }

    private func beginScanWindow(generation: Int) {
        guard dutyActive, generation == dutyGeneration,
              let central = central, central.state == .poweredOn else { return }
        isScanning = true
        central.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: true
        ])
        bleQueue.asyncAfter(deadline: .now() + Self.scanWindow) { [weak self] in
            self?.endScanWindow(generation: generation)
        }
    }

    private func endScanWindow(generation: Int) {
        guard dutyActive, generation == dutyGeneration else { return }
        if isScanning {
            isScanning = false
            central?.stopScan()
        }
        bleQueue.asyncAfter(deadline: .now() + Self.scanPause) { [weak self] in
            self?.beginScanWindow(generation: generation)
        }
    }

    private func stopScanningOnBLEQueue() {
        dutyActive = false
        dutyGeneration &+= 1
        guard let central = central, isScanning else { return }
        isScanning = false
        central.stopScan()
    }

    @objc private func bluetoothDeviceConnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard let name = device.name else { return }
        guard Self.isAirPods(name: name, address: device.addressString) else { return }
        Self.logger.notice("AirPods Bluetooth connected: \(name)")
        cachedBTDevice = device
        hasPairedAirPods = true
        disconnectNotification?.unregister()
        disconnectNotification = device.register(
            forDisconnectNotification: self,
            selector: #selector(bluetoothDeviceDisconnected(_:device:))
        )
        DispatchQueue.main.async { [weak self] in
            self?.onConnect?(name)
            self?.refreshPlist(force: true)
            self?.startScanning()
        }
    }

    @objc private func bluetoothDeviceDisconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        Self.logger.notice("AirPods Bluetooth disconnected: \(device.name ?? "Unknown")")
        cachedBTDevice = nil
        disconnectNotification?.unregister()
        disconnectNotification = nil
        // Do not clear lastBattery! The AirPods are simply in the case or disconnected from audio.
        // Refresh plist to check for in-case battery updates.
        refreshPlist(force: true)
        if let battery = lastBattery {
            onUpdate?(battery)
        }
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            isScanning = false
            dutyActive = false
            dutyGeneration &+= 1
            return
        }
        startScanningOnBLEQueue()
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        // -85 dBm: covers same-room proximity (desk, nightstand); -75 was too strict for non-adjacent placement
        guard RSSI.intValue > -85 else { return }

        guard let mfr = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              Self.isValidProximityPairingPacket(mfr)
        else { return }

        let b7 = mfr[7], b8 = mfr[8], b9 = mfr[9]
        let now = ProcessInfo.processInfo.systemUptime
        let pid = peripheral.identifier
        if let prev = lastAdvByPeripheral[pid],
           prev.b7 == b7, prev.b8 == b8, prev.b9 == b9,
           now - prev.time < 2.0 {
            return
        }
        if lastAdvByPeripheral.count >= 32 {
            lastAdvByPeripheral = lastAdvByPeripheral.filter { now - $0.value.time < 10.0 }
        }
        lastAdvByPeripheral[pid] = (b7, b8, b9, now)

        let lidClosed = isLidClosed(mfr)
        DispatchQueue.main.async { [weak self] in
            self?.handleAdvertisement(mfr, lidClosed: lidClosed)
        }
    }

    private func handleAdvertisement(_ mfr: Data, lidClosed: Bool) {
        // Only process if we have paired AirPods or plist data
        if !hasPairedAirPods && plistLevels == nil {
            return
        }
        guard Self.isValidProximityPairingPacket(mfr, expectedPID: knownProductID) else {
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

        let leftPodCharging: Bool
        let rightPodCharging: Bool
        if chargingValid {
            if caseInPacket {
                lastCaseCharging = (chargingBits & 0x04) != 0
                lastCaseChargingDate = now
            }
            let leftBit  = flip ? (chargingBits & 0x02) != 0 : (chargingBits & 0x01) != 0
            let rightBit = flip ? (chargingBits & 0x01) != 0 : (chargingBits & 0x02) != 0
            leftPodCharging  = leftBit || lidClosed
            rightPodCharging = rightBit || lidClosed
            let podBits = (chargingBits & 0x03) != 0
            if podBits || lidClosed {
                lastPodCharging = true
                lastChargingSeenDate = now
            } else if caseInPacket {
                lastPodCharging = false
                lastChargingSeenDate = now
            }
        } else {
            leftPodCharging  = false
            rightPodCharging = false
        }

        if lastCaseCharging == true,
           let seen = lastCaseChargingDate,
           now.timeIntervalSince(seen) > Self.caseChargingStaleTimeout {
            lastCaseCharging = false
        }
        if lastPodCharging == true,
           let seen = lastChargingSeenDate,
           now.timeIntervalSince(seen) > Self.caseChargingStaleTimeout {
            lastPodCharging = false
        }

        let leftBat:  Int? = plistLevels?.left  ?? lastLeftBattery
        let rightBat: Int? = plistLevels?.right ?? lastRightBattery
        let caseBat:  Int? = plistLevels?.cas   ?? lastCaseBattery

        guard leftBat != nil || rightBat != nil || caseBat != nil else { return }

        let leftCharging  = plistLevels?.leftCharging ?? (chargingValid ? leftPodCharging : (lastPodCharging ?? false))
        let rightCharging = plistLevels?.rightCharging ?? (chargingValid ? rightPodCharging : (lastPodCharging ?? false))
        let isPodCharging = leftCharging || rightCharging
        let plistCaseChargingFresh = (plistLevels?.caseCharging == true) &&
            Self.isCaseChargingFresh(observedAt: plistLevels?.caseLastSeen,
                                     referenceDate: plistLevels?.lastSeen ?? now,
                                     now: now)
        let caseCharging  = lastCaseCharging ?? plistCaseChargingFresh

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
        return autoreleasepool {
            guard let obj = cls.perform(selAlloc)?.takeUnretainedValue() as? NSObject else { return false }
            guard let adv = obj.perform(selInitData, with: mfr as NSData)?.takeRetainedValue() as? NSObject else { return false }
            guard let payloads = adv.perform(selPayloads)?.takeUnretainedValue() as? [AnyObject],
                  let payload = payloads.first else { return false }
            let pObj = payload as AnyObject
            guard pObj.responds(to: NSSelectorFromString("lidClosed")) else { return false }
            return pObj.value(forKey: "lidClosed") as? Int == 1
        }
    }

    // MARK: - Plist (high-precision battery from audioaccessoryd)

    private let prefPath = NSHomeDirectory() + "/Library/Preferences/com.apple.AudioAccessory.plist"
    private var fileWatcher: DispatchSourceFileSystemObject?
    // Staleness: 4 hours (AirPods in closed case on desk can rest without losing reading)
    private let staleTimeout: TimeInterval = 14400

    private func watchPlist() {
        fileWatcher?.cancel()
        fileWatcher = nil
        let fd = open(prefPath, O_RDONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = self.fileWatcher?.data ?? []
            self.refreshPlist(force: true)
            if flags.contains(.rename) || flags.contains(.delete) {
                // File was atomically replaced — fd is now stale, re-open watcher on new inode
                self.watchPlist()
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        fileWatcher = src
    }

    func refreshPlist(force: Bool = false) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: prefPath),
              let mod = attrs[.modificationDate] as? Date else { return }
        if Date().timeIntervalSince(mod) > staleTimeout {
            // Plist is stale — clear cached plist levels so we don't serve old data
            if plistLevels != nil {
                plistLevels = nil
                Self.logger.notice("AirPods plist stale (>4h), clearing cached levels")
            }
            return
        }
        if !force, let lastMod = lastPlistModDate, mod == lastMod {
            return
        }
        lastPlistModDate = mod

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
            hasPairedAirPods = true
            if let pid = levels.productID { knownProductID = pid }
            if let l = levels.left { lastLeftBattery = l }
            if let r = levels.right { lastRightBattery = r }
            if let c = levels.cas {
                lastCaseBattery = c
                lastCaseSeenDate = Date()
            }
            lastCaseCharging = levels.caseCharging
            lastCaseChargingDate = levels.caseCharging ? (levels.caseLastSeen ?? levels.lastSeen) : nil
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

    private func expireStaleCaseCharging(now: Date = Date()) {
        var changed = false
        if lastCaseCharging == true,
           let seen = lastCaseChargingDate,
           now.timeIntervalSince(seen) > Self.caseChargingStaleTimeout {
            lastCaseCharging = false
            changed = true
        }
        if lastPodCharging == true,
           let seen = lastChargingSeenDate,
           now.timeIntervalSince(seen) > Self.caseChargingStaleTimeout {
            lastPodCharging = false
            changed = true
        }
        guard changed, let current = lastBattery else { return }
        let updated = AirPodsBattery(
            left: current.left, right: current.right, case: current.case,
            leftCharging: lastPodCharging ?? false,
            rightCharging: lastPodCharging ?? false,
            caseCharging: lastCaseCharging ?? false
        )
        if !updated.isEqual(to: current) {
            lastBattery = updated
            onUpdate?(updated)
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
            var lstMap = [String: Double]()
            for field in ["bale", "bari", "baca"] {
                guard let bat = resolveObj(d[field]) else { continue }
                if let t = bat["lstS"] as? Double {
                    maxLstS = max(maxLstS, t)
                    lstMap[field] = t
                }
                if let l = bat["btyl"] as? Double { lv[field] = l }
                if let aabs = bat["aabs"] as? Int { chg[field] = (aabs == 2) }
            }
            guard maxLstS > bestLstS else { continue }
            bestLstS = maxLstS

            let lastSeen = Date(timeIntervalSinceReferenceDate: maxLstS)
            let caseLastSeen = lstMap["baca"].map { Date(timeIntervalSinceReferenceDate: $0) }
            let rawCaseChg = chg["baca"] ?? false
            let freshCaseChg = rawCaseChg && Self.isCaseChargingFresh(observedAt: caseLastSeen, referenceDate: lastSeen)
            let rawPID = (d["pid"] as? Int) ?? (d["prid"] as? Int)
            let pid = rawPID.flatMap { (1...Int(UInt16.max)).contains($0) ? UInt16($0) : nil }

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
                caseCharging: freshCaseChg,
                lastSeen: lastSeen,
                caseLastSeen: caseLastSeen,
                productID: pid
            )
        }

        if let levels = bestLevels, Date().timeIntervalSince(levels.lastSeen) <= staleTimeout {
            return levels
        }
        return nil
    }

    // MARK: - Bluetooth connect / disconnect

    var isConnected:  Bool    { btDevice()?.isConnected() ?? false }
    var deviceName:   String? { btDevice()?.name }

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
