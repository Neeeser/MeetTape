import MeetTapeCore
import MeetTapeLocalAI
import MeetTapeServices
import SwiftUI

/// Where each stage runs, and what the local voice memory is allowed to do.
struct ProcessingSettingsTab: View {
    let model: SettingsModel
    private var runtime: MeetTapeRuntime { model.runtime }

    var body: some View {
        Form {
            Section("Transcription") {
                backendPicker(
                    keyPath: \.transcription,
                    localLabel: "Local — Whisper Large-v3-Turbo",
                    cloudLabel: "OpenAI — \(runtime.settings.models.transcription)"
                )
                Text(
                    "Local transcription runs on this Mac and needs no API key. It matches "
                        + "the cloud model on words and is less consistent about punctuation "
                        + "and capitalisation between passages."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Section("Diarization") {
                backendPicker(
                    keyPath: \.diarization,
                    localLabel: "Local — FluidAudio",
                    cloudLabel: "OpenAI — \(runtime.settings.models.diarization)"
                )
                Text(
                    "Who spoke when. Chosen separately from transcription: either one can "
                        + "run in the cloud without the other."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Section("Speaker recognition") {
                speakerToggle("Recognize known voices", keyPath: \.recognizeKnownVoices)
                speakerToggle("Remember recurring unnamed voices", keyPath: \.rememberRecurringVoices)
                speakerToggle("Learn my voice automatically", keyPath: \.learnMyVoice)
                speakerToggle("Learn from confirmed speaker corrections", keyPath: \.learnFromCorrections)
                Text(
                    "Voice profiles stay on this Mac and are never uploaded, whichever "
                        + "backends are selected above. Only your microphone track and speaker "
                        + "names you confirm yourself ever add to a profile."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            if runtime.settings.processing.isFullyLocal {
                Section {
                    Label(
                        "Recording, transcription, speakers and voice recognition all run on "
                            + "this Mac. An API key is needed only for titles, summaries and notes.",
                        systemImage: "lock.laptopcomputer"
                    )
                    .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func backendPicker(
        keyPath: WritableKeyPath<ProcessingSettings, ProcessingBackendChoice>,
        localLabel: String,
        cloudLabel: String
    ) -> some View {
        Picker("Runs on", selection: Binding(
            get: { runtime.settings.processing[keyPath: keyPath] },
            set: { newValue in
                var settings = runtime.settings
                settings.processing[keyPath: keyPath] = newValue
                runtime.update(settings: settings)
            }
        )) {
            Text(localLabel).tag(ProcessingBackendChoice.local)
            Text(cloudLabel).tag(ProcessingBackendChoice.openAI)
        }
        .pickerStyle(.radioGroup)
    }

    private func speakerToggle(
        _ title: String, keyPath: WritableKeyPath<SpeakerRecognitionSettings, Bool>
    ) -> some View {
        Toggle(title, isOn: Binding(
            get: { runtime.settings.processing.speakers[keyPath: keyPath] },
            set: { newValue in
                var settings = runtime.settings
                settings.processing.speakers[keyPath: keyPath] = newValue
                runtime.update(settings: settings)
            }
        ))
    }
}

/// What is installed on disk, and the one control that changes it.
struct LocalModelsSettingsTab: View {
    let model: SettingsModel
    private var runtime: MeetTapeRuntime { model.runtime }

    var body: some View {
        Form {
            Section("Speech models") {
                LabeledContent("Whisper Large-v3-Turbo") { Text(whisperStatus) }
                LabeledContent("FluidAudio speaker models") { Text(diarizerStatus) }
                switch runtime.localModelState {
                case .downloading(let fraction, let detail):
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: fraction)
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.caption)
                    Button("Try Again") { Task { await runtime.installLocalModels() } }
                case .notInstalled:
                    Button("Download about 650 MB") {
                        Task { await runtime.installLocalModels() }
                    }
                case .outdated:
                    Label(
                        "These were downloaded by an older build that pinned different model "
                            + "revisions. Re-downloading matches the versions this build was "
                            + "measured against.",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    Button("Re-download") { Task { await runtime.reinstallLocalModels() } }
                    Button("Delete Models") { Task { await runtime.removeLocalModels() } }
                case .installed:
                    Button("Delete Models") { Task { await runtime.removeLocalModels() } }
                }
                Text(
                    "Downloaded once and stored in MeetTape's Application Support folder. "
                        + "Recording works while they download; meetings queue and process "
                        + "when they arrive."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Section("Location") {
                Text(runtime.models?.locations.root.path ?? "")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .task { await runtime.refreshLocalModelState() }
    }

    private var whisperStatus: String {
        switch runtime.localModelState {
        case .installed(let receipt), .outdated(let receipt):
            "Installed — \(megabytes(receipt.whisperBytes))"
        case .downloading: "Downloading"
        case .notInstalled, .failed: "Not installed — about 624 MB"
        }
    }

    private var diarizerStatus: String {
        switch runtime.localModelState {
        case .installed(let receipt), .outdated(let receipt):
            "Installed — \(megabytes(receipt.diarizerBytes))"
        case .downloading: "Downloading"
        case .notInstalled, .failed: "Not installed — about 21 MB"
        }
    }

    private func megabytes(_ bytes: Int64) -> String {
        "\(max(1, bytes / 1_048_576)) MB"
    }
}

/// The people MeetTape can recognize, and the voices it has heard more than
/// once without knowing who they are.
struct PeopleSettingsTab: View {
    let model: SettingsModel
    private var runtime: MeetTapeRuntime { model.runtime }

    var body: some View {
        Form {
            if let renaming = model.renaming {
                Section(renaming.identity.kind == .anonymous ? "Name this voice" : "Rename") {
                    TextField("Name", text: model.text(\.renameDraft))
                    TextField("Organization (optional)", text: model.text(\.renameOrganization))
                    HStack {
                        Button("Save") { Task { await model.commitRename() } }
                            .disabled(model.renameDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button("Cancel") { model.cancelRename() }
                    }
                    if renaming.identity.kind == .anonymous {
                        Text(
                            "Every meeting this voice appeared in will show the name. Nothing is "
                                + "transcribed or analysed again."
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("People") {
                if model.people.isEmpty {
                    Text("Nobody yet. Naming a speaker on a meeting creates them here.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(model.people) { entry in row(entry) }
                }
            }
            Section("Voices heard more than once") {
                if model.recurringVoices.isEmpty {
                    Text(
                        "None yet. A voice with at least 45 seconds of clean speech that turns "
                            + "up in a second meeting is remembered here until you name it."
                    )
                    .font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(model.recurringVoices) { entry in row(entry) }
                }
            }
            if let statistics = model.voiceStatistics {
                Section("Storage") {
                    LabeledContent("Voice profiles") {
                        Text("\(statistics.namedPeople) named, \(statistics.recurringVoices) unnamed")
                    }
                    LabeledContent("Embeddings") { Text("\(statistics.embeddings)") }
                    LabeledContent("Database") {
                        Text("\(max(1, statistics.storageBytes / 1_024)) KB")
                    }
                    Text(
                        "Voice profiles are stored on this Mac only. They are never uploaded "
                            + "and never written into a meeting folder or an export."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .task { await model.refreshPeople() }
    }

    private func row(_ entry: SpeakerDirectoryEntry) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.identity.resolvedName).font(.callout)
                Text(subtitle(entry)).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Menu("Edit") {
                Button(entry.identity.kind == .anonymous ? "Name this person…" : "Rename…") {
                    model.beginRename(entry)
                }
                Button("Forget learned voice") {
                    Task { await model.forgetVoice(entry) }
                }
                Divider()
                Button("Delete", role: .destructive) {
                    Task { await model.deletePerson(entry) }
                }
            }
            .fixedSize()
        }
    }

    private func subtitle(_ entry: SpeakerDirectoryEntry) -> String {
        var parts: [String] = []
        if let organization = entry.identity.organization, !organization.isEmpty {
            parts.append(organization)
        }
        parts.append(entry.profile.summary)
        if entry.meetingCount > 0 {
            parts.append("heard in \(entry.meetingCount) meeting\(entry.meetingCount == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }
}
