import AppKit
import MeetTapeCore
import MeetTapeLocalAI
import MeetTapeServices
import SwiftUI

/// The body of whichever step the wizard is on.
struct SetupStepContent: View {
    let model: SetupModel

    var body: some View {
        switch model.current {
        case .welcome: WelcomeStep()
        case .backend: BackendStep(model: model)
        case .models: ModelsStep(model: model)
        case .microphone: PermissionStep(model: model, kind: .microphone)
        case .screenRecording: PermissionStep(model: model, kind: .screenRecording)
        case .accessibility: PermissionStep(model: model, kind: .accessibility)
        case .optionalPermissions: OptionalPermissionsStep(model: model)
        case .firefox: FirefoxStep(model: model)
        case .finish: FinishStep(model: model)
        }
    }
}

/// Title, eyebrow and body, shared by every step so the pages line up.
struct StepHeader: View {
    var eyebrow: String?
    var title: String
    var message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let eyebrow {
                Text(eyebrow).font(.caption).foregroundStyle(.tertiary)
            }
            Text(title).font(.title2.weight(.semibold))
            Text(message)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - welcome

struct WelcomeStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ApplicationIcon(size: 64)
            StepHeader(
                title: "MeetTape records your meetings automatically",
                message: "It notices Slack huddles and Meet and Zoom calls in your browser, records "
                    + "your microphone and the meeting audio as separate tracks, and writes the "
                    + "results to ordinary files on disk."
            )
            Text(
                "Setup takes a few minutes. Three macOS permissions are needed before MeetTape "
                    + "can record anything, and this walks through them one at a time."
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - backend

struct BackendStep: View {
    let model: SetupModel
    private var runtime: MeetTapeRuntime { model.runtime }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepHeader(
                eyebrow: "Required",
                title: "Where transcription runs",
                message: "Transcription and speaker labelling can run on this Mac or through OpenAI. "
                    + "Voice profiles stay on this Mac either way, and are never uploaded."
            )

            Picker("", selection: Binding(
                get: { runtime.settings.processing.isFullyLocal ? ProcessingBackendChoice.local : .openAI },
                set: { model.chooseBackend($0) }
            )) {
                choice(
                    .local, "On this Mac",
                    "Nothing leaves the machine. Needs a one-time model download."
                )
                choice(
                    .openAI, "OpenAI",
                    "More accurate on hard audio, and needs an API key. Meeting audio is sent to "
                        + "OpenAI for transcription."
                )
            }
            .labelsHidden()
            .pickerStyle(.radioGroup)

            if !runtime.settings.processing.isFullyLocal { keyField }
        }
    }

    private func choice(
        _ tag: ProcessingBackendChoice, _ title: String, _ blurb: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
            Text(blurb).font(.caption).foregroundStyle(.secondary)
        }
        .tag(tag)
    }

    private var keyField: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text("OpenAI API key").font(.headline)
            SecureField("sk-…", text: Binding(get: { model.apiKey }, set: { model.apiKey = $0 }))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 380)
            HStack(spacing: 10) {
                Button(model.hasKeyOnDisk && model.apiKey.isEmpty ? "Check saved key" : "Save and check") {
                    Task { await model.saveAndVerifyKey() }
                }
                .disabled(
                    (model.apiKey.isEmpty && !model.hasKeyOnDisk) || model.keyState == .checking
                )
                keyStateLabel
            }
            if model.mayAcceptUnverifiedKey {
                Button("Continue anyway") { model.acceptUnverifiedKey() }
                    .buttonStyle(.link)
                Text(
                    "The request failed for a reason that was not a refusal, so the key may be "
                        + "fine. It is checked again at the first meeting."
                )
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Text(
                "The key is stored in the macOS keychain and never written to a meeting file, a "
                    + "log or a preference."
            )
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var keyStateLabel: some View {
        switch model.keyState {
        case .absent:
            EmptyView()
        case .checking:
            ProgressView().controlSize(.small)
        case .verified:
            Label("The key works", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.caption)
        case .rejected(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red).font(.caption)
        case .unreachable(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange).font(.caption)
        }
    }
}

// MARK: - models

