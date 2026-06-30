// swift-tools-version:6.2
import PackageDescription

// Swift language mode pinned to v5 globally.
//
// **Why not Swift 6 mode?** The Swift 6.3 toolchain that ships with Xcode 26
// has a runtime regression in `swift_task_isMainExecutorImpl`: any closure
// dispatched through Apple's frameworks (NSEvent monitors, SwiftUI
// TimelineView/Combine subscribers, AppKit event handlers, etc.) triggers
// an executor-identity check that dereferences a stale/invalid
// SerialExecutorRef and traps. Production crash reports captured the same
// `swift_getObjectType → swift_task_isMainExecutorImpl +36 →
// SerialExecutorRef::isMainExecutor` stack reached from **unrelated** call
// paths: TimelineView render, Combine.Timer.publish subscriber, and the
// HotkeyService NSEvent global monitor. The dereferenced pointer was
// bit-identical across crashes, which is the signature of a runtime-side
// table corruption — not a user-code race.
//
// Swift 5 language mode skips the strict concurrency runtime checks that
// invoke `swift_task_isCurrentExecutor`, sidestepping the bug entirely
// without sacrificing any actual language features the codebase uses
// (we don't write `nonisolated(unsafe)`, `sending`, etc.). Swift 6 syntax
// — `@MainActor`, `nonisolated`, `Sendable`, structured concurrency
// (`async`/`await`/`Task`) — all continue to work, the compiler just
// stops *enforcing* them at runtime.
//
// Revisit once Swift 6.3.x ships a fix (track upstream
// apple/swift issues around `swift_task_isMainExecutorImpl`).
private let langModeV5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

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
        .executable(name: "tap-benchmark", targets: ["TapBenchmark"]),
        .executable(name: "pacing-eval", targets: ["PacingEval"])
    ],
    // Note: swift-snapshot-testing requires XCTest, which is not
    // available on Command Line Tools-only setups. We ship our own
    // tiny image-snapshot helper (`Tests/UnisonUITests/SnapshotConfig.swift`)
    // that uses CGImage diffs and Swift Testing — no external deps.
    targets: [
        .target(name: "UnisonDomain", swiftSettings: langModeV5),
        .target(name: "UnisonTranslation", dependencies: ["UnisonDomain"], swiftSettings: langModeV5),
        .target(name: "UnisonAudio", dependencies: ["UnisonDomain", "CSpeexDSP"], swiftSettings: langModeV5),
        .target(
            name: "CSpeexDSP",
            path: "Sources/CSpeexDSP",
            publicHeadersPath: "include",
            cSettings: [
                .define("HAVE_CONFIG_H"),
                .headerSearchPath("include"),
                .headerSearchPath(".")
            ]
        ),
        .target(name: "UnisonSystem", dependencies: ["UnisonDomain"], swiftSettings: langModeV5),
        .target(name: "UnisonUI", dependencies: ["UnisonDomain", "UnisonAudio"], swiftSettings: langModeV5),
        .executableTarget(name: "UnisonApp", dependencies: [
            "UnisonDomain", "UnisonTranslation", "UnisonAudio",
            "UnisonSystem", "UnisonUI"
        ], swiftSettings: langModeV5),
        .executableTarget(
            name: "TapBenchmark",
            dependencies: ["UnisonAudio", "UnisonDomain"],
            path: "Sources/Tools/TapBenchmark",
            exclude: ["Info.plist", "tap-benchmark.entitlements"],
            swiftSettings: langModeV5
        ),
        .executableTarget(
            name: "PacingEval",
            dependencies: ["UnisonAudio", "UnisonTranslation", "UnisonDomain"],
            path: "Sources/Tools/PacingEval",
            swiftSettings: langModeV5
        ),
        .testTarget(name: "UnisonDomainTests", dependencies: ["UnisonDomain", "UnisonUI", "UnisonAudio"], swiftSettings: langModeV5),
        // Both targets `@testable import UnisonDomain` — the dependency
        // must be declared, not inherited through same-package search
        // paths (breaks under explicit-target-dependency checking).
        .testTarget(name: "UnisonTranslationTests", dependencies: ["UnisonTranslation", "UnisonDomain"], swiftSettings: langModeV5),
        .testTarget(name: "UnisonAudioTests", dependencies: ["UnisonAudio", "UnisonDomain"],
                    resources: [.copy("Fixtures")], swiftSettings: langModeV5),
        .testTarget(name: "UnisonSystemTests", dependencies: ["UnisonSystem", "UnisonDomain"], swiftSettings: langModeV5),
        .testTarget(
            name: "UnisonUITests",
            dependencies: [
                "UnisonUI",
                "UnisonDomain"
            ],
            // swift-snapshot-testing writes/reads `__Snapshots__/*.png`
            // through `#file`-based disk paths at runtime — never via
            // `Bundle.module`. So bundling them as resources is a waste
            // (inflates the test binary) AND SwiftPM emits an
            // "unhandled file" warning per snapshot. Explicit exclude
            // mutes the warning and keeps the test binary small.
            exclude: ["__Snapshots__"],
            swiftSettings: langModeV5
        ),
        .testTarget(
            name: "TapBenchmarkTests",
            dependencies: ["TapBenchmark"],
            swiftSettings: langModeV5
        )
    ]
)
