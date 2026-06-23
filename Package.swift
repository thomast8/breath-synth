// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "breath-synth",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "BreathEngine", targets: ["BreathEngine"]),
        .executable(name: "breath", targets: ["BreathCLI"]),
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
        .testTarget(
            name: "BreathEngineTests",
            dependencies: ["BreathEngine"]
        ),
    ]
)
