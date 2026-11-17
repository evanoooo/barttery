import CoreBluetooth
import Foundation

// Reads battery level from BLE peripherals via GATT Battery Service (UUID 0x180F).
// Works for any BLE device that exposes Battery Level (0x2A19) and is visible to
// CoreBluetooth (i.e. not exclusively managed by IOKit HID kernel driver).
// Reads PnP ID (0x2A50) from Device Information Service (0x180A) to identify Logitech
// devices (VendorID 0x046D). DeviceBatteryMonitor decides whether to suppress them in
// favour of LogitechReader's HID++ data, or keep them as fallback if HID++ is unavailable.
class BLEDeviceReader: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var onUpdate: (([AccessoryBattery]) -> Void)?
    /// Called when a peripheral is confirmed as Logitech via PnP ID.
    /// Passes (current BLE display name, product ID). DeviceBatteryMonitor uses this
    /// to suppress the BLE entry only when LogitechReader has actual battery data.
    var onLogiConfirmed: ((String, Int) -> Void)?

    private var central: CBCentralManager?
    private var peripherals:     [UUID: CBPeripheral]   = [:]
    private var battChars:       [UUID: CBCharacteristic] = [:]
    private var levels:          [UUID: Int]            = [:]
    private var previousLevels:  [UUID: Int]            = [:]
    private var outlierCounts:   [UUID: Int]            = [:]
    private var chargingStates:  [UUID: Bool]           = [:]
    private var chargingInferredAt: [UUID: Date]        = [:]
    private var measurementDates: [UUID: Date]         = [:]

    private static let battService   = CBUUID(string: "180F")
    private static let battCharUUID  = CBUUID(string: "2A19")
    private static let devInfoService = CBUUID(string: "180A")
    private static let pnpIDCharUUID  = CBUUID(string: "2A50")

    // Service UUIDs to query for already-connected peripherals.
    // 180A (Device Information) is intentionally excluded from probing — it's too generic
    // and matches phones, tablets, and other devices we don't want to show as accessories.
    private static let probedServices: [CBUUID] = [
        CBUUID(string: "180F"),  // Battery Service
        CBUUID(string: "1812"),  // HID
    ]

    func startMonitoring() {
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    deinit {
        for p in peripherals.values {
            p.delegate = nil
            if p.state == .connected || p.state == .connecting {
                central?.cancelPeripheralConnection(p)
            }
        }
    }

    func refresh() {
        guard central?.state == .poweredOn else { return }
        pruneStalePeripherals()
        connectExisting()
        for (id, ch) in battChars {
            if let p = peripherals[id], p.state == .connected {
                p.readValue(for: ch)
            }
        }
    }

    private func pruneStalePeripherals() {
        let now = Date()
        let staleTimeout: TimeInterval = 7200
        let staleIDs = measurementDates.compactMap { id, date -> UUID? in
            guard now.timeIntervalSince(date) > staleTimeout else { return nil }
            if let p = peripherals[id], p.state == .connected { return nil }
            return id
        }
        for id in staleIDs {
            remove(id)
        }
        if !staleIDs.isEmpty {
            publish()
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else { return }
        connectExisting()
    }

    private func connectExisting() {
        guard let central else { return }
        var seen = Set<UUID>()
        for svc in Self.probedServices {
            for p in central.retrieveConnectedPeripherals(withServices: [svc]) {
                guard seen.insert(p.identifier).inserted else { continue }
                if let existing = peripherals[p.identifier] {
                    if existing.state == .disconnected {
                        existing.delegate = self
                        central.connect(existing, options: nil)
                    }
                    continue
                }
                // iPhones and iPads are handled by IDeviceReader; AirPods/Beats by AirPodsReader.
                let lower = (p.name ?? "").lowercased()
                guard !lower.contains("iphone"), !lower.contains("ipad"),
                      !AirPodsReader.isAirPods(name: p.name, address: nil) else { continue }
                peripherals[p.identifier] = p
                p.delegate = self
                central.connect(p, options: nil)
            }
        }
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        // Discover Battery Service to read level, and Device Information Service to check VendorID.
        p.discoverServices([Self.battService, Self.devInfoService])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        remove(p.identifier)
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        remove(p.identifier)
        publish()
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for svc in p.services ?? [] {
            switch svc.uuid {
            case Self.battService:
                p.discoverCharacteristics([Self.battCharUUID], for: svc)
            case Self.devInfoService:
                p.discoverCharacteristics([Self.pnpIDCharUUID], for: svc)
            default:
                break
            }
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor svc: CBService, error: Error?) {
        if svc.uuid == Self.battService,
           let ch = svc.characteristics?.first(where: { $0.uuid == Self.battCharUUID }) {
            battChars[p.identifier] = ch
            p.readValue(for: ch)
            if ch.properties.contains(.notify) { p.setNotifyValue(true, for: ch) }
        } else if svc.uuid == Self.devInfoService,
                  let ch = svc.characteristics?.first(where: { $0.uuid == Self.pnpIDCharUUID }) {
            p.readValue(for: ch)
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard error == nil else { return }
        if ch.uuid == Self.pnpIDCharUUID {
            // PnP ID layout: [vendorIDSource(1), vendorID(2 LE), productID(2 LE), productVersion(2)]
            if let data = ch.value, data.count >= 5 {
                let vendorID  = UInt16(data[1]) | (UInt16(data[2]) << 8)
                let productID = Int(UInt16(data[3]) | (UInt16(data[4]) << 8))
                if vendorID == 0x046D {
                    // Notify DeviceBatteryMonitor; it decides whether to suppress this BLE entry
                    // (when LogitechReader has HID++ data) or keep it (as fallback when HID++ fails).
                    // CBCentralManager is on .main queue, so this callback is already on main.
                    let name = p.name ?? "Unknown Device"
                    onLogiConfirmed?(name, productID)
                }
            }
            return
        }

        guard ch.uuid == Self.battCharUUID, let raw = ch.value?.first else { return }
        guard recordBatteryLevel(Int(raw), for: p.identifier) else { return }
        publish()
    }

    @discardableResult
    func recordBatteryLevel(_ newLevel: Int, for id: UUID, at date: Date = Date()) -> Bool {
        // Reject obviously invalid readings: below 5% (device would disconnect before reaching
        // this level in practice). If an apparent sudden drop of >50 points occurs, require 2
        // consecutive confirmations to prevent latch-up when a device genuinely drained while away.
        guard (5...100).contains(newLevel) else { return false }
        if let prev = previousLevels[id], newLevel < prev - 50 {
            let count = (outlierCounts[id] ?? 0) + 1
            outlierCounts[id] = count
            if count < 2 { return false }
        }
        outlierCounts[id] = 0
        // Infer charging from trend: if level rose since the last reading, the device is charging.
        if let prev = previousLevels[id] {
            if newLevel > prev {
                chargingStates[id] = true
                chargingInferredAt[id] = date
            } else if newLevel < prev {
                chargingStates[id] = false
                chargingInferredAt.removeValue(forKey: id)
            }
        }
        previousLevels[id] = newLevel
        levels[id] = newLevel
        measurementDates[id] = date
        return true
    }

    func batteryReading(for id: UUID, name: String) -> AccessoryBattery? {
        guard let level = levels[id] else { return nil }
        var isCharging = chargingStates[id] ?? false
        if isCharging, let inferredAt = chargingInferredAt[id], Date().timeIntervalSince(inferredAt) > 900 {
            isCharging = false
            chargingStates[id] = false
        }
        return AccessoryBattery(name: name, level: level, charging: isCharging,
                                updatedAt: measurementDates[id], chargingKnown: false)
    }

    private func remove(_ id: UUID) {
        if let p = peripherals.removeValue(forKey: id) {
            p.delegate = nil
            if p.state == .connected || p.state == .connecting {
                central?.cancelPeripheralConnection(p)
            }
        }
        battChars.removeValue(forKey: id)
        levels.removeValue(forKey: id)
        previousLevels.removeValue(forKey: id)
        outlierCounts.removeValue(forKey: id)
        chargingStates.removeValue(forKey: id)
        chargingInferredAt.removeValue(forKey: id)
        measurementDates.removeValue(forKey: id)
    }

    private func publish() {
        let items = peripherals.values.compactMap { p -> AccessoryBattery? in
            batteryReading(for: p.identifier, name: p.name ?? "Unknown Device")
        }.sorted { $0.name < $1.name }
        onUpdate?(items)
    }
}
