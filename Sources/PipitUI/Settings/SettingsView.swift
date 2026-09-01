import PipitServices
import SwiftUI

/// Which page of Settings is showing.
///
/// A sidebar rather than a row of tab icons, matching the People and Meetings
/// windows, and readable at seven entries where a tab row is not.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case recording
    case processing
    case cloud
    case browsers
    case folders
    case storage
    case permissions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .recording: "Recording"
        case .processing: "Processing"
        case .cloud: "Cloud"
        case .browsers: "Browsers"
        case .folders: "Folders"
        case .storage: "Storage"
        case .permissions: "Permissions"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .recording: "record.circle"
        case .processing: "waveform.badge.magnifyingglass"
        case .cloud: "sparkles"
        case .browsers: "globe"
        case .folders: "folder.badge.gearshape"
        case .storage: "internaldrive"
        case .permissions: "lock.shield"
        }
    }
}

public struct SettingsView: View {
    let model: SettingsModel

    public init(model: SettingsModel) {
        self.model = model
    }

    private var pane: SettingsPane { model.pane }

    public var body: some View {
        NavigationSplitView {
            List(
                SettingsPane.allCases,
                selection: Binding(get: { model.pane }, set: { model.pane = $0 })
            ) { entry in
                Label(entry.title, systemImage: entry.symbol).tag(entry)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 180, max: 220)
        } detail: {
            detail
                .navigationTitle(pane.title)
                .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 740, minHeight: 520)
    }

    @ViewBuilder
    private var detail: some View {
        switch pane {
        case .general: GeneralSettingsPane(model: model)
        case .recording: RecordingSettingsPane(model: model)
        case .processing: ProcessingSettingsPane(model: model)
        case .cloud: CloudSettingsPane(model: model)
        case .browsers: BrowsersSettingsPane(model: model)
        case .folders: FoldersSettingsPane(model: model)
        case .storage: StorageSettingsPane(model: model)
        case .permissions: PermissionsSettingsPane(model: model)
        }
    }
}
