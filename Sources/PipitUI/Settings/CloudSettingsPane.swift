import PipitCore
import PipitServices
import SwiftUI

struct CloudSettingsPane: View {
    let model: SettingsModel
    private var runtime: PipitRuntime { model.runtime }

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
                Text(
                    "The key is stored in the macOS keychain. Spend and usage are not readable "
                        + "through a project key, so use the OpenAI dashboard to review them."
                )
                .font(.caption).foregroundStyle(.secondary)
                Link(
                    "Open the OpenAI dashboard",
                    destination: URL(string: "https://platform.openai.com/usage")!
                )
                .font(.caption)
            }
            Section("Models") {
                metadataModelRow()
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
        // Reads the keychain, which can block on an authorisation prompt.
        .task { await model.refresh() }
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
                Text("Titles, summaries, speaker suggestions")
                    .font(.caption2).foregroundStyle(.secondary)
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
