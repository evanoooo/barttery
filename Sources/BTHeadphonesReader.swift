import AppKit
import IOBluetooth
import Foundation
import ObjectiveC

// Reads battery level from Bluetooth Classic headphones via native/private IOBluetoothDevice methods.
// Supports single-cell headphones, multi-cell headsets (HFP +IPHONEACCEV / +XAPLEACC),
// and TWS earbuds reporting left/right/case batteries.
class BTHeadphonesReader: NSObject {
    var onUpdate: (([AccessoryBattery]) -> Void)?

    private var connectNote: IOBluetoothUserNotification?
    private var disconnectNotes: [String: IOBluetoothUserNotification] = [:]
    private var timer: Timer?
    private var lastKnownHeadphones: [String: AccessoryBattery] = [:]

    private static let leftSelectors     = ["batteryPercentLeft", "leftBatteryLevel"].map(NSSelectorFromString)
    private static let rightSelectors    = ["batteryPercentRight", "rightBatteryLevel"].map(NSSelectorFromString)
    private static let caseSelectors     = ["batteryPercentCase", "caseBatteryLevel"].map(NSSelectorFromString)
    private static let singleSelectors   = [
        "batteryPercentSingle",
        "batteryPercentCombined",
        "headsetBattery",
        "batteryLevel",
        "batteryPercent"
    ].map(NSSelectorFromString)
    private static let chargingSelectors = ["isCharging", "batteryIsCharging"].map(NSSelectorFromString)

