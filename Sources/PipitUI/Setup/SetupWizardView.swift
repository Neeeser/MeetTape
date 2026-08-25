import AppKit
import PipitCore
import PipitServices
import SwiftUI

/// First-run setup: one question per screen, with the required steps gated.
///
/// The shape follows Jump Desktop Connect's permissions assistant, which walks a
/// user through one permission at a time, shows exactly which row in System
/// Settings to switch on, and keeps Continue disabled until the permission is
/// actually in effect. What is added here is a rail, so a nine-screen sequence
/// says how much is left, and so a long model download can keep reporting itself
/// while the user is off granting permissions.
public struct SetupWizardView: View {
    let model: SetupModel
    let onFinish: () -> Void

    public init(model: SetupModel, onFinish: @escaping () -> Void) {
        self.model = model
        self.onFinish = onFinish
    }

    public var body: some View {
        HStack(spacing: 0) {
            rail
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    SetupStepContent(model: model)
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                footer.padding(.horizontal, 24).padding(.vertical, 14)
            }
        }
        .frame(minWidth: 720, minHeight: 540)
        .task { await model.begin() }
        .onDisappear { model.end() }
    }

    // MARK: - rail

    private var rail: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Setup")
                .font(.caption).foregroundStyle(.tertiary)
                .padding(.horizontal, 10).padding(.bottom, 6)
            ForEach(model.steps) { step in
                railRow(step)
            }
            Spacer()
        }
        .padding(.vertical, 16)
        .frame(width: 186, alignment: .leading)
        .background(.quaternary.opacity(0.25))
    }

    private func railRow(_ step: SetupStep) -> some View {
        let isCurrent = step.id == model.current
        return Button {
            model.jump(to: step.id)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: symbol(for: step, isCurrent: isCurrent))
                    .foregroundStyle(colour(for: step, isCurrent: isCurrent))
                    .frame(width: 15)
                Text(step.id.railTitle)
                    .font(.callout)
                    .foregroundStyle(isCurrent ? .primary : .secondary)
                Spacer(minLength: 0)
                if step.id == .models, let progress = downloadPercentage {
                    Text(progress).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                isCurrent ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }

    private func symbol(for step: SetupStep, isCurrent: Bool) -> String {
        if step.id == .models, model.runtime.localModelState.isBusy {
            return "arrow.down.circle"
        }
        if step.isSatisfied, step.isRequired { return "checkmark.circle.fill" }
        if isCurrent { return "circle.inset.filled" }
        return step.isRequired ? "circle" : "circle.dotted"
    }

    private func colour(for step: SetupStep, isCurrent: Bool) -> Color {
        if step.id == .models, model.runtime.localModelState.isBusy { return .accentColor }
        if step.isSatisfied, step.isRequired { return .green }
        return isCurrent ? .accentColor : .secondary
    }

    private var downloadPercentage: String? {
        guard case .downloading(let fraction, _, _) = model.runtime.localModelState else {
            return nil
        }
        return "\(Int(fraction * 100))%"
    }

    // MARK: - footer

    private var footer: some View {
        HStack {
            if SetupFlow.step(before: model.current) != nil {
                Button("Back") { model.retreat() }
            }
            Spacer()
            advanceButton
        }
    }

    @ViewBuilder
    private var advanceButton: some View {
        switch model.current {
        case .finish:
            Button("Done") {
                model.finish()
                onFinish()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canFinish)
            .keyboardShortcut(.defaultAction)
        case .welcome, .backend, .models, .microphone, .screenRecording, .accessibility:
            Button("Continue") { model.advance() }
                .buttonStyle(.borderedProminent)
                .disabled(!model.isCurrentStepSatisfied)
                .keyboardShortcut(.defaultAction)
        case .optionalPermissions, .firefox:
            // Available, deliberately not the accent colour. Skipping is a real
            // choice and connecting is the better one.
            Button(hasDoneOptionalWork ? "Continue" : "Skip for now") { model.advance() }
                .buttonStyle(hasDoneOptionalWork ? AnyButtonStyle(.borderedProminent) : AnyButtonStyle(.link))
                .keyboardShortcut(.defaultAction)
        }
    }

    /// Whether the optional step in front of the user has anything to show for
    /// itself, which decides whether the footer says Continue or Skip.
    private var hasDoneOptionalWork: Bool {
        switch model.current {
        case .optionalPermissions:
            return model.status(for: .calendar).isUsable || model.status(for: .notifications).isUsable
        case .firefox:
            return model.hostStatus?.isReadyForFirefox == true
        default:
            return false
        }
    }
}

/// Erases a button style so one `Button` can carry either of two.
struct AnyButtonStyle: PrimitiveButtonStyle {
    private let make: (Configuration) -> AnyView

    init<S: PrimitiveButtonStyle>(_ style: S) {
        make = { configuration in AnyView(Button(configuration).buttonStyle(style)) }
    }

    func makeBody(configuration: Configuration) -> some View {
        make(configuration)
    }
}
