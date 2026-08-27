import AppKit
import PipitCore
import PipitServices
import SwiftUI

/// Where the archive is and what it costs.
struct StorageSettingsPane: View {
    let model: SettingsModel
    private var runtime: PipitRuntime { model.runtime }

    var body: some View {
        Form {
            Section("Meetings folder") {
                Text(runtime.settings.storageRootPath)
                    .font(.callout).textSelection(.enabled)
                HStack {
                    Button("Choose Folder…") { model.chooseStorage() }
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.open(runtime.settings.storageRoot)
                    }
                }
            }
            Section("Meetings on disk") {
                if let usage = model.archiveUsage {
                    Text(Self.summary(usage))
                    if let free = usage.freeBytes {
                        Text("\(Self.size(free)) free on this Mac")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Calculating…").foregroundStyle(.secondary)
                    }
                }
                Button("Recalculate") { Task { await model.refreshArchiveUsage(force: true) } }
                    .disabled(model.isMeasuringArchive)
            }
            if let statistics = model.voiceStatistics {
                Section("Voice profiles") {
                    LabeledContent("People") {
                        Text("\(statistics.namedPeople) named, \(statistics.recurringVoices) unnamed")
                    }
                    LabeledContent("Embeddings") { Text("\(statistics.embeddings)") }
                    LabeledContent("Database") {
                        Text("\(max(1, statistics.storageBytes / 1_024)) KB")
                    }
                    Text(
                        "Stored on this Mac only. They are never uploaded and never written "
                            + "into a meeting folder or an export."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Speech models") {
                LabeledContent("Installed") { Text(Self.size(model.installedModelBytes)) }
                if let path = runtime.models?.locations.root.path {
                    Text(path)
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Text("Chosen and downloaded on the Processing page.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            await model.refreshPeople()
            await model.refreshArchiveUsage()
        }
    }

    static func summary(_ usage: ArchiveUsage) -> String {
        let meetings = usage.meetingCount == 1 ? "1 meeting" : "\(usage.meetingCount) meetings"
        return "\(size(usage.bytes)) across \(meetings)"
    }

    static func size(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }
}
