import Foundation
import MeetTapeCore
import MeetTapeServices
import MeetTapeUI
import TestKit

/// What first-run setup refuses to finish without.
///
/// Every rule here is one a user hits on a fresh machine exactly once, where a
/// regression is invisible until someone reinstalls and records a meeting that
/// captures nothing.
enum SetupFlowTests {
    /// A snapshot with the three blocking permissions granted and nothing else
    /// arranged, so each test spoils exactly the thing it is about.
    private static func ready(
        settings: AppSettings = AppSettings(),
        cloudKeyVerified: Bool = false
    ) -> SetupSnapshot {
        var snapshot = SetupSnapshot(settings: settings, cloudKeyVerified: cloudKeyVerified)
        snapshot.permissions = [
            .microphone: .granted, .screenRecording: .granted, .accessibility: .granted,
        ]
        snapshot.installedUnits = snapshot.requiredUnits
        return snapshot
    }

    static var suite: Suite {
        Suite("SetupFlow", [
            test("all three detection permissions block finishing") { expect in
                // Microphone alone was the required set, so a user could press
                // Done having granted nothing else and get a recorder that never
                // notices a meeting.
                expect.isTrue(SetupFlow.canFinish(ready()), "the baseline finishes")

                for kind in [PermissionKind.microphone, .screenRecording, .accessibility] {
                    var snapshot = ready()
                    snapshot.permissions[kind] = .denied
                    expect.isFalse(
                        SetupFlow.canFinish(snapshot), "\(kind.rawValue) denied must block Done"
                    )
                    expect.isTrue(kind.isRequired, "\(kind.rawValue) is a required permission")
                }
            },

            test("calendar and notifications never block finishing") { expect in
                var snapshot = ready()
                snapshot.permissions[.calendar] = .denied
                snapshot.permissions[.notifications] = .denied
                expect.isTrue(SetupFlow.canFinish(snapshot))
                expect.isFalse(PermissionKind.calendar.isRequired)
                expect.isFalse(PermissionKind.notifications.isRequired)
            },

            test("a granted-but-not-effective permission does not count as granted") { expect in
                // The state an unsigned rebuild produces: the toggle reads on and
                // the running binary has no access. Treating it as granted let
                // setup finish onto a build that could not read a window title.
                var snapshot = ready()
                snapshot.permissions[.accessibility] = .grantedButNotEffective
                expect.isFalse(SetupFlow.canFinish(snapshot))
            },

            test("cloud needs a verified key, local needs nothing") { expect in
                var cloud = AppSettings()
                cloud.processing.transcription = .openAI
                cloud.processing.diarization = .openAI

                expect.isFalse(
                    SetupFlow.isSatisfied(.backend, in: ready(settings: cloud)),
                    "an unverified key leaves the backend step undone"
                )
                expect.isTrue(
                    SetupFlow.isSatisfied(
                        .backend, in: ready(settings: cloud, cloudKeyVerified: true)
                    )
                )
                expect.isTrue(
                    SetupFlow.isSatisfied(.backend, in: ready()),
                    "the local default needs no key at all"
                )
            },

            test("the cloud path still requires local model units") { expect in
                // The diarizer is required in every configuration because voice
                // memory embeds a cloud diarizer's intervals with local models,
                // and gpt-transcribe returns no timings so it needs the aligner.
                var cloud = AppSettings()
                cloud.processing.transcription = .openAI
                cloud.processing.diarization = .openAI
                let units = LocalModelUnit.required(for: cloud)
                expect.isTrue(units.contains(.diarizer), "the diarizer is always required")
                expect.isTrue(
                    units.contains(.ctcAligner), "gpt-transcribe returns text, so timings are local"
                )
                expect.isFalse(units.contains(.cohere), "and no local transcription engine")

                var local = AppSettings()
                local.processing.localTranscriptionModel = .cohere
                let localUnits = LocalModelUnit.required(for: local)
                expect.isTrue(localUnits.contains(.cohere))
                expect.isTrue(localUnits.contains(.diarizer))
            },

            test("models already on disk satisfy the step with no download") { expect in
                var snapshot = ready()
                expect.isTrue(snapshot.missingUnits.isEmpty)
                expect.isFalse(snapshot.isDownloadingModels)
                expect.isTrue(
                    SetupFlow.isSatisfied(.models, in: snapshot),
                    "a reinstall onto existing models downloads nothing"
                )

                snapshot.installedUnits = []
                expect.isFalse(SetupFlow.isSatisfied(.models, in: snapshot))
                expect.isFalse(SetupFlow.canFinish(snapshot))
            },

            test("a running download unblocks the models step") { expect in
                // Recording works while models arrive and meetings queue until
                // they do, so holding the user at this step for 2.1 GB buys
                // nothing.
                var snapshot = ready()
                snapshot.installedUnits = []
                snapshot.isDownloadingModels = true
                expect.isTrue(SetupFlow.isSatisfied(.models, in: snapshot))
                expect.isTrue(SetupFlow.canFinish(snapshot))
            },

            test("setup opens on Finish only when there is nothing left to do") { expect in
                expect.equal(
                    SetupFlow.openingStep(for: ready()), .finish,
                    "a reinstall that kept everything opens at the end"
                )
                var finished = AppSettings()
                finished.hasCompletedOnboarding = true
                expect.equal(
                    SetupFlow.openingStep(for: ready(settings: finished)), .finish,
                    "and so does a returning user with nothing broken"
                )

                var fresh = SetupSnapshot()
                fresh.permissions = [:]
                expect.equal(SetupFlow.openingStep(for: fresh), .welcome)

                // The backend step is satisfied by its own local default, so
                // resuming at the first unsatisfied step would skip the
                // local-or-cloud choice without ever showing it.
                expect.isTrue(SetupFlow.isSatisfied(.backend, in: fresh))
            },

            test("a revoked required permission reopens setup at the next launch") { expect in
                // Without this a user whose microphone grant was dropped by an OS
                // update carries on with a menu bar icon that looks exactly the
                // same as always, and finds out at the end of a meeting that
                // recorded nothing.
                var settings = AppSettings()
                settings.hasCompletedOnboarding = true
                var snapshot = ready(settings: settings)
                expect.isFalse(
                    SetupFlow.shouldOpenAtLaunch(snapshot), "nothing is wrong, so nothing opens"
                )

                for kind in [PermissionKind.microphone, .screenRecording, .accessibility] {
                    var revoked = snapshot
                    revoked.permissions[kind] = .denied
                    expect.isTrue(
                        SetupFlow.shouldOpenAtLaunch(revoked),
                        "\(kind.rawValue) revoked must bring setup back"
                    )
                    expect.equal(
                        SetupFlow.openingStep(for: revoked),
                        SetupStepID.allCases.first { $0.permission == kind },
                        "and open on the permission that broke, not on Welcome"
                    )
                }

                // An optional permission is not worth a window on every launch.
                snapshot.permissions[.calendar] = .denied
                snapshot.permissions[.notifications] = .denied
                expect.isFalse(SetupFlow.shouldOpenAtLaunch(snapshot))
            },

            test("setup that was never finished always opens") { expect in
                var snapshot = ready()
                expect.isFalse(snapshot.settings.hasCompletedOnboarding)
                expect.isTrue(
                    SetupFlow.shouldOpenAtLaunch(snapshot),
                    "every permission granted still leaves the choices unmade"
                )

                // And a missing model does not, on its own, reopen anything: it
                // is repaired in Settings and costs no recording.
                var finished = AppSettings()
                finished.hasCompletedOnboarding = true
                snapshot = ready(settings: finished)
                snapshot.installedUnits = []
                expect.isFalse(SetupFlow.isSatisfied(.models, in: snapshot))
                expect.isFalse(SetupFlow.shouldOpenAtLaunch(snapshot))
            },

            test("the step order runs welcome to finish with no gaps") { expect in
                var id = SetupStepID.welcome
                var walked: [SetupStepID] = [id]
                while let next = SetupFlow.step(after: id) {
                    id = next
                    walked.append(id)
                }
                expect.equal(walked, SetupStepID.allCases)
                expect.equal(id, .finish)
                expect.isTrue(SetupFlow.step(after: .finish) == nil)
                expect.isTrue(SetupFlow.step(before: .welcome) == nil)
                expect.equal(SetupFlow.step(before: .finish), .firefox)
            },

            test("only the panes with an application list accept a dropped app") { expect in
                // Dragging MeetTape in is the fast route for the two panes that
                // hold a list. The others are granted by a system prompt and have
                // nothing to drop onto, so offering a drag chip there would be a
                // control that does nothing.
                expect.isTrue(PermissionKind.accessibility.acceptsDroppedApplication)
                expect.isTrue(PermissionKind.screenRecording.acceptsDroppedApplication)
                expect.isFalse(PermissionKind.microphone.acceptsDroppedApplication)
                expect.isFalse(PermissionKind.calendar.acceptsDroppedApplication)
                expect.isFalse(PermissionKind.notifications.acceptsDroppedApplication)

                expect.isFalse(PermissionKind.accessibility.isGrantedByPrompt)
                expect.isTrue(PermissionKind.microphone.isGrantedByPrompt)
            },

            test("the Speech models step offers the engine choice at the settings default") { expect in
                // The step showed whatever the settings default happened to be
                // and no way to change it, so a fresh install committed to an
                // engine nobody had been shown.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }

                let model = await MainActor.run { makeSetupModel(root: root, requested: nil) }
                await MainActor.run {
                    expect.equal(
                        Set(LocalTranscriptionModel.offered),
                        Set(LocalTranscriptionModel.allCases),
                        "every engine has a row in the picker"
                    )
                    expect.equal(
                        LocalTranscriptionModel.offered.first, .parakeet,
                        "and the recommended one is offered first"
                    )
                    expect.equal(model.localModel, AppSettings().processing.localTranscriptionModel)
                    expect.equal(model.localModel, .parakeet)
                    expect.isTrue(
                        model.runtime.settings.processing.usesLocalTranscription,
                        "the default backend is local, which is what shows the picker"
                    )
                }
            },

            test("choosing Cohere in setup downloads Cohere and keeps the choice") { expect in
                // Picking a model is the consent for its download. The wizard
                // wrote the setting and started the install as two unordered
                // tasks, so the install could fetch the engine the user had
                // just moved away from.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }

                let requested = RequestedUnits()
                let model = await MainActor.run { makeSetupModel(root: root, requested: requested) }
                await model.chooseLocalModel(.cohere)

                expect.equal(
                    await requested.all, [[.cohere, .ctcAligner, .diarizer]],
                    "the download is for the chosen engine, with the aligner it needs"
                )
                await MainActor.run {
                    expect.equal(model.localModel, .cohere, "and the step shows what was picked")
                    model.finish()
                }
                expect.equal(
                    SettingsStore(directory: root).load().processing.localTranscriptionModel,
                    .cohere,
                    "finishing setup leaves the engine the user saw selected"
                )
            },

            test("leaving the choice alone downloads Parakeet and the diarizer only") { expect in
                // Nothing in setup may reach for the 2.1 GB engine on its own.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }

                let requested = RequestedUnits()
                let model = await MainActor.run { makeSetupModel(root: root, requested: requested) }
                await model.startModelDownload()

                expect.equal(await requested.all, [[.parakeet, .diarizer]])
                await MainActor.run { model.finish() }
                expect.equal(
                    SettingsStore(directory: root).load().processing.localTranscriptionModel,
                    .parakeet,
                    "and finishing setup stores the engine nobody touched"
                )
            },

            test("the illustrated pane names match the panes macOS 27 actually opens") { expect in
                // Checked against the panes themselves. Accessibility is the one
                // that moved: its privacy pane is called Device Control and Data
                // Access now, while the Accessibility item in the sidebar is the
                // unrelated VoiceOver and Zoom one. Naming the picture after the
                // sidebar item sends people somewhere with no MeetTape row in it.
                expect.equal(
                    PermissionKind.accessibility.paneTitle, "Device Control and Data Access"
                )
                expect.equal(
                    PermissionKind.screenRecording.paneTitle, "Screen & System Audio Recording"
                )
                for kind in PermissionKind.allCases {
                    expect.isFalse(kind.paneCaption.isEmpty, "\(kind.rawValue) has no caption")
                }
            },

            test("every settings deep link names a pane System Settings still has") { expect in
                // The com.apple.preference.security pane has not existed since
                // System Settings replaced System Preferences; opening it lands
                // on the Settings root with nothing to switch on.
                for kind in PermissionKind.allCases {
                    let url = try expect.unwrap(kind.settingsURL, "\(kind.rawValue) has no pane")
                    expect.equal(url.scheme, "x-apple.systempreferences")
                    expect.isFalse(
                        url.absoluteString.contains("com.apple.preference.security"),
                        "\(kind.rawValue) still points at the pre-Ventura pane"
                    )
                }
            },
        ])
    }
}

/// The unit sets an install was asked for, in the order they were asked.
actor RequestedUnits {
    private(set) var all: [Set<LocalModelUnit>] = []
    func record(_ units: Set<LocalModelUnit>) { all.append(units) }
}

@MainActor
private func makeSetupModel(root: URL, requested: RequestedUnits?) -> SetupModel {
    SetupModel(
        runtime: MeetTapeRuntime(settingsDirectory: root),
        // Setup on the local default asks the keychain nothing, and a real
        // install here would fetch gigabytes to answer a question about which
        // units were named.
        keyPresence: { false },
        install: { _, units in await requested?.record(units) }
    )
}
