import UserNotifications
import AppKit

enum BatteryDevice: String, CaseIterable, Codable {
    case mac, phone, pad, watch, airPods, keyboard, mouse, trackpad, headphones

    var label: String {
        localizedName
    }
}

class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    private struct DeviceState: Equatable {
        var lastLevel: Int?
        var notifiedBelow: Set<Int> = []
        var notifiedAbove: Set<Int> = []
        var wasCharging = false
    }

    private var states: [BatteryDevice: DeviceState] = [:]

    private var isAppEnvironment: Bool {
        NSClassFromString("XCTestCase") == nil && Bundle.main.bundleURL.pathExtension.lowercased() == "app"
    }

    private override init() {
        super.init()
        if isAppEnvironment {
            UNUserNotificationCenter.current().delegate = self
        }
        loadPersistedStates()
    }

    private func loadPersistedStates() {
        let ud = UserDefaults.standard
        for device in BatteryDevice.allCases {
            var state = DeviceState()
            if let level = ud.object(forKey: "nm.\(device.rawValue).level") as? Int {
                state.lastLevel = level
            }
            if let belowArr = ud.array(forKey: "nm.\(device.rawValue).notified_below") as? [Int] {
                state.notifiedBelow = Set(belowArr)
            } else if let legacyArr = ud.array(forKey: "nm.\(device.rawValue).notified") as? [Int] {
                // Migrate legacy notifications
                state.notifiedBelow = Set(legacyArr.filter { $0 < 50 })
                state.notifiedAbove = Set(legacyArr.filter { $0 >= 50 })
            }
            if let aboveArr = ud.array(forKey: "nm.\(device.rawValue).notified_above") as? [Int] {
                state.notifiedAbove = Set(aboveArr)
            }
            states[device] = state
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let urlString = response.notification.request.content.userInfo["url"] as? String,
           let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
        completionHandler()
    }

    func requestPermission() {
        guard isAppEnvironment else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func check(device: BatteryDevice, level: Int, isCharging: Bool) {
        guard (1...100).contains(level) else { return }
        let settings = AppSettings.shared
        let rules = settings.rules(for: device)
        var state = states[device] ?? DeviceState()
        let initialState = state
        let prev = state.lastLevel
        let wasCharging = state.wasCharging
        let justStoppedCharging = !isCharging && wasCharging

        defer {
            state.wasCharging = isCharging
            state.lastLevel = level
            states[device] = state
            if state != initialState {
                persist(device: device, state: state)
            }
        }

        // 1. Check "Above" charging thresholds (e.g. 80%, 100%)
        if isCharging {
            // Level rose or charging active: evaluate above thresholds
            for threshold in rules.above {
                let crossed = level >= threshold && (prev == nil || prev! < threshold)
                if crossed && !state.notifiedAbove.contains(threshold) {
                    send(device: device, level: threshold, type: .above, playSound: rules.soundEnabled)
                    state.notifiedAbove.insert(threshold)
                }
                // Hysteresis reset: if level drops below threshold - 3%, allow re-triggering later
                if level <= threshold - 3 {
                    state.notifiedAbove.remove(threshold)
                }
            }
            // Charging started or level rose: reset discharge notifications that have been cleared
            state.notifiedBelow = state.notifiedBelow.filter { threshold in
                level < threshold + 3
            }
        } else {
            // Not charging: clear all charging notifications if unplugged or below threshold - 3%
            if justStoppedCharging {
                state.notifiedAbove.removeAll()
            } else {
                for threshold in rules.above {
                    if level <= threshold - 3 {
                        state.notifiedAbove.remove(threshold)
                    }
                }
            }
        }

        // 2. Check "Below" discharge thresholds (e.g. 10%, 20%)
        if !isCharging {
            for threshold in rules.below {
                let effectivePrev = prev ?? (level <= threshold ? threshold + 1 : level)
                let crossed = effectivePrev > threshold && level <= threshold
                if crossed && !state.notifiedBelow.contains(threshold) {
                    send(device: device, level: threshold, type: .below, playSound: rules.soundEnabled)
                    state.notifiedBelow.insert(threshold)
                }
                // Hysteresis reset: if level rises back above threshold + 3%, allow re-triggering later
                if level >= threshold + 3 {
                    state.notifiedBelow.remove(threshold)
                }
            }
        }
    }

    func sendTestNotification(device: BatteryDevice, type: BatteryThresholdType, level: Int) {
        requestPermission()
        send(device: device, level: level, type: type, playSound: true, isTest: true)
    }

    private func persist(device: BatteryDevice, state: DeviceState) {
        let ud = UserDefaults.standard
        if let level = state.lastLevel {
            ud.set(level, forKey: "nm.\(device.rawValue).level")
        } else {
            ud.removeObject(forKey: "nm.\(device.rawValue).level")
        }
        ud.set(Array(state.notifiedBelow), forKey: "nm.\(device.rawValue).notified_below")
        ud.set(Array(state.notifiedAbove), forKey: "nm.\(device.rawValue).notified_above")
    }

    private func send(device: BatteryDevice, level: Int, type: BatteryThresholdType, playSound: Bool, isTest: Bool = false) {
        let content = UNMutableNotificationContent()
        let deviceName = device.localizedName

        switch type {
        case .below:
            content.title = L10n.tr("notification.title.below")
            content.body  = L10n.tr("notification.body.below", deviceName, level)
        case .above:
            content.title = L10n.tr("notification.title.above")
            if level == 100 {
                content.body = L10n.tr("notification.body.fully_charged", deviceName)
            } else {
                content.body = L10n.tr("notification.body.above", deviceName, level)
            }
        }

        if playSound {
            content.sound = .default
        }

        guard isAppEnvironment else { return }

        let identifier = isTest
            ? "battery-test-\(UUID().uuidString)"
            : "battery-\(device.rawValue)-\(type.rawValue)-\(level)"

        let req = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
