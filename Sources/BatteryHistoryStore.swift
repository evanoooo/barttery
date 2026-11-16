import Foundation
import Combine
import AppKit

// MARK: - Battery Sample

struct BatterySample: Codable, Equatable {
    let timestamp: UInt32  // Unix epoch in seconds
    let level: UInt8       // 0...100
    let flags: UInt8       // bit 0: isCharging, bit 1: isPlugged, bit 2: isPaused

    var isCharging: Bool { (flags & 1) != 0 }
    var isPlugged: Bool  { (flags & 2) != 0 }
    var isPaused: Bool   { (flags & 4) != 0 }
    var date: Date       { Date(timeIntervalSince1970: TimeInterval(timestamp)) }

    init(timestamp: UInt32, level: UInt8, flags: UInt8) {
        self.timestamp = timestamp
        self.level = level
        self.flags = flags
    }

    init(date: Date = Date(), level: Int, isCharging: Bool, isPlugged: Bool = false, isPaused: Bool = false) {
        self.timestamp = UInt32(date.timeIntervalSince1970)
        self.level = UInt8(clamping: min(100, max(0, level)))
        var f: UInt8 = 0
        if isCharging { f |= 1 }
        if isPlugged  { f |= 2 }
        if isPaused   { f |= 4 }
        self.flags = f
    }
}

// MARK: - Timeline Bucket

struct BatteryTimelineBucket: Identifiable, Equatable {
    let id: Int                 // 0..<count (oldest to newest)
    let startDate: Date
    let endDate: Date
    let level: Int?             // 0...100, or nil if no data / asleep for > 6h
    let isCharging: Bool
    let isPlugged: Bool

    init(id: Int, startDate: Date, endDate: Date, level: Int?, isCharging: Bool, isPlugged: Bool) {
        self.id = id
        self.startDate = startDate
        self.endDate = endDate
        self.level = level
        self.isCharging = isCharging
        self.isPlugged = isPlugged
    }
}

// MARK: - Charging Span

struct ChargingTimeSpan: Identifiable, Equatable {
    let id: Int
    let startIndex: Int
    let endIndex: Int
    let startDate: Date
    let endDate: Date

    init(id: Int, startIndex: Int, endIndex: Int, startDate: Date, endDate: Date) {
        self.id = id
        self.startIndex = startIndex
        self.endIndex = endIndex
        self.startDate = startDate
        self.endDate = endDate
    }
}

// MARK: - History Store

final class BatteryHistoryStore: ObservableObject {
    static let shared = BatteryHistoryStore()

    @Published private(set) var samplesByDevice: [String: [BatterySample]] = [:]
    private var pendingSaveWork: DispatchWorkItem?
    private let saveQueue = DispatchQueue(label: "me.yura.barttery.history.save", qos: .utility)
    private var isDirty = false

    private static let retentionHours: TimeInterval = 216 // 9 days retention for 7-day view support
    private static let bucketMinutes: Int = 15
    private static let totalBuckets24h: Int = 96

