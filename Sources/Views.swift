import SwiftUI
import AppKit

private let popupExpandAnimation: Animation = .easeInOut(duration: 0.2)
private let popupCornerRadius: CGFloat = 14

private struct RefreshButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(configuration.isPressed ? .primary : .secondary)
    }
}

// MARK: - Menu bar icon

struct MenuBarLabel: View {
    @ObservedObject var monitor: DeviceBatteryMonitor

    var body: some View {
        Image(nsImage: monitor.menuBarIcon)
            .renderingMode(.template)
            .interpolation(.high)
            .antialiased(true)
            .frame(maxHeight: .infinity)
    }
}

// MARK: - Popup window

struct MenuContentView: View {
    @EnvironmentObject var monitor: DeviceBatteryMonitor
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var updater = AppUpdater.shared
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        let fitted = contentHeight > 1 ? min(contentHeight, Self.maxPopupHeight) : nil
        let scrolling = fitted.map { contentHeight > $0 + 1 } ?? false

        ScrollView(.vertical, showsIndicators: scrolling) {
            menuStack
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: MenuContentHeightKey.self,
                            value: geo.size.height
                        )
                    }
                )
        }
        .scrollContentBackground(.hidden)
        .frame(width: 360, alignment: .top)
        .frame(height: fitted, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: popupCornerRadius, style: .continuous)
                .fill(Color(NSColor.windowBackgroundColor).opacity(0.92))
        )
        .onPreferenceChange(MenuContentHeightKey.self) { newValue in
            guard abs(newValue - contentHeight) > 0.5 else { return }
            if contentHeight <= 1 {
                contentHeight = newValue
            } else {
                withAnimation(popupExpandAnimation) { contentHeight = newValue }
            }
        }
        .background(MenuBarWindowHeightAnimator(height: fitted ?? 0))
    }

    private static var maxPopupHeight: CGFloat {
        guard let screen = NSScreen.main else { return 800 }
        return max(240, screen.visibleFrame.height - 12)
    }

    private var menuStack: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button {
                    NSWorkspace.shared.open(URL(string: "https://github.com/yurastegny/barttery")!)
                } label: {
                    Text("Barttery")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                Spacer()
                RefreshButton(monitor: monitor)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 4)

            if monitor.hasAnyDevices {
                VStack(spacing: 8) {
                    if let mac = monitor.macBattery {
                        DeviceRow(icon: "macbook", name: monitor.displayMacName,
                                  battery: mac.level, state: mac.state, device: .mac)
                    }
                    if let pods = monitor.airPodsBattery {
                        AirPodsRow(name: monitor.displayAirPodsName, battery: pods, isConnected: monitor.airPodsConnected)
                    }
                    ForEach(monitor.accessories, id: \.name) { acc in
                        AccessoryRow(accessory: acc)
                    }
                    if let pct = monitor.phoneBattery {
                        DeviceRow(icon: "iphone", name: monitor.displayPhoneName,
                                  battery: pct, state: monitor.phoneCharging ? .charging : .discharging, device: .phone)
                    }
                    if let pct = monitor.padBattery {
                        DeviceRow(icon: "ipad", name: monitor.padName,
                                  battery: pct, state: monitor.padCharging ? .charging : .discharging, device: .pad)
                    }
                    if let watch = monitor.watchBattery {
                        DeviceRow(icon: "applewatch", name: watch.name,
                                  battery: watch.level, state: watch.isCharging ? .charging : .discharging,
                                  device: .watch, chargingKnown: watch.chargingKnown)
                    }
                }
                .padding(.leading, 16)
                .padding(.trailing, 16)
                .padding(.top, 10)
                .padding(.bottom, 10)
            } else {
                EmptyDevicesView()
                    .padding(.top, 12)
                    .padding(.bottom, 12)
            }

            Button {
                settings.launchAtLogin.toggle()
            } label: {
                HStack {
                    Text(L10n.tr("menu.launch_at_login"))
                    Spacer()
                    if settings.launchAtLogin {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(.system(size: 14, weight: .regular))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Button {
                SettingsWindowController.shared.show()
            } label: {
                HStack {
                    Text(L10n.tr("menu.settings"))
                    Spacer()
                    Image(systemName: "gearshape")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(.system(size: 14, weight: .regular))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .keyboardShortcut(",", modifiers: .command)

            if updater.isUpdateAvailable {
                Button {
                    updater.showUpdate()
                } label: {
                    HStack {
                        Text(L10n.tr("menu.update_available"))
                        Spacer()
                        Image(systemName: "arrow.down.circle")
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(.system(size: 14, weight: .regular))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .disabled(!updater.canCheckForUpdates)
            }

            Divider().padding(.horizontal, 16)

            HStack(alignment: .center) {
                if let cycles = monitor.macBattery?.cycleCount, cycles > 0 {
                    Text(L10n.tr("menu.cycles", "MacBook", cycles))
                        .foregroundColor(.secondary)
                        .offset(y: -1)
                }
                Spacer()
                Button(L10n.tr("menu.quit")) {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.borderless)
                .font(.system(size: 14, weight: .regular))
                .keyboardShortcut("q", modifiers: .command)
                .offset(y: -1)
            }
            .font(.system(size: 14, weight: .regular))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

}

private struct MenuContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct MenuBarWindowHeightAnimator: View, Animatable {
    var height: CGFloat

    var animatableData: CGFloat {
        get { height }
        set { height = newValue }
    }

    var body: some View {
        MenuBarWindowHeightSync(contentHeight: height)
    }
}

private struct MenuBarWindowHeightSync: NSViewRepresentable {
    let contentHeight: CGFloat

    private static let cornerRadiusSelectors = [
        "_setCornerRadius:",
        "_setEffectiveCornerRadius:",
        "_setTopCornerRadius:",
        "_setBottomCornerRadius:"
    ].map(NSSelectorFromString)

    private static let cornerMaskSelectors = [
        "_updateCornerMask",
        "_cornerMaskChanged"
    ].map(NSSelectorFromString)

    final class Coordinator {
        weak var configuredWindow: NSWindow?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = popupCornerRadius
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        return effect
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        let coordinator = context.coordinator
        let apply = {
            if let window = nsView.window, coordinator.configuredWindow !== window {
                Self.applyWindowShape(probe: nsView)
                coordinator.configuredWindow = window
            }
            Self.resize(window: nsView.window, contentHeight: contentHeight)
        }
        if nsView.window == nil {
            DispatchQueue.main.async(execute: apply)
        } else {
            apply()
        }
    }

    static func dismantleNSView(_ nsView: NSVisualEffectView, coordinator: Coordinator) {
        coordinator.configuredWindow = nil
    }

    private static func applyWindowShape(probe: NSView) {
        guard let window = probe.window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
        setWindowCornerRadius(window, popupCornerRadius)
        applyMenuMaterial(from: window.contentView, probe: probe)
        window.invalidateShadow()
    }

    private static func isAncestor(_ view: NSView, of descendant: NSView) -> Bool {
        var current: NSView? = descendant
        while let node = current {
            if node === view { return true }
            current = node.superview
        }
        return false
    }

    private static func applyMenuMaterial(from start: NSView?, probe: NSView) {
        guard let start else { return }
        func walk(_ view: NSView) {
            if let effect = view as? NSVisualEffectView {
                effect.material = .popover
                effect.blendingMode = .withinWindow
                effect.state = .active
            }
            if #available(macOS 26.0, *),
               let glass = view as? NSGlassEffectView,
               glass.bounds.width > 200,
               !isAncestor(glass, of: probe) {
                glass.isHidden = true
            }
            view.subviews.forEach(walk)
        }
        var root: NSView? = start
        while let superview = root?.superview { root = superview }
        if let root { walk(root) }
    }

    private static func setWindowCornerRadius(_ window: NSWindow, _ radius: CGFloat) {
        guard let cls: AnyClass = object_getClass(window) else { return }
        for sel in cornerRadiusSelectors {
            guard let method = class_getInstanceMethod(cls, sel) else { continue }
            let fn = unsafeBitCast(
                method_getImplementation(method),
                to: (@convention(c) (AnyObject, Selector, CGFloat) -> Void).self
            )
            fn(window, sel, radius)
        }
        for sel in cornerMaskSelectors {
            if window.responds(to: sel) { window.perform(sel) }
        }
    }

    private static func resize(window: NSWindow?, contentHeight: CGFloat) {
        guard let window, let contentView = window.contentView, contentHeight > 1 else { return }
        let top = window.frame.maxY
        let screenMinY = (window.screen ?? NSScreen.main)?.visibleFrame.minY ?? 0
        let chrome = window.frame.height - contentView.frame.height
        let capped = min(
            contentHeight + chrome,
            max(120, top - screenMinY)
        )
        guard abs(capped - window.frame.height) > 0.5 else { return }
        var frame = window.frame
        frame.size.height = capped
        frame.origin.y = top - capped
        window.setFrame(frame, display: true, animate: false)
    }
}

// MARK: - Empty devices view

struct EmptyDevicesView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "bolt.slash.fill")
                .font(.system(size: 26))
                .foregroundColor(.secondary.opacity(0.6))
                .padding(.top, 6)

            Text(L10n.tr("empty.title"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.primary)

            Text(L10n.tr("empty.message"))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.06))
        )
        .padding(.horizontal, 16)
    }
}

// MARK: - Relative time formatting

func formatRelativeTime(since date: Date?) -> String? {
    guard let date = date else { return nil }
    let elapsed = Date().timeIntervalSince(date)
    guard elapsed >= 600 else { return nil }
    let mins = Int(elapsed / 60)
    if mins < 60 {
        return "\(mins)m"
    }
    let hours = mins / 60
    return "\(hours)h"
}

// MARK: - Refresh button

struct RefreshButton: View {
    @ObservedObject var monitor: DeviceBatteryMonitor
    @State private var isHovered = false

    var body: some View {
        Button {
            guard !monitor.isRefreshing else { return }
            monitor.refresh(userInitiated: true)
            NotificationCenter.default.post(name: .userInitiatedRefresh, object: nil)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 14, height: 14)
                    .rotationEffect(.degrees(monitor.isRefreshing ? 360 : 0))
                    .animation(
                        monitor.isRefreshing
                            ? Animation.linear(duration: 0.85).repeatForever(autoreverses: false)
                            : .easeOut(duration: 0.2),
                        value: monitor.isRefreshing
                    )

                Text(L10n.tr("menu.refresh"))
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(monitor.isRefreshing ? Color.accentColor.opacity(0.12) : (isHovered ? Color.primary.opacity(0.06) : Color.clear))
            )
            .foregroundColor(monitor.isRefreshing ? .accentColor : .secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(monitor.isRefreshing)
        .onHover { isHovered = $0 }
        .keyboardShortcut("r", modifiers: .command)
    }
}

// MARK: - Device row

struct DeviceRow: View {
    let icon: String
    let name: String
    let battery: Int
    let state: ChargeState
    let device: BatteryDevice
    var chargingKnown: Bool = true

    @State private var expanded = false
    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    private var isLowBattery: Bool {
        battery <= 20 && (!chargingKnown || state == .discharging)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                // Device Icon in soft tinted squircle
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(iconBackgroundColor)
                        .frame(width: 28, height: 28)

                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(iconForegroundColor)
                }

                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .center) {
                        Text(name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.primary)

                        Spacer()

                        HStack(spacing: 6) {
                            statusBadge

                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.secondary.opacity(0.6))
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                                .animation(.easeInOut(duration: 0.18), value: expanded)
                        }
                    }

                    BatteryBar(level: battery, state: state)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05) : Color.primary.opacity(colorScheme == .dark ? 0.04 : 0.025))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.04), lineWidth: 0.5)
            )
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .onTapGesture {
                withAnimation(popupExpandAnimation) { expanded.toggle() }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(name), \(battery)%, \(chargeTooltip)")

            if expanded {
                NotificationThresholdRow(device: device)
                    .padding(.leading, 38)
                    .padding(.trailing, 10)
                    .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        HStack(spacing: 4) {
            if chargingKnown && state == .charging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(EyeFriendlyColors.charging)
            } else if chargingKnown && state == .paused {
                Image(systemName: "pause.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(EyeFriendlyColors.paused)
            } else if chargingKnown && state == .plugged {
                Image(systemName: "powerplug.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
            }

            Text("\(battery)%")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundColor(levelTextColor)
        }
    }

    private var levelTextColor: Color {
        if isLowBattery {
            return EyeFriendlyColors.red
        } else {
            return .primary
        }
    }

    private var iconBackgroundColor: Color {
        switch device {
        case .mac:
            return EyeFriendlyColors.mac
        case .phone, .pad:
            return EyeFriendlyColors.phone
        case .watch:
            return EyeFriendlyColors.watch
        case .airPods:
            return EyeFriendlyColors.airPods
        default:
            return EyeFriendlyColors.accessory
        }
    }

    private var iconForegroundColor: Color {
        switch device {
        case .mac:
            return .primary.opacity(0.85)
        case .phone, .pad:
            return EyeFriendlyColors.phoneFg
        case .watch:
            return EyeFriendlyColors.watchFg
        case .airPods:
            return EyeFriendlyColors.airPodsFg
        default:
            return EyeFriendlyColors.accessoryFg
        }
    }

    private var chargeTooltip: String {
        switch state {
        case .charging:    return L10n.tr("status.charging")
        case .plugged:     return L10n.tr("status.plugged")
        case .paused:      return L10n.tr("status.paused")
        case .discharging: return L10n.tr("status.battery_status")
        }
    }
}

// MARK: - Battery bar

struct BatteryBar: View {
    let level: Int
    var state: ChargeState = .discharging

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let fillW = max(4, w * CGFloat(min(max(level, 0), 100)) / 100)

            ZStack(alignment: .leading) {
                // Background Track
                Capsule()
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.09 : 0.06))

                // Progress Fill with eye-friendly smooth gradient
                Capsule()
                    .fill(barGradient)
                    .frame(width: fillW)
            }
        }
        .frame(height: 4)
    }

    private var barGradient: LinearGradient {
        LinearGradient(
            colors: gradientColors,
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private var gradientColors: [Color] {
        switch state {
        case .charging:
            return [EyeFriendlyColors.charging, EyeFriendlyColors.chargingSoft]
        case .paused:
            return [EyeFriendlyColors.paused, EyeFriendlyColors.pausedSoft]
        case .plugged:
            return [EyeFriendlyColors.paused, EyeFriendlyColors.charging]
        case .discharging:
            if level <= 15 {
                return [EyeFriendlyColors.red, EyeFriendlyColors.redSoft]
            } else if level <= 35 {
                return [EyeFriendlyColors.amber, EyeFriendlyColors.amberSoft]
            } else {
                return [EyeFriendlyColors.charging, EyeFriendlyColors.chargingSoft]
            }
        }
    }
}

// MARK: - AirPods row

struct AirPodsRow: View {
    let name: String
    let battery: AirPodsBattery
    var isConnected: Bool = true

    @State private var expanded = false
    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    private var isPro: Bool { name.lowercased().contains("pro") }

    private var isCharging: Bool {
        battery.leftCharging || battery.rightCharging
    }

    private var isLowBattery: Bool {
        if let lvl = podsBarLevel, lvl <= 20, !isCharging {
            return true
        }
        return false
    }

    private var podsBarLevel: Int? {
        [battery.left, battery.right].compactMap { $0 }.min()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Main AirPods Card (Earbuds)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(EyeFriendlyColors.airPods)
                            .frame(width: 28, height: 28)

                        Image(systemName: isPro ? "airpodspro" : "airpods")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(EyeFriendlyColors.airPodsFg)
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .center) {
                            Text(name)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.primary)

                            if !isConnected {
                                Text(isCharging ? L10n.tr("status.in_case") : L10n.tr("status.nearby"))
                                    .font(.system(size: 10, weight: .medium))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1.5)
                                    .background(Color.secondary.opacity(0.12))
                                    .clipShape(Capsule())
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            HStack(spacing: 6) {
                                podsBadge

                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(.secondary.opacity(0.6))
                                    .rotationEffect(.degrees(expanded ? 90 : 0))
                                    .animation(.easeInOut(duration: 0.18), value: expanded)
                            }
                        }

                        if let barLevel = podsBarLevel {
                            BatteryBar(level: barLevel, state: isCharging ? .charging : .discharging)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isHovered ? Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05) : Color.primary.opacity(colorScheme == .dark ? 0.04 : 0.025))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.04), lineWidth: 0.5)
                )
                .contentShape(Rectangle())
                .onHover { isHovered = $0 }
                .onTapGesture {
                    withAnimation(popupExpandAnimation) { expanded.toggle() }
                }
                .accessibilityElement(children: .combine)

                if expanded {
                    NotificationThresholdRow(device: .airPods)
                        .padding(.leading, 38)
                        .padding(.trailing, 10)
                        .transition(.opacity)
                }
            }

            // AirPods Case Row
            if let caseLevel = battery.case {
                HStack(alignment: .center, spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.secondary.opacity(0.08))
                            .frame(width: 28, height: 28)

                        Image(systemName: isPro ? "airpodspro.chargingcase.wireless" : "airpods.chargingcase")
                            .font(.system(size: 14, weight: .regular))
                            .foregroundColor(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .center) {
                            Text(L10n.tr("status.case"))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.secondary)

                            Spacer()

                            HStack(spacing: 4) {
                                if battery.caseCharging {
                                    Image(systemName: "bolt.fill")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundColor(EyeFriendlyColors.charging)
                                }
                                Text("\(caseLevel)%")
                                    .font(.system(size: 13, weight: .bold, design: .rounded))
                                    .foregroundColor(.secondary)
                            }
                        }

                        BatteryBar(level: caseLevel, state: battery.caseCharging ? .charging : .discharging)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(colorScheme == .dark ? 0.03 : 0.015))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.primary.opacity(colorScheme == .dark ? 0.05 : 0.03), lineWidth: 0.5)
                )
            }
        }
    }

    @ViewBuilder
    private var podsBadge: some View {
        HStack(spacing: 5) {
            if isCharging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(EyeFriendlyColors.charging)
            }

            switch (battery.left, battery.right) {
            case (let l?, let r?) where l != r:
                HStack(spacing: 4) {
                    Text("L \(l)%")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(l <= 20 && !battery.leftCharging ? EyeFriendlyColors.red : .primary)
                    Text("·")
                        .foregroundColor(.secondary)
                    Text("R \(r)%")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(r <= 20 && !battery.rightCharging ? EyeFriendlyColors.red : .primary)
                }
            case (let l?, _):
                Text("\(l)%")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(isLowBattery ? EyeFriendlyColors.red : .primary)
            case (_, let r?):
                Text("\(r)%")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(isLowBattery ? EyeFriendlyColors.red : .primary)
            default:
                EmptyView()
            }
        }
    }
}

