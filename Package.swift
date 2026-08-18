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
        .library(name: "MeetTapeCore", targets: ["MeetTapeCore"]),
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

        // Wiring: session controller runtime, capture engine, processing pipeline,
        // meeting repository, app coordinator.
        .target(
            name: "MeetTapeServices",
            dependencies: ["MeetTapeCore", "MeetTapeAudio", "MeetTapeDetection", "MeetTapeIntegrations"]
        ),

        // SwiftUI/AppKit surfaces.
        .target(name: "MeetTapeUI", dependencies: ["MeetTapeServices"]),

        .executableTarget(name: "MeetTapeApp", dependencies: ["MeetTapeUI"]),

        // Firefox native messaging host. A compiled binary, because Firefox spawns
        // hosts with a minimal PATH and an interpreter shebang silently fails.
        .executableTarget(name: "MeetTapeNativeHost", dependencies: ["MeetTapeCore"]),

        // Minimal test harness. XCTest and swift-testing ship with Xcode, which is
        // not installed here, so the suite runs as an ordinary executable.
        .target(name: "TestKit"),
        .executableTarget(
            name: "MeetTapeTests",
            dependencies: [
                "TestKit", "MeetTapeCore", "MeetTapeAudio", "MeetTapeDetection",
                "MeetTapeIntegrations", "MeetTapeServices", "MeetTapeUI",
            ],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
