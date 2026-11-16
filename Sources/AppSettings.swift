import Foundation
import ServiceManagement
import Combine

enum BatteryThresholdType: String, Codable, CaseIterable {
    case below  // 低于某电量（放电低电量警告）
    case above  // 高于某电量（充电目标/充满提醒）
}

enum WidgetDeviceSelectionMode: String, Codable, CaseIterable {
    case all     // 自动显示所有活跃设备（默认）
    case custom  // 仅显示选定的设备，并按自定义顺序排列
}

extension Notification.Name {
    static let widgetSettingsChanged = Notification.Name("widgetSettingsChanged")
    static let userInitiatedRefresh = Notification.Name("userInitiatedRefresh")
}

struct DeviceNotificationRules: Codable, Equatable {
    var below: [Int] = [20]
    var above: [Int] = [80, 100]
    var soundEnabled: Bool = true

    init(below: [Int] = [20], above: [Int] = [80, 100], soundEnabled: Bool = true) {
        self.below = Array(Set(below)).sorted()
        self.above = Array(Set(above)).sorted()
        self.soundEnabled = soundEnabled
    }
}

class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var launchAtLogin: Bool
    @Published var deviceRules: [String: DeviceNotificationRules] = [:]
    @Published var showPercentageInMenuBar: Bool {
        didSet {
            UserDefaults.standard.set(showPercentageInMenuBar, forKey: "showPercentageInMenuBar")
        }
    }

    @Published var widgetSelectionMode: WidgetDeviceSelectionMode {
        didSet {
            UserDefaults.standard.set(widgetSelectionMode.rawValue, forKey: "widgetSelectionMode")
            notifyWidgetSettingsChanged()
        }
    }

    @Published var widgetEnabledDeviceIds: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(widgetEnabledDeviceIds), forKey: "widgetEnabledDeviceIds")
            notifyWidgetSettingsChanged()
        }
    }

    @Published var widgetDeviceOrder: [String] {
        didSet {
            UserDefaults.standard.set(widgetDeviceOrder, forKey: "widgetDeviceOrder")
            notifyWidgetSettingsChanged()
        }
    }

    static let defaultWidgetOrder: [String] = [
        "mac",
        "phone",
        "airpods",
        "watch",
        "airpods.case",
        "pad",
        "accessory"
    ]

    private var bag = Set<AnyCancellable>()
    private var isRevertingLaunchAtLogin = false

    private static let rulesStorageKey = "deviceNotificationRules_v2"
    private static let legacyStorageKey = "notificationThresholds"

    private init() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        showPercentageInMenuBar = UserDefaults.standard.bool(forKey: "showPercentageInMenuBar")

        if let modeStr = UserDefaults.standard.string(forKey: "widgetSelectionMode"),
           let mode = WidgetDeviceSelectionMode(rawValue: modeStr) {
            widgetSelectionMode = mode
        } else {
            widgetSelectionMode = .all
        }

        if let savedEnabled = UserDefaults.standard.array(forKey: "widgetEnabledDeviceIds") as? [String] {
            widgetEnabledDeviceIds = Set(savedEnabled)
        } else {
            widgetEnabledDeviceIds = Set(Self.defaultWidgetOrder)
        }

        if let savedOrder = UserDefaults.standard.array(forKey: "widgetDeviceOrder") as? [String] {
            var order = savedOrder
            for item in Self.defaultWidgetOrder where !order.contains(item) {
                order.append(item)
            }
            widgetDeviceOrder = order
        } else {
            widgetDeviceOrder = Self.defaultWidgetOrder
        }

        loadRules()

        $launchAtLogin.dropFirst().sink { [weak self] enabled in
            guard let self, !isRevertingLaunchAtLogin else { return }
            do {
                if enabled { try SMAppService.mainApp.register() }
                else       { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Failed to update Launch at Login: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.isRevertingLaunchAtLogin = true
                    self.launchAtLogin = SMAppService.mainApp.status == .enabled
                    self.isRevertingLaunchAtLogin = false
                }
            }
        }.store(in: &bag)

        $deviceRules.dropFirst().sink { [weak self] rules in
            self?.saveRules(rules)
        }.store(in: &bag)
    }

    private func loadRules() {
        let ud = UserDefaults.standard
        if let data = ud.data(forKey: Self.rulesStorageKey),
           let decoded = try? JSONDecoder().decode([String: DeviceNotificationRules].self, from: data) {
            self.deviceRules = decoded
            return
        }

        // Migrate from legacy format [String: [Int]]
        if let data = ud.data(forKey: Self.legacyStorageKey),
           let legacy = try? JSONDecoder().decode([String: [Int]].self, from: data) {
            var migrated: [String: DeviceNotificationRules] = [:]
            for (key, values) in legacy {
                let below = values.filter { $0 < 50 }
                let above = values.filter { $0 >= 50 }
                migrated[key] = DeviceNotificationRules(below: below, above: above)
            }
            self.deviceRules = migrated
            saveRules(migrated)
            return
        }

        // Default empty configuration; default rules will be initialized on-demand
        self.deviceRules = [:]
    }

    private func saveRules(_ rules: [String: DeviceNotificationRules]) {
        if let data = try? JSONEncoder().encode(rules) {
            UserDefaults.standard.set(data, forKey: Self.rulesStorageKey)
        }
    }

    // MARK: - Rule Accessors

    func rules(for device: BatteryDevice) -> DeviceNotificationRules {
        if let existing = deviceRules[device.rawValue] {
            return existing
        }
        // Headphones default to only discharge warning [20]
        if device == .airPods || device == .headphones {
            return DeviceNotificationRules(below: [20], above: [])
        }
        return DeviceNotificationRules(below: [20], above: [80, 100])
    }

    func setRules(_ rules: DeviceNotificationRules, for device: BatteryDevice) {
        var cleanRules = rules
        cleanRules.below = Array(Set(cleanRules.below.filter { (1...99).contains($0) })).sorted()
        cleanRules.above = Array(Set(cleanRules.above.filter { (1...100).contains($0) })).sorted()
        deviceRules[device.rawValue] = cleanRules
    }

    func isThresholdEnabled(device: BatteryDevice, type: BatteryThresholdType, threshold: Int) -> Bool {
        let current = rules(for: device)
        switch type {
        case .below: return current.below.contains(threshold)
        case .above: return current.above.contains(threshold)
        }
    }

    func toggleThreshold(device: BatteryDevice, type: BatteryThresholdType, threshold: Int) {
        var current = rules(for: device)
        switch type {
        case .below:
            if current.below.contains(threshold) {
                current.below.removeAll { $0 == threshold }
            } else {
                current.below.append(threshold)
                NotificationManager.shared.requestPermission()
            }
        case .above:
            if current.above.contains(threshold) {
                current.above.removeAll { $0 == threshold }
            } else {
                current.above.append(threshold)
                NotificationManager.shared.requestPermission()
            }
        }
        setRules(current, for: device)
    }

    func addThreshold(device: BatteryDevice, type: BatteryThresholdType, threshold: Int) {
        guard (1...100).contains(threshold) else { return }
        var current = rules(for: device)
        switch type {
        case .below:
            guard threshold < 100, !current.below.contains(threshold) else { return }
            current.below.append(threshold)
        case .above:
            guard threshold > 0, !current.above.contains(threshold) else { return }
            current.above.append(threshold)
        }
        NotificationManager.shared.requestPermission()
        setRules(current, for: device)
    }

    func removeThreshold(device: BatteryDevice, type: BatteryThresholdType, threshold: Int) {
        var current = rules(for: device)
        switch type {
        case .below:
            current.below.removeAll { $0 == threshold }
        case .above:
            current.above.removeAll { $0 == threshold }
        }
        setRules(current, for: device)
    }

    // MARK: - Legacy Compatibility

    func isThresholdEnabled(device: BatteryDevice, threshold: Int) -> Bool {
        if threshold < 50 {
            return isThresholdEnabled(device: device, type: .below, threshold: threshold)
        } else {
            return isThresholdEnabled(device: device, type: .above, threshold: threshold)
        }
    }

    func toggleThreshold(device: BatteryDevice, threshold: Int) {
        if threshold < 50 {
            toggleThreshold(device: device, type: .below, threshold: threshold)
        } else {
            toggleThreshold(device: device, type: .above, threshold: threshold)
        }
    }

    // MARK: - Widget Device Selection & Ordering

    func notifyWidgetSettingsChanged() {
        NotificationCenter.default.post(name: .widgetSettingsChanged, object: nil)
    }

    func isDeviceEnabledForWidget(id: String) -> Bool {
        if widgetSelectionMode == .all {
            return true
        }
        if widgetEnabledDeviceIds.contains(id) {
            return true
        }
        if id.hasPrefix("accessory.") && (widgetEnabledDeviceIds.contains("accessory") || widgetEnabledDeviceIds.contains(id)) {
            return true
        }
        return false
    }

    func toggleDeviceForWidget(id: String) {
        if widgetSelectionMode == .all {
            widgetSelectionMode = .custom
        }
        var updated = widgetEnabledDeviceIds
        if id == "accessory" {
            let currentlyEnabled = updated.contains("accessory") || updated.contains { $0.hasPrefix("accessory.") }
            if currentlyEnabled {
                updated.remove("accessory")
                updated = updated.filter { !$0.hasPrefix("accessory.") }
            } else {
                updated.insert("accessory")
            }
        } else if id.hasPrefix("accessory.") {
            if updated.contains(id) || updated.contains("accessory") {
                updated.remove(id)
                updated.remove("accessory")
            } else {
                updated.insert(id)
            }
        } else if updated.contains(id) {
            updated.remove(id)
        } else {
            updated.insert(id)
        }
        widgetEnabledDeviceIds = updated
    }

    func setDeviceEnabledForWidget(id: String, enabled: Bool) {
        if widgetSelectionMode == .all {
            widgetSelectionMode = .custom
        }
        var updated = widgetEnabledDeviceIds
        if enabled {
            updated.insert(id)
        } else {
            updated.remove(id)
            if id == "accessory" {
                updated = updated.filter { !$0.hasPrefix("accessory.") }
            } else if id.hasPrefix("accessory.") {
                updated.remove("accessory")
            }
        }
        widgetEnabledDeviceIds = updated
    }

    func moveWidgetDevice(from sourceIndex: Int, to destinationIndex: Int) {
        guard widgetDeviceOrder.indices.contains(sourceIndex),
              widgetDeviceOrder.indices.contains(destinationIndex),
              sourceIndex != destinationIndex else { return }
        var updated = widgetDeviceOrder
        let item = updated.remove(at: sourceIndex)
        updated.insert(item, at: destinationIndex)
        widgetDeviceOrder = updated
    }

    func resetWidgetSettings() {
        widgetSelectionMode = .all
        widgetEnabledDeviceIds = Set(Self.defaultWidgetOrder)
        widgetDeviceOrder = Self.defaultWidgetOrder
    }

    func filterDevicesForWidget(_ devices: [WidgetBatteryDevice]) -> [WidgetBatteryDevice] {
        guard widgetSelectionMode == .custom else {
            return devices
        }

        // Only keep enabled devices
        let filtered = devices.filter { dev in
            isDeviceEnabledForWidget(id: dev.id)
        }

        // Sort according to widgetDeviceOrder
        return filtered.sorted { d1, d2 in
            let idx1 = indexInOrder(for: d1.id)
            let idx2 = indexInOrder(for: d2.id)
            if idx1 != idx2 {
                return idx1 < idx2
            }
            return d1.name < d2.name
        }
    }

    private func indexInOrder(for id: String) -> Int {
        if let idx = widgetDeviceOrder.firstIndex(of: id) {
            return idx
        }
        if id.hasPrefix("accessory.") {
            if let idx = widgetDeviceOrder.firstIndex(of: "accessory") {
                return idx
            }
        }
        return 999
    }

    static func defaultDeviceName(for id: String) -> String {
        switch id {
        case "mac":          return L10n.tr("widget.device_mac")
        case "phone":        return L10n.tr("widget.device_phone")
        case "airpods":      return L10n.tr("widget.device_airpods")
        case "airpods.case": return L10n.tr("widget.device_airpods_case")
        case "watch":        return L10n.tr("widget.device_watch")
        case "pad":          return L10n.tr("widget.device_pad")
        case "accessory":    return L10n.tr("widget.device_accessories")
        default:             return id
        }
    }

    static func defaultDeviceIcon(for id: String) -> String {
        switch id {
        case "mac":          return "macbook"
        case "phone":        return "iphone"
        case "airpods":      return "airpods"
        case "airpods.case": return "airpods.chargingcase"
        case "watch":        return "applewatch"
        case "pad":          return "ipad"
        case "accessory":    return "keyboard"
        default:             return "battery.100"
        }
    }
}
