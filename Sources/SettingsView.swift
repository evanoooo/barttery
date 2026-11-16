import SwiftUI
import AppKit

// MARK: - Settings Tab

enum SettingsTab: String, CaseIterable, Identifiable {
    case notifications = "notifications"
    case widget = "widget"
    case general = "general"

    var id: String { rawValue }
}

// MARK: - Settings Window Controller

@MainActor
class SettingsWindowController: NSObject {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show(selectedDevice: BatteryDevice? = nil, tab: SettingsTab = .notifications) {
        NSApp.activate(ignoringOtherApps: true)

        if let window = window {
            window.makeKeyAndOrderFront(nil)
            if let dev = selectedDevice {
                NotificationCenter.default.post(name: .selectSettingsDevice, object: dev)
            }
            NotificationCenter.default.post(name: .selectSettingsTab, object: tab)
            return
        }

        let rootView = SettingsView(initialDevice: selectedDevice ?? .mac, initialTab: tab)
        let hosting = NSHostingController(rootView: rootView)

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 490),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = L10n.tr("settings.title")
        win.center()
        win.contentViewController = hosting
        win.isReleasedWhenClosed = false
        win.makeKeyAndOrderFront(nil)

        self.window = win
    }
}

extension Notification.Name {
    static let selectSettingsDevice = Notification.Name("selectSettingsDevice")
    static let selectSettingsTab = Notification.Name("selectSettingsTab")
}