struct ModelsStep: View {
    let model: SetupModel
    private var runtime: MeetTapeRuntime { model.runtime }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepHeader(
                eyebrow: "Required",
                title: "Speech models",
                message: bodyText
            )

            if runtime.settings.processing.usesLocalTranscription {
                LocalModelChoicePicker(runtime: runtime)
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(units, id: \.rawValue) { unit in
                    HStack {
                        Image(systemName: installed(unit) ? "checkmark.circle.fill" : "arrow.down.circle")
                            .foregroundStyle(installed(unit) ? .green : .secondary)
                        Text(ProcessingSettingsTab.unitName(unit))
                        Spacer()
                        Text(status(unit)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            downloadControls
        }
    }

    private var bodyText: String {
        if runtime.settings.processing.usesLocalTranscription {
            return "Downloaded once, then transcription and speaker recognition run on this Mac "
                + "with nothing sent anywhere."
        }
        // The cloud path is not download-free and saying otherwise sets up a
        // surprise: the diarizer is required in every configuration because voice
        // memory embeds a cloud diarizer's intervals locally, and gpt-transcribe
        // returns no timings, so the aligner computes them here.
        return "OpenAI transcribes, and two pieces still run on this Mac: the speaker models "
            + "that voice recognition needs, and the aligner that works out word timings, "
            + "which the transcription model does not return."
    }

    private var units: [LocalModelUnit] {
        LocalModelUnit.allCases.filter { model.snapshot.requiredUnits.contains($0) }
    }

    private func installed(_ unit: LocalModelUnit) -> Bool {
        runtime.localModelState.present.bytes(for: unit) != nil
    }

    private func status(_ unit: LocalModelUnit) -> String {
        if let bytes = runtime.localModelState.present.bytes(for: unit) {
            return "Installed, \(ProcessingSettingsTab.megabytes(bytes))"
        }
        if runtime.localModelState.isBusy { return "Downloading" }
        return "About \(ProcessingSettingsTab.megabytes(unit.approximateBytes))"
    }

    @ViewBuilder
    private var downloadControls: some View {
        switch runtime.localModelState {
        case .downloading(let fraction, let detail, _):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: fraction)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                Text(
                    "This keeps running while you carry on. Nothing later in setup waits for it."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        case .failed(let message, _):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange).font(.caption)
            Button("Try again") { Task { await model.startModelDownload() } }
        case .notInstalled:
            Button(downloadLabel) { Task { await model.startModelDownload() } }
                .buttonStyle(.borderedProminent)
        case .installed, .outdated:
            Label("Everything this configuration needs is on disk", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.callout)
        }
    }

    private var downloadLabel: String {
        let missing = model.snapshot.missingUnits.reduce(Int64(0)) { $0 + $1.approximateBytes }
        return "Download about \(ProcessingSettingsTab.megabytes(missing))"
    }
}

// MARK: - one permission

struct PermissionStep: View {
    let model: SetupModel
    let kind: PermissionKind

    private var status: PermissionStatus { model.status(for: kind) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepHeader(
                eyebrow: kind.isRequired ? "Required" : "Optional",
                title: kind.title,
                message: kind.rationale
            )

            liveState

            if !status.isUsable {
                SettingsPaneIllustration(kind: kind)
                    .frame(maxWidth: 420)

                // Shown for a plain denial too, not only the granted-but-not-
                // effective state. A list pane keeps its old entry when a build is
                // re-signed, and switching that stale row on does nothing for the
                // running binary: it has to be removed with the minus button and
                // added again. Without the advice here that is a dead end the user
                // has to work out alone.
                if let advice = status.advice, status.state != .notDetermined {
                    Label(advice, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 14) {
                    // One call either way. For a prompt permission it raises the
                    // prompt; for a list permission it is what puts MeetTape into
                    // the list, and the model opens the pane straight after so the
                    // row the illustration shows is actually there.
                    Button(actionLabel) { Task { await model.request(kind) } }
                    .buttonStyle(.borderedProminent)

                    if kind.acceptsDroppedApplication { AppDragChip() }
                }
            }
        }
    }

