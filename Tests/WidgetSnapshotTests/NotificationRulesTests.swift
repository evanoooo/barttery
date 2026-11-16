import XCTest
@testable import Barttery

final class NotificationRulesTests: XCTestCase {

    func testNotificationRulesSeparation() {
        let rules = DeviceNotificationRules(
            below: [30, 10, 20],
            above: [100, 80, 90],
            soundEnabled: true
        )

        // Automatically sorted and deduplicated
        XCTAssertEqual(rules.below, [10, 20, 30])
        XCTAssertEqual(rules.above, [80, 90, 100])
        XCTAssertTrue(rules.soundEnabled)
    }

    func testAppSettingsAddAndToggleThresholds() {
        let settings = AppSettings.shared
        let testDevice = BatteryDevice.mac

        // Add custom below threshold (e.g. 15%)
        settings.addThreshold(device: testDevice, type: .below, threshold: 15)
        XCTAssertTrue(settings.isThresholdEnabled(device: testDevice, type: .below, threshold: 15))

        // Toggle below threshold off
        settings.toggleThreshold(device: testDevice, type: .below, threshold: 15)
        XCTAssertFalse(settings.isThresholdEnabled(device: testDevice, type: .below, threshold: 15))

        // Toggle back on
        settings.toggleThreshold(device: testDevice, type: .below, threshold: 15)
        XCTAssertTrue(settings.isThresholdEnabled(device: testDevice, type: .below, threshold: 15))

        // Remove below threshold
        settings.removeThreshold(device: testDevice, type: .below, threshold: 15)
        XCTAssertFalse(settings.isThresholdEnabled(device: testDevice, type: .below, threshold: 15))

        // Add custom above threshold (e.g. 85%)
        settings.addThreshold(device: testDevice, type: .above, threshold: 85)
        XCTAssertTrue(settings.isThresholdEnabled(device: testDevice, type: .above, threshold: 85))

        // Remove above threshold
        settings.removeThreshold(device: testDevice, type: .above, threshold: 85)
        XCTAssertFalse(settings.isThresholdEnabled(device: testDevice, type: .above, threshold: 85))
    }

    func testLegacyThresholdCompatibility() {
        let settings = AppSettings.shared
        let testDevice = BatteryDevice.phone

        // Initial default below threshold for phone is 20
        let initiallyEnabled = settings.isThresholdEnabled(device: testDevice, threshold: 20)
        
        // Toggle once flips state
        settings.toggleThreshold(device: testDevice, threshold: 20)
        XCTAssertEqual(settings.isThresholdEnabled(device: testDevice, threshold: 20), !initiallyEnabled)

        // Toggle back restores state
        settings.toggleThreshold(device: testDevice, threshold: 20)
        XCTAssertEqual(settings.isThresholdEnabled(device: testDevice, threshold: 20), initiallyEnabled)
    }

    func testAccessoryDeviceClassificationDoesNotDefaultToMouse() {
        let speaker = AccessoryBattery(name: "REDMI音箱", level: 50, charging: false, updatedAt: Date(), chargingKnown: false)
        XCTAssertEqual(speaker.batteryDevice, .headphones)

        let headphones = AccessoryBattery(name: "Sony WH-1000XM4", level: 80, charging: false, updatedAt: Date(), chargingKnown: false)
        XCTAssertEqual(headphones.batteryDevice, .headphones)

        let mouse = AccessoryBattery(name: "Logitech MX Master 3S", level: 60, charging: false, updatedAt: Date(), chargingKnown: false)
        XCTAssertEqual(mouse.batteryDevice, .mouse)

        let keyboard = AccessoryBattery(name: "Keychron K3 Keyboard", level: 70, charging: false, updatedAt: Date(), chargingKnown: false)
        XCTAssertEqual(keyboard.batteryDevice, .keyboard)

        let trackpad = AccessoryBattery(name: "Magic Trackpad", level: 90, charging: false, updatedAt: Date(), chargingKnown: false)
        XCTAssertEqual(trackpad.batteryDevice, .trackpad)
    }

    func testNotificationManagerIgnoresInvalidZeroLevel() {
        // Clear any previous test residual
        UserDefaults.standard.removeObject(forKey: "nm.mouse.level")
        NotificationManager.shared.check(device: .mouse, level: 0, isCharging: false)
        XCTAssertNil(UserDefaults.standard.object(forKey: "nm.mouse.level"))
    }
}
