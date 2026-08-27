import PipitCore
import PipitServices
import SwiftUI

struct GeneralSettingsPane: View {
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
            Section("People") {
                Button("Manage people…") { model.openPeople() }
            }
        }
        .formStyle(.grouped)
        .onDisappear { model.saveLocalUserName() }
    }
}
