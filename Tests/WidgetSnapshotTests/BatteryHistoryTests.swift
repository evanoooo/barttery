import XCTest
@testable import Barttery

final class BatteryHistoryTests: XCTestCase {

    // MARK: - BatterySample Tests

    func testBatterySampleBitFlags() {
        let date = Date(timeIntervalSince1970: 1700000000)
        let sample1 = BatterySample(date: date, level: 85, isCharging: true, isPlugged: true, isPaused: false)
        XCTAssertEqual(sample1.level, 85)
        XCTAssertTrue(sample1.isCharging)
        XCTAssertTrue(sample1.isPlugged)
        XCTAssertFalse(sample1.isPaused)
        XCTAssertEqual(sample1.timestamp, 1700000000)

        let sample2 = BatterySample(date: date, level: 100, isCharging: false, isPlugged: true, isPaused: true)
        XCTAssertEqual(sample2.level, 100)
        XCTAssertFalse(sample2.isCharging)
        XCTAssertTrue(sample2.isPlugged)
        XCTAssertTrue(sample2.isPaused)
    }

    func testBatterySampleCodableRoundtrip() throws {
        let original = BatterySample(date: Date(timeIntervalSince1970: 1700000000), level: 78, isCharging: true, isPlugged: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BatterySample.self, from: data)

        XCTAssertEqual(original.timestamp, decoded.timestamp)
        XCTAssertEqual(original.level, decoded.level)
        XCTAssertEqual(original.flags, decoded.flags)
        XCTAssertEqual(original.isCharging, decoded.isCharging)
        XCTAssertEqual(original.isPlugged, decoded.isPlugged)
    }

    // MARK: - Timeline Bucketing Tests

    func testTimelineBucketsCountAndSpacing() {
        let store = BatteryHistoryStore()
        let calendar = Calendar.current
        let todayNoon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!

        let buckets = store.timelineBuckets(for: "mac", referenceDate: todayNoon)
        XCTAssertEqual(buckets.count, 96, "Must produce exactly 96 15-minute buckets for 24 hours")

        // First bucket should be 00:00
        let startOfDay = calendar.startOfDay(for: todayNoon)
        XCTAssertEqual(buckets.first?.startDate, startOfDay)

        // Buckets after 12:00 should be nil (future)
        let afternoonBuckets = buckets.filter { $0.startDate > todayNoon }
        XCTAssertFalse(afternoonBuckets.isEmpty)
        for b in afternoonBuckets {
            XCTAssertNil(b.level, "Future buckets must have level nil")
        }
    }

    func testTimelineCarriesForwardWithinWindow() {
        let store = BatteryHistoryStore()
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        let sampleTime = startOfDay.addingTimeInterval(2 * 3600) // 02:00 AM

        store.record(device: "mac_test", level: 80, isCharging: false, at: sampleTime)

        let refDate = startOfDay.addingTimeInterval(5 * 3600) // 05:00 AM
        let buckets = store.timelineBuckets(for: "mac_test", referenceDate: refDate)

        // At 03:00 (index 12), level should carry forward as 80
        let bucketAt3AM = buckets.first(where: { calendar.component(.hour, from: $0.startDate) == 3 })
        XCTAssertNotNil(bucketAt3AM)
        XCTAssertEqual(bucketAt3AM?.level, 80)
    }

    // MARK: - Charging Spans Tests

    func testChargingSpansDetection() {
        let store = BatteryHistoryStore()
        let now = Date()

        // Create buckets with two separate charging windows
        // Window 1: index 10..<15 (5 buckets)
        // Window 2: index 30..<35 (5 buckets)
        var mockBuckets: [BatteryTimelineBucket] = []
        for i in 0..<50 {
            let start = now.addingTimeInterval(Double(i) * 900)
            let end = start.addingTimeInterval(900)
            let isChg = (i >= 10 && i < 15) || (i >= 30 && i < 35)
            mockBuckets.append(BatteryTimelineBucket(
                id: i,
                startDate: start,
                endDate: end,
                level: 80,
                isCharging: isChg,
                isPlugged: isChg
            ))
        }

        let spans = store.chargingSpans(for: mockBuckets)
        XCTAssertEqual(spans.count, 2, "Should detect exactly 2 charging spans")

        XCTAssertEqual(spans[0].startIndex, 10)
        XCTAssertEqual(spans[0].endIndex, 14)
        XCTAssertEqual(spans[0].startDate, mockBuckets[10].startDate)
        XCTAssertEqual(spans[0].endDate, mockBuckets[14].endDate)

        XCTAssertEqual(spans[1].startIndex, 30)
        XCTAssertEqual(spans[1].endIndex, 34)
    }

