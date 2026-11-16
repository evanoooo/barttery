import Foundation
import AppKit
import IOBluetooth
import Combine

class DeviceBatteryMonitor: ObservableObject {
    @Published var macBattery:    MacBattery?  = nil
    private(set) var macBatteryUpdatedAt: Date?
    @Published var macName:       String       = Host.current().localizedName ?? "Mac"
    @Published var phoneBattery:  Int?         = cachedBattery("phone")
    @Published var phoneCharging: Bool         = false
    @Published var phoneName:     String       = UserDefaults.standard.string(forKey: "phone.lastName") ?? "iPhone"
    @Published var padBattery:    Int?         = cachedBattery("pad")
    @Published var padCharging:   Bool         = false
    @Published var padName:       String       = UserDefaults.standard.string(forKey: "pad.lastName") ?? "iPad"
    @Published var watchBattery:  WatchBattery? = WatchBattery.cached()
    @Published var menuBarIcon:   NSImage      = renderPlugIcon()
    @Published var syncTimes:     [String: Date] = {
        let ud = UserDefaults.standard
        var times: [String: Date] = [:]
        for key in ["phone", "pad", "watch", "airPods"] {
            let maxAge: TimeInterval = (key == "airPods") ? 14400 : 1800
            if let t = ud.object(forKey: "\(key).lastSyncTime") as? Date,
               Date().timeIntervalSince(t) < maxAge {
                times[key] = t
            }
        }
        return times
    }()

    @Published var airPodsBattery:   AirPodsBattery? = cachedAirPodsBattery()
    @Published var airPodsConnected: Bool = false
    @Published var airPodsName:      String = UserDefaults.standard.string(forKey: "airPods.lastName") ?? "AirPods"
    @Published var accessories:      [AccessoryBattery] = cachedAccessories()
    @Published var isRefreshing:     Bool = false

    var hasAnyDevices: Bool {
        macBattery != nil || airPodsBattery != nil || !accessories.isEmpty ||
        phoneBattery != nil || padBattery != nil || watchBattery != nil
    }

    private var macReader:          MacBatteryReader?
    private var ideviceReader:      IDeviceReader?
    private var airPodsReader:      AirPodsReader?
    private var accessoryReader:    AccessoryReader?
    private var bleReader:          BLEDeviceReader?
    private var logiReader:         LogitechReader?
    private var btHeadphonesReader: BTHeadphonesReader?
    private var refreshTimer:    Timer?
    private var retryTimer:      Timer?
    private var refreshEndWork:  DispatchWorkItem?
    private var isPopupOpen:     Bool = false
    private var iconCancellable: AnyCancellable?
    private var wakeObserver:    NSObjectProtocol?
    private var lastIconKey:     (level: Int?, state: ChargeState?, showPct: Bool)?

    // Separate buckets merged into `accessories` for display.
    private var appleAccessories: [AccessoryBattery] = []
    private var logiAccessories:  [AccessoryBattery] = []
    private var bleAccessories:   [AccessoryBattery] = []
    private var btHeadphones:     [AccessoryBattery] = []
    private var logiCache = LogitechBatteryCache()
    private var logiChargingCache = LogitechChargingCache()
    // BLE display name → canonical Logitech name, populated via PnP ID reads.
    // Used to suppress a BLE entry only when LogitechReader has actual battery data.
    private var bleLogiMapping:   [String: String]   = [:]

