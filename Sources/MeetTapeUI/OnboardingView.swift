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

    private var openAISection: some View {
        SectionCard(
            title: "OpenAI",
            subtitle: "Transcription and speaker identification use your own API key."
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
                Text("The key is stored in the macOS keychain and is not written to any meeting file.")
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
                    Label("Native messaging host installed", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.caption)
                } else {
                    Label("Native messaging host not installed", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange).font(.caption)
                }
                Text(
                    "Without the extension, Meet and Zoom are still recorded using window "
                        + "titles and microphone state. A prejoin screen cannot be distinguished "
                        + "from a joined call, so recordings start earlier than necessary."
                )
                .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Install Host") { model.installHost() }
                    Button("Show Extension Folder") { revealExtension() }
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
            if canRequestInApp {
                Button("Enable") { Task { await onRequest() } }
            } else {
                Button("Open System Settings") { onOpenSettings() }
            }
        case .denied, .grantedButNotEffective:
            Button("Open System Settings") { onOpenSettings() }
        }
    }

    /// Microphone, Calendar and Notifications present a dialog. Accessibility and
    /// Screen Recording can only be granted in System Settings.
    private var canRequestInApp: Bool {
        switch status.kind {
        case .microphone, .calendar, .notifications: true
        case .accessibility, .screenRecording: false
        }
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