// MARK: - Accessory row (keyboard / mouse / trackpad / headphones)

struct AccessoryRow: View {
    let accessory: AccessoryBattery

    @State private var expanded = false
    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    private var isLowBattery: Bool {
        accessory.level <= 20 && (!accessory.chargingKnown || !accessory.charging)
    }

    private var relativeTime: String? {
        formatRelativeTime(since: accessory.updatedAt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(EyeFriendlyColors.accessory)
                        .frame(width: 28, height: 28)

                    Image(systemName: accessory.icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(EyeFriendlyColors.accessoryFg)
                }

                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .center) {
                        Text(accessory.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.primary)

                        Spacer()

                        HStack(spacing: 5) {
                            if let relative = relativeTime {
                                Text(relative)
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary.opacity(0.8))
                                    .padding(.trailing, 2)
                            }

                            if accessory.chargingKnown && accessory.charging {
                                Image(systemName: "bolt.fill")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(EyeFriendlyColors.charging)
                            }

                            Text("\(accessory.level)%")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundColor(isLowBattery ? EyeFriendlyColors.red : .primary)

                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.secondary.opacity(0.6))
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                                .animation(.easeInOut(duration: 0.18), value: expanded)
                        }
                    }

                    BatteryBar(
                        level: accessory.level,
                        state: (accessory.chargingKnown && accessory.charging) ? .charging : .discharging
                    )
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05) : Color.primary.opacity(colorScheme == .dark ? 0.04 : 0.025))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.04), lineWidth: 0.5)
            )
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .onTapGesture {
                withAnimation(popupExpandAnimation) { expanded.toggle() }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(accessory.name), \(accessory.level)%")

            if expanded {
                NotificationThresholdRow(device: accessory.batteryDevice, accessory: accessory)
                    .padding(.leading, 38)
                    .padding(.trailing, 10)
                    .transition(.opacity)
            }
        }
    }
}

