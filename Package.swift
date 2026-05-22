// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Unison",
    // macOS 26 (Tahoe) baseline — native Liquid Glass APIs
    // (`glassEffect`, `.buttonStyle(.glass)`, `GlassEffectContainer`) are
    // the source of truth for the app's surface treatment. No backports.
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "UnisonDomain", targets: ["UnisonDomain"]),
        .library(name: "UnisonTranslation", targets: ["UnisonTranslation"]),
        .library(name: "UnisonAudio", targets: ["UnisonAudio"]),
        .library(name: "UnisonSystem", targets: ["UnisonSystem"]),
        .library(name: "UnisonUI", targets: ["UnisonUI"]),
        .executable(name: "Unison", targets: ["UnisonApp"]),
    ],
    // Note: swift-snapshot-testing requires XCTest, which is not
    // available on Command Line Tools-only setups. We ship our own
    // tiny image-snapshot helper (`Tests/UnisonUITests/SnapshotConfig.swift`)
    // that uses CGImage diffs and Swift Testing — no external deps.
    targets: [
        .target(name: "UnisonDomain"),
        .target(name: "UnisonTranslation", dependencies: ["UnisonDomain"]),
        .target(name: "UnisonAudio", dependencies: ["UnisonDomain"]),
        .target(name: "UnisonSystem", dependencies: ["UnisonDomain"]),
        .target(name: "UnisonUI", dependencies: ["UnisonDomain"]),
        .executableTarget(name: "UnisonApp", dependencies: [
            "UnisonDomain", "UnisonTranslation", "UnisonAudio",
            "UnisonSystem", "UnisonUI",
        ]),
        .testTarget(name: "UnisonDomainTests", dependencies: ["UnisonDomain", "UnisonUI"]),
        .testTarget(name: "UnisonTranslationTests", dependencies: ["UnisonTranslation"]),
        .testTarget(name: "UnisonAudioTests", dependencies: ["UnisonAudio"],
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "UnisonSystemTests", dependencies: ["UnisonSystem", "UnisonDomain"]),
        .testTarget(
            name: "UnisonUITests",
            dependencies: [
                "UnisonUI",
                "UnisonDomain",
            ]
        ),
    ]
)
