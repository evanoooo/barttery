import SwiftUI
import AppKit

// MARK: - Battery History View

struct BatteryHistoryView: View {
    @ObservedObject var monitor: DeviceBatteryMonitor
    @ObservedObject private var historyStore = BatteryHistoryStore.shared

    @State private var selectedDeviceKey: String = "mac"
    @State private var hoveredBucket: BatteryTimelineBucket? = nil
    @State private var isCollapsed: Bool = UserDefaults.standard.bool(forKey: "batteryHistory.isCollapsed")

    init(monitor: DeviceBatteryMonitor) {
        self.monitor = monitor
    }

    private var availableDevices: [(key: String, name: String, icon: String)] {
        var list: [(key: String, name: String, icon: String)] = [
            ("mac", monitor.displayMacName, "macbook")
        ]
        if monitor.phoneBattery != nil || (historyStore.samplesByDevice["phone"]?.isEmpty == false) {
            list.append(("phone", monitor.displayPhoneName, "iphone"))
        }
        if monitor.padBattery != nil || (historyStore.samplesByDevice["pad"]?.isEmpty == false) {
            list.append(("pad", monitor.padName, "ipad"))
        }
        if monitor.watchBattery != nil || (historyStore.samplesByDevice["watch"]?.isEmpty == false) {
            let watchName = monitor.watchBattery?.name ?? "Apple Watch"
            list.append(("watch", watchName, "applewatch"))
        }
        return list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header with title and collapse toggle
            HStack(alignment: .center) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isCollapsed.toggle()
                        UserDefaults.standard.set(isCollapsed, forKey: "batteryHistory.isCollapsed")
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                            .frame(width: 12)

                        Text(L10n.tr("history.title"))
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.primary)

