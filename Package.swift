// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "breath-synth",
    platforms: [
        .macOS("26.0"),
        .iOS("26.0"),
    ],
    products: [
        .library(name: "BreathEngineCore", targets: ["BreathEngineCore"]),
        .library(name: "BreathEngine", targets: ["BreathEngine"]),
        .executable(name: "breath", targets: ["BreathCLI"]),
        .executable(name: "breath-debug", targets: ["BreathDebugApp"]),
        .executable(name: "breath-enroll", targets: ["BreathEnrollApp"]),
        .library(name: "BreathBank", targets: ["BreathBank"]),
        .executable(name: "breath-bank", targets: ["BreathBankCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .target(
            // Platform-portable subset of the engine (Model/DSP/Capture analysis/BreathAssembler/
            // SequencePlanner) — no AVFoundation, no hard Accelerate dependency (SpectralDenoise
            // falls back to a pure-Swift FFT off Apple platforms). This is what a Linux server can
            // link against directly; `BreathEngine` re-exports it for existing Apple consumers.
            name: "BreathEngineCore"
        ),
        .target(
            name: "BreathEngine",
            dependencies: ["BreathEngineCore"]
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
        .executableTarget(
            name: "BreathEnrollApp",
            dependencies: ["BreathEngine", "BreathBank"],
            exclude: ["Resources/Info.plist", "Resources/BreathEnroll.entitlements"],
            linkerSettings: [
                // Embed an Info.plist so the binary carries a bundle name + the microphone usage
                // string (NSMicrophoneUsageDescription) macOS requires before any input-node access.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/BreathEnrollApp/Resources/Info.plist",
                ])
            ]
        ),
        .target(
            name: "BreathBank",
            dependencies: ["BreathEngineCore"]
        ),
        .executableTarget(
            name: "BreathBankCLI",
            dependencies: [
                "BreathBank",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "BreathEngineCoreTests",
            dependencies: ["BreathEngineCore"]
        ),
        .testTarget(
            name: "BreathEngineTests",
            dependencies: ["BreathEngine"]
        ),
        .testTarget(
            name: "BreathBankTests",
            dependencies: ["BreathBank"]
        ),
    ]
)
