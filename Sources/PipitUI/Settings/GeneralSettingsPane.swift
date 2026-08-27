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
            Section("You") {
                // Which person in the directory, rather than a name typed here.
                // The identity owns the name: Settings held one and the store
                // held a flag, and the launch sync pushed one onto the other.
                if !model.people.isEmpty {
                    Picker(
                        "You are",
                        selection: Binding(
                            get: { model.localUserIdentityID },
                            set: { chosen in
                                guard let chosen else { return }
                                Task { await model.chooseLocalUser(chosen) }
                            }
                        )
                    ) {
                        if model.localUserIdentityID == nil {
                            Text("Nobody yet").tag(IdentityID?.none)
                        }
                        ForEach(model.people) { entry in
                            Text(entry.identity.resolvedName).tag(IdentityID?.some(entry.id))
                        }
                    }
                }
                TextField("Name", text: model.localUserNameField)
                    .onSubmit { Task { await model.commitLocalUserName() } }
                Text(
                    "Your own speech is labelled with this person, and the microphone track "
                        + "of every call teaches their voice profile. Naming yourself on an "
                        + "imported recording puts it on the same profile."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Section("People") {
                Button("Manage people…") { model.openPeople() }
            }
        }
        .formStyle(.grouped)
        .task { await model.refreshPeople() }
        // A name typed and not submitted is still a name the person meant.
        .onDisappear { Task { await model.commitLocalUserName() } }
    }
}
