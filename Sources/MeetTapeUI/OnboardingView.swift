import AppKit
import MeetTapeCore
import MeetTapeDetection
import MeetTapeIntegrations
import MeetTapeServices
import SwiftUI

/// First-run setup.
///
/// Every step requests what macOS allows in-app and links straight to the exact
/// System Settings pane for the rest, then verifies that access actually works
/// rather than trusting the toggle.
public struct OnboardingView: View {
    let model: OnboardingModel
    let onFinish: () -> Void

    public init(model: OnboardingModel, onFinish: @escaping () -> Void) {
        self.model = model
        self.onFinish = onFinish
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                permissionsSection
                localModelsSection
                openAISection
                extensionSection
                storageSection
                footer
            }
            .padding(24)
        }
        .frame(minWidth: 560)
        .task { await model.refresh() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("MeetTape records your meetings automatically")
                .font(.title2.weight(.semibold))
            Text(
                "MeetTape detects Slack Huddles and Google Meet and Zoom calls in your "
                    + "browser, records your microphone and the meeting audio as separate "
                    + "tracks, and writes the results to ordinary files on disk."
            )
            .foregroundStyle(.secondary)
        }
    }

    private var permissionsSection: some View {
        SectionCard(title: "Permissions", subtitle: "The microphone is required. The others improve detection accuracy.") {
            VStack(spacing: 10) {
                ForEach(model.statuses) { status in
                    PermissionRow(
                        status: status,
                        onRequest: { await model.request(status.kind) },
                        onOpenSettings: { model.runtime.permissions.openSettings(for: status.kind) }
                    )
                }
            }
        }
    }

    private var localModelsSection: some View {
        SectionCard(
            title: "Speech models",
            subtitle: "Downloaded once. After that, transcription and speaker recognition run on this Mac."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                switch model.runtime.localModelState {
                case .installed:
                    Label("Installed", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.callout)
                case .outdated:
                    Label("Installed, pinned by an older build", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary).font(.callout)
                case .downloading(let fraction, let detail):
                    ProgressView(value: fraction)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.caption)
                    Button("Try Again") { Task { await model.runtime.installLocalModels() } }
                case .notInstalled:
                    Button("Download about 650 MB") {
                        Task { await model.runtime.installLocalModels() }
                    }
                }
                Text(
                    "You can start recording straight away. Meetings that finish while the "
                        + "download is running are processed when it completes."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var openAISection: some View {
        SectionCard(
            title: "OpenAI",
            subtitle: "Optional. Titles, summaries and notes are written by a cloud model; everything else runs here."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                SecureField(
                    "sk-…",
                    text: Binding(get: { model.apiKey }, set: { model.apiKey = $0 })
                )
                .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Save and Test Connection") { Task { await model.saveAndTestKey() } }
                        .disabled(model.apiKey.isEmpty || model.apiKeyState == .checking)
                    switch model.apiKeyState {
                    case .unknown: EmptyView()
                    case .checking: ProgressView().controlSize(.small)
                    case .valid:
                        Label("Key works", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green).font(.caption)
                    case .invalid(let message):
                        Label(message, systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red).font(.caption)
                    }
                }
                Text(
                    "The key is stored in the macOS keychain and is not written to any meeting "
                        + "file. Recording, transcription, speakers and voice recognition all "
                        + "work without one."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var extensionSection: some View {
        SectionCard(
            title: "Firefox extension",
            subtitle: "Optional. It reports when you join and leave a Meet or Zoom call."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                if model.hostStatus?.isReadyForFirefox == true {
                    Label(
                        "Step 1 done: the native messaging host is installed",
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(.green).font(.caption)
                } else {
                    Label(
                        "Step 1: the native messaging host is not installed",
                        systemImage: "exclamationmark.circle"
                    )
                    .foregroundStyle(.orange).font(.caption)
                }
                Label(
                    "Step 2: load the extension in Firefox yourself. Firefox only "
                        + "installs add-ons through its own interface.",
                    systemImage: "2.circle"
                )
                .font(.caption).foregroundStyle(.secondary)
                Text(
                    "Open about:debugging#/runtime/this-firefox, choose Load Temporary "
                        + "Add-on, and select manifest.json in the folder below. Firefox "
                        + "drops a temporary add-on when it quits, so this repeats each "
                        + "launch until the extension is signed and published."
                )
                .font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled)
                Text(
                    "Without the extension, Meet and Zoom are still recorded using window "
                        + "titles and microphone state. A prejoin screen cannot be distinguished "
                        + "from a joined call, so recordings start earlier than necessary."
                )
                .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Install Host") { model.installHost() }
                    Button("Show Extension Folder") { revealExtension() }
                    Button("Copy about:debugging") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            "about:debugging#/runtime/this-firefox", forType: .string
                        )
                    }
                }
            }
        }
    }

    private var storageSection: some View {
        SectionCard(title: "Where meetings are saved", subtitle: model.storagePath) {
            HStack {
                Button("Choose Folder…") { model.chooseStorage() }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.open(model.runtime.settings.storageRoot)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Re-check") { Task { await model.refresh() } }
                .disabled(model.isChecking)
            Spacer()
            Button("Done") {
                model.finish()
                onFinish()
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private func revealExtension() {
        let candidates = [
            Bundle.main.url(forResource: "extension", withExtension: nil),
            Bundle.main.resourceURL?.appendingPathComponent("extension"),
        ].compactMap { $0 }
        if let existing = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            NSWorkspace.shared.activateFileViewerSelecting([existing])
        } else {
            NSWorkspace.shared.open(SensorTransport.defaultApplicationSupport)
        }
    }
}

struct PermissionRow: View {
    let status: PermissionStatus
    let onRequest: () async -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(status.kind.title).font(.body.weight(.medium))
                    if status.kind.isRequired {
                        Text("Required").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Text(status.kind.rationale).font(.caption).foregroundStyle(.secondary)
                if let advice = status.advice {
                    Text(advice).font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            actions
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(status.kind.title), \(status.state.rawValue)")
    }

    @ViewBuilder
    private var actions: some View {
        switch status.state {
        case .granted:
            EmptyView()
        case .notDetermined:
            Button("Enable") { Task { await onRequest() } }
        case .denied, .grantedButNotEffective:
            if grantedInSystemSettings {
                // Requesting first is what adds MeetTape to the list in System
                // Settings. Without it the pane opens on a list the app is not in
                // and there is nothing to switch on.
                Button("Enable in System Settings") { Task { await onRequest() } }
            } else {
                Button("Open System Settings") { onOpenSettings() }
            }
        }
    }

    /// Permissions macOS never grants from inside the app.
    private var grantedInSystemSettings: Bool {
        status.kind == .accessibility || status.kind == .screenRecording
    }

    private var symbol: String {
        switch status.state {
        case .granted: "checkmark.circle.fill"
        case .denied: "xmark.circle.fill"
        case .notDetermined: "circle"
        case .grantedButNotEffective: "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch status.state {
        case .granted: .green
        case .denied: .red
        case .notDetermined: .secondary
        case .grantedButNotEffective: .orange
        }
    }
}
