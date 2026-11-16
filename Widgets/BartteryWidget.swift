import SwiftUI
import WidgetKit

struct BatteryEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetBatterySnapshot
}

struct BatteryTimelineProvider: TimelineProvider {
    var layout: WidgetBatteryLayout = .fourWide

    func placeholder(in context: Context) -> BatteryEntry {
        BatteryEntry(date: Date(), snapshot: .placeholder(layout: layout))
    }

    func getSnapshot(in context: Context, completion: @escaping (BatteryEntry) -> Void) {
        completion(BatteryEntry(date: Date(), snapshot: context.isPreview ? .placeholder(layout: layout) : WidgetSnapshotStore.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BatteryEntry>) -> Void) {
        let now = Date()
        let snapshot = WidgetSnapshotStore.read()
        // Pre-schedule freshness transitions even if the host app stops running.
        let expiryDates = Set(snapshot.displayedDevices(for: layout).map {
            $0.updatedAt.addingTimeInterval(WidgetBatterySnapshot.staleInterval)
        }.filter { $0 > now }).sorted()
        let entries = [BatteryEntry(date: now, snapshot: snapshot)] + expiryDates.map {
            BatteryEntry(date: $0, snapshot: snapshot)
        }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(15 * 60))))
    }
}

private func nativeBatteryTint(for device: WidgetBatteryDevice, stale: Bool, colorScheme: ColorScheme = .dark) -> Color {
    if stale { return .secondary }
    if device.level <= 15 && !device.isCharging {
        return colorScheme == .dark
            ? Color(red: 255/255, green: 69/255, blue: 58/255)
            : Color(red: 255/255, green: 59/255, blue: 48/255)
    } else if device.level <= 35 && !device.isCharging {
        return colorScheme == .dark
            ? Color(red: 255/255, green: 159/255, blue: 10/255)
            : Color(red: 255/255, green: 149/255, blue: 0/255)
    } else if device.isPaused {
        return colorScheme == .dark
            ? Color(red: 10/255, green: 132/255, blue: 255/255)
            : Color(red: 0/255, green: 122/255, blue: 255/255)
    } else {
        return colorScheme == .dark
            ? Color(red: 48/255, green: 209/255, blue: 88/255)
            : Color(red: 40/255, green: 205/255, blue: 65/255)
    }
}