    func startMonitoring() {
        connectNote = IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(deviceConnected(_:device:))
        )
        read()
        setupTimer()

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(handleSleep), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(handleWake), name: NSWorkspace.didWakeNotification, object: nil)
    }

    private func setupTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.read()
        }
        timer?.tolerance = 15
    }

    @objc private func handleSleep() {
        timer?.invalidate()
        timer = nil
    }

    @objc private func handleWake() {
        setupTimer()
        read()
    }

    func readOnce() { read() }

    private func read() {
        guard let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else { return }
        var result: [AccessoryBattery] = []
        var connectedNames = Set<String>()
        var activeKeys = Set<String>()

        for device in devices {
            guard device.isConnected(), let name = device.name else { continue }
            guard isCandidateHeadphone(name: name, address: device.addressString) else { continue }

            connectedNames.insert(name)
            let key = (device.addressString ?? name).lowercased()
            activeKeys.insert(key)
            if disconnectNotes[key] == nil,
               let n = device.register(forDisconnectNotification: self, selector: #selector(deviceDisconnected(_:device:))) {
                disconnectNotes[key] = n
            }

            if let batteryInfo = readNativeHeadphoneBattery(device), (1...100).contains(batteryInfo.level) {
                let reading = AccessoryBattery(
                    name: name,
                    level: batteryInfo.level,
                    charging: batteryInfo.charging,
                    updatedAt: Date(),
                    chargingKnown: batteryInfo.chargingKnown,
                    device: .headphones
                )
                // Key by address (with name fallback) to avoid collisions between same-named devices.
                lastKnownHeadphones[key] = reading
                result.append(reading)
            } else if let cached = lastKnownHeadphones[key] {
                // Device is still connected to macOS! Keep last known battery reading instead of flickering to empty
                result.append(cached)
            }
        }

        // Clean up devices that are truly no longer connected (key is address-based, same as activeKeys)
        lastKnownHeadphones = lastKnownHeadphones.filter { activeKeys.contains($0.key) }
        for key in disconnectNotes.keys where !activeKeys.contains(key) {
            disconnectNotes.removeValue(forKey: key)?.unregister()
        }

        if activeKeys.isEmpty && timer?.timeInterval != 300 {
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
                self?.read()
            }
            timer?.tolerance = 60
        } else if !activeKeys.isEmpty && timer?.timeInterval != 60 {
            setupTimer()
        }

        if Thread.isMainThread {
            onUpdate?(result)
        } else {
            DispatchQueue.main.async { [weak self] in self?.onUpdate?(result) }
        }
    }

    private func isCandidateHeadphone(name: String, address: String?) -> Bool {
        let lower = name.lowercased()
        // AirPods are handled by AirPodsReader
        guard !AirPodsReader.isAirPods(name: name, address: address) else { return false }
        // Skip keyboards, mice, trackpads which are handled by AccessoryReader
        guard !lower.contains("keyboard"), !lower.contains("mouse"), !lower.contains("trackpad") else { return false }
        return true
    }

    private struct BatteryInfo {
        let level: Int
        let charging: Bool
        let chargingKnown: Bool
    }

    // Comprehensive inspection of macOS native IOBluetoothDevice battery selectors
    private func readNativeHeadphoneBattery(_ device: IOBluetoothDevice) -> BatteryInfo? {
        // 1. Check for split L/R/Case earbuds (e.g. Beats Studio Buds, Galaxy Buds, Sony WF, etc.)
        let left = readIntProperty(device, selectors: Self.leftSelectors)
        let right = readIntProperty(device, selectors: Self.rightSelectors)
        let caseLevel = readIntProperty(device, selectors: Self.caseSelectors)

        var levels: [Int] = []
        if let l = left, (1...100).contains(l) { levels.append(l) }
        if let r = right, (1...100).contains(r) { levels.append(r) }

        if !levels.isEmpty {
            // For earbuds in use, take the minimum of left/right as the alertable level
            let minLevel = levels.min() ?? 100
            let isChargingVal = readBoolProperty(device, selectors: Self.chargingSelectors)
            let charging = isChargingVal ?? false
            let chargingKnown = (isChargingVal != nil)
            return BatteryInfo(level: minLevel, charging: charging, chargingKnown: chargingKnown)
        }

        // 2. Check for single/combined battery (standard over-ear/on-ear Bluetooth headphones)
        // A return value of 0 from private selectors indicates unsupported/no battery data; ignore it.
        if let single = readIntProperty(device, selectors: Self.singleSelectors), (1...100).contains(single) {
            let isChargingVal = readBoolProperty(device, selectors: Self.chargingSelectors)
            let charging = isChargingVal ?? false
            let chargingKnown = (isChargingVal != nil)
            return BatteryInfo(level: single, charging: charging, chargingKnown: chargingKnown)
        }

        // 3. Fallback to case level if available alone
        if let c = caseLevel, (1...100).contains(c) {
            let isChargingVal = readBoolProperty(device, selectors: Self.chargingSelectors)
            return BatteryInfo(level: c, charging: isChargingVal ?? false, chargingKnown: isChargingVal != nil)
        }

        return nil
    }

    private func readIntProperty(_ obj: AnyObject, selectors: [Selector]) -> Int? {
        for sel in selectors {
            guard obj.responds(to: sel) else { continue }
            if let val = callIntSelector(obj, sel), (1...100).contains(val) {
                return val
            }
        }
        return nil
    }

    private func readBoolProperty(_ obj: AnyObject, selectors: [Selector]) -> Bool? {
        let cls: AnyClass = type(of: obj)
        for sel in selectors {
            guard obj.responds(to: sel),
                  let method = class_getInstanceMethod(cls, sel) else { continue }
            let retTypePtr = method_copyReturnType(method)
            defer { free(retTypePtr) }
            let imp = method_getImplementation(method)
            let retType = String(cString: retTypePtr)
            switch retType {
            case "B":
                typealias Fn = @convention(c) (AnyObject, Selector) -> Bool
                return unsafeBitCast(imp, to: Fn.self)(obj, sel)
            case "c", "C":
                typealias Fn = @convention(c) (AnyObject, Selector) -> UInt8
                return unsafeBitCast(imp, to: Fn.self)(obj, sel) != 0
            case "i", "I":
                typealias Fn = @convention(c) (AnyObject, Selector) -> Int32
                return unsafeBitCast(imp, to: Fn.self)(obj, sel) != 0
            case "q", "Q":
                typealias Fn = @convention(c) (AnyObject, Selector) -> Int64
                return unsafeBitCast(imp, to: Fn.self)(obj, sel) != 0
            case "@":
                typealias Fn = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
                let raw = unsafeBitCast(imp, to: Fn.self)(obj, sel)?.takeUnretainedValue()
                return (raw as? NSNumber)?.boolValue
            default:
                continue
            }
        }
        return nil
    }

    private func callIntSelector(_ obj: AnyObject, _ sel: Selector) -> Int? {
        guard let method = class_getInstanceMethod(type(of: obj), sel) else { return nil }
        let retTypePtr = method_copyReturnType(method)
        defer { free(retTypePtr) }
        let imp = method_getImplementation(method)
        let retType = String(cString: retTypePtr)
        switch retType {
        case "c":
            typealias Fn = @convention(c) (AnyObject, Selector) -> Int8
            return Int(unsafeBitCast(imp, to: Fn.self)(obj, sel))
        case "C":
            typealias Fn = @convention(c) (AnyObject, Selector) -> UInt8
            return Int(unsafeBitCast(imp, to: Fn.self)(obj, sel))
        case "s":
            typealias Fn = @convention(c) (AnyObject, Selector) -> Int16
            return Int(unsafeBitCast(imp, to: Fn.self)(obj, sel))
        case "S":
            typealias Fn = @convention(c) (AnyObject, Selector) -> UInt16
            return Int(unsafeBitCast(imp, to: Fn.self)(obj, sel))
        case "i":
            typealias Fn = @convention(c) (AnyObject, Selector) -> Int32
            return Int(unsafeBitCast(imp, to: Fn.self)(obj, sel))
        case "I":
            typealias Fn = @convention(c) (AnyObject, Selector) -> UInt32
            return Int(unsafeBitCast(imp, to: Fn.self)(obj, sel))
        case "q":
            typealias Fn = @convention(c) (AnyObject, Selector) -> Int64
            return Int(exactly: unsafeBitCast(imp, to: Fn.self)(obj, sel))
        case "Q":
            typealias Fn = @convention(c) (AnyObject, Selector) -> UInt64
            return Int(exactly: unsafeBitCast(imp, to: Fn.self)(obj, sel))
        case "@":
            typealias Fn = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
            let raw = unsafeBitCast(imp, to: Fn.self)(obj, sel)?.takeUnretainedValue()
            return (raw as? NSNumber)?.intValue
        default:
            return nil
        }
    }

    @objc private func deviceConnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard let name = device.name, isCandidateHeadphone(name: name, address: device.addressString) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let key = (device.addressString ?? name).lowercased()
            if self.disconnectNotes[key] == nil,
               let n = device.register(forDisconnectNotification: self, selector: #selector(self.deviceDisconnected(_:device:))) {
                self.disconnectNotes[key] = n
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.read() }
        }
    }

    @objc private func deviceDisconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let key = (device.addressString ?? device.name ?? "").lowercased()
            if !key.isEmpty {
                self.disconnectNotes.removeValue(forKey: key)?.unregister()
            } else {
                note.unregister()
            }
            self.read()
        }
    }

    deinit {
        timer?.invalidate()
        timer = nil
        connectNote?.unregister()
        disconnectNotes.values.forEach { $0.unregister() }
        disconnectNotes.removeAll()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}
