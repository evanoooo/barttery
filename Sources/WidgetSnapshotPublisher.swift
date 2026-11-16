import Combine
import Foundation
import OSLog
import WidgetKit

/// Only the host app talks to hardware. The extension consumes an atomic JSON snapshot.
final class WidgetSnapshotPublisher {
    private var changes: AnyCancellable?
    private var settingsObserver: NSObjectProtocol?
    private var refreshObserver: NSObjectProtocol?
    private var pendingReload: DispatchWorkItem?
    private var pendingPublishWork: DispatchWorkItem?
    private var lastReload = Date.distantPast
    private var hasPublishedSnapshot = false
    private var lastWrittenDevices: [WidgetBatteryDevice] = []
    private var lastWrittenAt = Date.distantPast
    private static let minDiskWriteInterval: TimeInterval = 15
    private static let logger = Logger(subsystem: "com.yura.barttery", category: "Widget")

    init(monitor: DeviceBatteryMonitor) {
        changes = monitor.objectWillChange
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self, weak monitor] _ in
                guard let self, let monitor else { return }
                self.publish(monitor)
            }

        settingsObserver = NotificationCenter.default.addObserver(
            forName: .widgetSettingsChanged,
            object: nil,
            queue: .main
        ) { [weak self, weak monitor] _ in
            guard let self, let monitor else { return }
            self.publish(monitor, force: true)
        }

        refreshObserver = NotificationCenter.default.addObserver(
            forName: .userInitiatedRefresh,
            object: nil,
            queue: .main
        ) { [weak self, weak monitor] _ in
            guard let self, let monitor else { return }
            self.publish(monitor, force: true)
        }

        publish(monitor, force: true)
    }

    deinit {
        pendingReload?.cancel()
        pendingPublishWork?.cancel()
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
        if let refreshObserver {
            NotificationCenter.default.removeObserver(refreshObserver)
        }
    }

    private func devicesContentMatches(_ lhs: [WidgetBatteryDevice], _ rhs: [WidgetBatteryDevice]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (a, b) in zip(lhs, rhs) {
            if a.id != b.id || a.name != b.name || a.symbol != b.symbol ||
               a.level != b.level || a.isCharging != b.isCharging ||
               a.isPaused != b.isPaused || a.chargingKnown != b.chargingKnown {
                return false
            }
        }
        return true
    }

    private func publish(_ monitor: DeviceBatteryMonitor, force: Bool = false) {
        // The plain SwiftPM/DMG build deliberately has no App Group entitlement.
        guard Bundle.main.object(forInfoDictionaryKey: "BartteryWidgetsEnabled") as? Bool != false else { return }
        let now = Date()
        let snapshot = monitor.widgetSnapshot(at: now)
        let contentChanged = !devicesContentMatches(snapshot.devices, lastWrittenDevices)
        if !force, hasPublishedSnapshot {
            if !contentChanged && now.timeIntervalSince(lastWrittenAt) < 300 {
                return
            }
            if contentChanged && now.timeIntervalSince(lastWrittenAt) < Self.minDiskWriteInterval {
                let remaining = Self.minDiskWriteInterval - now.timeIntervalSince(lastWrittenAt)
                if pendingPublishWork == nil {
                    let work = DispatchWorkItem { [weak self, weak monitor] in
                        guard let self, let monitor else { return }
                        self.pendingPublishWork = nil
                        self.publish(monitor)
                    }
                    pendingPublishWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: work)
                }
                return
            }
        }
        pendingPublishWork?.cancel()
        pendingPublishWork = nil
        lastWrittenDevices = snapshot.devices
        lastWrittenAt = now

        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                try WidgetSnapshotStore.write(snapshot)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if !self.hasPublishedSnapshot || force {
                        self.hasPublishedSnapshot = true
                        self.pendingReload?.cancel()
                        self.pendingReload = nil
                        self.lastReload = Date()
                        Self.reloadAllWidgets()
                    } else if contentChanged {
                        self.requestReload()
                    }
                }
            } catch {
                let path = WidgetSnapshotStore.fileURL?.path ?? "nil"
                Self.logger.error("Cannot save widget snapshot: \(error.localizedDescription, privacy: .public) [fopenErr=\(WidgetSnapshotStore.lastFopenErrno), path=\(path, privacy: .public)]")
            }
        }
    }

    static func reloadAllWidgets() {
        guard Bundle.main.object(forInfoDictionaryKey: "BartteryWidgetsEnabled") as? Bool != false else { return }
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func requestReload() {
        guard pendingReload == nil else { return }
        // Coalesce frequent BLE updates; WidgetKit also applies its own refresh budget.
        let delay = max(0, 30 - Date().timeIntervalSince(lastReload))
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingReload = nil
            self.lastReload = Date()
            Self.reloadAllWidgets()
        }
        pendingReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

extension DeviceBatteryMonitor {
    func widgetSnapshot(at date: Date = Date()) -> WidgetBatterySnapshot {
        var devices: [WidgetBatteryDevice] = []
        func append(_ id: String, _ name: String, _ symbol: String, _ level: Int?, _ charging: Bool,
                    paused: Bool = false, updatedAt: Date, chargingKnown: Bool = true) {
            guard let level else { return }
            devices.append(WidgetBatteryDevice(id: id, name: name, symbol: symbol,
                                               level: min(100, max(0, level)),
                                                isCharging: charging, isPaused: paused, updatedAt: updatedAt,
                                                chargingKnown: chargingKnown))
        }

        if let mac = macBattery {
            append("mac", displayMacName, "macbook", mac.level, mac.state == .charging,
                   paused: mac.state == .paused,
                   updatedAt: macBatteryUpdatedAt ?? date)
        }
        append("phone", displayPhoneName, "iphone", phoneBattery, phoneCharging,
               updatedAt: syncTimes[BatteryDevice.phone.rawValue] ?? date)
        if let pods = airPodsBattery {
            // One ring for the earbuds, using the lower available level.
            let level = [pods.left, pods.right].compactMap { $0 }.min()
            let updatedAt = syncTimes[BatteryDevice.airPods.rawValue] ?? date
            let isPro = displayAirPodsName.lowercased().contains("pro")
            let podsSymbol = isPro ? "airpodspro" : "airpods"
            append("airpods", displayAirPodsName, podsSymbol, level,
                   pods.leftCharging || pods.rightCharging, updatedAt: updatedAt)
        }
        if let watch = watchBattery {
            append("watch", watch.name, "applewatch", watch.level, watch.isCharging,
                   updatedAt: watch.updatedAt, chargingKnown: watch.chargingKnown)
        }
        if let pods = airPodsBattery {
            let updatedAt = syncTimes[BatteryDevice.airPods.rawValue] ?? date
            let isPro = displayAirPodsName.lowercased().contains("pro")
            let caseSymbol = isPro ? "airpodspro.chargingcase.wireless.fill" : "airpods.chargingcase.fill"
            append("airpods.case", "\(displayAirPodsName) Case", caseSymbol, pods.case,
                   pods.caseCharging, updatedAt: updatedAt)
        }
        append("pad", padName, "ipad", padBattery, padCharging,
               updatedAt: syncTimes[BatteryDevice.pad.rawValue] ?? date)
        for accessory in accessories {
            devices.append(WidgetBatteryDevice(accessory: accessory))
        }
        let filteredDevices = AppSettings.shared.filterDevicesForWidget(devices)
        return WidgetBatterySnapshot(devices: filteredDevices, writtenAt: date)
    }
}

extension WidgetBatteryDevice {
    init(accessory: AccessoryBattery) {
        self.init(id: "accessory.\(accessory.name)", name: accessory.name, symbol: accessory.icon,
                  level: min(100, max(0, accessory.level)), isCharging: accessory.charging,
                  updatedAt: accessory.updatedAt ?? .distantPast, chargingKnown: accessory.chargingKnown)
    }
}
