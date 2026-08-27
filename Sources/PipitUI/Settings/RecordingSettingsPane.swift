import PipitCore
import PipitServices
import SwiftUI

/// What starts a recording and how the audio is captured.
///
/// Providers and audio were two pages. Audio held two settings and three
/// read-only readouts, and once the readouts went there was not a page left.
struct RecordingSettingsPane: View {
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
            Section("Microphone") {
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
    private func appList(
        title: String, identifiers: [String], remove: @escaping (String) -> Void
    ) -> some View {
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
