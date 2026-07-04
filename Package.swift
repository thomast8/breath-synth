// swift-tools-version: 6.3
import PackageDescription

// Package.swift is itself compiled/executed by SwiftPM, so ordinary conditional compilation works
// here too: on Linux, only the portable targets (BreathEngineCore, BreathBank) and their test
// targets are declared — the Apple-only ones (BreathEngine and everything that imports AVFoundation
// transitively: the CLI/app targets, BreathBankCLI, BreathEngineTests) simply aren't part of the
// manifest there, so `swift build`/`swift test` never attempts to compile AVFoundation-only code on
// a toolchain that doesn't have it. macOS/iOS builds are unaffected — every target below still
// applies there exactly as before.
#if os(Linux)
let products: [Product] = [
    .library(name: "BreathEngineCore", targets: ["BreathEngineCore"]),
    .library(name: "BreathBank", targets: ["BreathBank"]),
]
let targets: [Target] = [
    .target(name: "BreathEngineCore"),
    .target(name: "BreathBank", dependencies: ["BreathEngineCore"]),
    .testTarget(name: "BreathEngineCoreTests", dependencies: ["BreathEngineCore"]),
    .testTarget(name: "BreathBankTests", dependencies: ["BreathBank"]),
]
#else
let products: [Product] = [
    .library(name: "BreathEngineCore", targets: ["BreathEngineCore"]),
    .library(name: "BreathEngine", targets: ["BreathEngine"]),
    .executable(name: "breath", targets: ["BreathCLI"]),
    .executable(name: "breath-debug", targets: ["BreathDebugApp"]),
    .executable(name: "breath-enroll", targets: ["BreathEnrollApp"]),
    .library(name: "BreathBank", targets: ["BreathBank"]),
    .executable(name: "breath-bank", targets: ["BreathBankCLI"]),
]
let targets: [Target] = [
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
        // Includes PoolRenderTests.swift, which needs both the real BreathEngine render API and
        // BreathBank's BankBuilder — a genuine cross-target integration test, not portable, so it
        // lives here rather than in BreathBankTests (which Linux builds and tests on its own).
        name: "BreathEngineTests",
        dependencies: ["BreathEngine", "BreathBank"]
    ),
    .testTarget(
        name: "BreathBankTests",
        dependencies: ["BreathBank"]
    ),
]
#endif

let package = Package(
    name: "breath-synth",
    platforms: [
        .macOS("26.0"),
        .iOS("26.0"),
    ],
    products: products,
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: targets
)
