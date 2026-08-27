import PipitServices
import SwiftUI

struct PermissionsSettingsPane: View {
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
            Section {
                Button("Re-check Everything") { Task { await model.refresh() } }
            }
        }
        .formStyle(.grouped)
        .task { await model.refresh() }
    }
}