struct BatteryWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.widgetRenderingMode) private var renderingMode

    let entry: BatteryEntry
    var layout: WidgetBatteryLayout = .fourWide
    // WidgetKit supplies this read-only environment value; offscreen previews cannot set it.
    var previewFamily: WidgetFamily? = nil

    private var tableSlotCount: Int {
        (previewFamily ?? family) == .systemLarge ? 8 : 4
    }

    private var devices: [WidgetBatteryDevice] {
        let limit = layout == .table ? tableSlotCount : layout.capacity
        return Array(entry.snapshot.displayedDevices(for: layout).prefix(limit))
    }

    private var hasStaleData: Bool { devices.contains { $0.isStale(at: entry.date) } }

    var body: some View {
        Group {
            if devices.isEmpty {
                emptyStateView
            } else if layout == .table {
                tableView
            } else {
                ringsView
            }
        }
        .overlay(alignment: .topTrailing) {
            if hasStaleData && !devices.isEmpty {
                Image(systemName: "clock")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .offset(x: 6, y: -6)
                    .accessibilityLabel("Data may be out of date")
            }
        }
        .containerBackground(for: .widget) {
            if renderingMode != .fullColor {
                Color.clear
            } else if colorScheme == .dark {
                ZStack {
                    LinearGradient(
                        colors: [
                            Color(red: 32/255, green: 32/255, blue: 34/255),
                            Color(red: 24/255, green: 24/255, blue: 26/255)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    ContainerRelativeShape()
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.18),
                                    Color.white.opacity(0.05)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.75
                        )
                }
            } else {
                ZStack {
                    LinearGradient(
                        colors: [
                            Color(red: 250/255, green: 250/255, blue: 252/255),
                            Color(red: 242/255, green: 242/255, blue: 247/255)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    ContainerRelativeShape()
                        .strokeBorder(Color.black.opacity(0.06), lineWidth: 0.75)
                }
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 6) {
            Image(systemName: "battery.100percent")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Open Barttery to see your devices")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if layout == .fourWide || layout == .table {
                Text("Keep Barttery running to update batteries")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var tableView: some View {
        VStack(spacing: 0) {
            ForEach(0..<tableSlotCount, id: \.self) { index in
                if index < devices.count {
                    BatteryTableRow(device: devices[index], date: entry.date)
                        .frame(maxHeight: .infinity)
                } else {
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityHidden(true)
                }
                if index < tableSlotCount - 1 {
                    Divider().opacity(0.32)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var ringsView: some View {
        GeometryReader { geometry in
            let rows = max(1, layout.capacity / layout.columns)
            let verticalSpacing: CGFloat = layout.isCompact ? 10 : 8
            let horizontalSpacing: CGFloat = layout.isCompact ? 10 : 12
            let rowHeight = (geometry.size.height - CGFloat(rows - 1) * verticalSpacing) / CGFloat(rows)
            let columnWidth = (geometry.size.width - CGFloat(layout.columns - 1) * horizontalSpacing) / CGFloat(layout.columns)
            let labelHeight: CGFloat = layout.isCompact ? 0 : (layout == .single ? 32 : 30)
            let maxRing: CGFloat = layout == .single ? 80 : (layout.isCompact ? 54 : 56)
            let ringSize = max(20, min(maxRing, min(rowHeight - labelHeight, columnWidth - 4)))
            let lineWidth: CGFloat = layout == .single ? 6.5 : (layout.isCompact ? 5 : 5.75)

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: horizontalSpacing), count: layout.columns),
                spacing: verticalSpacing
            ) {
                ForEach(0..<layout.capacity, id: \.self) { index in
                    if index < devices.count {
                        BatteryRing(
                            device: devices[index],
                            date: entry.date,
                            size: ringSize,
                            lineWidth: lineWidth,
                            compact: layout.isCompact,
                            single: layout == .single
                        )
                        .frame(height: rowHeight)
                    } else {
                        EmptyBatteryRing(
                            size: ringSize,
                            lineWidth: lineWidth,
                            compact: layout.isCompact,
                            single: layout == .single
                        )
                        .frame(height: rowHeight)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }
}

private struct BatteryTableRow: View {
    @Environment(\.colorScheme) private var colorScheme

    let device: WidgetBatteryDevice
    let date: Date

    private var stale: Bool { device.isStale(at: date) }
    private var tint: Color { nativeBatteryTint(for: device, stale: stale, colorScheme: colorScheme) }
    private var primaryInk: Color {
        colorScheme == .dark ? Color.white.opacity(0.92) : Color.primary.opacity(0.86)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: device.symbol)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(stale ? Color.secondary : primaryInk)
                .frame(width: 24, alignment: .center)

            Text(device.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(stale ? Color.secondary : primaryInk)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                Text("\(device.level)%")
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                MiniBatteryGauge(
                    level: device.level,
                    tint: tint,
                    statusSymbol: device.statusSymbol
                )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(device.name), \(device.level)%")
        .accessibilityValue(stale ? "Out of date" : device.statusDescription)
    }
}

private struct MiniBatteryGauge: View {
    let level: Int
    let tint: Color
    let statusSymbol: String?

    var body: some View {
        HStack(spacing: 1.5) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .stroke(.secondary.opacity(0.45), lineWidth: 1)

                GeometryReader { geo in
                    let fillRatio = CGFloat(min(100, max(0, level))) / 100
                    let maxW = max(0, geo.size.width - 3)
                    let fillW = max(2, maxW * fillRatio)
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(tint)
                        .widgetAccentable()
                        .frame(width: fillW)
                        .padding(1.5)
                }

                if let statusSymbol {
                    Image(systemName: statusSymbol)
                        .font(.system(size: 7.5, weight: .black))
                        .foregroundStyle(level >= 45 ? .white : .primary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: 21, height: 11)

            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(.secondary.opacity(0.45))
                .frame(width: 1.5, height: 4)
        }
    }
}

private struct BatteryRing: View {
    @Environment(\.colorScheme) private var colorScheme

    let device: WidgetBatteryDevice
    let date: Date
    var size: CGFloat = 56
    var lineWidth: CGFloat = 5.5
    var compact: Bool = false
    var single: Bool = false

    private var stale: Bool { device.isStale(at: date) }
    private var tint: Color { nativeBatteryTint(for: device, stale: stale, colorScheme: colorScheme) }
    private var trackColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.10)
    }
    private var iconColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.92) : Color.primary.opacity(0.84)
    }
    private var labelColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.88) : Color.primary.opacity(0.85)
    }

    var body: some View {
        VStack(spacing: single ? 11 : 10) {
            ZStack {
                Circle()
                    .stroke(trackColor, lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: CGFloat(min(100, max(0, device.level))) / 100)
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .widgetAccentable()

                Image(systemName: device.symbol)
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(stale ? Color.secondary : iconColor)

                if compact, let statusSymbol = device.statusSymbol {
                    Image(systemName: statusSymbol)
                        .font(.system(size: max(8, size * 0.19), weight: .bold))
                        .foregroundStyle(tint)
                        .padding(2)
                        .background(Circle().fill(.ultraThinMaterial))
                        .offset(y: size * 0.46)
                }
            }
            .frame(width: size, height: size)

            if !compact {
                HStack(spacing: 2.5) {
                    Text("\(device.level)%")
                        .font(.system(size: single ? 18 : 16, weight: .regular))
                        .monospacedDigit()
                        .foregroundStyle(stale ? Color.secondary : labelColor)

                    if let statusSymbol = device.statusSymbol {
                        Image(systemName: statusSymbol)
                            .font(.system(size: single ? 13 : 10.5, weight: .bold))
                            .foregroundStyle(tint)
                            .widgetAccentable()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(device.name), \(device.level)%")
        .accessibilityValue(stale ? "Out of date" : device.statusDescription)
    }
}

private struct EmptyBatteryRing: View {
    @Environment(\.colorScheme) private var colorScheme

    let size: CGFloat
    let lineWidth: CGFloat
    let compact: Bool
    let single: Bool

    private var trackColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.10)
    }

    var body: some View {
        VStack(spacing: single ? 11 : 10) {
            Circle()
                .stroke(trackColor, lineWidth: lineWidth)
                .frame(width: size, height: size)

            if !compact {
                Text("0%")
                    .font(.system(size: single ? 18 : 16, weight: .regular))
                    .opacity(0)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }
}

#if !WIDGET_RENDER
@main
struct BartteryWidgets: WidgetBundle {
    var body: some Widget {
        BartteryWidget()
        SingleBatteryWidget()
        FourSquareBatteryWidget()
        TableBatteryWidget()
    }
}

struct BartteryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSnapshotStore.widgetKind, provider: BatteryTimelineProvider()) { entry in
            BatteryWidgetView(entry: entry)
        }
        .configurationDisplayName("Batteries")
        .description("Battery levels for up to four of your devices. Keep Barttery running for fresh readings.")
        .supportedFamilies([.systemMedium])
        .containerBackgroundRemovable(true)
    }
}

struct SingleBatteryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetBatteryLayout.single.widgetKind, provider: BatteryTimelineProvider(layout: .single)) { entry in
            BatteryWidgetView(entry: entry, layout: .single)
        }
        .configurationDisplayName("Battery · 1 device")
        .description("One device with a large battery ring. Keep Barttery running for fresh readings.")
        .supportedFamilies([.systemSmall])
        .containerBackgroundRemovable(true)
    }
}

struct FourSquareBatteryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetBatteryLayout.fourSquare.widgetKind, provider: BatteryTimelineProvider(layout: .fourSquare)) { entry in
            BatteryWidgetView(entry: entry, layout: .fourSquare)
        }
        .configurationDisplayName("Batteries · 4 devices")
        .description("Four battery rings in a compact square. Keep Barttery running for fresh readings.")
        .supportedFamilies([.systemSmall])
        .containerBackgroundRemovable(true)
    }
}

struct TableBatteryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetBatteryLayout.table.widgetKind, provider: BatteryTimelineProvider(layout: .table)) { entry in
            BatteryWidgetView(entry: entry, layout: .table)
        }
        .configurationDisplayName("Batteries · Table")
        .description("Device names, battery levels, and charging status in rows. Up to four devices in medium size or eight in large size.")
        .supportedFamilies([.systemMedium, .systemLarge])
        .containerBackgroundRemovable(true)
    }
}

struct BartteryWidgetPreviews: PreviewProvider {
    static var previews: some View {
        BatteryWidgetView(entry: BatteryEntry(date: Date(), snapshot: .placeholder()))
            .previewContext(WidgetPreviewContext(family: .systemMedium))
    }
}
#endif
