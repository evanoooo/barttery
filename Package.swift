// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Barttery",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Barttery",
            path: "Sources",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("IOBluetooth"),
                .linkedFramework("IOKit")
            ]
        ),
        .testTarget(
            name: "WidgetSnapshotTests",
            dependencies: ["Barttery"],
            path: "Tests/WidgetSnapshotTests"
        )
    ]
)
