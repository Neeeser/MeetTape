import AppKit
import PipitAudio
import PipitCore
import PipitDetection
import PipitIntegrations
import PipitServices
import SwiftUI

public struct SettingsView: View {
    let model: SettingsModel
    private var runtime: PipitRuntime { model.runtime }

    public init(model: SettingsModel) {
        self.model = model
    }

    public var body: some View {
        TabView {
            GeneralSettingsTab(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
            ProcessingSettingsTab(model: model)
                .tabItem { Label("Processing", systemImage: "waveform.badge.magnifyingglass") }
            PeopleSettingsTab(model: model)
                .tabItem { Label("People", systemImage: "person.crop.circle") }
            ProviderSettingsTab(model: model)
                .tabItem { Label("Providers", systemImage: "person.2.wave.2") }
            AudioSettingsTab(model: model)
                .tabItem { Label("Audio", systemImage: "waveform") }
            OpenAISettingsTab(model: model)
                .tabItem { Label("Cloud", systemImage: "sparkles") }
            PermissionsSettingsTab(model: model)
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
            StorageSettingsTab(model: model)
                .tabItem { Label("Storage", systemImage: "folder") }
        }
        .padding(16)
        .frame(minWidth: 760, minHeight: 520)
    }
}

struct GeneralSettingsTab: View {
    let model: SettingsModel
    private var runtime: PipitRuntime { model.runtime }

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: model.binding(\.launchAtLogin))
                Toggle("Show notifications", isOn: model.binding(\.showNotifications))
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Show in Dock", isOn: model.binding(\.showsDockIcon))
                    Text("The menu bar item stays either way.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle(
                    "Pause automatic detection",
                    isOn: Binding(
                        get: { runtime.settings.providers.detectionPaused },
                        set: { runtime.setDetectionPaused($0) }
                    )
                )
                if runtime.settings.providers.detectionPaused {
                    Label(
                        "Automatic detection is paused. Meetings are not recorded until it is resumed.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                    .font(.callout)
                }
            }
            Section("Your name") {
                TextField("Name", text: model.text(\.localUserName))
                    .onSubmit { model.saveLocalUserName() }
                Text(
                    "Used to label your own speech. On a remote call it comes from the "
                        + "microphone track, so it is attributed without diarization."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onDisappear { model.saveLocalUserName() }
    }
}

struct ProviderSettingsTab: View {
    let model: SettingsModel
    private var runtime: PipitRuntime { model.runtime }