// MARK: - Notification threshold row

struct NotificationThresholdRow: View {
    let device: BatteryDevice
    var accessory: AccessoryBattery? = nil
    @ObservedObject private var settings = AppSettings.shared
    @EnvironmentObject private var monitor: DeviceBatteryMonitor
    @Environment(\.colorScheme) private var colorScheme

    @State private var showingAddBelow = false
    @State private var showingAddAbove = false
    @State private var quickBelowValue: Double = 15
    @State private var quickAboveValue: Double = 85

    private var updatedAt: Date? {
        if let accessory { return accessory.updatedAt }
        return monitor.syncTimes[device.rawValue]
    }

    private var targetWidgetId: String {
        if let accessory {
            return "accessory.\(accessory.name)"
        }
        switch device {
        case .mac:        return "mac"
        case .phone:      return "phone"
        case .pad:        return "pad"
        case .watch:      return "watch"
        case .airPods:    return "airpods"
        default:          return "accessory"
        }
    }

    private var rules: DeviceNotificationRules {
        settings.rules(for: device)
    }

    // Active thresholds configured by the user; fallback to recommended presets when empty
    private var belowOptions: [Int] {
        if rules.below.isEmpty {
            return [10, 20]
        }
        return rules.below
    }

    private var aboveOptions: [Int] {
        if rules.above.isEmpty {
            return [80, 100]
        }
        return rules.above
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header with status & settings button
            HStack(alignment: .center) {
                Text(L10n.tr("notification.notifications"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)

                Spacer()

                if device == .mac, let mac = monitor.macBattery {
                    if let mins = mac.minutesToFull {
                        Text(L10n.tr("status.to_full", formatMinutes(mins)))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    } else if let mins = mac.minutesToEmpty {
                        Text(L10n.tr("status.remaining", formatMinutes(mins)))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    } else if mac.state == .charging || mac.state == .discharging {
                        Text(L10n.tr("status.calculating"))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                } else if accessory != nil || updatedAt != nil {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(BatteryUpdateAge.text(since: updatedAt, at: context.date))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }

                Button {
                    SettingsWindowController.shared.show(selectedDevice: device, tab: .widget)
                } label: {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 11))
                        .foregroundColor(settings.isDeviceEnabledForWidget(id: targetWidgetId) ? .accentColor : .secondary.opacity(0.6))
                }
                .buttonStyle(.plain)
                .help(L10n.tr("widget.show_in_widget"))

                Button {
                    SettingsWindowController.shared.show(selectedDevice: device, tab: .notifications)
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help(L10n.tr("menu.settings"))
            }

            // Below thresholds (Discharge)
            HStack(spacing: 6) {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 9, weight: .bold))
                    Text(L10n.tr("rules.below_label"))
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(EyeFriendlyColors.amber)
                .frame(width: 44, alignment: .leading)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(belowOptions, id: \.self) { val in
                            ModernChip(
                                label: "\(val)%",
                                isEnabled: rules.below.contains(val),
                                accentColor: EyeFriendlyColors.amber
                            ) {
                                settings.toggleThreshold(device: device, type: .below, threshold: val)
                            }
                        }

                        Button {
                            showingAddBelow = true
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 10, weight: .bold))
                                .frame(width: 22, height: 20)
                                .foregroundColor(.secondary)
                                .background(Color.secondary.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showingAddBelow) {
                            QuickAddPopover(
                                title: L10n.tr("rules.section_below"),
                                value: $quickBelowValue,
                                range: 5...50,
                                step: 5,
                                color: EyeFriendlyColors.amber,
                                onAdd: {
                                    settings.addThreshold(device: device, type: .below, threshold: Int(quickBelowValue))
                                    showingAddBelow = false
                                }
                            )
                        }
                    }
                }
            }

            // Above thresholds (Charging)
            if device != .airPods && device != .headphones {
                HStack(spacing: 6) {
                    HStack(spacing: 3) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 9, weight: .bold))
                        Text(L10n.tr("rules.above_label"))
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(EyeFriendlyColors.charging)
                    .frame(width: 44, alignment: .leading)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 5) {
                            ForEach(aboveOptions, id: \.self) { val in
                                ModernChip(
                                    label: "\(val)%",
                                    isEnabled: rules.above.contains(val),
                                    accentColor: EyeFriendlyColors.charging
                                ) {
                                    settings.toggleThreshold(device: device, type: .above, threshold: val)
                                }
                            }

                            Button {
                                showingAddAbove = true
                            } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 10, weight: .bold))
                                    .frame(width: 22, height: 20)
                                    .foregroundColor(.secondary)
                                    .background(Color.secondary.opacity(0.12))
                                    .clipShape(RoundedRectangle(cornerRadius: 5))
                            }
                            .buttonStyle(.plain)
                            .popover(isPresented: $showingAddAbove) {
                                QuickAddPopover(
                                    title: L10n.tr("rules.section_above"),
                                    value: $quickAboveValue,
                                    range: 50...100,
                                    step: 5,
                                    color: EyeFriendlyColors.charging,
                                    onAdd: {
                                        settings.addThreshold(device: device, type: .above, threshold: Int(quickAboveValue))
                                        showingAddAbove = false
                                    }
                                )
                            }
                        }
                    }
                }
            }

            // Quick toggle for Widget display
            HStack(spacing: 6) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 10))
                    .foregroundColor(settings.isDeviceEnabledForWidget(id: targetWidgetId) ? .accentColor : .secondary)

                Text(L10n.tr("widget.show_in_widget"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                Spacer()

                Toggle("", isOn: Binding(
                    get: { settings.isDeviceEnabledForWidget(id: targetWidgetId) },
                    set: { _ in settings.toggleDeviceForWidget(id: targetWidgetId) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .scaleEffect(0.65)
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(colorScheme == .dark ? 0.12 : 0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .modifier(IsolatedGeometry())
    }
}

private struct IsolatedGeometry: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.geometryGroup()
        } else {
            content
        }
    }
}

// MARK: - Modern Chip

private struct ModernChip: View {
    let label: String
    let isEnabled: Bool
    let accentColor: Color
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: isEnabled ? .semibold : .regular))
                .foregroundColor(isEnabled ? (colorScheme == .dark ? .white : accentColor) : .secondary)
                .frame(minWidth: 36)
                .frame(height: 20)
                .padding(.horizontal, 4)
                .background(
                    isEnabled
                        ? accentColor.opacity(colorScheme == .dark ? 0.35 : 0.18)
                        : Color.clear
                )
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(
                            isEnabled
                                ? accentColor.opacity(0.6)
                                : Color.primary.opacity(0.15),
                            lineWidth: isEnabled ? 1 : 0.5
                        )
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Quick Add Popover

