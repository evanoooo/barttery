import Foundation
import IOKit
import IOBluetooth

struct AccessoryBattery: Equatable {
    let name: String
    let level: Int
    var charging: Bool
    var isApple: Bool = false
    /// Time of this device's last successful battery read, not its last redraw.
    var updatedAt: Date? = nil
    var chargingKnown: Bool = true

    func renamed(_ displayName: String) -> AccessoryBattery {
        AccessoryBattery(name: displayName, level: level, charging: charging,
                         isApple: isApple, updatedAt: updatedAt, chargingKnown: chargingKnown)
    }

    static func isHeadphoneName(_ lower: String) -> Bool {
        lower.contains("bud") || lower.contains("headphone") || lower.contains("earphone")
            || lower.contains("wh-") || lower.contains("wf-") || lower.contains("bose")
            || lower.contains("beats") || lower.contains("jabra") || lower.contains("shokz")
            || lower.contains("soundcore") || lower.contains("linkbuds") || lower.contains("headset")
    }

    static func isSupportedAccessoryName(_ lower: String) -> Bool {
        lower.contains("keyboard") || lower.contains("mouse") || lower.contains("trackpad")
            || isHeadphoneName(lower)
    }

    private var isKeyboard: Bool {
        let lower = name.lowercased()
        return lower.contains("keyboard") || lower.contains(" keys") || lower.contains("k380")
            || lower.contains("k780") || lower.contains("k800") || lower.contains("k850")
    }

    private var isHeadphones: Bool {
        Self.isHeadphoneName(name.lowercased())
    }

    var icon: String {
        let lower = name.lowercased()
        if isHeadphones               { return "headphones" }
        if isKeyboard                 { return "keyboard" }
        if lower.contains("trackpad") { return "rectangle.and.hand.point.up.left" }
        return isApple ? "magicmouse" : "computermouse"
    }

    var batteryDevice: BatteryDevice {
        let lower = name.lowercased()
        if isHeadphones               { return .headphones }
        if isKeyboard                 { return .keyboard }
        if lower.contains("trackpad") { return .trackpad }
        return .mouse
    }
}

class AccessoryReader: NSObject {
    var onUpdate: (([AccessoryBattery]) -> Void)?
    private var timer: Timer?
    private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]
    private var connectNotification: IOBluetoothUserNotification?
    private var lastKnownAccessories: [String: AccessoryBattery] = [:]

    deinit {
        timer?.invalidate()
        timer = nil
        connectNotification?.unregister()
        disconnectNotifications.values.forEach { $0.unregister() }
        disconnectNotifications.removeAll()
    }

    func startMonitoring() {
        connectNotification = IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(deviceConnected(_:device:))
        )
        read()
        // Poll every 5 s for the first minute (BT may not be ready at login), then every 180 s.
        var ticks = 0
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] t in
            self?.read()
            ticks += 1
            if ticks >= 12 {
                t.invalidate()
                self?.timer = Timer.scheduledTimer(withTimeInterval: 180, repeats: true) { [weak self] _ in
                    self?.read()
                }
                self?.timer?.tolerance = 30
            }
        }
        timer?.tolerance = 1
    }

    func readOnce() { read() }

    private func read() {
        readReturningFound(addr: "")
    }

    private func registerDisconnectNotifications(paired: [IOBluetoothDevice]) {
        var activeKeys = Set<String>()
        for device in paired {
            guard device.isConnected(), let rawName = device.name else { continue }
            guard AccessoryBattery.isSupportedAccessoryName(rawName.lowercased()) else { continue }
            let key = (device.addressString ?? rawName).lowercased()
            activeKeys.insert(key)
            if disconnectNotifications[key] == nil,
               let note = device.register(forDisconnectNotification: self, selector: #selector(deviceDisconnected(_:device:))) {
                disconnectNotifications[key] = note
            }
        }
        for key in disconnectNotifications.keys where !activeKeys.contains(key) {
            disconnectNotifications.removeValue(forKey: key)?.unregister()
        }
    }

    @objc private func deviceConnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        if let name = device.name {
            guard !AirPodsReader.isAirPods(name: name, address: device.addressString) else { return }
            let lower = name.lowercased()
            guard !lower.contains("iphone"), !lower.contains("ipad") else { return }
            guard AccessoryBattery.isSupportedAccessoryName(lower) else { return }
        }
        // IOKit HID service appears asynchronously after BT connects — retry until found.
        let addr = device.addressString?.lowercased() ?? ""
        retryUntilFound(addr: addr, attempts: 10, interval: 0.5)
    }

    private func retryUntilFound(addr: String, attempts: Int, interval: TimeInterval) {
        if readReturningFound(addr: addr) || attempts <= 1 { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak self] in
            self?.retryUntilFound(addr: addr, attempts: attempts - 1, interval: interval)
        }
    }

    // Returns true if the device with the given BT address appeared in IOKit.
    @discardableResult
    private func readReturningFound(addr: String) -> Bool {
        let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        var btNames: [String: String] = [:]
        var connectedNames = Set<String>()
        for d in paired {
            if let name = d.name {
                if let a = d.addressString {
                    btNames[a.lowercased()] = name
                }
                if d.isConnected() {
                    connectedNames.insert(name)
                }
            }
        }

        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("AppleDeviceManagementHIDEventService"),
            &iter
        ) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(iter) }

        var seen: [String: AccessoryBattery] = [:]
        var found = false
        var service = IOIteratorNext(iter)
        while service != IO_OBJECT_NULL {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iter)
            }
            var cfProps: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &cfProps, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let props = cfProps?.takeRetainedValue() as? [String: Any],
                  let battery = props["BatteryPercent"] as? Int, battery >= 0,
                  let product = props["Product"] as? String, !product.isEmpty
            else { continue }

            // Skip Logitech devices — handled by LogitechReader with better data.
            let vendorID = props["VendorID"] as? Int ?? 0
            guard vendorID != 0x046D else { continue }

            let lower = product.lowercased()
            guard AccessoryBattery.isSupportedAccessoryName(lower) else { continue }

            if seen[product] == nil {
                let devAddr = (props["DeviceAddress"] as? String)?.lowercased() ?? ""
                let displayName = btNames[devAddr] ?? product
                let flags = props["BatteryStatusFlags"] as? Int ?? 0
                let charging = (flags & 2) != 0
                let isAppleDevice = lower.contains("apple") || lower.contains("magic") || lower.contains("beats")
                seen[product] = AccessoryBattery(name: displayName, level: battery, charging: charging,
                                                 isApple: isAppleDevice, updatedAt: Date())
                if !addr.isEmpty && devAddr == addr { found = true }
            }
        }

        // Keep last known readings for devices that are still connected via Bluetooth
        for (key, item) in lastKnownAccessories where connectedNames.contains(item.name) {
            if seen[key] == nil {
                seen[key] = item
            }
        }
        lastKnownAccessories = seen

        let result = Array(seen.values).sorted { $0.name < $1.name }
        registerDisconnectNotifications(paired: paired)
        if Thread.isMainThread {
            onUpdate?(result)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.onUpdate?(result)
            }
        }
        return found
    }

    @objc private func deviceDisconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let key = (device.addressString ?? device.name ?? "").lowercased()
        if !key.isEmpty {
            disconnectNotifications.removeValue(forKey: key)?.unregister()
        }
        if let name = device.name {
            lastKnownAccessories = lastKnownAccessories.filter { $0.value.name != name }
        }
        read()
    }
}