    var body: some View {
        Form {
            Section("Providers") {
                providerRow("Slack Huddles", keyPath: \.slack)
                providerRow("Google Meet", keyPath: \.googleMeet)
                providerRow("Zoom", keyPath: \.zoom)
                providerRow("FaceTime", keyPath: \.faceTime)
                providerRow("Unknown calls", keyPath: \.unknownCalls)
            }
            Section("Browser integration") {
                LabeledContent("Firefox extension") {
                    Text(runtime.status.sensorConnection.label)
                        .foregroundStyle(runtime.status.sensorConnection.color)
                }
                Text(
                    "Meet and Zoom are recorded whether or not the extension is installed. "
                        + "Without it, a prejoin screen cannot be distinguished from a joined "
                        + "call, so recordings start earlier and run somewhat longer."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Section("Applications") {
                appList(
                    title: "Always record",
                    identifiers: runtime.settings.alwaysRecordApplications,
                    remove: { identifier in
                        var settings = runtime.settings
                        settings.alwaysRecordApplications.removeAll { $0 == identifier }
                        runtime.update(settings: settings)
                    }
                )
                appList(
                    title: "Never record",
                    identifiers: runtime.settings.neverRecordApplications,
                    remove: { identifier in
                        var settings = runtime.settings
                        settings.neverRecordApplications.removeAll { $0 == identifier }
                        runtime.update(settings: settings)
                    }
                )
            }
        }
        .formStyle(.grouped)
    }


    private func providerRow(
        _ title: String, keyPath: WritableKeyPath<ProviderPolicies, ProviderPolicy>
    ) -> some View {
        LabeledContent(title) {
            Picker("", selection: Binding(
                get: { runtime.settings.providers[keyPath: keyPath].autoStart },
                set: { newValue in
                    var settings = runtime.settings
                    settings.providers[keyPath: keyPath].autoStart = newValue
                    runtime.update(settings: settings)
                }
            )) {
                Text("Always record").tag(ProviderPolicy.AutoStart.always)
                Text("Ask").tag(ProviderPolicy.AutoStart.ask)
                Text("Never").tag(ProviderPolicy.AutoStart.never)
            }
            .labelsHidden()
            .frame(width: 160)
        }
    }

    @ViewBuilder
    private func appList(title: String, identifiers: [String], remove: @escaping (String) -> Void) -> some View {
        if identifiers.isEmpty {
            LabeledContent(title) { Text("None").foregroundStyle(.secondary) }
        } else {
            ForEach(identifiers, id: \.self) { identifier in
                LabeledContent(title) {
                    HStack {
                        Text(identifier).font(.caption)
                        Button("Remove") { remove(identifier) }.buttonStyle(.link)
                    }
                }
            }
        }
    }
}

struct AudioSettingsTab: View {
    let model: SettingsModel
    private var runtime: PipitRuntime { model.runtime }

    var body: some View {
        Form {
            Section("Input") {
                LabeledContent("Current microphone") { Text(model.inputDescription) }
                Toggle(
                    "Prefer the built-in microphone while Bluetooth headphones are connected",
                    isOn: Binding(
                        get: { runtime.settings.preferBuiltInMicrophone },
                        set: { newValue in
                            var settings = runtime.settings
                            settings.preferBuiltInMicrophone = newValue
                            runtime.update(settings: settings)
                        }
                    )
                )
                Text(
                    "A Bluetooth headset switches its microphone to the hands-free profile at "
                        + "16 kHz. The audio is recorded accurately at that rate, and it "
                        + "transcribes less accurately than the built-in microphone at 48 kHz."
                )
                .font(.caption).foregroundStyle(.secondary)
                Toggle(
                    "Remove speaker audio from the microphone",
                    isOn: Binding(
                        get: { runtime.settings.echoCancellation },
                        set: { newValue in
                            var settings = runtime.settings
                            settings.echoCancellation = newValue
                            runtime.update(settings: settings)
                        }
                    )
                )
                Text(
                    "Uses the system voice-processing unit to subtract what the speakers are "
                        + "playing, so a call taken without headphones does not record the "
                        + "other side onto your track. Applies to the next recording. When the "
                        + "input and output devices cannot be paired, recording continues "
                        + "without it."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Section("Recording health") {
                HealthIndicator(state: runtime.status.displayHealth)
                LabeledContent("Microphone") { Text(runtime.status.health.mic.rawValue) }
                LabeledContent("Meeting audio") { Text(runtime.status.health.remote.rawValue) }
                LabeledContent("Rebuilds this session") {
                    Text("\(runtime.status.health.micRestarts)")
                }
            }
            Section("Segments") {
                LabeledContent("Segment length") {
                    Text("\(Int(runtime.settings.segmentSeconds)) seconds")
                }
                LabeledContent("Pre-roll") {
                    Text("\(Int(runtime.settings.preRollSeconds)) seconds")
                }
                Text(
                    "Audio is written in short segments, so a crash loses less than a tenth of "
                        + "a second. Capture begins before a call is confirmed and the pre-roll "
                        + "is kept in memory, which covers the opening of the meeting."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await model.refresh() }
    }
}

struct OpenAISettingsTab: View {
    let model: SettingsModel
    private var runtime: PipitRuntime { model.runtime }

    var body: some View {
        cloudForm
            // Reads the keychain, which can block on an authorisation prompt.
            .task { await model.refresh() }
    }

    private var cloudForm: some View {
        Form {
            Section("API key") {
                SecureField("sk-…", text: model.text(\.apiKey))
                HStack {
                    Button("Save") { model.saveKey() }.disabled(model.apiKey.isEmpty)
                    Button("Test Connection") { Task { await model.testConnection() } }
                        .disabled(!model.hasStoredKey && model.apiKey.isEmpty)
                    Button("Remove") { model.removeKey() }.disabled(!model.hasStoredKey)
                    switch model.testState {
                    case .idle: EmptyView()
                    case .testing: ProgressView().controlSize(.small)
                    case .success:
                        Label("Key and model access confirmed", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green).font(.caption)
                    case .failure(let message):
                        Label(message, systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red).font(.caption)
                    }
                }
                Text("The key is stored in the macOS keychain. Spend and usage are not readable through a project key, so use the OpenAI dashboard to review them.")
                    .font(.caption).foregroundStyle(.secondary)
                Link("Open the OpenAI dashboard", destination: URL(string: "https://platform.openai.com/usage")!)
                    .font(.caption)
            }
            Section("Models") {
                metadataModelRow()
                Text("Transcription and diarization models are chosen on the Processing tab.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Enrichment") {
                enrichmentToggle("Generate a title", keyPath: \.generateTitle)
                enrichmentToggle("Generate a description", keyPath: \.generateDescription)
                enrichmentToggle("Generate notes", keyPath: \.generateNotes)
                enrichmentToggle("Generate a summary", keyPath: \.generateSummary)
                enrichmentToggle("Suggest speaker names", keyPath: \.suggestSpeakers)
                Text("Recording and transcription work with all of these disabled.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// The sentinel the picker uses for a model identifier typed by hand.
    private static let customModelTag = "custom"

    /// A dropdown of known metadata models, with a text field for any other
    /// identifier. Whether the field shows is derived from the stored value, so
    /// no view-local state is needed.
    private func metadataModelRow() -> some View {
        let current = runtime.settings.models.metadata
        let isPreset = AIModelSettings.metadataChoices.contains(current)
        return LabeledContent("Metadata") {
            VStack(alignment: .trailing, spacing: 2) {
                Picker("", selection: Binding(
                    get: { isPreset ? current : Self.customModelTag },
                    set: { newValue in
                        var settings = runtime.settings
                        settings.models.metadata = newValue == Self.customModelTag ? "" : newValue
                        runtime.update(settings: settings)
                    }
                )) {
                    ForEach(AIModelSettings.metadataChoices, id: \.self) { choice in
                        Text(choice).tag(choice)
                    }
                    Text("Other…").tag(Self.customModelTag)
                }
                .labelsHidden()
                .frame(width: 240)
                if !isPreset {
                    TextField("model identifier", text: Binding(
                        get: { runtime.settings.models.metadata },
                        set: { newValue in
                            var settings = runtime.settings
                            settings.models.metadata = newValue
                            runtime.update(settings: settings)
                        }
                    ))
                    .frame(width: 240)
                }
                Text("Titles, summaries, speaker suggestions").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func enrichmentToggle(
        _ title: String, keyPath: WritableKeyPath<EnrichmentSettings, Bool>
    ) -> some View {
        Toggle(title, isOn: Binding(
            get: { runtime.settings.enrichment[keyPath: keyPath] },
            set: { newValue in
                var settings = runtime.settings
                settings.enrichment[keyPath: keyPath] = newValue
                runtime.update(settings: settings)
            }
        ))
    }

}

struct PermissionsSettingsTab: View {
    let model: SettingsModel
    private var runtime: PipitRuntime { model.runtime }

    var body: some View {
        Form {
            Section("Permissions") {
                ForEach(model.statuses) { status in
                    PermissionRow(
                        status: status,
                        onRequest: { await model.request(status.kind) },
                        onOpenSettings: { runtime.permissions.openSettings(for: status.kind) }
                    )
                }
            }
            Section("Browser sensor") {
                LabeledContent("Native messaging host") {
                    Text(model.hostStatus?.isReadyForFirefox == true ? "Installed" : "Not installed")
                        .foregroundStyle(model.hostStatus?.isReadyForFirefox == true ? .green : .orange)
                }
                if let path = model.hostStatus?.installedHostPath {
                    Text(path).font(.caption).foregroundStyle(.secondary)
                }
                Button("Re-install Host") { model.installHost() }

                LabeledContent("Firefox extension") {
                    Text(runtime.status.sensorConnection.label)
                        .foregroundStyle(runtime.status.sensorConnection.color)
                }
                Text(
                    "Firefox loads the extension as a temporary add-on, which lasts until "
                        + "Firefox quits. Open about:debugging#/runtime/this-firefox, choose "
                        + "Load Temporary Add-on, and select the manifest below."
                )
                .font(.caption).foregroundStyle(.secondary)
                if let manifest = NativeMessagingInstaller.bundledExtensionManifestURL() {
                    Text(manifest.path)
                        .font(.caption)
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Copy Path") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(manifest.path, forType: .string)
                        }
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([manifest])
                        }
                    }
                }
                if let rejected = model.sensorStatus?.rejectedConnections, rejected > 0 {
                    Label(
                        "\(rejected) connection\(rejected == 1 ? "" : "s") refused. Only "
                            + "Pipit's own relay, launched by a browser, may report meetings.",
                        systemImage: "shield.lefthalf.filled"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }
            Section {
                Button("Re-check Everything") { Task { await model.refresh() } }
            }
        }
        .formStyle(.grouped)
        .task { await model.refresh() }
    }
}

struct StorageSettingsTab: View {
    let model: SettingsModel
    private var runtime: PipitRuntime { model.runtime }

    var body: some View {
        Form {
            Section("Meetings folder") {
                Text(runtime.settings.storageRootPath).font(.callout)
                HStack {
                    Button("Choose Folder…") { model.chooseStorage() }
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.open(runtime.settings.storageRoot)
                    }
                }
            }
            Section("What is stored") {
                Text(
                    """
                    Each meeting is a folder of ordinary files: the transcript as Markdown, \
                    the recording as M4A, your notes and summary, and a raw folder holding \
                    the per-track source audio, the manifest, the API responses and the \
                    speaker map. Every file can be read without Pipit, and uninstalling \
                    the application leaves the recordings in place.
                    """
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Section("Meetings") {
                LabeledContent("Recorded") { Text("\(runtime.recentMeetings.count)") }
            }
        }
        .formStyle(.grouped)
    }
}


extension BrowserSensorTracker.Connection {
    /// One wording for the sensor, shown wherever it is reported.
    var label: String {
        switch self {
        case .fresh: "Connected"
        case .stale: "Connected but silent, using native detection"
        case .disconnected: "Disconnected, using native detection"
        case .absent: "Not installed, using native detection"
        }
    }

    var color: Color {
        switch self {
        case .fresh: .green
        case .stale, .disconnected: .orange
        case .absent: .secondary
        }
    }
}