private struct QuickAddPopover: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let color: Color
    let onAdd: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))

            Text("\(Int(value))%")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundColor(color)

            Slider(value: $value, in: range, step: step)
                .frame(width: 140)

            HStack {
                Button(L10n.tr("rules.add")) {
                    onAdd()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 170)
    }
}


// MARK: - Helpers

private func formatMinutes(_ minutes: Int) -> String {
    if minutes <= 1 { return "1 min" }
    let h = minutes / 60
    let m = minutes % 60
    return h > 0 ? "\(h):\(String(format: "%02d", m))" : "0:\(String(format: "%02d", m))"
}

private extension Color {
    init(hex: UInt32) {
        self.init(red:   Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >>  8) & 0xFF) / 255,
                  blue:  Double( hex        & 0xFF) / 255)
    }

    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(
                red:   CGFloat((hex >> 16) & 0xFF) / 255.0,
                green: CGFloat((hex >>  8) & 0xFF) / 255.0,
                blue:  CGFloat( hex        & 0xFF) / 255.0,
                alpha: 1.0
            )
        })
    }
}

// MARK: - Eye-Friendly Semantic Color Palette

enum EyeFriendlyColors {
    // Gentle natural Apple emerald green (Charging & Good battery)
    // Light: #248A3D (gentle iOS green), Dark: #30D158 (calibrated luminance)
    static let charging = Color(light: 0x248A3D, dark: 0x30D158)
    static let chargingSoft = Color(light: 0x2DA44E, dark: 0x34C759)