// MARK: - Settings View

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var selectedTab: SettingsTab
    @State private var selectedDevice: BatteryDevice

    @State private var newBelowValue: Double = 15
    @State private var newAboveValue: Double = 85
    @State private var showingAddBelow = false
    @State private var showingAddAbove = false
    @State private var testNotificationSent = false

    init(initialDevice: BatteryDevice = .mac, initialTab: SettingsTab = .notifications) {
        _selectedDevice = State(initialValue: initialDevice)
        _selectedTab = State(initialValue: initialTab)
    }

    private var currentRules: DeviceNotificationRules {
        settings.rules(for: selectedDevice)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top Tab Navigation
            Picker("", selection: $selectedTab) {
                Label(L10n.tr("settings.tab_notifications"), systemImage: "bell.badge")
                    .tag(SettingsTab.notifications)
                Label(L10n.tr("settings.tab_widget"), systemImage: "square.grid.2x2")
                    .tag(SettingsTab.widget)
                Label(L10n.tr("settings.tab_general"), systemImage: "gearshape")
                    .tag(SettingsTab.general)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 24)
            .padding(.top, 14)
            .padding(.bottom, 12)

            Divider()

            // Active Tab Content
            Group {
                switch selectedTab {
                case .notifications:
                    notificationRulesView
                case .widget:
                    WidgetSettingsView(settings: settings)
                case .general:
                    GeneralSettingsView(settings: settings)
                }
            }
        }
        .frame(minWidth: 600, minHeight: 480)
        .onReceive(NotificationCenter.default.publisher(for: .selectSettingsDevice)) { notif in
            if let dev = notif.object as? BatteryDevice {
                self.selectedDevice = dev
                self.selectedTab = .notifications
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectSettingsTab)) { notif in
            if let tab = notif.object as? SettingsTab {
                self.selectedTab = tab
            }
        }
    }

    // MARK: - Notification Rules View

    private var notificationRulesView: some View {
        HStack(spacing: 0) {
            // Left Sidebar: Device Selection
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("settings.devices"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .padding(.bottom, 4)

                List(BatteryDevice.allCases, id: \.self, selection: $selectedDevice) { device in
                    HStack(spacing: 8) {
                        Image(systemName: iconFor(device: device))
                            .frame(width: 18)
                            .foregroundColor(selectedDevice == device ? .accentColor : .secondary)
                        Text(device.localizedName)
                            .font(.system(size: 13))
                    }
                    .tag(device)
                }
                .listStyle(.sidebar)
            }
            .frame(width: 160)

            Divider()

            // Right Content Area
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Header
                    HStack {
                        Image(systemName: iconFor(device: selectedDevice))
                            .font(.system(size: 22))
                            .foregroundColor(.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(selectedDevice.localizedName)
                                .font(.system(size: 18, weight: .semibold))
                            Text(L10n.tr("notification.notifications"))
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.bottom, 4)

                    // Section 1: Below thresholds
                    VStack(alignment: .leading, spacing: 10) {
                        Label(L10n.tr("rules.section_below"), systemImage: "arrow.down.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.orange)

                        Text(L10n.tr("settings.hint_below"))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)

                        // Threshold tags
                        HStack(spacing: 8) {
                            ForEach(currentRules.below, id: \.self) { val in
                                ThresholdChip(
                                    label: "\(L10n.tr("rules.below_label")) \(val)%",
                                    color: .orange,
                                    onDelete: {
                                        settings.removeThreshold(device: selectedDevice, type: .below, threshold: val)
                                    }
                                )
                            }

                            Button {
                                showingAddBelow = true
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "plus")
                                    Text(L10n.tr("rules.add"))
                                }
                                .font(.system(size: 12))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.bordered)
                            .popover(isPresented: $showingAddBelow) {
                                AddThresholdPopover(
                                    title: L10n.tr("rules.section_below"),
                                    value: $newBelowValue,
                                    range: 5...50,
                                    step: 5,
                                    onAdd: {
                                        settings.addThreshold(device: selectedDevice, type: .below, threshold: Int(newBelowValue))
                                        showingAddBelow = false
                                    },
                                    onCancel: {
                                        showingAddBelow = false
                                    }
                                )
                            }
                        }
                    }
                    .padding(14)
                    .background(Color.secondary.opacity(0.06))
                    .cornerRadius(10)

                    // Section 2: Above thresholds
                    VStack(alignment: .leading, spacing: 10) {
                        Label(L10n.tr("rules.section_above"), systemImage: "bolt.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.green)

                        Text(L10n.tr("settings.hint_above"))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)

                        // Threshold tags
                        HStack(spacing: 8) {
                            ForEach(currentRules.above, id: \.self) { val in
                                ThresholdChip(
                                    label: "\(L10n.tr("rules.above_label")) \(val)%",
                                    color: .green,
                                    onDelete: {
                                        settings.removeThreshold(device: selectedDevice, type: .above, threshold: val)
                                    }
                                )
                            }

                            Button {
                                showingAddAbove = true
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "plus")
                                    Text(L10n.tr("rules.add"))
                                }
                                .font(.system(size: 12))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.bordered)
                            .popover(isPresented: $showingAddAbove) {
                                AddThresholdPopover(
                                    title: L10n.tr("rules.section_above"),
                                    value: $newAboveValue,
                                    range: 50...100,
                                    step: 5,
                                    onAdd: {
                                        settings.addThreshold(device: selectedDevice, type: .above, threshold: Int(newAboveValue))
                                        showingAddAbove = false
                                    },
                                    onCancel: {
                                        showingAddAbove = false
                                    }
                                )
                            }
                        }
                    }
                    .padding(14)
                    .background(Color.secondary.opacity(0.06))
                    .cornerRadius(10)

                    // Section 3: Sound & Test Notification
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(isOn: Binding(
                            get: { currentRules.soundEnabled },
                            set: { newVal in
                                var updated = currentRules
                                updated.soundEnabled = newVal
                                settings.setRules(updated, for: selectedDevice)
                            }
                        )) {
                            Label(L10n.tr("settings.sound_alert"), systemImage: "speaker.wave.2")
                                .font(.system(size: 13))
                        }

                        HStack {
                            Button {
                                let testLevel = currentRules.below.first ?? 20
                                NotificationManager.shared.sendTestNotification(
                                    device: selectedDevice,
                                    type: .below,
                                    level: testLevel
                                )
                                testNotificationSent = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                                    testNotificationSent = false
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "paperplane.fill")
                                    Text(L10n.tr("settings.test_button"))
                                }
                            }
                            .buttonStyle(.borderedProminent)

                            if testNotificationSent {
                                Text(L10n.tr("settings.test_sent"))
                                    .font(.system(size: 12))
                                    .foregroundColor(.green)
                                    .transition(.opacity)
                            }
                        }
                    }
                    .padding(14)
                    .background(Color.secondary.opacity(0.06))
                    .cornerRadius(10)

                    Spacer(minLength: 20)
                }
                .padding(20)
            }
        }
    }

    private func iconFor(device: BatteryDevice) -> String {
        switch device {
        case .mac:        return "macbook"
        case .phone:      return "iphone"
        case .pad:        return "ipad"
        case .watch:      return "applewatch"
        case .airPods:    return "airpodspro"
        case .keyboard:   return "keyboard"
        case .mouse:      return "magicmouse"
        case .trackpad:   return "rectangle.and.hand.point.up.left"
        case .headphones: return "headphones"
        }
    }
}

