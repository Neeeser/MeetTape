import AppKit
import Foundation
import MeetTapeAudio
import MeetTapeCore
import MeetTapeIntegrations
import MeetTapeServices
import MeetTapeUI
import SwiftUI
import TestKit

/// Builds each window's view tree and forces a layout pass.
///
/// This is not a pixel test. It catches the failures that otherwise only appear
/// when a user opens a panel: a view that traps on a nil, a binding that reads a
/// meeting that no longer exists, a model that crashes on an empty archive.
enum UITests {
    @MainActor
    static func render(_ view: some View, size: NSSize = NSSize(width: 720, height: 560)) {
        let controller = NSHostingController(rootView: AnyView(view))
        controller.view.frame = NSRect(origin: .zero, size: size)
        controller.view.layoutSubtreeIfNeeded()
        controller.view.displayIfNeeded()
    }

    static var suite: Suite {
        Suite("UI", [
            test("every panel builds and lays out") { expect in
                let root = try ManifestTests.makeTemporaryDirectory()
                await MainActor.run {
                    NSApplication.shared.setActivationPolicy(.prohibited)

                    let runtime = MeetTapeRuntime(settingsDirectory: root)
                    var settings = runtime.settings
                    settings.storageRootPath = root.appendingPathComponent("Meetings").path
                    runtime.update(settings: settings)

                    // Onboarding on a machine with no permissions granted yet.
                    render(OnboardingView(model: OnboardingModel(runtime: runtime), onFinish: {}))
                    // Settings, including the tabs that read live audio state.
                    render(SettingsView(model: SettingsModel(runtime: runtime)))
                    expect.isTrue(true, "the panels built without trapping")
                }
                try? FileManager.default.removeItem(at: root)
            },

            test("the review panel handles a meeting with nothing processed yet") { expect in
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let repository = MeetingRepository(root: root.appendingPathComponent("Meetings"))
                let started = Date(timeIntervalSince1970: 1_787_070_000)
                let created = try repository.createMeeting(
                    source: .slackHuddle, provider: .slack, startedAt: started,
                    titles: TitleCandidates(provider: "Engineering huddle", timestampFallback: "f"),
                    now: started
                )

                await MainActor.run {
                    let runtime = MeetTapeRuntime(settingsDirectory: root)
                    var settings = runtime.settings
                    settings.storageRootPath = root.appendingPathComponent("Meetings").path
                    runtime.update(settings: settings)

                    let model = MeetingReviewModel(runtime: runtime, meetingID: created.metadata.id)
                    expect.equal(model.title, "Engineering huddle")
                    expect.isNil(model.transcript, "nothing has been transcribed yet")
                    expect.equal(model.speakerKeys, [])
                    render(MeetingReviewView(model: model), size: NSSize(width: 780, height: 620))

                    // Editing the title while processing has not started must stick.
                    model.title = "Q3 planning"
                    model.save()
                    expect.equal(
                        repository.findMeeting(id: created.metadata.id)?.metadata.displayTitle,
                        "Q3 planning"
                    )
                }
            },

            test("closing the panel does not overwrite a note added elsewhere") { expect in
                // The menu bar appends a quick note straight to the file. The
                // panel holds whatever it read when it opened, and writes the
                // whole file on close, so an unconditional write threw the
                // appended note away.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let archive = root.appendingPathComponent("Meetings")
                let repository = MeetingRepository(root: archive)
                let started = Date(timeIntervalSince1970: 1_787_070_000)
                let created = try repository.createMeeting(
                    source: .slackHuddle, provider: .slack, startedAt: started,
                    titles: TitleCandidates(provider: "Standup", timestampFallback: "f"),
                    now: started
                )

                await MainActor.run {
                    let runtime = MeetTapeRuntime(settingsDirectory: root)
                    var settings = runtime.settings
                    settings.storageRootPath = archive.path
                    runtime.update(settings: settings)
                    let model = MeetingReviewModel(runtime: runtime, meetingID: created.metadata.id)
                    expect.equal(model.notes, "")

                    try? created.store.appendNote("ship on Friday", at: started)
                    model.saveNotes()
                    expect.isTrue(
                        created.store.readNotes().contains("ship on Friday"),
                        "the panel typed nothing, so it writes nothing"
                    )

                    // What the user did type still saves.
                    model.notes = "my own note"
                    model.saveNotes()
                    expect.equal(created.store.readNotes(), "my own note")
                }
            },

            test("typing a title or a note reaches disk without closing the panel") { expect in
                // Both were written only when the panel closed, under a card
                // that says editing is saved immediately, and the title only
                // when Return was pressed. onDisappear does not run on
                // termination, so quitting with the panel open lost everything
                // typed into it.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let archive = root.appendingPathComponent("Meetings")
                let repository = MeetingRepository(root: archive)
                let started = Date(timeIntervalSince1970: 1_787_070_000)
                let created = try repository.createMeeting(
                    source: .manual, provider: .unknown, startedAt: started,
                    titles: TitleCandidates(timestampFallback: "Manual"), now: started
                )

                let model = await MainActor.run { () -> MeetingReviewModel in
                    let runtime = MeetTapeRuntime(settingsDirectory: root)
                    var settings = runtime.settings
                    settings.storageRootPath = archive.path
                    runtime.update(settings: settings)
                    let model = MeetingReviewModel(runtime: runtime, meetingID: created.metadata.id)
                    model.titleBinding().wrappedValue = "Frankfurt cutover"
                    model.notesBinding().wrappedValue = "Chris owns the runbook"
                    return model
                }
                _ = model

                var savedNotes = ""
                var savedTitle: String?
                for _ in 0..<40 {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    savedNotes = created.store.readNotes()
                    savedTitle = (try? created.store.readMetadata())?.titles.human
                    if !savedNotes.isEmpty, savedTitle != nil { break }
                }
                expect.equal(savedNotes, "Chris owns the runbook")
                expect.equal(savedTitle, "Frankfurt cutover")
            },

            test("the panel resolves the archive once, not on every render") { expect in
                // The panel body reads the processing fraction beside the
                // meeting's own paths, so anything computed there runs on every
                // tick. Local diarization reports hundreds of times in a few
                // seconds, and `findMeeting` walks the archive root, every year
                // and month directory below it, and decodes a metadata.json,
                // all on the actor that arms the next recording.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let archive = root.appendingPathComponent("Meetings")
                let repository = MeetingRepository(root: archive)
                let started = Date(timeIntervalSince1970: 1_787_070_000)
                let earlier = try repository.createMeeting(
                    source: .slackHuddle, provider: .slack, startedAt: started,
                    titles: TitleCandidates(provider: "Standup", timestampFallback: "f"),
                    now: started
                )
                let later = try repository.createMeeting(
                    source: .slackHuddle, provider: .slack,
                    startedAt: started.addingTimeInterval(900),
                    titles: TitleCandidates(provider: "Standup", timestampFallback: "f"),
                    now: started.addingTimeInterval(900)
                )
                var metadata = later.metadata
                metadata.possibleContinuationOf = earlier.metadata.id
                metadata.possibleContinuationReason = "same meeting, 15 minutes later"
                try later.store.writeMetadata(metadata)

                await MainActor.run {
                    let runtime = MeetTapeRuntime(settingsDirectory: root)
                    var settings = runtime.settings
                    settings.storageRootPath = archive.path
                    runtime.update(settings: settings)

                    let model = MeetingReviewModel(runtime: runtime, meetingID: metadata.id)
                    expect.isTrue(model.directory != nil, "the reload resolved where it lives")
                    expect.equal(model.continuationSuggestion?.title, "Standup")

                    // With the archive gone, anything still walking it answers
                    // nil. Both of these were computed properties reached from
                    // the body, so this is the read the progress tick paid for.
                    try? FileManager.default.removeItem(at: archive)
                    expect.isTrue(
                        model.directory != nil,
                        "the panel's paths come from the last read, not from a fresh archive walk"
                    )
                    expect.equal(
                        model.continuationSuggestion?.title, "Standup",
                        "and so does the continuation it offers"
                    )
                }
            },

            test("menu-bar state reads correctly in each phase") { expect in
                var status = RuntimeStatus()
                expect.isFalse(status.isRecording)
                expect.equal(status.displayHealth, .idle)

                status.sessionState = .recording
                status.startedAt = Date().addingTimeInterval(-125)
                status.health = CaptureHealthSnapshot(mic: .healthy, remote: .idleButBound)
                expect.isTrue(status.isRecording)
                expect.equal(status.displayHealth, .healthy)
                expect.close(status.elapsed(now: Date()), 125, tolerance: 2)
                expect.equal(Format.duration(125), "02:05")

                // A failing required source is never displayed as healthy.
                status.health = CaptureHealthSnapshot(mic: .failed, remote: .healthy)
                expect.equal(status.displayHealth, .failed)

                // The reconnect window is not recording: segments are closed and
                // capture waits in memory, so the menu shows a distinct state.
                status.sessionState = .reconnecting
                expect.isFalse(status.isRecording)
                expect.isTrue(status.isInReconnectWindow)
                expect.isTrue(status.hasActiveSession)

                status.sessionState = .idle
                expect.equal(status.displayHealth, .idle, "an idle session shows no health")
            },

            test("settings survive a round trip through disk") { expect in
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let store = SettingsStore(directory: root)
                expect.equal(store.load().localUserName, "Me", "defaults apply to a fresh install")

                var settings = AppSettings()
                settings.localUserName = "Andrew"
                settings.providers.zoom = ProviderPolicy(autoStart: .never, autoStop: false)
                settings.enrichment.generateSummary = false
                settings.alwaysRecordApplications = ["com.example.videochat"]
                try store.save(settings)

                let reloaded = SettingsStore(directory: root).load()
                expect.equal(reloaded.localUserName, "Andrew")
                expect.equal(reloaded.providers.zoom.autoStart, .never)
                expect.isFalse(reloaded.enrichment.generateSummary)
                expect.equal(reloaded.alwaysRecordApplications, ["com.example.videochat"])
                // The API key is never in settings; it lives in the keychain.
                let raw = try String(contentsOf: store.url, encoding: .utf8)
                expect.isFalse(raw.contains("apiKey"))
                expect.isFalse(raw.lowercased().contains("sk-"))
            },

            test("a settings file from an older build keeps its values when a field is added") { expect in
                // Synthesized Codable throws on a missing key, and load() falls
                // back to defaults, so adding one field silently reset every
                // setting a user had chosen.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let store = SettingsStore(directory: root)

                var settings = AppSettings()
                settings.localUserName = "Andrew"
                settings.hasCompletedOnboarding = true
                try store.save(settings)

                // Strip a field, as if the file were written before it existed.
                var object = try JSONSerialization.jsonObject(
                    with: Data(contentsOf: store.url)
                ) as! [String: Any]
                object.removeValue(forKey: "echoCancellation")
                object.removeValue(forKey: "preferBuiltInMicrophone")
                try JSONSerialization.data(withJSONObject: object).write(to: store.url)

                let reloaded = store.load()
                expect.equal(reloaded.localUserName, "Andrew", "existing values must survive")
                expect.isTrue(reloaded.hasCompletedOnboarding, "onboarding must not reappear")
                expect.isTrue(reloaded.echoCancellation, "the missing field takes its default")
            },

            test("every menu row draws in a colour that is readable on a dark menu") { expect in
                // An attributed menu title with no foreground colour draws in
                // black, and a disabled row draws in the system's disabled grey.
                // Both are unreadable on a dark menu, which is where the menu bar
                // lives most of the time.
                await MainActor.run {
                    let item = MenuBarController.informationItem("  Recording")
                    guard let attributed = item.attributedTitle else {
                        return expect.fail("an informational row needs an explicit colour")
                    }
                    var found = false
                    attributed.enumerateAttribute(
                        .foregroundColor, in: NSRange(location: 0, length: attributed.length)
                    ) { value, _, _ in
                        found = value is NSColor
                    }
                    expect.isTrue(found, "no foreground colour on \(attributed.string)")
                    expect.isFalse(item.isEnabled, "an informational row is not clickable")

                    let heading = MenuBarController.informationItem("Processing", emphasis: true)
                    let colour = heading.attributedTitle?.attribute(
                        .foregroundColor, at: 0, effectiveRange: nil
                    ) as? NSColor
                    expect.equal(colour, NSColor.labelColor, "a heading uses the primary label colour")
                }
            },

            test("permission checks never trap outside an app bundle") { expect in
                // Reading notification permission through UserNotifications raises
                // an uncatchable Objective-C exception when the process has no
                // bundle identifier, which killed the whole test run when an
                // onboarding view refreshed itself in the background.
                expect.isFalse(
                    NotificationSupport.isAvailable, "the test runner is not an app bundle"
                )
                let statuses = await PermissionsService().allStatuses()
                expect.equal(statuses.count, PermissionKind.allCases.count)
                expect.equal(
                    statuses.first { $0.kind == .notifications }?.state, .notDetermined
                )
                NotificationService().registerCategories()
                NotificationService().recordingStarted(provider: .slack, title: "Standup")
            },

            test("processing state maps to something a person can read") { expect in
                expect.equal(ProcessingState.transcribing.displayName, "Transcribing")
                expect.equal(ProcessingState.failed.displayName, "Needs attention")
                expect.equal(ProcessingState.complete.displayName, "Complete")
                // Every failure message reassures about the recording.
                for error: ProcessingError in [
                    .missingAPIKey, .authenticationFailed, .rateLimited(retryAfter: nil),
                    .serverError(status: 500), .transport(reason: "offline"),
                ] {
                    expect.isTrue(
                        error.userMessage.contains("recording is safe")
                            || error.userMessage.contains("Your recording"),
                        "\(error.logSafeDescription) does not reassure: \(error.userMessage)"
                    )
                }
            },
        ])
    }
}