    init() {
        setupMac()
        setupIDevice()
        setupAirPods()
        setupAccessories()
        setupBLEDevices()
        setupLogitech()
        setupBTHeadphones()
        iconCancellable = AppSettings.shared.$showPercentageInMenuBar.sink { [weak self] _ in
            DispatchQueue.main.async { self?.rebuildIcon() }
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 90, repeats: true) { [weak self] _ in
            guard let self, !self.isPopupOpen else { return }
            self.refresh()
        }
        refreshTimer?.tolerance = 15
        // Timers don't fire during sleep, so Logitech/BLE/BT accessories can sit stale
        // for as long as the Mac was asleep. Force an immediate re-poll on wake.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.macReader?.readNow()
            self.pruneStaleSyncTimes()
            // Stagger peripheral refresh by 5s to allow Bluetooth stack to ready
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.accessoryReader?.readOnce()
                self?.bleReader?.refresh()
                self?.logiReader?.refresh()
                self?.btHeadphonesReader?.readOnce()
                self?.ideviceReader?.scanNow()
            }
        }
    }

    deinit {
        refreshTimer?.invalidate()
        retryTimer?.invalidate()
        refreshEndWork?.cancel()
        iconCancellable?.cancel()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    func refresh(userInitiated: Bool = false) {
        if userInitiated || isPopupOpen {
            if !isRefreshing { isRefreshing = true }
            refreshEndWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.isRefreshing = false
                self?.refreshEndWork = nil
            }
            refreshEndWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
        }
        macReader?.readNow()
        accessoryReader?.readOnce()
        bleReader?.refresh()
        logiReader?.refresh()
        btHeadphonesReader?.readOnce()
        ideviceReader?.scanNow()
        pruneStaleSyncTimes()
    }

    func onPopupOpen() {
        isPopupOpen = true
        let openTime = Date()
        airPodsReader?.refreshPlist()
        airPodsReader?.startScanning()
        // Restart wedged bartbeat when either phone or Watch data looks stale.
        let phoneAge = syncTimes[BatteryDevice.phone.rawValue].map { openTime.timeIntervalSince($0) }
        let watchAge = syncTimes[BatteryDevice.watch.rawValue].map { openTime.timeIntervalSince($0) }
        let needsKick = (phoneAge.map { $0 > 120 } ?? (phoneBattery != nil)) ||
            (watchAge.map { $0 > 120 } ?? (watchBattery != nil))
        if needsKick {
            ideviceReader?.forceReconnect()
        }
        refresh()
        retryTimer?.invalidate()
        retryTimer = nil
        var attempts = 0
        retryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            attempts += 1
            let hasFreshUpdate: Bool
            if needsKick {
                let phoneFresh = self.syncTimes[BatteryDevice.phone.rawValue].map { $0 > openTime } ?? false
                let watchFresh = self.syncTimes[BatteryDevice.watch.rawValue].map { $0 > openTime } ?? false
                hasFreshUpdate = phoneFresh || watchFresh
            } else {
                hasFreshUpdate = self.syncTimes.values.contains(where: { $0 > openTime })
            }
            if attempts >= 3 || hasFreshUpdate {
                t.invalidate()
                self.retryTimer = nil
            } else {
                self.refresh()
            }
        }
    }

    func onPopupClose() {
        isPopupOpen = false
        retryTimer?.invalidate()
        retryTimer = nil
        refreshEndWork?.cancel()
        refreshEndWork = nil
        if isRefreshing { isRefreshing = false }
    }

    /// Hide phone/pad/watch rows whose last sync is older than 30 minutes.
    private func pruneStaleSyncTimes() {
        let timeout: TimeInterval = 1800
        let now = Date()
        if let t = syncTimes[BatteryDevice.phone.rawValue], now.timeIntervalSince(t) > timeout {
            phoneBattery = nil
            syncTimes.removeValue(forKey: BatteryDevice.phone.rawValue)
        }
        if let t = syncTimes[BatteryDevice.pad.rawValue], now.timeIntervalSince(t) > timeout {
            padBattery = nil
            syncTimes.removeValue(forKey: BatteryDevice.pad.rawValue)
        }
        if let t = syncTimes[BatteryDevice.watch.rawValue], now.timeIntervalSince(t) > timeout {
            watchBattery = nil
            syncTimes.removeValue(forKey: BatteryDevice.watch.rawValue)
        }
        if let t = syncTimes[BatteryDevice.airPods.rawValue], now.timeIntervalSince(t) > 14400 {
            airPodsBattery = nil
            syncTimes.removeValue(forKey: BatteryDevice.airPods.rawValue)
        }
    }

    // MARK: - Setup

    private func setupMac() {
        let reader = MacBatteryReader()
        reader.onUpdate = { [weak self] battery in
            guard let self else { return }
            self.macBatteryUpdatedAt = battery == nil ? nil : Date()
            if self.macBattery != battery {
                self.macBattery = battery
                self.rebuildIcon()
            }
            if let battery = battery {
                NotificationManager.shared.check(
                    device: .mac,
                    level: battery.level,
                    isCharging: battery.state == .charging
                )
            }
        }
        reader.start()
        macReader = reader
    }

    private func setupIDevice() {

        let reader = IDeviceReader()

        reader.onPhoneUpdate = { [weak self] level, charging, name in
            let apply = {
                guard let self else { return }
                let newCharging = charging ?? false
                if self.phoneBattery != level { self.phoneBattery = level }
                if self.phoneCharging != newCharging { self.phoneCharging = newCharging }
                if let name, self.phoneName != name { self.phoneName = name }
                if let level {
                    self.syncTimes[BatteryDevice.phone.rawValue] = Date()
                    NotificationManager.shared.check(
                        device: .phone,
                        level: level,
                        isCharging: newCharging
                    )
                } else {
                    self.syncTimes.removeValue(forKey: BatteryDevice.phone.rawValue)
                }
            }
            if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
        }

        reader.onPadUpdate = { [weak self] level, charging, name in
            let apply = {
                guard let self else { return }
                let newCharging = charging ?? false
                if self.padBattery != level { self.padBattery = level }
                if self.padCharging != newCharging { self.padCharging = newCharging }
                if let name, self.padName != name { self.padName = name }
                if let level {
                    self.syncTimes[BatteryDevice.pad.rawValue] = Date()
                    NotificationManager.shared.check(
                        device: .pad,
                        level: level,
                        isCharging: newCharging
                    )
                } else {
                    self.syncTimes.removeValue(forKey: BatteryDevice.pad.rawValue)
                }
            }
            if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
        }

        reader.onWatchUpdate = { [weak self] watch in
            let apply = {
                guard let self else { return }
                if self.watchBattery != watch { self.watchBattery = watch }
                if let watch {
                    self.syncTimes[BatteryDevice.watch.rawValue] = watch.updatedAt
                    NotificationManager.shared.check(
                        device: .watch,
                        level: watch.level,
                        isCharging: watch.isCharging
                    )
                } else {
                    self.syncTimes.removeValue(forKey: BatteryDevice.watch.rawValue)
                }
            }
            if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
        }

        reader.start()
        ideviceReader = reader
    }

    var displayMacName: String {
        if macName == airPodsName || macName == phoneName {
            return "\(macName) (Mac)"
        }
        return macName
    }

    var displayPhoneName: String {
        if phoneName == macName || phoneName == airPodsName {
            return "\(phoneName) (iPhone)"
        }
        return phoneName
    }

    var displayAirPodsName: String {
        let lower = airPodsName.lowercased()
        if !lower.contains("airpod") && !lower.contains("beats") && !lower.contains("耳") {
            return "\(airPodsName) (AirPods Pro)"
        }
        return airPodsName
    }

    private func setupAirPods() {
        if let cached = cachedAirPodsBattery() {
            self.airPodsBattery = cached
            if let name = UserDefaults.standard.string(forKey: "airPods.lastName") {
                self.airPodsName = name
            }
        }
        let reader = AirPodsReader()
        reader.onConnect = { [weak self] name in
            guard let self else { return }
            if self.airPodsName != name {
                self.airPodsName = name
                UserDefaults.standard.set(name, forKey: "airPods.lastName")
            }
        }
        reader.onUpdate = { [weak self] battery in
            guard let self else { return }
            if let battery {
                if self.airPodsBattery != battery {
                    self.airPodsBattery = battery
                }
                let connected = reader.isConnected
                if self.airPodsConnected != connected {
                    self.airPodsConnected = connected
                }
                self.syncTimes[BatteryDevice.airPods.rawValue] = Date()
                saveCachedAirPodsBattery(battery)
            }
            if let name = reader.deviceName, self.airPodsName != name {
                self.airPodsName = name
                UserDefaults.standard.set(name, forKey: "airPods.lastName")
            }
            if let battery,
               let minLevel = [battery.left, battery.right].compactMap({ $0 }).min() {
                NotificationManager.shared.check(
                    device: .airPods,
                    level: minLevel,
                    isCharging: battery.leftCharging || battery.rightCharging
                )
            }
        }
        reader.startMonitoring()
        airPodsReader = reader
    }

    private func setupAccessories() {
        let reader = AccessoryReader()
        reader.onUpdate = { [weak self] items in
            guard let self else { return }
            appleAccessories = items
            mergeAccessories()
            let cache = items.map { ["name": $0.name, "level": $0.level] as [String: Any] }
            UserDefaults.standard.set(cache, forKey: "accessories.last")
            UserDefaults.standard.set(Date(), forKey: "accessories.lastSyncTime")
            for item in items {
                syncTimes[item.batteryDevice.rawValue] = Date()
                NotificationManager.shared.check(device: item.batteryDevice, level: item.level,
                                                 isCharging: item.chargingKnown && item.charging)
            }
        }
        reader.startMonitoring()
        accessoryReader = reader
    }

    private func setupBLEDevices() {
        let reader = BLEDeviceReader()
        reader.onUpdate = { [weak self] items in
            guard let self else { return }
            bleAccessories = items
            mergeAccessories()
            let logiCanonical = Set(logiAccessories.map { $0.name })
            for item in items {
                let canonical = bleLogiMapping[item.name] ?? LogitechReader.canonicalName(for: item.name) ?? item.name
                logiReader?.hintLevel(item.level, forDevice: canonical)
                guard !logiCanonical.contains(canonical) else { continue }
                syncTimes[item.batteryDevice.rawValue] = Date()
                let resolved = logiChargingCache.applying(to: item, canonicalName: canonical)
                NotificationManager.shared.check(device: resolved.batteryDevice, level: resolved.level,
                                                 isCharging: resolved.chargingKnown && resolved.charging)
            }
        }
        reader.onLogiConfirmed = { [weak self] bleName, pid in
            guard let self else { return }
            if let canonical = LogitechReader.supportedPIDs[pid] {
                bleLogiMapping[bleName] = canonical
                mergeAccessories()
            }
        }
        reader.startMonitoring()
        bleReader = reader
    }

    private func setupLogitech() {
        let reader = LogitechReader()
        reader.onDevicesFound = { [weak self] names in
            guard let self else { return }
            // Drop cached data for devices that are no longer visible in IOKit.
            logiCache.retainVisible(names)
            logiChargingCache.retainVisible(names)
            mergeAccessories()
        }
        reader.onChargingUpdate = { [weak self] readings in
            guard let self else { return }
            logiChargingCache.record(readings)
            mergeAccessories()
        }
        reader.onUpdate = { [weak self] items in
            guard let self else { return }
            logiCache.record(items)
            mergeAccessories()
            for item in items {
                syncTimes[item.batteryDevice.rawValue] = Date()
                NotificationManager.shared.check(device: item.batteryDevice, level: item.level,
                                                 isCharging: item.chargingKnown && item.charging)
            }
        }
        reader.startMonitoring()
        logiReader = reader
    }

    private func setupBTHeadphones() {
        let reader = BTHeadphonesReader()
        reader.onUpdate = { [weak self] items in
            guard let self else { return }
            btHeadphones = items
            mergeAccessories()
            for item in items {
                syncTimes[item.batteryDevice.rawValue] = Date()
                let canonical = LogitechReader.canonicalName(for: item.name) ?? item.name
                let resolved = logiChargingCache.applying(to: item, canonicalName: canonical)
                NotificationManager.shared.check(device: resolved.batteryDevice, level: resolved.level,
                                                 isCharging: resolved.chargingKnown && resolved.charging)
            }
        }
        reader.startMonitoring()
        btHeadphonesReader = reader
    }

    private func mergeAccessories() {
        logiAccessories = logiCache.current()
        let appleNames = Set(appleAccessories.map { $0.name })
        let logiNames  = Set(logiAccessories.map { $0.name })
        let bleNames   = Set(bleAccessories.map { $0.name })
        let ownedNames = Set([phoneName, padName].filter { !$0.isEmpty })

        // Try to show user-assigned BT names for Logitech devices connected via direct Bluetooth.
        // Match by looking for connected BT peripheral-class devices not already shown elsewhere.
        let logiOnly = Self.applyBTNames(to: logiAccessories.filter { !appleNames.contains($0.name) },
                                         excluding: appleNames.union(bleNames))
        let logiDisplayNames = Set(logiOnly.map { $0.name })

        let bleOnly = bleAccessories.filter { item in
            if appleNames.contains(item.name)       { return false }
            if logiNames.contains(item.name)        { return false }
            if logiDisplayNames.contains(item.name) { return false }
            if ownedNames.contains(item.name)       { return false }
            // Enumeration alone does not mean HID++ queries succeeded. Keep BLE
            // fallback until we actually have a recent HID++ battery reading.
            if let canonical = bleLogiMapping[item.name],
               logiNames.contains(canonical) { return false }
            return true
        }
        let btOnly = btHeadphones.filter {
            !appleNames.contains($0.name) &&
            !logiNames.contains($0.name) &&
            !logiDisplayNames.contains($0.name) &&
            !bleNames.contains($0.name) &&
            !ownedNames.contains($0.name)
        }
        let merged = (appleAccessories + logiOnly + bleOnly + btOnly).map { item in
            let canonical = bleLogiMapping[item.name] ?? LogitechReader.canonicalName(for: item.name) ?? item.name
            return logiChargingCache.applying(to: item, canonicalName: canonical)
        }.sorted { $0.name < $1.name }
        if accessories != merged {
            accessories = merged
        }
    }

    /// Renames Logitech items using connected IOBluetooth peripheral-class devices.
    /// Matches by index when counts agree (e.g. 1 Logi device + 1 BT mouse → same device).
    private static func applyBTNames(to items: [AccessoryBattery],
                                     excluding occupied: Set<String>) -> [AccessoryBattery] {
        guard !items.isEmpty else { return items }
        // Use a short-TTL cache: mergeAccessories() fires on every sub-reader
        // callback and calling pairedDevices() unconditionally hammers IOBluetooth.
        let paired = cachedPairedDevices()
        // Connected BT peripheral devices (mice/keyboards: major device class 0x05)
        // whose names aren't already shown in another reader's output.
        let candidates = paired.filter { dev in
            guard dev.isConnected(), let name = dev.name, !occupied.contains(name) else { return false }
            return (dev.classOfDevice >> 8) & 0x1F == 0x05
        }
        guard candidates.count == items.count else { return items }
        // Sort both sides by name for stable pairing.
        let sortedItems      = items.sorted { $0.name < $1.name }
        let sortedCandidates = candidates.sorted { ($0.name ?? "") < ($1.name ?? "") }
        return zip(sortedItems, sortedCandidates).map { item, btDev in
            guard let btName = btDev.name, btName != item.name else { return item }
            return item.renamed(btName)
        }
    }

    /// Cached result of `IOBluetoothDevice.pairedDevices()` with a 5-second TTL.
    /// `mergeAccessories()` fires on every sub-reader callback, so calling
    /// `pairedDevices()` unconditionally would hammer IOBluetooth unnecessarily.
    private static var _pairedDevicesCache: [IOBluetoothDevice] = []
    private static var _pairedDevicesCachedAt: Date = .distantPast

    private static func cachedPairedDevices() -> [IOBluetoothDevice] {
        let now = Date()
        if now.timeIntervalSince(_pairedDevicesCachedAt) < 5 {
            return _pairedDevicesCache
        }
        let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        _pairedDevicesCache = devices
        _pairedDevicesCachedAt = now
        return devices
    }

    // MARK: - Icon

    private func rebuildIcon() {
        let showPct = AppSettings.shared.showPercentageInMenuBar
        let key = (macBattery?.level, macBattery?.state, showPct)
        if let last = lastIconKey, last == key {
            return
        }
        lastIconKey = key
        guard let mac = macBattery else {
            menuBarIcon = renderPlugIcon()
            return
        }
        if showPct {
            menuBarIcon = renderBatteryIcon(level: mac.level, state: mac.state)
        } else {
            menuBarIcon = renderSymbolBatteryIcon(level: mac.level, state: mac.state)
        }
    }
}

