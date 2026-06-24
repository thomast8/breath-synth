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
        .executable(name: "breath", targets: ["BreathCLI"]),
        .executable(name: "breath-debug", targets: ["BreathDebugApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "BreathEngine"
        ),
        .executableTarget(
            name: "BreathCLI",
            dependencies: [
                "BreathEngine",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "BreathDebugApp",
            dependencies: ["BreathEngine"],
            exclude: ["Resources/Info.plist"],
            linkerSettings: [
                // Embed an Info.plist so a `swift run` binary still gets a proper bundle name /
                // high-resolution backing store. Audio output needs no TCC entitlement, so unlike
                // the BLE debug app this binary runs fine unsigned; the .app bundle is just nicer.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/BreathDebugApp/Resources/Info.plist",
                ])
            ]
        ),
        .testTarget(
            name: "BreathEngineTests",
            dependencies: ["BreathEngine"]
        ),
    ]
)