// MARK: - Widget Settings View

struct WidgetSettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var isRefreshed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Header
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.accentColor.opacity(0.12))
                            .frame(width: 44, height: 44)
                        Image(systemName: "square.grid.2x2.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(.accentColor)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.tr("widget.settings_title"))
                            .font(.system(size: 17, weight: .bold))
                        Text(L10n.tr("widget.settings_subtitle"))
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }

                // Mode Selection
                VStack(alignment: .leading, spacing: 10) {
                    Picker("", selection: $settings.widgetSelectionMode) {
                        Text(L10n.tr("widget.mode_all")).tag(WidgetDeviceSelectionMode.all)
                        Text(L10n.tr("widget.mode_custom")).tag(WidgetDeviceSelectionMode.custom)
                    }
                    .pickerStyle(.radioGroup)
                }
                .padding(14)
                .background(Color.secondary.opacity(0.06))
                .cornerRadius(10)

                // Subtitle / Slot Guidance
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundColor(.accentColor)
                    Text(L10n.tr("widget.top_four_hint"))
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Spacer()
                    if settings.widgetSelectionMode == .custom {
                        Button(L10n.tr("widget.reset_default")) {
                            settings.resetWidgetSettings()
                        }
                        .font(.system(size: 12))
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.horizontal, 4)

                // Device List
                VStack(spacing: 8) {
                    ForEach(Array(settings.widgetDeviceOrder.enumerated()), id: \.element) { index, deviceId in
                        WidgetDeviceRow(
                            deviceId: deviceId,
                            index: index,
                            totalCount: settings.widgetDeviceOrder.count,
                            isEnabled: settings.isDeviceEnabledForWidget(id: deviceId),
                            isCustomMode: settings.widgetSelectionMode == .custom,
                            onToggle: {
                                settings.toggleDeviceForWidget(id: deviceId)
                            },
                            onMoveUp: {
                                settings.moveWidgetDevice(from: index, to: max(0, index - 1))
                            },
                            onMoveDown: {
                                settings.moveWidgetDevice(from: index, to: min(settings.widgetDeviceOrder.count - 1, index + 1))
                            }
                        )
                    }
                }

                // Manual Refresh / Sync Action
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.tr("widget.refresh_hint_title"))
                            .font(.system(size: 12, weight: .medium))
                        Text(L10n.tr("widget.refresh_hint_desc"))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button {
                        settings.notifyWidgetSettingsChanged()
                        isRefreshed = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            isRefreshed = false
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: isRefreshed ? "checkmark" : "arrow.clockwise")
                            Text(isRefreshed ? L10n.tr("widget.refreshed") : L10n.tr("widget.refresh_now"))
                        }
                        .font(.system(size: 12))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(14)
                .background(Color.secondary.opacity(0.04))
                .cornerRadius(10)

                Spacer(minLength: 20)
            }
            .padding(20)
        }
    }
}

// MARK: - Widget Device Row

private struct WidgetDeviceRow: View {
    let deviceId: String
    let index: Int
    let totalCount: Int
    let isEnabled: Bool
    let isCustomMode: Bool
    let onToggle: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void

    private var isTopFour: Bool {
        index < 4 && isEnabled
    }

