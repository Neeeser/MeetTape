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
            // Nothing here says who you are. Naming yourself is a rename and
            // saying an existing row is you is a merge, and People owns both.
            // A second door onto them here renamed the person just picked to
            // the name left in the field. The microphone track never needed
            // the answer. It is labelled deterministically whatever the row
            // ends up called.
            Section("People") {
                Button("Manage people…") { model.openPeople() }
            }
        }
        .formStyle(.grouped)
    }
}
