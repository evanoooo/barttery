import XCTest
@testable import Barttery

final class WidgetDeviceSelectionTests: XCTestCase {
    private var settings: AppSettings!

    override func setUp() {
        super.setUp()
        settings = AppSettings.shared
        settings.resetWidgetSettings()
    }

    override func tearDown() {
        settings.resetWidgetSettings()
        super.tearDown()
    }

    func testDefaultModeShowsAllDevices() {
        XCTAssertEqual(settings.widgetSelectionMode, .all)

        let now = Date()
        let sampleDevices = [
            WidgetBatteryDevice(id: "mac", name: "MacBook", symbol: "macbook", level: 90, isCharging: true, updatedAt: now),
            WidgetBatteryDevice(id: "phone", name: "iPhone", symbol: "iphone", level: 75, isCharging: false, updatedAt: now),
            WidgetBatteryDevice(id: "watch", name: "Apple Watch", symbol: "applewatch", level: 60, isCharging: false, updatedAt: now)
        ]

        let filtered = settings.filterDevicesForWidget(sampleDevices)
        XCTAssertEqual(filtered.count, 3)
        XCTAssertEqual(filtered.map(\.id), ["mac", "phone", "watch"])
    }

    func testCustomModeFiltersOutDisabledDevices() {
        settings.widgetSelectionMode = .custom
        // Enable only mac and watch, exclude phone
        settings.widgetEnabledDeviceIds = Set(["mac", "watch"])

        let now = Date()
        let sampleDevices = [
            WidgetBatteryDevice(id: "mac", name: "MacBook", symbol: "macbook", level: 90, isCharging: true, updatedAt: now),
            WidgetBatteryDevice(id: "phone", name: "iPhone", symbol: "iphone", level: 75, isCharging: false, updatedAt: now),
            WidgetBatteryDevice(id: "watch", name: "Apple Watch", symbol: "applewatch", level: 60, isCharging: false, updatedAt: now)
        ]

        let filtered = settings.filterDevicesForWidget(sampleDevices)
        XCTAssertEqual(filtered.count, 2)
        XCTAssertFalse(filtered.map(\.id).contains("phone"))
        XCTAssertTrue(filtered.map(\.id).contains("mac"))
        XCTAssertTrue(filtered.map(\.id).contains("watch"))
    }

    func testCustomModeOrdersDevicesAccordingToCustomPriority() {
        settings.widgetSelectionMode = .custom
        settings.widgetEnabledDeviceIds = Set(["mac", "phone", "watch", "airpods"])
        // Custom order: phone first, then watch, then mac, then airpods
        settings.widgetDeviceOrder = ["phone", "watch", "mac", "airpods"]

        let now = Date()
        let sampleDevices = [
            WidgetBatteryDevice(id: "mac", name: "MacBook", symbol: "macbook", level: 90, isCharging: true, updatedAt: now),
            WidgetBatteryDevice(id: "phone", name: "iPhone", symbol: "iphone", level: 75, isCharging: false, updatedAt: now),
            WidgetBatteryDevice(id: "watch", name: "Apple Watch", symbol: "applewatch", level: 60, isCharging: false, updatedAt: now),
            WidgetBatteryDevice(id: "airpods", name: "AirPods", symbol: "airpods", level: 100, isCharging: true, updatedAt: now)
        ]

        let filtered = settings.filterDevicesForWidget(sampleDevices)
        XCTAssertEqual(filtered.map(\.id), ["phone", "watch", "mac", "airpods"])
    }

    func testMoveWidgetDeviceChangesOrder() {
        settings.widgetSelectionMode = .custom
        settings.widgetDeviceOrder = ["mac", "phone", "watch"]

        // Move "watch" (index 2) to top (index 0)
        settings.moveWidgetDevice(from: 2, to: 0)
        XCTAssertEqual(settings.widgetDeviceOrder, ["watch", "mac", "phone"])
    }

    func testToggleDeviceSwitchesToCustomMode() {
        settings.widgetSelectionMode = .all
        XCTAssertTrue(settings.isDeviceEnabledForWidget(id: "phone"))

        // Toggling a device should automatically engage custom mode
        settings.toggleDeviceForWidget(id: "phone")
        XCTAssertEqual(settings.widgetSelectionMode, .custom)
        XCTAssertFalse(settings.isDeviceEnabledForWidget(id: "phone"))

        // Toggling again should re-enable
        settings.toggleDeviceForWidget(id: "phone")
        XCTAssertTrue(settings.isDeviceEnabledForWidget(id: "phone"))
    }
}
