import PipitCore
import PipitServices
import SwiftUI

/// What is offered a folder, what files itself, and where any of it lands.
///
/// The reach picker is the tuning control, deliberately three named choices
/// rather than a confidence number: the number is what the choice sets, and a
/// number is not a thing anyone can judge from a settings pane.
struct FoldersSettingsPane: View {
    let model: SettingsModel
    @State private var folders: [MeetingFolder] = []
    private var runtime: PipitRuntime { model.runtime }

    var body: some View {
        Form {
            Section("Suggestions") {
                Toggle("Suggest a folder when a meeting finishes", isOn: binding(\.suggestFolders))
                Picker("How far a suggestion may reach", selection: Binding(
                    get: { runtime.settings.enrichment.folderReach },
                    set: { newValue in
                        var settings = runtime.settings
                        settings.enrichment.folderReach = newValue
                        runtime.update(settings: settings)
                    }
                )) {
                    ForEach(SuggestionReach.allCases) { reach in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(reach.label)
                            Text(reach.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(reach)
                    }
                }
                .pickerStyle(.radioGroup)
                .disabled(!runtime.settings.enrichment.suggestFolders)
                Toggle(
                    "Notice recurring meetings and offer a rule",
                    isOn: binding(\.noticesRecurringMeetings)
                )
                Text(
                    "A recurring meeting is recognised from metadata alone: a calendar series, "
                        + "or the same title in the same slot. Only a topic match reads the "
                        + "transcript, and it rides the request that already writes the summary."
                )
                .font(.caption).foregroundStyle(.secondary)
            }

            Section("Filing") {
                Toggle(
                    "Let a folder file its own matches without asking",
                    isOn: binding(\.filesMatchingMeetings)
                )
                Text(
                    "Off here stops every folder at once, without editing any of them. A "
                        + "suggestion a model made is never filed on its own, whatever this says."
                )
                .font(.caption).foregroundStyle(.secondary)
            }

            Section("Folders") {
                if folders.isEmpty {
                    Text("No folders yet. Right-click a meeting in the Meetings window to file it.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(folders) { folder in
                        folderRow(folder)
                    }
                }
                HStack {
                    Text("Folders are made and renamed in the Meetings window.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reveal in Finder") { runtime.revealArchive() }
                }
            }

            Section("On disk") {
                Label(
                    "A filed meeting lives in Meetings/Folders/<name>. Everything else stays "
                        + "under Meetings/2026/08. Filing one moves its directory and leaves its "
                        + "identifier alone, so the speakers database and search follow it.",
                    systemImage: "folder"
                )
                .font(.caption)
            }
        }
        .formStyle(.grouped)
        .task { folders = runtime.folders() }
    }

    private func folderRow(_ folder: MeetingFolder) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "folder.fill")
                .foregroundStyle(FolderTint.color(folder.tintIndex))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name).font(.body.weight(.medium))
                Text(folder.rule.isEmpty ? "No rule, filed by hand" : FolderRuleSummary.text(folder.rule))
                    .font(.caption)
                    .foregroundStyle(folder.rule.isEmpty ? .tertiary : .secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(
                get: { folder.filesAutomatically },
                set: { newValue in
                    var updated = folder
                    updated.filesAutomatically = newValue
                    try? runtime.updateFolder(updated)
                    folders = runtime.folders()
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .disabled(folder.rule.isEmpty || !runtime.settings.enrichment.filesMatchingMeetings)
            .help(
                folder.rule.isEmpty
                    ? "This folder has no rule, so there is nothing for it to file."
                    : "Files matching meetings here without asking."
            )
        }
    }

    private func binding(_ keyPath: WritableKeyPath<EnrichmentSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { runtime.settings.enrichment[keyPath: keyPath] },
            set: { newValue in
                var settings = runtime.settings
                settings.enrichment[keyPath: keyPath] = newValue
                runtime.update(settings: settings)
            }
        )
    }
}
