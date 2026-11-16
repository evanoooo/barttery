import IOBluetooth
import Foundation
import ObjectiveC

// Reads battery level from Bluetooth Classic headphones via native/private IOBluetoothDevice methods.
// Supports single-cell headphones, multi-cell headsets (HFP +IPHONEACCEV / +XAPLEACC),
// and TWS earbuds reporting left/right/case batteries.
class BTHeadphonesReader: NSObject {
    var onUpdate: (([AccessoryBattery]) -> Void)?

    private var connectNote: IOBluetoothUserNotification?
    private var disconnectNotes: [IOBluetoothUserNotification] = []
    private var timer: Timer?
    private var lastKnownHeadphones: [String: AccessoryBattery] = [:]

    func startMonitoring() {
        connectNote = IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(deviceConnected(_:device:))
        )
        read()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.read()
        }
        timer?.tolerance = 15
    }

    func readOnce() { read() }

    private func read() {
        guard let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else { return }
        var result: [AccessoryBattery] = []
        var connectedNames = Set<String>()

        for device in devices {
            guard device.isConnected(), let name = device.name else { continue }
            let lower = name.lowercased()
            // AirPods are handled by AirPodsReader
            guard !AirPodsReader.isAirPods(name: name, address: device.addressString) else { continue }
            // Skip keyboards, mice, trackpads which are handled by AccessoryReader
            guard !lower.contains("keyboard"), !lower.contains("mouse"), !lower.contains("trackpad") else { continue }

            connectedNames.insert(name)

            if let batteryInfo = readNativeHeadphoneBattery(device), batteryInfo.level > 0, batteryInfo.level <= 100 {
                let reading = AccessoryBattery(
                    name: name,
                    level: batteryInfo.level,
                    charging: batteryInfo.charging,
                    updatedAt: Date(),
                    chargingKnown: batteryInfo.chargingKnown
                )
                lastKnownHeadphones[name] = reading
                result.append(reading)
            } else if let cached = lastKnownHeadphones[name] {
                // Device is still connected to macOS! Keep last known battery reading instead of flickering to empty
                result.append(cached)
            }
        }

        // Clean up devices that are truly no longer connected
        lastKnownHeadphones = lastKnownHeadphones.filter { connectedNames.contains($0.key) }

        DispatchQueue.main.async { [weak self] in self?.onUpdate?(result) }
    }

    private struct BatteryInfo {
        let level: Int
        let charging: Bool
        let chargingKnown: Bool
    }

    // Comprehensive inspection of macOS native IOBluetoothDevice battery selectors
    private func readNativeHeadphoneBattery(_ device: IOBluetoothDevice) -> BatteryInfo? {
        // 1. Check for split L/R/Case earbuds (e.g. Beats Studio Buds, Galaxy Buds, Sony WF, etc.)
        let left = readIntProperty(device, selectors: ["batteryPercentLeft", "leftBatteryLevel"])
        let right = readIntProperty(device, selectors: ["batteryPercentRight", "rightBatteryLevel"])
        let caseLevel = readIntProperty(device, selectors: ["batteryPercentCase", "caseBatteryLevel"])

        var levels: [Int] = []
        if let l = left, l > 0, l <= 100 { levels.append(l) }
        if let r = right, r > 0, r <= 100 { levels.append(r) }
        
        if !levels.isEmpty {
            // For earbuds in use, take the minimum of left/right as the alertable level
            let minLevel = levels.min() ?? 100
            let charging = readBoolProperty(device, selectors: ["isCharging", "batteryIsCharging"]) ?? false
            return BatteryInfo(level: minLevel, charging: charging, chargingKnown: charging)
        }

        // 2. Check for single/combined battery (standard over-ear/on-ear Bluetooth headphones)
        let singleSelectors = [
            "batteryPercentSingle",
            "batteryPercentCombined",
            "headsetBattery",
            "batteryLevel",
            "batteryPercent"
        ]
        if let single = readIntProperty(device, selectors: singleSelectors), single > 0, single <= 100 {
            let charging = readBoolProperty(device, selectors: ["isCharging", "batteryIsCharging"]) ?? false
            return BatteryInfo(level: single, charging: charging, chargingKnown: charging)
        }

        // 3. Fallback to case level if available alone
        if let c = caseLevel, c > 0, c <= 100 {
            return BatteryInfo(level: c, charging: true, chargingKnown: true)
        }

        return nil
    }

    private func readIntProperty(_ obj: AnyObject, selectors: [String]) -> Int? {
        for name in selectors {
            let sel = NSSelectorFromString(name)
            guard obj.responds(to: sel) else { continue }
            if let val = callIntSelector(obj, sel), val > 0, val <= 100 {
                return val
            }
        }
        return nil
    }

    private func readBoolProperty(_ obj: AnyObject, selectors: [String]) -> Bool? {
        for name in selectors {
            let sel = NSSelectorFromString(name)
            guard obj.responds(to: sel) else { continue }
            guard let imp = class_getMethodImplementation(type(of: obj), sel) else { continue }
            typealias Fn = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(imp, to: Fn.self)(obj, sel)
        }
        return nil
    }

    private func callIntSelector(_ obj: AnyObject, _ sel: Selector) -> Int? {
        guard let imp = class_getMethodImplementation(type(of: obj), sel) else { return nil }
        typealias Fn = @convention(c) (AnyObject, Selector) -> Int32
        return Int(unsafeBitCast(imp, to: Fn.self)(obj, sel))
    }

    @objc private func deviceConnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.read() }
        if let n = device.register(forDisconnectNotification: self, selector: #selector(deviceDisconnected(_:device:))) {
            disconnectNotes.append(n)
        }
    }

    @objc private func deviceDisconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        note.unregister()
        disconnectNotes.removeAll { $0 === note }
        read()
    }

    deinit {
        timer?.invalidate()
        connectNote?.unregister()
        disconnectNotes.forEach { $0.unregister() }
        disconnectNotes.removeAll()
    }
}