    @ViewBuilder
    private var liveState: some View {
        if status.isUsable {
            Label("\(kind.title) is on", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(waitingText).foregroundStyle(.secondary)
            }
        }
    }

    private var waitingText: String {
        kind.isGrantedByPrompt
            ? "Waiting for you to allow it"
            : "Waiting for you to switch \(ApplicationIdentity.name) on"
    }

    private var actionLabel: String {
        if kind.isGrantedByPrompt, status.state == .notDetermined { return "Allow \(kind.title)" }
        // Not the pane name. On macOS 27 that reads "Open Device Control and Data
        // Access settings", which is a button wider than the illustration above
        // it. The picture already says which pane opens.
        return "Open System Settings"
    }
}

// MARK: - the optional pair

struct OptionalPermissionsStep: View {
    let model: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepHeader(
                eyebrow: "Optional, and both make MeetTape better",
                title: "Calendar and notifications",
                message: "Neither is needed to record. Skipping them leaves recording exactly as it "
                    + "is, and both can be switched on later in Settings."
            )
            row(.calendar)
            Divider()
            row(.notifications)
        }
    }

    private func row(_ kind: PermissionKind) -> some View {
        let status = model.status(for: kind)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: status.isUsable ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(status.isUsable ? .green : .secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text(kind.title).font(.body.weight(.medium))
                Text(kind.rationale).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !status.isUsable {
                Button("Connect") { Task { await model.request(kind) } }
            }
        }
    }
}

// MARK: - Firefox

struct FirefoxStep: View {
    let model: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepHeader(
                eyebrow: "Optional, and it makes browser calls precise",
                title: "Firefox extension",
                message: "The extension reports when you join and leave a Meet or Zoom call. Without "
                    + "it those calls are still recorded, from window titles and microphone "
                    + "state, so recording starts before you have actually joined."
            )

            HStack(spacing: 8) {
                Image(
                    systemName: model.hostStatus?.isReadyForFirefox == true
                        ? "checkmark.circle.fill" : "circle"
                )
                .foregroundStyle(model.hostStatus?.isReadyForFirefox == true ? .green : .secondary)
                Text("Step 1, the native messaging host")
                Spacer()
                Button("Install host") { model.installHost() }
                    .disabled(model.hostStatus?.isReadyForFirefox == true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Step 2, load the add-on in Firefox").font(.body.weight(.medium))
                Text(
                    "Firefox only installs add-ons through its own interface. Open "
                        + "about:debugging#/runtime/this-firefox, choose Load Temporary Add-on, "
                        + "and select manifest.json in the folder below. A temporary add-on is "
                        + "dropped when Firefox quits, so this repeats each launch until the "
                        + "extension is signed and published."
                )
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                HStack {
                    Button("Show extension folder") { model.revealExtension() }
                    Button("Copy about:debugging") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            "about:debugging#/runtime/this-firefox", forType: .string
                        )
                    }
                }
            }
        }
    }
}

// MARK: - finish

struct FinishStep: View {
    let model: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepHeader(
                title: model.canFinish ? "MeetTape is ready" : "Something is still missing",
                message: model.canFinish
                    ? "MeetTape lives in the menu bar. It starts recording when it notices a "
                        + "meeting, and files each one as a folder of ordinary files."
                    : "The steps marked in the list on the left still need finishing before "
                        + "MeetTape can record."
            )

            if !model.canFinish {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(unfinished) { step in
                        Button {
                            model.jump(to: step.id)
                        } label: {
                            Label(step.id.railTitle, systemImage: "arrow.right.circle")
                        }
                        .buttonStyle(.link)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Meetings are saved to").font(.body.weight(.medium))
                Text(model.storagePath).font(.callout).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                HStack {
                    Button("Choose folder…") { model.chooseStorage() }
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.open(model.runtime.settings.storageRoot)
                    }
                }
            }

            if model.runtime.localModelState.isBusy {
                Label(
                    "Models are still downloading. Recording works now; meetings that finish "
                        + "first are processed when the download completes.",
                    systemImage: "arrow.down.circle"
                )
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var unfinished: [SetupStep] {
        model.steps.filter { $0.isRequired && !$0.isSatisfied }
    }
}
