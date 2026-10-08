// swift-tools-version: 6.2
// Coverage-guided fuzzing with libFuzzer (Linux). See Fuzz/README.md.
import PackageDescription

let package = Package(
    name: "circles-fuzz",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "..")],
    targets: [
        .executableTarget(
            name: "circles-fuzz",
            dependencies: [.product(name: "CirclesFuzz", package: "circles")],
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        ),
    ]
)
