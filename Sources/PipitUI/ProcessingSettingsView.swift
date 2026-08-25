import PipitCore
import PipitLocalAI
import PipitServices
import SwiftUI

/// Where each stage runs, which model it uses, and what is on disk to run it.
///
/// One page: picking a model that is not installed starts its download here,
/// inline on the row, instead of sending the user to a second page.
struct ProcessingSettingsTab: View {
    let model: SettingsModel
    private var runtime: PipitRuntime { model.runtime }

    var body: some View {
        Form {
            Section("Transcription") {
                backendPicker(keyPath: \.transcription)
                if runtime.settings.processing.usesLocalTranscription {
                    LocalModelChoicePicker(
                        selected: runtime.settings.processing.localTranscriptionModel,
                        select: { choice in
                            Task { await runtime.chooseLocalTranscriptionModel(choice) }
                        }
                    )
                } else {
                    cloudTranscriptionPicker
                }
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
                    "gpt-4o-transcribe-diarize",
                    "Speaker identification built in: one request returns the words "
                        + "and who said them. Nothing to download."
                )
                cloudChoice(
                    "gpt-transcribe",
                    "Strongest on clear recordings, takes vocabulary hints. Timings "
                        + "are computed on this Mac by a 600 MB aligner model. Can "
                        + "return nothing for stretches of very difficult audio; the "
                        + "meeting then retries instead of losing words."
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
                        + "revisions. Re-downloading matches the versions this build "
                        + "expects.",
                    systemImage: "arrow.triangle.2.circlepath"
                )
                .font(.caption).foregroundStyle(.secondary)
                Button("Re-download") { Task { await runtime.reinstallLocalModels() } }
            case .installed:
                EmptyView()
            }
            Text(
                "Stored in Pipit's Application Support folder. Recording works while "
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
        case .canary: "Canary 1B v2"
        case .ctcAligner: "Timing aligner"
        case .diarizer: "Speaker models"
        case .voiceActivity: "Voice detector"
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
    let selected: LocalTranscriptionModel
    /// Applied by whoever owns the choice: Settings writes it straight to the
    /// runtime, the wizard routes it through `SetupModel`.
    let select: (LocalTranscriptionModel) -> Void

    var body: some View {
        Picker("Model", selection: Binding(get: { selected }, set: select)) {
            ForEach(LocalTranscriptionModel.pickerRows(selected: selected), id: \.rawValue) { model in
                choice(model)
            }
        }
        .pickerStyle(.radioGroup)
    }

    private func choice(_ model: LocalTranscriptionModel) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(Self.title(model))
            Text(Self.blurb(model)).font(.caption).foregroundStyle(.secondary)
        }
        .tag(model)
    }

    private static func title(_ model: LocalTranscriptionModel) -> String {
        switch model {
        case .parakeet: "Parakeet TDT v3"
        case .cohere: "Cohere Transcribe"
        case .whisper: "Whisper Large-v3-Turbo"
        case .canary: "Canary 1B v2"
        case .apple: "Apple Speech"
        }
    }

    private static func blurb(_ model: LocalTranscriptionModel) -> String {
        switch model {
        case .apple:
            "Nothing to download: the speech models come with macOS. "
                + "Transcribes your first meeting immediately."
        case .parakeet:
            "The most accurate engine. Word timings built in, 25 languages, "
                + "about 50x realtime. 460 MB."
        case .cohere:
            // Rendered only on installs that already have it selected.
            "Slower and larger than Parakeet, with no accuracy advantage. "
                + "2.1 GB plus a 600 MB aligner."
        case .whisper:
            "The previous engine. 624 MB."
        case .canary:
            // Never rendered: not offered. Here because the switch is
            // exhaustive.
            "Not offered."
        }
    }
}

/// Where the voice database is and what is in it.
///
/// The directory itself moved to its own window: a list that grows to hundreds
/// of people needs search, grouping and multiple selection, and none of that
/// fits a settings pane sized by seven other tabs.
struct PeopleSettingsTab: View {
    let model: SettingsModel

    var body: some View {
        Form {
            Section {
                Button("Manage people…") { model.openPeople() }
                if let statistics = model.voiceStatistics {
                    Text(
                        "\(statistics.namedPeople) named, \(statistics.recurringVoices) unnamed "
                            + "recurring voices."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
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
}
