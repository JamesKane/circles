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
        .library(name: "CirclesMLS", targets: ["CirclesMLS"]),
        .library(name: "CirclesDHT", targets: ["CirclesDHT"]),
        .library(name: "CirclesPresentation", targets: ["CirclesPresentation"]),
        .executable(name: "circles", targets: ["circles-cli"]),
        .executable(name: "circles-pod", targets: ["circles-pod"]),
        .executable(name: "circles-relay", targets: ["circles-relay"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", "4.0.0"..<"6.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.100.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        // Pre-release; pinned exactly (docs/DESIGN.md §8.3).
        .package(url: "https://github.com/germ-network/swift-mls.git", exact: "0.1.7"),
        .package(url: "https://github.com/germ-network/swift-secret-bytes.git", from: "0.5.0"),
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
        // The system SQLite (docs/DESIGN.md §10). On Linux it needs the
        // development headers: libsqlite3-dev (apt) or sqlite-devel (dnf).
        .target(
            name: "CSQLite",
            linkerSettings: [
                .linkedLibrary("sqlite3", .when(platforms: [.linux, .macOS, .iOS, .tvOS, .watchOS, .visionOS, .android])),
                .linkedLibrary("winsqlite3", .when(platforms: [.windows])),
            ]
        ),
        .target(
            name: "CirclesStorage",
            dependencies: ["CirclesCore", "CirclesCrypto", "CirclesSync", "CSQLite"],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "CirclesDHT",
            dependencies: ["CirclesCore", "CirclesCrypto", .product(name: "Crypto", package: "swift-crypto")],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "CirclesMLS",
            dependencies: [
                .product(name: "MLSProfileRFC9420", package: "swift-mls"),
                .product(name: "MLSCrypto", package: "swift-mls"),
                .product(name: "MLSCodec", package: "swift-mls"),
                .product(name: "MLSFraming", package: "swift-mls"),
                .product(name: "MLSTreeMath", package: "swift-mls"),
                .product(name: "MLSTreeKEM", package: "swift-mls"),
                .product(name: "SecretBytes", package: "swift-secret-bytes"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "CirclesKit",
            dependencies: ["CirclesCore", "CirclesCrypto", "CirclesSync", "CirclesNet", "CirclesStorage", "CirclesMLS"],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "CirclesPresentation",
            dependencies: ["CirclesKit"],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "CirclesCLISupport",
            dependencies: ["CirclesKit"],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "circles-cli",
            dependencies: ["CirclesKit", "CirclesPresentation", "CirclesCLISupport", .product(name: "ArgumentParser", package: "swift-argument-parser")],
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
            name: "CirclesStorageTests",
            dependencies: ["CirclesStorage"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "CirclesPresentationTests",
            dependencies: ["CirclesPresentation", "CirclesNet"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "CirclesDHTTests",
            dependencies: ["CirclesDHT", "CirclesSync"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "CirclesMLSTests",
            dependencies: ["CirclesMLS"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "CirclesKitTests",
            dependencies: ["CirclesKit"],
            swiftSettings: swiftSettings
        ),
    ]
)