    func testNoSpansWhenNotCharging() {
        let store = BatteryHistoryStore()
        let now = Date()

        var mockBuckets: [BatteryTimelineBucket] = []
        for i in 0..<20 {
            let start = now.addingTimeInterval(Double(i) * 900)
            mockBuckets.append(BatteryTimelineBucket(
                id: i,
                startDate: start,
                endDate: start.addingTimeInterval(900),
                level: 60,
                isCharging: false,
                isPlugged: false
            ))
        }

        let spans = store.chargingSpans(for: mockBuckets)
        XCTAssertTrue(spans.isEmpty, "Should have no spans when not charging")
    }

    // MARK: - Deduplication & Pruning Tests

    func testDeduplicationWithin60Seconds() {
        let store = BatteryHistoryStore()
        let t0 = Date(timeIntervalSince1970: 1700000000)

        store.record(device: "phone_test", level: 90, isCharging: true, at: t0)
        store.record(device: "phone_test", level: 90, isCharging: true, at: t0.addingTimeInterval(30))
        store.record(device: "phone_test", level: 90, isCharging: true, at: t0.addingTimeInterval(50))

        let samples = store.samplesByDevice["phone_test"] ?? []
        XCTAssertEqual(samples.count, 1, "Duplicate readings within 60s should be ignored")

        // Value change within 60s should be recorded
        store.record(device: "phone_test", level: 91, isCharging: true, at: t0.addingTimeInterval(55))
        XCTAssertEqual(store.samplesByDevice["phone_test"]?.count, 2)
    }

    // MARK: - 7 Days Timeline Tests

    func testSevenDaysTimelineBucketsCountAndSpan() {
        let store = BatteryHistoryStore()
        let calendar = Calendar.current
        let todayNoon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!

        let buckets = store.sevenDaysTimelineBuckets(for: "mac", referenceDate: todayNoon)
        XCTAssertEqual(buckets.count, 168, "Must produce 168 1-hour buckets for 7 days")

        let todayStart = calendar.startOfDay(for: todayNoon)
        let expectedStart = calendar.date(byAdding: .day, value: -6, to: todayStart)!
        XCTAssertEqual(buckets.first?.startDate, expectedStart)

        // Buckets after referenceDate should be nil
        let futureBuckets = buckets.filter { $0.startDate > todayNoon }
        XCTAssertFalse(futureBuckets.isEmpty)
        for b in futureBuckets {
            XCTAssertNil(b.level, "Future buckets in 7-day view must be nil")
        }
    }

    func testSevenDaysTimelineCarriesForward() {
        let store = BatteryHistoryStore()
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: Date())
        let threeDaysAgo = calendar.date(byAdding: .day, value: -3, to: todayStart)!.addingTimeInterval(10 * 3600) // 10:00 AM

        store.record(device: "mac_7d", level: 95, isCharging: false, at: threeDaysAgo)

        let refDate = threeDaysAgo.addingTimeInterval(5 * 3600) // 15:00 PM
        let buckets = store.sevenDaysTimelineBuckets(for: "mac_7d", referenceDate: refDate)

        // Find bucket at 12:00 PM on that day (2h after sample)
        let bucketAtNoon = buckets.first(where: {
            abs($0.startDate.timeIntervalSince(threeDaysAgo.addingTimeInterval(2 * 3600))) < 1800
        })
        XCTAssertNotNil(bucketAtNoon)
        XCTAssertEqual(bucketAtNoon?.level, 95)
    }
}
