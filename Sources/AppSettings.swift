import Foundation
import ServiceManagement
import Combine

enum BatteryThresholdType: String, Codable, CaseIterable {
    case below  // 低于某电量（放电低电量警告）
    case above  // 高于某电量（充电目标/充满提醒）
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

    private var bag = Set<AnyCancellable>()
    private var isRevertingLaunchAtLogin = false

    private static let rulesStorageKey = "deviceNotificationRules_v2"
    private static let legacyStorageKey = "notificationThresholds"

    private init() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        showPercentageInMenuBar = UserDefaults.standard.bool(forKey: "showPercentageInMenuBar")

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
}