                        if let hovered = hoveredBucket, let lvl = hovered.level {
                            Text("•  \(formatTimeRange(from: hovered.startDate, to: hovered.endDate))  \(lvl)%\(hovered.isCharging || hovered.isPlugged ? " ⚡" : "")")
                                .font(.system(size: 11, weight: .regular))
                                .foregroundColor(.secondary)
                                .transition(.opacity)
                        } else if !isCollapsed {
                            Text("•  \(L10n.tr("history.past24h"))")
                                .font(.system(size: 11, weight: .regular))
                                .foregroundColor(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer()

                if !isCollapsed && availableDevices.count > 1 {
                    Menu {
                        ForEach(availableDevices, id: \.key) { dev in
                            Button {
                                selectedDeviceKey = dev.key
                            } label: {
                                Label(dev.name, systemImage: dev.icon)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(availableDevices.first(where: { $0.key == selectedDeviceKey })?.name ?? "Mac")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.secondary)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06))
                        .cornerRadius(5)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }

            if !isCollapsed {
                let buckets = historyStore.timelineBuckets(for: selectedDeviceKey)
                let spans = historyStore.chargingSpans(for: buckets)

                BatteryTimelineChart(
                    buckets: buckets,
                    chargingSpans: spans,
                    hoveredBucket: $hoveredBucket
                )
                .frame(height: 104)
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    private static let timeRangeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private func formatTimeRange(from start: Date, to end: Date) -> String {
        let f = Self.timeRangeFormatter
        return "\(f.string(from: start))-\(f.string(from: end))"
    }
}

// MARK: - Battery Timeline Chart

private struct BatteryTimelineChart: View {
    let buckets: [BatteryTimelineBucket]
    let chargingSpans: [ChargingTimeSpan]
    @Binding var hoveredBucket: BatteryTimelineBucket?

    // 8 markers for 24 hours: 00:00, 03:00, 06:00, 09:00, 12:00, 15:00, 18:00, 21:00
    private static let timeMarkers: [Int] = [0, 12, 24, 36, 48, 60, 72, 84]

    // Colors matching macOS native Battery settings
    private static let batteryGreen = Color(red: 52/255, green: 199/255, blue: 89/255)
    private static let chargingTint = Color(red: 52/255, green: 199/255, blue: 89/255).opacity(0.18)
    private static let batteryLow   = Color(red: 255/255, green: 59/255, blue: 48/255)
    private static let batteryWarn  = Color(red: 255/255, green: 149/255, blue: 0/255)

    var body: some View {
        GeometryReader { geo in
            let totalW = geo.size.width
            let yAxisW: CGFloat = 32
            let chartW = max(10, totalW - yAxisW)
            let chartH: CGFloat = 62
            let indicatorH: CGFloat = 14
            let timeLabelsH: CGFloat = 16

            HStack(alignment: .top, spacing: 0) {
                // Chart area (Bars, charging highlights, grid)
                VStack(spacing: 0) {
                    ZStack(alignment: .topLeading) {
                        // 1. Horizontal dashed grid lines (100%, 50%, 0%)
                        GridLinesView(width: chartW, height: chartH)

                        // 2. Vertical dotted lines for 3-hour time markers
                        VerticalTimeMarkersView(width: chartW, height: chartH, markers: Self.timeMarkers, totalBuckets: buckets.count)

                        // 3. Charging background highlights (translucent green area)
                        ForEach(chargingSpans) { span in
                            let left = (CGFloat(span.startIndex) / CGFloat(buckets.count)) * chartW
                            let right = (CGFloat(span.endIndex + 1) / CGFloat(buckets.count)) * chartW
                            let width = max(2, right - left)

                            Rectangle()
                                .fill(Self.chargingTint)
                                .frame(width: width, height: chartH)
                                .offset(x: left, y: 0)
                        }

                        // 4. Battery Level Capsule Bars
                        Canvas { ctx, size in
                            guard !buckets.isEmpty else { return }
                            let bucketW = size.width / CGFloat(buckets.count)
                            let barW = max(1.5, bucketW * 0.65)
                            let barInset = (bucketW - barW) / 2

                            for (idx, b) in buckets.enumerated() {
                                guard let level = b.level, level > 0 else { continue }
                                let x = CGFloat(idx) * bucketW + barInset
                                let barH = max(3, (CGFloat(level) / 100.0) * size.height)
                                let y = size.height - barH

                                let rect = CGRect(x: x, y: y, width: barW, height: barH)
                                let path = Path(roundedRect: rect, cornerRadius: barW / 2)

                                let barColor: Color
                                if b.isCharging || b.isPlugged {
                                    barColor = Self.batteryGreen
                                } else if level <= 15 {
                                    barColor = Self.batteryLow
                                } else if level <= 25 {
                                    barColor = Self.batteryWarn
                                } else {
                                    barColor = Self.batteryGreen
                                }

                                ctx.fill(path, with: .color(barColor))
                            }
                        }
                        .frame(width: chartW, height: chartH)

                        // 5. Hover guide hairline
                        if let hovered = hoveredBucket {
                            let x = (CGFloat(hovered.id) + 0.5) * (chartW / CGFloat(max(1, buckets.count)))
                            Rectangle()
                                .fill(Color.primary.opacity(0.4))
                                .frame(width: 1, height: chartH)
                                .offset(x: x, y: 0)
                        }
                    }
                    .frame(width: chartW, height: chartH)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard !buckets.isEmpty, chartW > 0 else { return }
                            let ratio = min(max(location.x / chartW, 0), 0.999)
                            let index = Int(ratio * CGFloat(buckets.count))
                            if buckets.indices.contains(index) {
                                hoveredBucket = buckets[index]
                            }
                        case .ended:
                            hoveredBucket = nil
                        }
                    }

                    // Bottom charging indicator line with lightning symbol
                    ZStack(alignment: .topLeading) {
                        ForEach(chargingSpans) { span in
                            let left = (CGFloat(span.startIndex) / CGFloat(buckets.count)) * chartW
                            let right = (CGFloat(span.endIndex + 1) / CGFloat(buckets.count)) * chartW
                            let width = max(6, right - left)

                            ZStack(alignment: .center) {
                                Capsule()
                                    .fill(Self.batteryGreen)
                                    .frame(width: width, height: 3)

                                if width >= 14 {
                                    Image(systemName: "bolt.fill")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundColor(Self.batteryGreen)
                                        .padding(.horizontal, 2)
                                        .background(Color(NSColor.windowBackgroundColor))
                                }
                            }
                            .frame(width: width, height: indicatorH)
                            .offset(x: left, y: 0)
                        }
                    }
                    .frame(width: chartW, height: indicatorH, alignment: .topLeading)

                    // X-axis time labels (e.g. 0时, 03, 06, 09, 12时, 15, 18, 21)
                    ZStack(alignment: .topLeading) {
                        ForEach(Self.timeMarkers, id: \.self) { idx in
                            if buckets.indices.contains(idx) {
                                let date = buckets[idx].startDate
                                let label = formatMarkerDate(date)
                                let x = (CGFloat(idx) / CGFloat(buckets.count)) * chartW

                                Text(label)
                                    .font(.system(size: 9, weight: .regular))
                                    .foregroundColor(.secondary)
                                    .offset(x: max(0, x - 10), y: 0)
                            }
                        }
                    }
                    .frame(width: chartW, height: timeLabelsH, alignment: .topLeading)
                }

                // Y-axis labels on the right (100%, 50%, 0%)
                VStack(alignment: .leading, spacing: 0) {
                    Text("100%")
                        .font(.system(size: 8, weight: .regular))
                        .foregroundColor(.secondary)
                        .frame(height: 10, alignment: .top)

                    Spacer()

                    Text("50%")
                        .font(.system(size: 8, weight: .regular))
                        .foregroundColor(.secondary)
                        .frame(height: 10, alignment: .center)

                    Spacer()

                    Text("0%")
                        .font(.system(size: 8, weight: .regular))
                        .foregroundColor(.secondary)
                        .frame(height: 10, alignment: .bottom)
                }
                .frame(width: yAxisW, height: chartH, alignment: .trailing)
                .padding(.leading, 4)
            }
        }
    }

    private func formatMarkerDate(_ date: Date) -> String {
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: date)
        let isZh = Locale.current.language.languageCode?.identifier == "zh"
        if isZh {
            if hour == 0 { return "0时" }
            if hour == 12 { return "12时" }
            return String(format: "%02d", hour)
        } else {
            if hour == 0 { return "12A" }
            if hour == 12 { return "12P" }
            return "\(hour % 12)"
        }
    }
}

// MARK: - Grid Lines

private struct GridLinesView: View {
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        Canvas { ctx, size in
            let yValues: [CGFloat] = [0.0, size.height * 0.5, size.height]
            for y in yValues {
                var p = Path()
                p.move(to: CGPoint(x: 0, y: y))
                p.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(p, with: .color(Color.primary.opacity(0.12)),
                           style: StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
            }
        }
        .frame(width: width, height: height)
    }
}

// MARK: - Vertical Time Markers

private struct VerticalTimeMarkersView: View {
    let width: CGFloat
    let height: CGFloat
    let markers: [Int]
    let totalBuckets: Int

    var body: some View {
        Canvas { ctx, size in
            guard totalBuckets > 0 else { return }
            for idx in markers where idx > 0 && idx < totalBuckets {
                let x = (CGFloat(idx) / CGFloat(totalBuckets)) * size.width
                var p = Path()
                p.move(to: CGPoint(x: x, y: 0))
                p.addLine(to: CGPoint(x: x, y: size.height))
                ctx.stroke(p, with: .color(Color.primary.opacity(0.12)),
                           style: StrokeStyle(lineWidth: 0.8, dash: [2, 3]))
            }
        }
        .frame(width: width, height: height)
    }
}
