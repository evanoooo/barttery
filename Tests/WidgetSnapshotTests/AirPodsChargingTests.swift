import XCTest
@testable import Barttery

final class AirPodsChargingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testProximityPairingPacketValidationRejectsWrongSubtypeAndMismatchedPID() {
        let valid = Data([0x4C, 0x00, 0x07, 0x19, 0x01, 0x14, 0x20, 0x55, 0x88, 0x80])
        XCTAssertTrue(AirPodsReader.isValidProximityPairingPacket(valid))
        XCTAssertTrue(AirPodsReader.isValidProximityPairingPacket(valid, expectedPID: 0x2014))
        XCTAssertFalse(AirPodsReader.isValidProximityPairingPacket(valid, expectedPID: 0x200E))

        let wrongSubtype = Data([0x4C, 0x00, 0x07, 0x19, 0x02, 0x14, 0x20, 0x55, 0x88, 0x84])
        XCTAssertFalse(AirPodsReader.isValidProximityPairingPacket(wrongSubtype))

        let tooShort = Data([0x4C, 0x00, 0x07, 0x19, 0x01, 0x14, 0x20])
        XCTAssertFalse(AirPodsReader.isValidProximityPairingPacket(tooShort))
    }

    func testCaseChargingFreshnessRejectsStaleAndLaggingObservations() {
        XCTAssertFalse(AirPodsReader.isCaseChargingFresh(observedAt: nil, referenceDate: now, now: now))
        XCTAssertTrue(AirPodsReader.isCaseChargingFresh(
            observedAt: now.addingTimeInterval(-30), referenceDate: now, now: now
        ))
        // Exceeds 5-minute case charging lifetime
        XCTAssertFalse(AirPodsReader.isCaseChargingFresh(
            observedAt: now.addingTimeInterval(-301), referenceDate: now.addingTimeInterval(-301), now: now
        ))
        // Case timestamp lags >120s behind buds' latest timestamp (case stopped advertising)
        XCTAssertFalse(AirPodsReader.isCaseChargingFresh(
            observedAt: now.addingTimeInterval(-180), referenceDate: now, now: now
        ))
    }

    func testCachedAirPodsBatteryExpiresChargingFlagsAfterFiveMinutes() throws {
        let suite = "Barttery.AirPodsChargingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(90, forKey: "airPods.lastLeft")
        defaults.set(90, forKey: "airPods.lastRight")
        defaults.set(88, forKey: "airPods.lastCase")
        defaults.set(true, forKey: "airPods.lastLeftCharging")
        defaults.set(true, forKey: "airPods.lastRightCharging")
        defaults.set(true, forKey: "airPods.lastCaseCharging")
        defaults.set(now, forKey: "airPods.lastSyncTime")

        let fresh = try XCTUnwrap(cachedAirPodsBattery(from: defaults, at: now.addingTimeInterval(60)))
        XCTAssertEqual(fresh.case, 88)
        XCTAssertTrue(fresh.caseCharging)
        XCTAssertTrue(fresh.leftCharging)

        let staleCharging = try XCTUnwrap(cachedAirPodsBattery(from: defaults, at: now.addingTimeInterval(600)))
        XCTAssertEqual(staleCharging.case, 88)
        XCTAssertFalse(staleCharging.caseCharging)
        XCTAssertFalse(staleCharging.leftCharging)
        XCTAssertFalse(staleCharging.rightCharging)

        XCTAssertNil(cachedAirPodsBattery(from: defaults, at: now.addingTimeInterval(15000)))
    }
}