private func cachedBattery(_ device: String) -> Int? {
    let ud = UserDefaults.standard
    guard let t = ud.object(forKey: "\(device).lastSyncTime") as? Date,
          Date().timeIntervalSince(t) < 1800 else { return nil }
    return ud.object(forKey: "\(device).lastBattery") as? Int
}

private func cachedAccessories() -> [AccessoryBattery] {
    let ud = UserDefaults.standard
    guard let t = ud.object(forKey: "accessories.lastSyncTime") as? Date,
          Date().timeIntervalSince(t) < 1800,
          let cached = ud.array(forKey: "accessories.last") as? [[String: Any]]
    else { return [] }

    return cached.compactMap {
        guard let name = $0["name"] as? String,
              let level = $0["level"] as? Int
        else { return nil }
        return AccessoryBattery(name: name, level: level, charging: false, updatedAt: t, chargingKnown: false)
    }
}

private func saveCachedAirPodsBattery(_ b: AirPodsBattery) {
    let ud = UserDefaults.standard
    ud.set(b.left, forKey: "airPods.lastLeft")
    ud.set(b.right, forKey: "airPods.lastRight")
    ud.set(b.case, forKey: "airPods.lastCase")
    ud.set(b.leftCharging, forKey: "airPods.lastLeftCharging")
    ud.set(b.rightCharging, forKey: "airPods.lastRightCharging")
    ud.set(b.caseCharging, forKey: "airPods.lastCaseCharging")
    ud.set(Date(), forKey: "airPods.lastSyncTime")
}

private func cachedAirPodsBattery() -> AirPodsBattery? {
    cachedAirPodsBattery(from: .standard, at: Date())
}

func cachedAirPodsBattery(from ud: UserDefaults, at now: Date = Date()) -> AirPodsBattery? {
    guard let t = ud.object(forKey: "airPods.lastSyncTime") as? Date else { return nil }
    let age = now.timeIntervalSince(t)
    guard age.isFinite, age >= -60, age < 14400 else { return nil }
    let left = ud.object(forKey: "airPods.lastLeft") as? Int
    let right = ud.object(forKey: "airPods.lastRight") as? Int
    let cas = ud.object(forKey: "airPods.lastCase") as? Int
    guard left != nil || right != nil || cas != nil else { return nil }
    let chargingStillFresh = age < AirPodsReader.caseChargingStaleTimeout
    return AirPodsBattery(
        left: left,
        right: right,
        case: cas,
        leftCharging: chargingStillFresh && ud.bool(forKey: "airPods.lastLeftCharging"),
        rightCharging: chargingStillFresh && ud.bool(forKey: "airPods.lastRightCharging"),
        caseCharging: chargingStillFresh && ud.bool(forKey: "airPods.lastCaseCharging")
    )
}