    // Gentle Apple slate blue (Paused / 80% optimized charging limit)
    static let paused = Color(light: 0x0071E3, dark: 0x2997FF)
    static let pausedSoft = Color(light: 0x147CE5, dark: 0x47A1F5)

    // Gentle warm amber (16% - 35% warning)
    static let amber = Color(light: 0xD97706, dark: 0xF59E0B)
    static let amberSoft = Color(light: 0xEA580C, dark: 0xFBBF24)

    // Gentle coral red (<= 15% low battery)
    static let red = Color(light: 0xDC2626, dark: 0xEF4444)
    static let redSoft = Color(light: 0xE11D48, dark: 0xF87171)

    // Device category icon colors
    static let mac = Color.secondary.opacity(0.12)
    static let phone = Color(light: 0x0071E3, dark: 0x2997FF).opacity(0.12)
    static let watch = Color(light: 0xD97706, dark: 0xF59E0B).opacity(0.12)
    static let airPods = Color(light: 0x248A3D, dark: 0x30D158).opacity(0.12)
    static let accessory = Color(light: 0x7C3AED, dark: 0xA855F7).opacity(0.12)

    static let phoneFg = Color(light: 0x0071E3, dark: 0x2997FF)
    static let watchFg = Color(light: 0xD97706, dark: 0xF59E0B)
    static let airPodsFg = Color(light: 0x248A3D, dark: 0x30D158)
    static let accessoryFg = Color(light: 0x7C3AED, dark: 0xA855F7)
}

private func batteryColor(_ level: Int) -> Color {
    switch level {
    case 0...15:  return EyeFriendlyColors.red
    case 16...35: return EyeFriendlyColors.amber
    default:      return EyeFriendlyColors.charging
    }
}
