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
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", "4.0.0"..<"6.0.0"),
    ],
    targets: [
        .target(
            name: "CirclesCore",
            dependencies: [.product(name: "Crypto", package: "swift-crypto")],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "CirclesCoreTests",
            dependencies: ["CirclesCore"],
            swiftSettings: swiftSettings
        ),
    ]
)
