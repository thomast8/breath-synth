// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "breath-synth",
    platforms: [
        .macOS("26.0"),
        .iOS("26.0"),
    ],
    products: [
        .library(name: "BreathEngine", targets: ["BreathEngine"]),
        .library(name: "BluetoothStack", targets: ["BluetoothStack"]),
        .executable(name: "breath", targets: ["BreathCLI"]),
        .executable(name: "sensor-debug", targets: ["SensorDebugApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "BreathEngine"
        ),
        .target(
            name: "BluetoothStack"
        ),
        .executableTarget(
            name: "BreathCLI",
            dependencies: [
                "BreathEngine",
                "BluetoothStack",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            exclude: ["Resources/Info.plist"],
            linkerSettings: [
                // Embed an Info.plist into the binary so macOS shows a Bluetooth-usage
                // rationale string when the CLI first touches CoreBluetooth. The grant is
                // still attributed to the terminal app, not to `breath` (OS limitation).
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/BreathCLI/Resources/Info.plist",
                ])
            ]
        ),
        .executableTarget(
            name: "SensorDebugApp",
            dependencies: ["BluetoothStack"],
            exclude: ["Resources/Info.plist"],
            linkerSettings: [
                // Embed the Info.plist (with NSBluetoothAlwaysUsageDescription) into the binary so a
                // `swift run` launch has a Bluetooth-usage rationale. For a stable TCC identity, bundle
                // it into a real .app with scripts/make-debug-app.sh.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/SensorDebugApp/Resources/Info.plist",
                ])
            ]
        ),
        .testTarget(
            name: "BreathEngineTests",
            dependencies: ["BreathEngine"]
        ),
        .testTarget(
            name: "BluetoothStackTests",
            dependencies: ["BluetoothStack"]
        ),
    ]
)
