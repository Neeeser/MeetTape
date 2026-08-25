// swift-tools-version: 6.0
import PackageDescription

// Pipit is built with SwiftPM because the development machine has Command Line
// Tools only (no Xcode, so no xcodebuild). scripts/bundle-app.sh assembles the
// executable products into Pipit.app.
let package = Package(
    name: "Pipit",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Pipit", targets: ["PipitApp"]),
        .executable(name: "pipit-nativehost", targets: ["PipitNativeHost"]),
        .executable(name: "pipit-test", targets: ["PipitTests"]),
        .executable(name: "pipit-eval", targets: ["PipitEval"]),
        .library(name: "PipitCore", targets: ["PipitCore"]),
    ],
    // Pinned to the exact versions the local-processing and speaker-scale probes
    // measured. A newer revision changes transcription and embedding behaviour,
    // so it is a re-evaluation, not a bump.
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.6"),
    ],
    targets: [
        // Pure logic. Foundation only: state machines, manifest, timeline arithmetic,
        // chunk planning, transcript merging, storage layout. Everything here is
        // deterministic and directly testable.
        .target(name: "PipitCore"),

        // AVFoundation + CoreAudio capture: microphone engine, process taps,
        // segment writing, pre-roll, import, mixdown, energy analysis.
        .target(name: "PipitAudio", dependencies: ["PipitCore"]),

        // Accessibility, window titles, CoreAudio process observation, browser sensor
        // transport. Turns OS signals into provider evidence.
        .target(name: "PipitDetection", dependencies: ["PipitCore", "PipitAudio"]),

        // OpenAI, Keychain, EventKit, UserNotifications.
        .target(name: "PipitIntegrations", dependencies: ["PipitCore"]),

        // The local voice-identity store: SQLite with Float32 embedding BLOBs,
        // plus the recognition service that scores a speaker occurrence against
        // it. Independent of which transcription or diarization backend ran, so
        // choosing OpenAI in Settings still keeps voice memory local.
        .target(name: "PipitSpeakers", dependencies: ["PipitCore"]),

        // On-device speech: WhisperKit transcription and the FluidAudio offline
        // diarizer, behind the same protocols the OpenAI client implements.
        .target(
            name: "PipitLocalAI",
            dependencies: [
                "PipitCore",
                "PipitAudio",
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),

        // Wiring: session controller runtime, capture engine, processing pipeline,
        // meeting repository, app coordinator.
        .target(
            name: "PipitServices",
            dependencies: [
                "PipitCore", "PipitAudio", "PipitDetection", "PipitIntegrations",
                "PipitSpeakers", "PipitLocalAI",
            ]
        ),

        // SwiftUI/AppKit surfaces.
        .target(name: "PipitUI", dependencies: ["PipitServices"]),

        .executableTarget(name: "PipitApp", dependencies: ["PipitUI"]),

        // Firefox native messaging host. A compiled binary, because Firefox spawns
        // hosts with a minimal PATH and an interpreter shebang silently fails.
        .executableTarget(name: "PipitNativeHost", dependencies: ["PipitCore"]),

        // The benchmark meter: ground-truth model, scorer and suite manifest.
        // Foundation only, so the same arithmetic runs in the test suite and in
        // the evaluation tool, and so nothing eval-only lands in PipitCore.
        .target(name: "PipitBench"),

        // Developer evaluation tool. Not bundled into the application: it is how
        // the local stack's measured numbers get checked again on real audio.
        .executableTarget(
            name: "PipitEval",
            dependencies: [
                "PipitCore", "PipitAudio", "PipitLocalAI", "PipitSpeakers",
                "PipitBench", "PipitIntegrations", "PipitServices",
            ]
        ),

        // Minimal test harness. XCTest and swift-testing ship with Xcode, which is
        // not installed here, so the suite runs as an ordinary executable.
        .target(name: "TestKit"),
        .executableTarget(
            name: "PipitTests",
            dependencies: [
                "TestKit", "PipitCore", "PipitAudio", "PipitDetection",
                "PipitIntegrations", "PipitSpeakers", "PipitLocalAI",
                "PipitServices", "PipitUI", "PipitBench",
            ],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
