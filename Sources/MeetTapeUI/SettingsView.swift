import AppKit
import MeetTapeAudio
import MeetTapeCore
import MeetTapeDetection
import MeetTapeIntegrations
import MeetTapeServices
import SwiftUI

public struct SettingsView: View {
    let model: SettingsModel
    private var runtime: MeetTapeRuntime { model.runtime }

    public init(model: SettingsModel) {
        self.model = model
    }

    public var body: some View {
        TabView {
            GeneralSettingsTab(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
            ProviderSettingsTab(model: model)
                .tabItem { Label("Providers", systemImage: "person.2.wave.2") }
            AudioSettingsTab(model: model)
                .tabItem { Label("Audio", systemImage: "waveform") }
            OpenAISettingsTab(model: model)
                .tabItem { Label("OpenAI", systemImage: "sparkles") }
            PermissionsSettingsTab(model: model)
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
            StorageSettingsTab(model: model)
                .tabItem { Label("Storage", systemImage: "folder") }
        }
        .padding(16)
        .frame(minWidth: 660, minHeight: 480)
    }
}

struct GeneralSettingsTab: View {
    let model: SettingsModel
    private var runtime: MeetTapeRuntime { model.runtime }

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: model.binding(\.launchAtLogin))
                Toggle("Show notifications", isOn: model.binding(\.showNotifications))
                Toggle(
                    "Pause automatic detection",
                    isOn: Binding(
                        get: { runtime.settings.providers.detectionPaused },
                        set: { runtime.setDetectionPaused($0) }
                    )
                )
                if runtime.settings.providers.detectionPaused {
                    Label(
                        "Automatic detection is paused. Meetings will not be recorded until you resume it.",
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
                    "Used for your own speech on a remote call, which comes from the microphone "
                        + "track and needs no identification."
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
    private var runtime: MeetTapeRuntime { model.runtime }

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
                    Text(sensorLabel).foregroundStyle(sensorColor)
                }
                Text(
                    "MeetTape records Meet and Zoom with or without the extension. Without it, "
                        + "a prejoin screen cannot be told apart from a joined call, so recordings "
                        + "start earlier and run a little longer."
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

    private var sensorLabel: String {
        switch runtime.status.sensorConnection {
        case .fresh: "Connected"
        case .stale: "Connected but silent — using native detection"
        case .disconnected: "Disconnected — using native detection"
        case .absent: "Not installed — using native detection"
        }
    }

    private var sensorColor: Color {
        switch runtime.status.sensorConnection {
        case .fresh: .green
        case .stale, .disconnected: .orange
        case .absent: .secondary
        }
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
    private var runtime: MeetTapeRuntime { model.runtime }

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
                        + "16 kHz. That is still valid audio and is recorded accurately, but it "
                        + "transcribes less well than the built-in microphone at 48 kHz."
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
                    "Audio is written in short segments so a crash costs under a tenth of a "
                        + "second, and capture starts before a call is confirmed so the first "
                        + "sentence is never missed."
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
    private var runtime: MeetTapeRuntime { model.runtime }

    var body: some View {
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
                Text("Stored in the macOS keychain. Spend and usage are not readable from a project key; open your OpenAI dashboard for those.")
                    .font(.caption).foregroundStyle(.secondary)
                Link("Open the OpenAI dashboard", destination: URL(string: "https://platform.openai.com/usage")!)
                    .font(.caption)
            }
            Section("Models") {
                modelField("Transcription", keyPath: \.transcription, hint: "Needs word or segment timestamps")
                modelField("Diarization", keyPath: \.diarization, hint: "Speaker-attributed transcription")
                modelField("Metadata", keyPath: \.metadata, hint: "Titles, summaries, speaker suggestions")
            }
            Section("Enrichment") {
                enrichmentToggle("Generate a title", keyPath: \.generateTitle)
                enrichmentToggle("Generate a description", keyPath: \.generateDescription)
                enrichmentToggle("Generate notes", keyPath: \.generateNotes)
                enrichmentToggle("Generate a summary", keyPath: \.generateSummary)
                enrichmentToggle("Suggest speaker names", keyPath: \.suggestSpeakers)
                Text("The recording and transcript stay useful with all of these off.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func modelField(
        _ title: String, keyPath: WritableKeyPath<AIModelSettings, String>, hint: String
    ) -> some View {
        LabeledContent(title) {
            VStack(alignment: .trailing, spacing: 2) {
                TextField("", text: Binding(
                    get: { runtime.settings.models[keyPath: keyPath] },
                    set: { newValue in
                        var settings = runtime.settings
                        settings.models[keyPath: keyPath] = newValue
                        runtime.update(settings: settings)
                    }
                ))
                .frame(width: 240)
                Text(hint).font(.caption2).foregroundStyle(.secondary)
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
    private var runtime: MeetTapeRuntime { model.runtime }

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
                if let rejected = model.sensorStatus?.rejectedConnections, rejected > 0 {
                    Label(
                        "\(rejected) connection\(rejected == 1 ? "" : "s") refused: only MeetTape's "
                            + "own relay, launched by a browser, may report meetings.",
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
    private var runtime: MeetTapeRuntime { model.runtime }

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
                    Each meeting is a folder of ordinary files: the recorded audio in CAF \
                    segments, an append-only manifest, the raw API responses, the transcript as \
                    JSON and Markdown, your notes, and a speaker map. Nothing needs MeetTape to \
                    be readable, and deleting the app leaves every recording intact.
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
