import MeetTapeCore
import MeetTapeLocalAI
import MeetTapeServices
import SwiftUI

/// Where each stage runs, which model it uses, and what is on disk to run it.
///
/// One page: picking a model that is not installed starts its download here,
/// inline on the row, instead of sending the user to a second page.
struct ProcessingSettingsTab: View {
    let model: SettingsModel
    private var runtime: MeetTapeRuntime { model.runtime }

    var body: some View {
        Form {
            Section("Transcription") {
                backendPicker(keyPath: \.transcription)
                if runtime.settings.processing.usesLocalTranscription {
                    LocalModelChoicePicker(runtime: runtime)
                } else {
                    cloudTranscriptionPicker
                }
            }
            Section("Diarization") {
                backendPicker(keyPath: \.diarization)
                if !runtime.settings.processing.usesLocalDiarization {
                    cloudDiarizationRow
                }
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
            modelsOnDiskSection
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
        .task { await runtime.refreshLocalModelState() }
    }

    private func backendPicker(
        keyPath: WritableKeyPath<ProcessingSettings, ProcessingBackendChoice>
    ) -> some View {
        Picker("Runs on", selection: Binding(
            get: { runtime.settings.processing[keyPath: keyPath] },
            set: { newValue in
                var settings = runtime.settings
                settings.processing[keyPath: keyPath] = newValue
                runtime.update(settings: settings)
                Task { await runtime.installLocalModels() }
            }
        )) {
            Text("Cloud — OpenAI").tag(ProcessingBackendChoice.openAI)
            Text("Local — on this Mac").tag(ProcessingBackendChoice.local)
        }
        .pickerStyle(.radioGroup)
    }

    /// The sentinel the pickers use for a model identifier typed by hand.
    private static let customModelTag = "custom"

    private var cloudTranscriptionPicker: some View {
        let current = runtime.settings.models.transcription
        let isPreset = AIModelSettings.transcriptionChoices.contains(current)
        return VStack(alignment: .leading, spacing: 6) {
            Picker("Model", selection: Binding(
                get: { isPreset ? current : Self.customModelTag },
                set: { newValue in
                    var settings = runtime.settings
                    settings.models.transcription =
                        newValue == Self.customModelTag ? "" : newValue
                    runtime.update(settings: settings)
                    // gpt-transcribe returns no timings; the aligner that
                    // supplies them is a local download.
                    Task { await runtime.installLocalModels() }
                }
            )) {
                cloudChoice(
                    "gpt-transcribe",
                    "Most accurate, takes vocabulary hints. Timings are computed on "
                        + "this Mac by a 600 MB aligner model."
                )
                cloudChoice(
                    "gpt-4o-transcribe-diarize",
                    "Words and speakers in one request. Nothing to download."
                )
                cloudChoice(
                    "whisper-1",
                    "The previous generation, word timings from the API."
                )
                Text("Custom…").tag(Self.customModelTag)
            }
            .pickerStyle(.radioGroup)
            if !isPreset {
                TextField("model identifier", text: Binding(
                    get: { runtime.settings.models.transcription },
                    set: { newValue in
                        var settings = runtime.settings
                        settings.models.transcription = newValue
                        runtime.update(settings: settings)
                    }
                ))
                .frame(width: 280)
            }
            if AIModelSettings.transcriptionTiming(for: current) == .text, isPreset {
                TextField(
                    "Vocabulary hints — names and jargon, comma separated",
                    text: Binding(
                        get: { runtime.settings.models.vocabularyHints },
                        set: { newValue in
                            var settings = runtime.settings
                            settings.models.vocabularyHints = newValue
                            runtime.update(settings: settings)
                        }
                    )
                )
                Text("Sent with each request so the model expects these words.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func cloudChoice(_ id: String, _ blurb: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(id)
            Text(blurb).font(.caption).foregroundStyle(.secondary)
        }
        .tag(id)
    }

    private var cloudDiarizationRow: some View {
        let current = runtime.settings.models.diarization
        let isPreset = AIModelSettings.diarizationChoices.contains(current)
        return VStack(alignment: .leading, spacing: 6) {
            Picker("Model", selection: Binding(
                get: { isPreset ? current : Self.customModelTag },
                set: { newValue in
                    var settings = runtime.settings
                    settings.models.diarization =
                        newValue == Self.customModelTag ? "" : newValue
                    runtime.update(settings: settings)
                }
            )) {
                Text("gpt-4o-transcribe-diarize").tag("gpt-4o-transcribe-diarize")
                Text("Custom…").tag(Self.customModelTag)
            }
            .pickerStyle(.radioGroup)
            if !isPreset {
                TextField("model identifier", text: Binding(
                    get: { runtime.settings.models.diarization },
                    set: { newValue in
                        var settings = runtime.settings
                        settings.models.diarization = newValue
                        runtime.update(settings: settings)
                    }
                ))
                .frame(width: 280)
            }
        }
    }

    /// Everything installed or needed, with the one control set that changes it.
    private var modelsOnDiskSection: some View {
        Section("Models on this Mac") {
            ForEach(visibleUnits, id: \.rawValue) { unit in
                LabeledContent(Self.unitName(unit)) {
                    HStack(spacing: 8) {
                        Text(unitStatus(unit)).foregroundStyle(.secondary)
                        if installedBytes(unit) != nil {
                            Button("Delete") {
                                Task { await runtime.removeLocalModel(unit) }
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
            switch runtime.localModelState {
            case .downloading(let fraction, let detail, _):
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: fraction)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            case .failed(let message, _):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.caption)
                Button("Try Again") { Task { await runtime.installLocalModels() } }
            case .notInstalled:
                if !requiredUnits.isEmpty {
                    Button(downloadLabel) { Task { await runtime.installLocalModels() } }
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
            case .installed:
                EmptyView()
            }
            Text(
                "Stored in MeetTape's Application Support folder. Recording works while "
                    + "models download; meetings queue and process when they arrive.\n"
                    + (runtime.models?.locations.root.path ?? "")
            )
            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    private var requiredUnits: Set<LocalModelUnit> {
        LocalModelUnit.required(for: runtime.settings)
    }

    /// Required units first, then anything else still on disk.
    private var visibleUnits: [LocalModelUnit] {
        LocalModelUnit.allCases.filter { unit in
            requiredUnits.contains(unit) || installedBytes(unit) != nil
        }
    }

    private func installedBytes(_ unit: LocalModelUnit) -> Int64? {
        runtime.localModelState.present.bytes(for: unit)
    }

    private func unitStatus(_ unit: LocalModelUnit) -> String {
        if let bytes = installedBytes(unit) { return "Installed — \(Self.megabytes(bytes))" }
        if case .downloading = runtime.localModelState, requiredUnits.contains(unit) {
            return "Downloading"
        }
        return "Not installed — about \(Self.megabytes(unit.approximateBytes))"
    }

    private var downloadLabel: String {
        let missing = requiredUnits.reduce(Int64(0)) { total, unit in
            installedBytes(unit) == nil ? total + unit.approximateBytes : total
        }
        return "Download about \(Self.megabytes(missing))"
    }

    static func unitName(_ unit: LocalModelUnit) -> String {
        switch unit {
        case .whisper: "Whisper Large-v3-Turbo"
        case .parakeet: "Parakeet TDT v3"
        case .cohere: "Cohere Transcribe"
        case .ctcAligner: "Timing aligner"
        case .diarizer: "Speaker models"
        }
    }

    static func megabytes(_ bytes: Int64) -> String {
        bytes >= 1_024 * 1_024 * 1_024
            ? String(format: "%.1f GB", Double(bytes) / (1_024 * 1_024 * 1_024))
            : "\(max(1, bytes / 1_048_576)) MB"
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

/// The local engine choice, shared between Settings and the setup wizard.
///
/// Picking a model that is not on disk starts its download immediately; the
/// row says what it costs before the click.
struct LocalModelChoicePicker: View {
    let runtime: MeetTapeRuntime

    var body: some View {
        Picker("Model", selection: Binding(
            get: { runtime.settings.processing.localTranscriptionModel },
            set: { newValue in
                var settings = runtime.settings
                settings.processing.localTranscriptionModel = newValue
                runtime.update(settings: settings)
                Task { await runtime.installLocalModels() }
            }
        )) {
            choice(
                .cohere, "Cohere Transcribe",
                "Most accurate on meeting audio. 2.1 GB plus a 600 MB aligner; the "
                    + "first use takes a few minutes to prepare."
            )
            choice(
                .parakeet, "Parakeet TDT v3",
                "Fast, word timings built in, 25 languages. 460 MB."
            )
            choice(
                .whisper, "Whisper Large-v3-Turbo",
                "The previous engine. 624 MB."
            )
        }
        .pickerStyle(.radioGroup)
    }

    private func choice(
        _ tag: LocalTranscriptionModel, _ title: String, _ blurb: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
            Text(blurb).font(.caption).foregroundStyle(.secondary)
        }
        .tag(tag)
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
        .alert(
            model.pendingDestructiveAction?.title ?? "",
            isPresented: Binding(
                get: { model.pendingDestructiveAction != nil },
                set: { if !$0 { model.pendingDestructiveAction = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { model.pendingDestructiveAction = nil }
            Button(
                model.pendingDestructiveAction?.confirmLabel ?? "Delete", role: .destructive
            ) {
                Task { await model.performPendingDestructiveAction() }
            }
        } message: {
            Text(model.pendingDestructiveAction?.message ?? "")
        }
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
                Button("Forget learned voice") { model.confirmForgetVoice(entry) }
                Divider()
                Button("Delete", role: .destructive) { model.confirmDelete(entry) }
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
