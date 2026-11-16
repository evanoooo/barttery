import SwiftUI
import AppKit

// MARK: - Settings Window Controller

@MainActor
class SettingsWindowController: NSObject {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show(selectedDevice: BatteryDevice? = nil) {
        NSApp.activate(ignoringOtherApps: true)

        if let window = window {
            window.makeKeyAndOrderFront(nil)
            if let dev = selectedDevice {
                NotificationCenter.default.post(name: .selectSettingsDevice, object: dev)
            }
            return
        }

        let rootView = SettingsView(initialDevice: selectedDevice ?? .mac)
        let hosting = NSHostingController(rootView: rootView)

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
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
}

// MARK: - Settings View

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var selectedDevice: BatteryDevice

    @State private var newBelowValue: Double = 15
    @State private var newAboveValue: Double = 85
    @State private var showingAddBelow = false
    @State private var showingAddAbove = false
    @State private var testNotificationSent = false

    init(initialDevice: BatteryDevice = .mac) {
        _selectedDevice = State(initialValue: initialDevice)
    }

    private var currentRules: DeviceNotificationRules {
        settings.rules(for: selectedDevice)
    }

    var body: some View {
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
                                    }
                                )
                            }
                        }
                    }
                    .padding(14)
                    .background(Color.secondary.opacity(0.06))
                    .cornerRadius(10)

                    // Section 3: Preferences & Test
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(isOn: $settings.showPercentageInMenuBar) {
                            Label(L10n.tr("settings.show_percentage_menubar"), systemImage: "percent")
                                .font(.system(size: 13))
                        }

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
        .frame(minWidth: 540, minHeight: 420)
        .onReceive(NotificationCenter.default.publisher(for: .selectSettingsDevice)) { notif in
            if let dev = notif.object as? BatteryDevice {
                self.selectedDevice = dev
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
                    // Closed by state binding
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