    private static let storageURL: URL? = {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = appSupport.appendingPathComponent("me.yura.barttery", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("battery-history.json")
    }()

    private var storageFileURL: URL? { Self.storageURL }

    init() {
        loadFromDisk()
        pruneAllDevices()
        setupNotifications()
    }

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleTerminate),
            name: NSApplication.willTerminateNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(handleSleep),
            name: NSWorkspace.willSleepNotification, object: nil
        )
    }

    @objc private func handleTerminate() {
        saveToDiskNow()
    }

    @objc private func handleSleep() {
        saveToDiskNow()
    }

    // MARK: - Record APIs

    func record(device: String, level: Int, state: ChargeState, at date: Date = Date()) {
        let isCharging = (state == .charging)
        let isPlugged  = (state == .plugged || state == .paused || state == .charging)
        let isPaused   = (state == .paused)
        record(device: device, level: level, isCharging: isCharging, isPlugged: isPlugged, isPaused: isPaused, at: date)
    }

    func record(device: String, level: Int, isCharging: Bool,
                isPlugged: Bool = false, isPaused: Bool = false, at date: Date = Date()) {
        if Thread.isMainThread {
            recordInternal(device: device, level: level, isCharging: isCharging, isPlugged: isPlugged, isPaused: isPaused, at: date)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.recordInternal(device: device, level: level, isCharging: isCharging, isPlugged: isPlugged, isPaused: isPaused, at: date)
            }
        }
    }

    private func recordInternal(device: String, level: Int, isCharging: Bool,
                                isPlugged: Bool, isPaused: Bool, at date: Date) {
        let newSample = BatterySample(date: date, level: level, isCharging: isCharging,
                                      isPlugged: isPlugged, isPaused: isPaused)

        var list = samplesByDevice[device] ?? []

        // Deduplication: if the last sample was within 60s and has identical level & flags, skip
        if let last = list.last {
            let elapsed = date.timeIntervalSince(last.date)
            if elapsed < 60 && last.level == newSample.level && last.flags == newSample.flags {
                return
            }
        }

        list.append(newSample)

        // Prune older than retention window
        let cutoff = UInt32(date.addingTimeInterval(-Self.retentionHours * 3600).timeIntervalSince1970)
        if let firstValid = list.firstIndex(where: { $0.timestamp >= cutoff }), firstValid > 0 {
            list.removeSubrange(0..<firstValid)
        }

        samplesByDevice[device] = list
        isDirty = true
        if let url = storageFileURL, !FileManager.default.fileExists(atPath: url.path) {
            saveToDiskNow()
        } else {
            scheduleDebouncedSave()
        }
    }

    // MARK: - Query / Bucket Generation

    func timelineBuckets(for device: String, referenceDate: Date = Date(),
                         bucketMinutes: Int = 15, count: Int = 96) -> [BatteryTimelineBucket] {
        let calendar = Calendar.current
        let timelineStart = calendar.startOfDay(for: referenceDate)
        let bucketDuration = TimeInterval(bucketMinutes * 60)

        let rawSamples = samplesByDevice[device] ?? []
        // Ensure chronological order
        let samples = rawSamples.sorted { $0.timestamp < $1.timestamp }
        let nSamples = samples.count

        var buckets: [BatteryTimelineBucket] = []
        buckets.reserveCapacity(count)

        var lastKnownLevel: Int? = nil
        var lastKnownSampleDate: Date? = nil

        // Seed with sample immediately preceding timelineStart if available
        if let prior = samples.last(where: { $0.date <= timelineStart }) {
            lastKnownLevel = Int(prior.level)
            lastKnownSampleDate = prior.date
        }

        var sampleIdx = 0

        for i in 0..<count {
            let bStart = timelineStart.addingTimeInterval(TimeInterval(i) * bucketDuration)
            let bEnd   = bStart.addingTimeInterval(bucketDuration)

            // Future bucket (beyond current referenceDate)
            if bStart > referenceDate {
                buckets.append(BatteryTimelineBucket(
                    id: i,
                    startDate: bStart,
                    endDate: bEnd,
                    level: nil,
                    isCharging: false,
                    isPlugged: false
                ))
                continue
            }

            // Fast linear scan: advance sampleIdx to current bucket window
            while sampleIdx < nSamples && samples[sampleIdx].date < bStart {
                lastKnownLevel = Int(samples[sampleIdx].level)
                lastKnownSampleDate = samples[sampleIdx].date
                sampleIdx += 1
            }

            var scanIdx = sampleIdx
            var inBucketLatest: BatterySample? = nil
            var inBucketCharging = false
            var inBucketPlugged = false

            while scanIdx < nSamples && samples[scanIdx].date < bEnd {
                let s = samples[scanIdx]
                inBucketLatest = s
                if s.isCharging { inBucketCharging = true }
                if s.isPlugged  { inBucketPlugged = true }
                scanIdx += 1
            }

            let level: Int?
            let isCharging: Bool
            let isPlugged: Bool

            if let latest = inBucketLatest {
                level = Int(latest.level)
                isCharging = inBucketCharging
                isPlugged = inBucketPlugged
                lastKnownLevel = level
                lastKnownSampleDate = latest.date
                sampleIdx = scanIdx
            } else if let prev = lastKnownLevel, let prevDate = lastKnownSampleDate,
                      bEnd.timeIntervalSince(prevDate) <= 8 * 3600 {
                // Carry forward if within 8 hours of last observation
                let nextSample = scanIdx < nSamples ? samples[scanIdx] : nil
                let wasCharging = (nextSample?.isCharging == true && (nextSample?.level ?? 0) > UInt8(prev))
                level = prev
                isCharging = wasCharging
                isPlugged = wasCharging || (nextSample?.isPlugged == true)
            } else {
                level = nil
                isCharging = false
                isPlugged = false
            }

            buckets.append(BatteryTimelineBucket(
                id: i,
                startDate: bStart,
                endDate: bEnd,
                level: level,
                isCharging: isCharging,
                isPlugged: isPlugged
            ))
        }

        return buckets
    }

    func sevenDaysTimelineBuckets(for device: String, referenceDate: Date = Date(),
                                  bucketMinutes: Int = 60) -> [BatteryTimelineBucket] {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: referenceDate)
        let timelineStart = calendar.date(byAdding: .day, value: -6, to: todayStart) ?? todayStart.addingTimeInterval(-6 * 86400)
        let bucketDuration = TimeInterval(bucketMinutes * 60)
        let totalCount = (7 * 24 * 60) / bucketMinutes

        let rawSamples = samplesByDevice[device] ?? []
        let samples = rawSamples.sorted { $0.timestamp < $1.timestamp }
        let nSamples = samples.count

        var buckets: [BatteryTimelineBucket] = []
        buckets.reserveCapacity(totalCount)

        var lastKnownLevel: Int? = nil
        var lastKnownSampleDate: Date? = nil

        if let prior = samples.last(where: { $0.date <= timelineStart }) {
            lastKnownLevel = Int(prior.level)
            lastKnownSampleDate = prior.date
        }

        var sampleIdx = 0

        for i in 0..<totalCount {
            let bStart = timelineStart.addingTimeInterval(TimeInterval(i) * bucketDuration)
            let bEnd   = bStart.addingTimeInterval(bucketDuration)

            if bStart > referenceDate {
                buckets.append(BatteryTimelineBucket(
                    id: i,
                    startDate: bStart,
                    endDate: bEnd,
                    level: nil,
                    isCharging: false,
                    isPlugged: false
                ))
                continue
            }

            while sampleIdx < nSamples && samples[sampleIdx].date < bStart {
                lastKnownLevel = Int(samples[sampleIdx].level)
                lastKnownSampleDate = samples[sampleIdx].date
                sampleIdx += 1
            }

            var scanIdx = sampleIdx
            var inBucketLatest: BatterySample? = nil
            var inBucketCharging = false
            var inBucketPlugged = false

            while scanIdx < nSamples && samples[scanIdx].date < bEnd {
                let s = samples[scanIdx]
                inBucketLatest = s
                if s.isCharging { inBucketCharging = true }
                if s.isPlugged  { inBucketPlugged = true }
                scanIdx += 1
            }

            let level: Int?
            let isCharging: Bool
            let isPlugged: Bool

            if let latest = inBucketLatest {
                level = Int(latest.level)
                isCharging = inBucketCharging
                isPlugged = inBucketPlugged
                lastKnownLevel = level
                lastKnownSampleDate = latest.date
                sampleIdx = scanIdx
            } else if let prev = lastKnownLevel, let prevDate = lastKnownSampleDate,
                      bEnd.timeIntervalSince(prevDate) <= 16 * 3600 {
                let nextSample = scanIdx < nSamples ? samples[scanIdx] : nil
                let wasCharging = (nextSample?.isCharging == true && (nextSample?.level ?? 0) > UInt8(prev))
                level = prev
                isCharging = wasCharging
                isPlugged = wasCharging || (nextSample?.isPlugged == true)
            } else {
                level = nil
                isCharging = false
                isPlugged = false
            }

            buckets.append(BatteryTimelineBucket(
                id: i,
                startDate: bStart,
                endDate: bEnd,
                level: level,
                isCharging: isCharging,
                isPlugged: isPlugged
            ))
        }

        return buckets
    }

    func chargingSpans(for buckets: [BatteryTimelineBucket]) -> [ChargingTimeSpan] {
        var spans: [ChargingTimeSpan] = []
        var spanStart: Int? = nil

        for (idx, b) in buckets.enumerated() {
            let isPower = (b.isCharging || b.isPlugged) && (b.level != nil)
            if isPower {
                if spanStart == nil {
                    spanStart = idx
                }
            } else {
                if let start = spanStart {
                    spans.append(ChargingTimeSpan(
                        id: spans.count,
                        startIndex: start,
                        endIndex: idx - 1,
                        startDate: buckets[start].startDate,
                        endDate: buckets[idx - 1].endDate
                    ))
                    spanStart = nil
                }
            }
        }

        if let start = spanStart, !buckets.isEmpty {
            spans.append(ChargingTimeSpan(
                id: spans.count,
                startIndex: start,
                endIndex: buckets.count - 1,
                startDate: buckets[start].startDate,
                endDate: buckets[buckets.count - 1].endDate
            ))
        }

        return spans
    }

    // MARK: - Persistence

    private func scheduleDebouncedSave() {
        guard pendingSaveWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.pendingSaveWork = nil
            self?.saveToDiskNow()
        }
        pendingSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 300, execute: work)
    }

    func saveToDiskNow() {
        guard isDirty, let url = storageFileURL else { return }
        let snapshot = samplesByDevice
        isDirty = false
        saveQueue.async {
            do {
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch {
                NSLog("Failed to save battery history: \(error.localizedDescription)")
            }
        }
    }

    private func loadFromDisk() {
        guard let url = storageFileURL,
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: [BatterySample]].self, from: data) else {
            return
        }
        self.samplesByDevice = decoded
    }

    func pruneAllDevices(referenceDate: Date = Date()) {
        let cutoff = UInt32(referenceDate.addingTimeInterval(-Self.retentionHours * 3600).timeIntervalSince1970)
        var modified = false
        for (dev, samples) in samplesByDevice {
            let valid = samples.filter { $0.timestamp >= cutoff }
            if valid.isEmpty {
                samplesByDevice.removeValue(forKey: dev)
                modified = true
            } else if valid.count != samples.count {
                samplesByDevice[dev] = valid
                modified = true
            }
        }
        if modified { isDirty = true }
    }
}
