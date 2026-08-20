// swift-tools-version: 6.0
import PackageDescription

// MeetTape is built with SwiftPM because the development machine has Command Line
// Tools only (no Xcode, so no xcodebuild). scripts/bundle-app.sh assembles the
// executable products into MeetTape.app.
let package = Package(
    name: "MeetTape",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "MeetTape", targets: ["MeetTapeApp"]),
        .executable(name: "meettape-nativehost", targets: ["MeetTapeNativeHost"]),
        .executable(name: "meettape-test", targets: ["MeetTapeTests"]),
        .executable(name: "meettape-eval", targets: ["MeetTapeEval"]),
        .library(name: "MeetTapeCore", targets: ["MeetTapeCore"]),
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
        .target(name: "MeetTapeCore"),

        // AVFoundation + CoreAudio capture: microphone engine, process taps,
        // segment writing, pre-roll, import, mixdown, energy analysis.
        .target(name: "MeetTapeAudio", dependencies: ["MeetTapeCore"]),

        // Accessibility, window titles, CoreAudio process observation, browser sensor
        // transport. Turns OS signals into provider evidence.
        .target(name: "MeetTapeDetection", dependencies: ["MeetTapeCore", "MeetTapeAudio"]),

        // OpenAI, Keychain, EventKit, UserNotifications.
        .target(name: "MeetTapeIntegrations", dependencies: ["MeetTapeCore"]),

        // The local voice-identity store: SQLite with Float32 embedding BLOBs,
        // plus the recognition service that scores a speaker occurrence against
        // it. Independent of which transcription or diarization backend ran, so
        // choosing OpenAI in Settings still keeps voice memory local.
        .target(name: "MeetTapeSpeakers", dependencies: ["MeetTapeCore"]),

        // On-device speech: WhisperKit transcription and the FluidAudio offline
        // diarizer, behind the same protocols the OpenAI client implements.
        .target(
            name: "MeetTapeLocalAI",
            dependencies: [
                "MeetTapeCore",
                "MeetTapeAudio",
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),

        // Wiring: session controller runtime, capture engine, processing pipeline,
        // meeting repository, app coordinator.
        .target(
            name: "MeetTapeServices",
            dependencies: [
                "MeetTapeCore", "MeetTapeAudio", "MeetTapeDetection", "MeetTapeIntegrations",
                "MeetTapeSpeakers", "MeetTapeLocalAI",
            ]
        ),

        // SwiftUI/AppKit surfaces.
        .target(name: "MeetTapeUI", dependencies: ["MeetTapeServices"]),

        .executableTarget(name: "MeetTapeApp", dependencies: ["MeetTapeUI"]),

        // Firefox native messaging host. A compiled binary, because Firefox spawns
        // hosts with a minimal PATH and an interpreter shebang silently fails.
        .executableTarget(name: "MeetTapeNativeHost", dependencies: ["MeetTapeCore"]),

        // Developer evaluation tool. Not bundled into the application: it is how
        // the local stack's measured numbers get checked again on real audio.
        .executableTarget(
            name: "MeetTapeEval",
            dependencies: ["MeetTapeCore", "MeetTapeAudio", "MeetTapeLocalAI", "MeetTapeSpeakers"]
        ),

        // Minimal test harness. XCTest and swift-testing ship with Xcode, which is
        // not installed here, so the suite runs as an ordinary executable.
        .target(name: "TestKit"),
        .executableTarget(
            name: "MeetTapeTests",
            dependencies: [
                "TestKit", "MeetTapeCore", "MeetTapeAudio", "MeetTapeDetection",
                "MeetTapeIntegrations", "MeetTapeSpeakers", "MeetTapeLocalAI",
                "MeetTapeServices", "MeetTapeUI",
            ],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
