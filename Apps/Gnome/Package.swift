// swift-tools-version: 6.3
// The GNOME app (docs/DESIGN.md §11.6): GTK 4 + libadwaita through direct C
// interop, over the shared CirclesPresentation layer. A separate package so
// the core package stays free of GTK. Requires gtk4 and libadwaita
// development files (dnf: gtk4-devel libadwaita-devel; apt: libadwaita-1-dev).
import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
    name: "CirclesGnome",
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .systemLibrary(
            name: "CGtk",
            pkgConfig: "libadwaita-1",
            providers: [.apt(["libadwaita-1-dev"]), .yum(["libadwaita-devel"])]
        ),
        .target(
            name: "GtkKit",
            dependencies: ["CGtk"],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "CirclesGnome",
            dependencies: [
                "GtkKit", "CGtk",
                .product(name: "CirclesKit", package: "circles"),
                .product(name: "CirclesPresentation", package: "circles"),
            ],
            resources: [.copy("Icons")],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "MainActorSpike",
            dependencies: ["GtkKit", "CGtk"],
            swiftSettings: swiftSettings
        ),
    ]
)
