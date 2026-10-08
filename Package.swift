// swift-tools-version: 6.3
// The design targets Swift 6.4+ (docs/DESIGN.md §11.1). The tools version is
// held at 6.3 until 6.4 toolchains are installed on dev machines and CI.
import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
    name: "circles",
    platforms: [.macOS(.v15), .iOS(.v18), .tvOS(.v18), .watchOS(.v11), .visionOS(.v2)],
    products: [
        .library(name: "CirclesCore", targets: ["CirclesCore"]),
        .library(name: "CirclesCrypto", targets: ["CirclesCrypto"]),
        .library(name: "CirclesSync", targets: ["CirclesSync"]),
        .library(name: "CirclesNet", targets: ["CirclesNet"]),
        .library(name: "CirclesStorage", targets: ["CirclesStorage"]),
        .library(name: "CirclesKit", targets: ["CirclesKit"]),
        .executable(name: "circles", targets: ["circles-cli"]),
        .executable(name: "circles-pod", targets: ["circles-pod"]),
        .executable(name: "circles-relay", targets: ["circles-relay"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", "4.0.0"..<"6.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.100.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "CirclesCore",
            dependencies: [.product(name: "Crypto", package: "swift-crypto")],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "CirclesCrypto",
            dependencies: ["CirclesCore", .product(name: "Crypto", package: "swift-crypto")],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "CirclesSync",
            dependencies: ["CirclesCore", "CirclesCrypto"],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "CirclesNet",
            dependencies: [
                "CirclesCrypto", "CirclesSync",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "CirclesStorage",
            dependencies: ["CirclesCore", "CirclesCrypto", "CirclesSync"],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "CirclesKit",
            dependencies: ["CirclesCore", "CirclesCrypto", "CirclesSync", "CirclesNet", "CirclesStorage"],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "CirclesCLISupport",
            dependencies: ["CirclesKit"],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "circles-cli",
            dependencies: ["CirclesKit", "CirclesCLISupport", .product(name: "ArgumentParser", package: "swift-argument-parser")],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "circles-pod",
            dependencies: ["CirclesKit", "CirclesCLISupport", .product(name: "ArgumentParser", package: "swift-argument-parser")],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "circles-relay",
            dependencies: ["CirclesKit", "CirclesCLISupport", .product(name: "ArgumentParser", package: "swift-argument-parser")],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "CirclesCoreTests",
            dependencies: ["CirclesCore"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "CirclesCryptoTests",
            dependencies: ["CirclesCrypto"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "CirclesSyncTests",
            dependencies: ["CirclesSync"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "CirclesNetTests",
            dependencies: ["CirclesNet"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "CirclesKitTests",
            dependencies: ["CirclesKit"],
            swiftSettings: swiftSettings
        ),
    ]
)