    var body: some View {
        HStack(spacing: 12) {
            // Reorder controls
            if isCustomMode {
                HStack(spacing: 2) {
                    Button(action: onMoveUp) {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 20, height: 22)
                    }
                    .buttonStyle(.plain)
                    .disabled(index == 0)
                    .opacity(index == 0 ? 0.25 : 0.75)
                    .help(L10n.tr("widget.move_up"))

                    Button(action: onMoveDown) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 20, height: 22)
                    }
                    .buttonStyle(.plain)
                    .disabled(index == totalCount - 1)
                    .opacity(index == totalCount - 1 ? 0.25 : 0.75)
                    .help(L10n.tr("widget.move_down"))
                }
                .frame(width: 44)
            }

            // Priority index badge
            Text("#\(index + 1)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(isTopFour ? .accentColor : .secondary.opacity(0.6))
                .frame(width: 26, alignment: .center)
                .padding(.vertical, 3)
                .background(isTopFour ? Color.accentColor.opacity(0.12) : Color.clear)
                .clipShape(Capsule())

            // Device Icon in soft squircle
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .frame(width: 28, height: 28)

                Image(systemName: AppSettings.defaultDeviceIcon(for: deviceId))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
            }

            // Device Name & Status
            VStack(alignment: .leading, spacing: 2) {
                Text(AppSettings.defaultDeviceName(for: deviceId))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(isEnabled ? .primary : .secondary)

                if isTopFour {
                    Text(L10n.tr("widget.slot_badge", index + 1))
                        .font(.system(size: 10))
                        .foregroundColor(.accentColor)
                }
            }

            Spacer()

            // Toggle Switch
            Toggle("", isOn: Binding(
                get: { isEnabled },
                set: { _ in onToggle() }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.secondary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(isTopFour ? Color.accentColor.opacity(0.25) : Color.clear, lineWidth: 1)
        )
    }
}

// MARK: - General Settings View

struct GeneralSettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var updater = AppUpdater.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.accentColor.opacity(0.12))
                            .frame(width: 44, height: 44)
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(.accentColor)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.tr("settings.general"))
                            .font(.system(size: 17, weight: .bold))
                        Text(L10n.tr("menu.barttery"))
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }

                // System options
                VStack(alignment: .leading, spacing: 14) {
                    Toggle(isOn: $settings.launchAtLogin) {
                        Label(L10n.tr("menu.launch_at_login"), systemImage: "power")
                            .font(.system(size: 13))
                    }

                    Toggle(isOn: $settings.showPercentageInMenuBar) {
                        Label(L10n.tr("settings.show_percentage_menubar"), systemImage: "percent")
                            .font(.system(size: 13))
                    }
                }
                .padding(14)
                .background(Color.secondary.opacity(0.06))
                .cornerRadius(10)

                // Software Update
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Barttery")
                                .font(.system(size: 13, weight: .semibold))
                            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.2.3")")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button {
                            updater.checkForUpdates()
                        } label: {
                            Text(L10n.tr("settings.check_for_updates"))
                        }
                    }
                }
                .padding(14)
                .background(Color.secondary.opacity(0.06))
                .cornerRadius(10)

                Spacer(minLength: 20)
            }
            .padding(20)
        }
    }
}

// MARK: - Custom Threshold Chip

private struct ThresholdChip: View {
    let label: String
    let color: Color
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
            Button(action: onDelete) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .opacity(0.7)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(color.opacity(0.15))
        .foregroundColor(color)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(color.opacity(0.3), lineWidth: 1))
    }
}

// MARK: - Add Threshold Popover

private struct AddThresholdPopover: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let onAdd: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))

            Text("\(Int(value))%")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundColor(.accentColor)

            Slider(value: $value, in: range, step: step)
                .frame(width: 180)

            HStack {
                Button(L10n.tr("rules.cancel")) {
                    onCancel()
                }
                .buttonStyle(.borderless)

                Spacer()

                Button(L10n.tr("rules.add")) {
                    onAdd()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 4)
        }
        .padding(16)
        .frame(width: 220)
    }
}
