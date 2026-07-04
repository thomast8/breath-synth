// swift-tools-version: 6.3
import PackageDescription

// Nested SPM package (not part of the root breath-synth manifest — `swift build` from the repo
// root never touches this). Depends on the root package by relative path for BreathEngineCore +
// BreathBank, which is why those had to become portable in the first place: this target links
// against the exact same calibrated CaptureAnalyzer/TakeGate/LiveTakeGrader/Grader/BankBuilder code
// the native breath-enroll app uses, no port.
let package = Package(
    name: "breath-web-server",
    platforms: [
        // Matches the root package's macOS deployment target (BreathEngineCore/BreathBank require
        // it) — irrelevant on Linux, where this whole platforms: list is ignored.
        .macOS("26.0")
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.89.0"),
        .package(url: "https://github.com/vapor/fluent.git", from: "4.8.0"),
        .package(url: "https://github.com/vapor/fluent-postgres-driver.git", from: "2.8.0"),
        // Test-only: route tests run against in-memory SQLite instead of a live Postgres — a
        // standard Vapor testing pattern, and Fluent's schema/enum abstraction is what makes it
        // safe (production still only ever uses Postgres, wired in configure.swift).
        .package(url: "https://github.com/vapor/fluent-sqlite-driver.git", from: "4.6.0"),
        .package(name: "breath-synth", path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "App",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
                .product(name: "BreathEngineCore", package: "breath-synth"),
                .product(name: "BreathBank", package: "breath-synth"),
            ]
        ),
        .testTarget(
            name: "AppTests",
            dependencies: [
                .target(name: "App"),
                .product(name: "XCTVapor", package: "vapor"),
                .product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver"),
            ]
        ),
    ]
)
