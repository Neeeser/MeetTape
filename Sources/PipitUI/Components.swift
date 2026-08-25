import PipitCore
import SwiftUI

/// Colour and label for a capture health state.
///
/// A recording is never shown as healthy while a required source is failing, and
/// a normal recovery is never shown as an alarm.
public struct HealthIndicator: View {
    public let state: CaptureHealthState

    public init(state: CaptureHealthState) {
        self.state = state
    }

    public var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    var color: Color {
        switch state {
        case .healthy: .green
        case .idleButBound: .green
        case .recovering: .orange
        case .degraded: .orange
        case .failed: .red
        case .idle: .secondary
        }
    }

    var label: String {
        switch state {
        case .healthy: "Capturing"
        case .idleButBound: "Capturing, source quiet"
        case .recovering: "Reconnecting"
        case .degraded: "Source unavailable"
        case .failed: "Not capturing"
        case .idle: "Idle"
        }
    }
}

public enum Format {
    public static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let secs = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%02d:%02d", minutes, secs)
    }

    public static func shortDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total >= 3_600 { return "\(total / 3_600)h \((total % 3_600) / 60)m" }
        if total >= 60 { return "\(total / 60)m" }
        return "\(total)s"
    }

    public static func day(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return "Today \(date.formatted(date: .omitted, time: .shortened))"
        }
        if Calendar.current.isDateInYesterday(date) {
            return "Yesterday \(date.formatted(date: .omitted, time: .shortened))"
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

/// The status of one processing stage, for the review panel.
public struct StageBadge: View {
    public let state: ProcessingState

    public init(state: ProcessingState) {
        self.state = state
    }

    public var body: some View {
        Text(state.displayName)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(background, in: Capsule())
            .foregroundStyle(foreground)
    }

    private var background: Color {
        switch state {
        case .complete: .green.opacity(0.15)
        case .failed: .red.opacity(0.15)
        default: .secondary.opacity(0.15)
        }
    }

    private var foreground: Color {
        switch state {
        case .complete: .green
        case .failed: .red
        default: .secondary
        }
    }
}

struct SectionCard<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// One permission's state and the control that changes it.
///
/// Shared by the Permissions tab in Settings and by the setup wizard's own
/// summary, so both report a permission the same way.
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
            if !status.kind.isGrantedByPrompt {
                // Requesting first is what adds Pipit to the list in System
                // Settings. Without it the pane opens on a list the app is not in
                // and there is nothing to switch on.
                Button("Enable in System Settings") { Task { await onRequest() } }
            } else {
                Button("Open System Settings") { onOpenSettings() }
            }
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
