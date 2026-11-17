import Foundation
import AppKit
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
    var device: BatteryDevice? = nil

    func renamed(_ displayName: String) -> AccessoryBattery {
        AccessoryBattery(name: displayName, level: level, charging: charging,
                         isApple: isApple, updatedAt: updatedAt, chargingKnown: chargingKnown,
                         device: device)
    }

    static func isHeadphoneName(_ lower: String) -> Bool {
        lower.contains("bud") || lower.contains("headphone") || lower.contains("earphone")
            || lower.contains("wh-") || lower.contains("wf-") || lower.contains("bose")
            || lower.contains("beats") || lower.contains("jabra") || lower.contains("shokz")
            || lower.contains("soundcore") || lower.contains("linkbuds") || lower.contains("headset")
            || lower.contains("音箱") || lower.contains("耳机") || lower.contains("speaker")
            || lower.contains("audio") || lower.contains("sound")
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

    private var isMouse: Bool {
        let lower = name.lowercased()
        return lower.contains("mouse") || lower.contains("trackball") || lower.contains("master")
            || lower.contains("anywhere") || lower.contains("g304") || lower.contains("g502")
            || lower.contains("gpro") || lower.contains("g pro") || lower.contains("superlight")
    }

    private var isHeadphones: Bool {
        Self.isHeadphoneName(name.lowercased())
    }

    var icon: String {
        if device == .headphones || isHeadphones { return "headphones" }
        if device == .keyboard || isKeyboard     { return "keyboard" }
        if device == .trackpad || name.lowercased().contains("trackpad") { return "rectangle.and.hand.point.up.left" }
        if device == .mouse || isMouse           { return isApple ? "magicmouse" : "computermouse" }
        return isApple ? "magicmouse" : "computermouse"
    }

    var batteryDevice: BatteryDevice {
        if let device { return device }
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
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    deinit {
        timer?.invalidate()
        timer = nil
        connectNotification?.unregister()
        disconnectNotifications.values.forEach { $0.unregister() }
        disconnectNotifications.removeAll()
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }

    func startMonitoring() {
        timer?.invalidate()
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

        let center = NSWorkspace.shared.notificationCenter
        if sleepObserver == nil {
            sleepObserver = center.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.timer?.invalidate()
                self?.timer = nil
            }
        }
        if wakeObserver == nil {
            wakeObserver = center.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.startMonitoring()
            }
        }
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
                  let battery = props["BatteryPercent"] as? Int, (1...100).contains(battery),
                  let product = props["Product"] as? String, !product.isEmpty
            else { continue }

            // Skip Logitech devices — handled by LogitechReader with better data.
            let vendorID = props["VendorID"] as? Int ?? 0
            guard vendorID != 0x046D else { continue }

            let lower = product.lowercased()
            guard AccessoryBattery.isSupportedAccessoryName(lower) else { continue }

            let devAddr = (props["DeviceAddress"] as? String)?.lowercased() ?? ""
            let entryKey = devAddr.isEmpty ? product : devAddr
            if seen[entryKey] == nil {
                let displayName = btNames[devAddr] ?? product
                let flags = props["BatteryStatusFlags"] as? Int ?? 0
                let charging = (flags & 2) != 0
                let isAppleDevice = lower.contains("apple") || lower.contains("magic") || lower.contains("beats")
                seen[entryKey] = AccessoryBattery(name: displayName, level: battery, charging: charging,
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
