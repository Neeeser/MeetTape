import AppKit
import EventKit
import Foundation
import UniformTypeIdentifiers
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

                    // Every setup step, on a machine with no permissions granted
                    // and no models on disk. Rendered one at a time because the
                    // wizard only builds the step it is showing, so a trap in a
                    // later step would otherwise never be reached here.
                    let setup = SetupModel(runtime: runtime, install: { _, _ in })
                    for step in SetupStepID.allCases {
                        setup.jump(to: step)
                        render(SetupWizardView(model: setup, onFinish: {}))
                    }
                    // Settings, including the tabs that read live audio state.
                    render(SettingsView(model: SettingsModel(runtime: runtime)))
                    expect.isTrue(true, "the panels built without trapping")
                }
                try? FileManager.default.removeItem(at: root)
            },

            test("the dragged application is offered as a file URL") { expect in
                // The drag adds MeetTape to the Accessibility and Screen Recording
                // lists, which is the fast route into panes that have no prompt.
                // Built with NSItemProvider(contentsOf:) it registered nothing
                // usable, because that wants a readable file and an application is
                // a directory: the drag picked up, dropped, and did nothing.
                let bundle = URL(fileURLWithPath: "/Applications/Safari.app")
                let provider = ApplicationIdentity.dragItemProvider(for: bundle)
                expect.isTrue(
                    provider.registeredTypeIdentifiers.contains(UTType.fileURL.identifier),
                    "a drop target that takes files sees nothing without public.file-url: "
                        + "\(provider.registeredTypeIdentifiers)"
                )
                expect.equal(provider.suggestedName, "Safari.app")

                let loaded: URL? = await withCheckedContinuation { continuation in
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        continuation.resume(returning: url)
                    }
                }
                expect.equal(loaded, bundle, "and it resolves back to the bundle")
            },

            test("calendar access is believed over EventKit's own status") { expect in
                // Observed on macOS 27: requestFullAccessToEvents called back with
                // granted = true, System Settings listed MeetTape under Calendars
                // with Full Access, and EKEventStore.authorizationStatus went on
                // reporting notDetermined for the rest of the process's life. The
                // wizard step never went green, and events(around:) returned
                // nothing, so a meeting recorded in that session got no calendar
                // title and no attendees.
                expect.equal(
                    PermissionsService.calendarState(reported: .notDetermined, canReadCalendars: true),
                    .granted,
                    "a store that can read calendars settles it"
                )
                expect.equal(
                    PermissionsService.calendarState(reported: .notDetermined, canReadCalendars: false),
                    .notDetermined,
                    "and one that cannot has genuinely not been asked"
                )

                // A refusal is a refusal. The probe never overrides it, or a
                // denied permission would read as granted off an empty answer.
                expect.equal(
                    PermissionsService.calendarState(reported: .denied, canReadCalendars: true),
                    .denied
                )
                expect.equal(
                    PermissionsService.calendarState(reported: .writeOnly, canReadCalendars: true),
                    .denied,
                    "write-only cannot read the events the matcher needs"
                )
                expect.equal(
                    PermissionsService.calendarState(reported: .fullAccess, canReadCalendars: false),
                    .granted,
                    "and the supported answer is trusted when it is positive"
                )
            },

            test("setup moves to whichever side of System Settings has room") { expect in
                // The wizard floats, so it stays readable while the user works in
                // System Settings. Floating also puts it on top of the pane it is
                // describing, which is worse than sinking was.
                let screen = CGRect(x: 0, y: 0, width: 1_800, height: 1_100)
                let size = CGSize(width: 760, height: 580)

                // Settings on the left, so the wizard goes right.
                let left = CGRect(x: 0, y: 0, width: 740, height: 1_100)
                let placedRight = SetupWindowPlacement.frame(
                    for: size, avoiding: left, within: screen
                )
                expect.isFalse(placedRight.intersects(left), "must not cover the pane")
                expect.isTrue(placedRight.maxX <= screen.maxX, "and must stay on screen")

                // Settings on the right, so the wizard goes left.
                let right = CGRect(x: 1_060, y: 0, width: 740, height: 1_100)
                let placedLeft = SetupWindowPlacement.frame(
                    for: size, avoiding: right, within: screen
                )
                expect.isFalse(placedLeft.intersects(right))
                expect.isTrue(placedLeft.minX >= screen.minX)

                // A screen too narrow to hold both: staying on screen wins over
                // not overlapping, since a window pushed off the display cannot
                // be read at all.
                let narrow = CGRect(x: 0, y: 0, width: 1_000, height: 1_100)
                let middle = CGRect(x: 130, y: 0, width: 740, height: 1_100)
                let squeezed = SetupWindowPlacement.frame(
                    for: size, avoiding: middle, within: narrow
                )
                expect.isTrue(squeezed.minX >= narrow.minX, "left edge stays on screen")
                expect.isTrue(squeezed.maxX <= narrow.maxX, "and so does the right edge")
            },

            test("window-server rectangles are flipped into AppKit coordinates") { expect in
                // The window list measures from the top left of the primary
                // display and AppKit from the bottom left. Skipping the flip put
                // the wizard off the bottom of the screen on any tall display.
                let measured: (x: CGFloat, maxY: CGFloat, screenTop: CGFloat)? = await MainActor.run {
                    guard let primary = NSScreen.screens.first else { return nil }
                    let topOfScreen = CGRect(x: 10, y: 0, width: 300, height: 200)
                    let flipped = SetupWindowPlacement.flipped(topOfScreen)
                    return (flipped.minX, flipped.maxY, primary.frame.maxY)
                }
                guard let measured else { return expect.fail("no screen") }
                expect.equal(measured.x, 10, "x is unchanged")
                expect.equal(
                    measured.maxY, measured.screenTop,
                    "a window at the top in window-server coordinates is at the top in AppKit"
                )
            },

            test("setup never touches the keychain on the local path") { expect in
                // Asking whether a key is stored can raise the keychain password
                // prompt: a login-keychain item enforces its access control on the
                // search as well as on the read, so a build re-signed since the
                // item was created is no longer trusted by it. Asked from begin(),
                // that dialog appeared over the wizard on every open, for every
                // user, including everyone who stays on the local default and has
                // no key at all.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }

                let lookups = Counter()
                let model = await MainActor.run {
                    SetupModel(
                        runtime: MeetTapeRuntime(settingsDirectory: root),
                        keyPresence: { await lookups.bump(); return true },
                        // Choosing a backend starts the download for that
                        // choice. With the real one this test fetched the
                        // aligner from HuggingFace to answer a question about
                        // the keychain.
                        install: { _, _ in }
                    )
                }

                await model.lookUpStoredKeyIfNeeded()
                expect.equal(
                    await lookups.value, 0,
                    "the local default must never ask the keychain anything"
                )

                await MainActor.run { model.chooseBackend(.openAI) }
                await model.lookUpStoredKeyIfNeeded()
                expect.equal(await lookups.value, 1, "choosing cloud is what asks")

                await model.lookUpStoredKeyIfNeeded()
                expect.equal(await lookups.value, 1, "and it is asked once, not per redraw")
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

            test("reconciling the login item does nothing when it already matches") { expect in
                // The setting was stored, shown and read by nothing, so the
                // toggle did nothing. Registration itself is a call into
                // launchd and is verified by hand; what is testable is that an
                // unchanged state asks for no work, which matters because
                // registering an already-registered item throws and this runs
                // on every settings change.
                expect.isNil(LoginItem.action(wanted: true, isRegistered: true))
                expect.isNil(LoginItem.action(wanted: false, isRegistered: false))
                expect.equal(LoginItem.action(wanted: true, isRegistered: false), .register)
                expect.equal(LoginItem.action(wanted: false, isRegistered: true), .unregister)
            },

            test("a speaker who never speaks is not offered for naming") { expect in
                // A cloud-diarized meeting listed eleven speakers, six of them
                // showing 0s: labels the diarizer emitted that own no words.
                // There is nothing a user can do with those rows.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let archive = root.appendingPathComponent("Meetings")
                let repository = MeetingRepository(root: archive)
                let started = Date(timeIntervalSince1970: 1_787_070_000)
                let created = try repository.createMeeting(
                    source: .inPerson, provider: .unknown, startedAt: started,
                    titles: TitleCandidates(provider: "Workshop", timestampFallback: "f"),
                    now: started
                )
                func utterance(key: String, start: Double, end: Double) -> Utterance {
                    Utterance(
                        id: Utterance.identifier(
                            chunkID: "mic_chunk_001", track: .mic, start: start, end: end
                        ),
                        start: start, end: end, track: .mic,
                        rawSpeakerLabel: key, speakerKey: key, text: "Morning.",
                        chunkID: "mic_chunk_001", model: "test"
                    )
                }
                try created.store.writeCanonicalTranscript(CanonicalTranscript(
                    generatedAt: started,
                    utterances: [
                        utterance(key: "mic_chunk_001_speaker_00", start: 0, end: 6),
                        utterance(key: "mic_chunk_001_speaker_01", start: 7, end: 7),
                    ]
                ))

                let model = await MainActor.run { () -> MeetingReviewModel in
                    let runtime = MeetTapeRuntime(settingsDirectory: root)
                    var settings = runtime.settings
                    settings.storageRootPath = archive.path
                    runtime.update(settings: settings)
                    return MeetingReviewModel(runtime: runtime, meetingID: created.metadata.id)
                }
                await model.reloadSpeakers()
                await MainActor.run {
                    expect.equal(model.speakerRows.count, 1, "the silent cluster is not a row")
                    expect.equal(model.speakerRows[0].clusterID, "mic_chunk_001_speaker_00")
                    // Hidden for display only: the transcript still holds it.
                    expect.equal(model.speakerKeys.count, 2)
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

            test("the Dock icon is off unless a settings file asks for it") { expect in
                // A menu-bar utility that takes a Dock slot on upgrade is a
                // visible change nobody asked for, so an absent key reads as
                // off rather than as the platform default for an app.
                let older = #"{"version": 3, "localUserName": "Andrew"}"#
                let settings = try JSONDecoder().decode(AppSettings.self, from: Data(older.utf8))
                expect.isFalse(settings.showsDockIcon)
                expect.equal(settings.localUserName, "Andrew", "the fields beside it are untouched")
                expect.isFalse(AppSettings().showsDockIcon, "and a fresh install is menu bar only")

                let chosen = #"{"version": 3, "showsDockIcon": true}"#
                let enabled = try JSONDecoder().decode(AppSettings.self, from: Data(chosen.utf8))
                expect.isTrue(enabled.showsDockIcon)
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

/// Counts calls from a `@Sendable` closure.
actor Counter {
    private(set) var value = 0
    func bump() { value += 1 }
}
