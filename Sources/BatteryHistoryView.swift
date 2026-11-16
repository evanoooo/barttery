import SwiftUI
import AppKit

// MARK: - History Range

enum HistoryRange: String, CaseIterable {
    case twentyFourHours = "24h"
    case sevenDays = "7d"
}

// MARK: - Battery History View

struct BatteryHistoryView: View {
    @ObservedObject var monitor: DeviceBatteryMonitor
    @ObservedObject private var historyStore = BatteryHistoryStore.shared

    @State private var selectedDeviceKey: String = UserDefaults.standard.string(forKey: "batteryHistory.selectedDevice") ?? "mac"
    @State private var selectedRange: HistoryRange = {
        let saved = UserDefaults.standard.string(forKey: "batteryHistory.range")
        return HistoryRange(rawValue: saved ?? "24h") ?? .twentyFourHours
    }()
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
        if monitor.airPodsBattery != nil || (historyStore.samplesByDevice["airpods"]?.isEmpty == false) {
            let isPro = monitor.displayAirPodsName.lowercased().contains("pro")
            list.append(("airpods", monitor.displayAirPodsName, isPro ? "airpodspro" : "airpods"))
        }
        if monitor.airPodsBattery?.case != nil || (historyStore.samplesByDevice["airpods.case"]?.isEmpty == false) {
            let isPro = monitor.displayAirPodsName.lowercased().contains("pro")
            list.append(("airpods.case", L10n.tr("status.case"), isPro ? "airpodspro.chargingcase.wireless" : "airpods.chargingcase"))
        }
        for acc in monitor.accessories {
            let key = "accessory.\(acc.name)"
            if !list.contains(where: { $0.key == key }) {
                list.append((key, acc.name, acc.icon))
            }
        }
        for (devKey, samples) in historyStore.samplesByDevice where !samples.isEmpty {
            if devKey.hasPrefix("accessory.") && !list.contains(where: { $0.key == devKey }) {
                let name = String(devKey.dropFirst("accessory.".count))
                list.append((devKey, name, "computermouse"))
            }
        }
        return list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Row 1: Header (Title & Collapse on left, Segmented switcher & Device picker on right)
            HStack(alignment: .center, spacing: 0) {
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
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer(minLength: 8)

                if !isCollapsed {
                    HStack(spacing: 6) {
                        // Range Segmented Switcher (24h / 7d)
                        HStack(spacing: 1) {
                            Button {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    selectedRange = .twentyFourHours
                                    UserDefaults.standard.set("24h", forKey: "batteryHistory.range")
                                    hoveredBucket = nil
                                }
                            } label: {
                                Text(L10n.tr("history.range_24h"))
                                    .font(.system(size: 10, weight: selectedRange == .twentyFourHours ? .semibold : .regular))
                                    .foregroundColor(selectedRange == .twentyFourHours ? .primary : .secondary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(
                                        selectedRange == .twentyFourHours ?
                                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                                .fill(Color.primary.opacity(0.12)) : nil
                                    )
                            }
                            .buttonStyle(.plain)

                            Button {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    selectedRange = .sevenDays
                                    UserDefaults.standard.set("7d", forKey: "batteryHistory.range")
                                    hoveredBucket = nil
                                }
                            } label: {
                                Text(L10n.tr("history.range_7d"))
                                    .font(.system(size: 10, weight: selectedRange == .sevenDays ? .semibold : .regular))
                                    .foregroundColor(selectedRange == .sevenDays ? .primary : .secondary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(
                                        selectedRange == .sevenDays ?
                                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                                .fill(Color.primary.opacity(0.12)) : nil
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(2)
                        .background(Color.primary.opacity(0.06))
                        .cornerRadius(6)

                        // Device Picker (if > 1 device)
                        if availableDevices.count > 1 {
                            Menu {
                                ForEach(availableDevices, id: \.key) { dev in
                                    Button {
                                        selectedDeviceKey = dev.key
                                        UserDefaults.standard.set(dev.key, forKey: "batteryHistory.selectedDevice")
                                        hoveredBucket = nil
                                    } label: {
                                        Label(dev.name, systemImage: dev.icon)
                                    }
                                }
                            } label: {
                                HStack(spacing: 3) {
                                    Text(availableDevices.first(where: { $0.key == selectedDeviceKey })?.name ?? availableDevices.first?.name ?? "Mac")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                        .frame(maxWidth: 85)
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.system(size: 8))
                                        .foregroundColor(.secondary)
                                }
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.primary.opacity(0.06))
                                .cornerRadius(5)
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                        }
                    }
                }
            }
            .frame(height: 20)

            if !isCollapsed {
                // Row 2: Subheader (Hover reading or Range subtitle, fixed 1-line height)
                HStack(spacing: 4) {
                    if let hovered = hoveredBucket {
                        let timeStr = (selectedRange == .sevenDays) ? formatSevenDaysHover(hovered.startDate) : formatTimeRange(from: hovered.startDate, to: hovered.endDate)
                        let readingStr: String = {
                            if let lvl = hovered.level {
                                return "\(lvl)%\(hovered.isCharging || hovered.isPlugged ? " ⚡" : "")"
                            } else {
                                return "--"
                            }
                        }()
                        Text("\(timeStr)  ·  \(readingStr)")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                    } else {
                        Text(selectedRange == .sevenDays ? L10n.tr("history.past7d") : L10n.tr("history.past24h"))
                            .font(.system(size: 11, weight: .regular))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .frame(height: 16, alignment: .leading)
                .transition(.opacity)

                // Row 3: The Chart (Fixed height 92)
                switch selectedRange {
                case .twentyFourHours:
                    let buckets = historyStore.timelineBuckets(for: selectedDeviceKey)
                    let spans = historyStore.chargingSpans(for: buckets)

                    BatteryTimelineChart(
                        buckets: buckets,
                        chargingSpans: spans,
                        hoveredBucket: $hoveredBucket
                    )
                    .frame(height: 92)

                case .sevenDays:
                    let buckets = historyStore.sevenDaysTimelineBuckets(for: selectedDeviceKey)

                    BatterySevenDaysLineChart(
                        buckets: buckets,
                        referenceDate: Date(),
                        hoveredBucket: $hoveredBucket
                    )
                    .frame(height: 92)
                }
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

    private static let sevenDaysHoverFormatterZh: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 (EEE) HH:mm"
        return f
    }()

    private static let sevenDaysHoverFormatterEn: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "EEE, MMM d, HH:mm"
        return f
    }()

    private func formatTimeRange(from start: Date, to end: Date) -> String {
        let f = Self.timeRangeFormatter
        return "\(f.string(from: start))-\(f.string(from: end))"
    }

    private func formatSevenDaysHover(_ date: Date) -> String {
        let isZh = Locale.current.language.languageCode?.identifier == "zh"
        if isZh {
            return Self.sevenDaysHoverFormatterZh.string(from: date)
        } else {
            return Self.sevenDaysHoverFormatterEn.string(from: date)
        }
    }
}

// MARK: - Battery Timeline Chart (24 Hours)

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

// MARK: - Battery Seven Days Line Chart (7 Days)

private struct BatterySevenDaysLineChart: View {
    let buckets: [BatteryTimelineBucket]
    let referenceDate: Date
    @Binding var hoveredBucket: BatteryTimelineBucket?

    private static let batteryGreen = Color(red: 52/255, green: 199/255, blue: 89/255)

    var body: some View {
        GeometryReader { geo in
            let totalW = geo.size.width
            let yAxisW: CGFloat = 32
            let chartW = max(10, totalW - yAxisW)
            let chartH: CGFloat = 62
            let timeLabelsH: CGFloat = 16

            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 0) {
                    ZStack(alignment: .topLeading) {
                        // 1. Horizontal dashed grid lines (100%, 50%, 0%)
                        GridLinesView(width: chartW, height: chartH)

                        // 2. Vertical day boundary lines (6 vertical lines dividing 7 days)
                        Canvas { ctx, size in
                            for day in 1..<7 {
                                let x = (CGFloat(day) / 7.0) * size.width
                                var p = Path()
                                p.move(to: CGPoint(x: x, y: 0))
                                p.addLine(to: CGPoint(x: x, y: size.height))
                                ctx.stroke(p, with: .color(Color.primary.opacity(0.10)),
                                           style: StrokeStyle(lineWidth: 0.8, dash: [2, 3]))
                            }
                        }
                        .frame(width: chartW, height: chartH)

                        // 3. Line Chart with Gradient Fill
                        Canvas { ctx, size in
                            guard buckets.count > 1 else { return }

                            var currentSegment: [(index: Int, point: CGPoint)] = []
                            var segments: [[(index: Int, point: CGPoint)]] = []

                            let totalIndices = CGFloat(max(1, buckets.count - 1))
                            for (idx, b) in buckets.enumerated() {
                                if let lvl = b.level {
                                    let x = (CGFloat(idx) / totalIndices) * size.width
                                    let y = (1.0 - (CGFloat(lvl) / 100.0)) * (size.height - 4) + 2
                                    currentSegment.append((idx, CGPoint(x: x, y: y)))
                                } else {
                                    if !currentSegment.isEmpty {
                                        segments.append(currentSegment)
                                        currentSegment = []
                                    }
                                }
                            }
                            if !currentSegment.isEmpty {
                                segments.append(currentSegment)
                            }

                            for seg in segments {
                                guard !seg.isEmpty else { continue }

                                if seg.count == 1 {
                                    let pt = seg[0].point
                                    let dotPath = Path(ellipseIn: CGRect(x: pt.x - 2.5, y: pt.y - 2.5, width: 5, height: 5))
                                    ctx.fill(dotPath, with: .color(Self.batteryGreen))
                                    continue
                                }

                                // 3a. Gradient fill under curve
                                var fillPath = Path()
                                fillPath.move(to: CGPoint(x: seg[0].point.x, y: size.height))
                                for item in seg {
                                    fillPath.addLine(to: item.point)
                                }
                                fillPath.addLine(to: CGPoint(x: seg.last!.point.x, y: size.height))
                                fillPath.closeSubpath()

                                let gradient = Gradient(stops: [
                                    .init(color: Self.batteryGreen.opacity(0.32), location: 0.0),
                                    .init(color: Self.batteryGreen.opacity(0.02), location: 1.0)
                                ])
                                ctx.fill(fillPath, with: .linearGradient(gradient,
                                                                         startPoint: CGPoint(x: 0, y: 0),
                                                                         endPoint: CGPoint(x: 0, y: size.height)))

                                // 3b. Line stroke
                                var linePath = Path()
                                linePath.move(to: seg[0].point)
                                for item in seg.dropFirst() {
                                    linePath.addLine(to: item.point)
                                }
                                ctx.stroke(linePath, with: .color(Self.batteryGreen),
                                           style: StrokeStyle(lineWidth: 2.0, lineCap: .round, lineJoin: .round))
                            }
                        }
                        .frame(width: chartW, height: chartH)

                        // 4. Hover Scrubber: Guide line + glowing dot
                        if let hovered = hoveredBucket, let lvl = hovered.level {
                            let totalIndices = CGFloat(max(1, buckets.count - 1))
                            let x = (CGFloat(hovered.id) / totalIndices) * chartW
                            let y = (1.0 - (CGFloat(lvl) / 100.0)) * (chartH - 4) + 2

                            // Vertical hairline
                            Rectangle()
                                .fill(Color.primary.opacity(0.35))
                                .frame(width: 1, height: chartH)
                                .offset(x: x, y: 0)

                            // Glowing dot
                            ZStack {
                                Circle()
                                    .fill(Self.batteryGreen.opacity(0.28))
                                    .frame(width: 14, height: 14)

                                Circle()
                                    .fill(Self.batteryGreen)
                                    .frame(width: 7, height: 7)
                                    .overlay(
                                        Circle()
                                            .stroke(Color(NSColor.windowBackgroundColor), lineWidth: 1.5)
                                    )
                            }
                            .offset(x: x - 7, y: y - 7)
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

                    // 5. Bottom spacing and X-axis Day labels (7 days evenly distributed)
                    Spacer().frame(height: 14)

                    HStack(spacing: 0) {
                        ForEach(0..<7, id: \.self) { day in
                            let label = dayLabel(for: day)
                            Text(label)
                                .font(.system(size: 9, weight: .regular))
                                .foregroundColor(.secondary)
                                .frame(width: chartW / 7.0, alignment: .center)
                        }
                    }
                    .frame(width: chartW, height: timeLabelsH, alignment: .center)
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

    private func dayLabel(for dayIndex: Int) -> String {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: referenceDate)
        guard let date = calendar.date(byAdding: .day, value: dayIndex - 6, to: todayStart) else {
            return ""
        }
        if calendar.isDateInToday(date) {
            return L10n.tr("history.today")
        }
        if calendar.isDateInYesterday(date) {
            return L10n.tr("history.yesterday")
        }
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateFormat = "EEE"
        return f.string(from: date)
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
