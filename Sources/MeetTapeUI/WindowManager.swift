import AppKit
import MeetTapeCore
import MeetTapeServices
import SwiftUI

/// Owns the app's windows. MeetTape has no main window: everything is opened from
/// the menu bar and closes without affecting recording or processing.
@MainActor
public final class WindowManager {
    private let runtime: MeetTapeRuntime
    private var settingsWindow: NSWindow?
    private var settingsModel: SettingsModel?
    private var onboardingWindow: NSWindow?
    private var onboardingModel: OnboardingModel?
    private var reviewWindows: [String: NSWindow] = [:]
    private var reviewModels: [String: MeetingReviewModel] = [:]
    private var provisionalWindow: NSWindow?
    private var provisionalPromptID: String?

    public init(runtime: MeetTapeRuntime) {
        self.runtime = runtime
    }

    public func showSettings() {
        if let window = settingsWindow {
            present(window)
            return
        }
        let model = SettingsModel(runtime: runtime)
        settingsModel = model
        let window = makeWindow(
            title: "MeetTape Settings",
            size: NSSize(width: 720, height: 560),
            content: SettingsView(model: model)
        )
        window.setFrameAutosaveName("MeetTapeSettings")
        settingsWindow = window
        present(window)
    }

    public func showOnboarding() {
        if let window = onboardingWindow {
            present(window)
            return
        }
        let model = OnboardingModel(runtime: runtime)
        onboardingModel = model
        let window = makeWindow(
            title: "Welcome to MeetTape",
            size: NSSize(width: 620, height: 560),
            content: OnboardingView(model: model, onFinish: { [weak self] in
                self?.closeOnboarding()
            })
        )
        onboardingWindow = window
        present(window)
    }

    public func closeOnboarding() {
        onboardingWindow?.close()
        onboardingWindow = nil
    }

    /// The post-meeting panel. It never steals focus and never blocks processing.
    public func showReview(meetingID: String) {
        if let window = reviewWindows[meetingID] {
            present(window, activating: false)
            return
        }
        let model = MeetingReviewModel(runtime: runtime, meetingID: meetingID)
        reviewModels[meetingID] = model
        let window = makeWindow(
            title: "Meeting",
            size: NSSize(width: 780, height: 620),
            content: MeetingReviewView(model: model)
        )
        window.setFrameAutosaveName("MeetTapeReview")
        reviewWindows[meetingID] = window
        window.isReleasedWhenClosed = false
        present(window, activating: false)
    }

    /// Asks whether to keep a recording of an application MeetTape does not
    /// recognise.
    ///
    /// The notification carries the same question, and macOS refuses to deliver
    /// notifications at all under an ad-hoc signature, so the recording would
    /// otherwise run with nothing on screen to say it had started.
    public func showProvisionalPrompt(_ prompt: ProvisionalPrompt) {
        if provisionalPromptID == prompt.id, let window = provisionalWindow {
            present(window, activating: false)
            return
        }
        closeProvisionalPrompt()
        let window = makeWindow(
            title: "Is this a meeting?",
            size: NSSize(width: 420, height: 200),
            content: ProvisionalPromptView(
                prompt: prompt,
                onKeep: { [weak self] in
                    self?.runtime.resolveProvisional(keep: true)
                    self?.closeProvisionalPrompt()
                },
                onDiscard: { [weak self] in
                    self?.runtime.resolveProvisional(keep: false)
                    self?.closeProvisionalPrompt()
                },
                onNever: { [weak self] in
                    self?.runtime.neverRecord(applicationBundleID: prompt.applicationBundleID)
                    self?.runtime.resolveProvisional(keep: false)
                    self?.closeProvisionalPrompt()
                }
            )
        )
        window.level = .floating
        provisionalWindow = window
        provisionalPromptID = prompt.id
        present(window, activating: false)
    }

    public func closeProvisionalPrompt() {
        provisionalWindow?.close()
        provisionalWindow = nil
        provisionalPromptID = nil
    }

    private func makeWindow(title: String, size: NSSize, content: some View) -> NSWindow {
        let controller = NSHostingController(rootView: AnyView(content))
        let window = NSWindow(contentViewController: controller)
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    private func present(_ window: NSWindow, activating: Bool = true) {
        if activating {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        } else {
            // Saving a meeting should not pull the user out of what they are doing.
            window.orderFrontRegardless()
        }
    }
}

/// The keep-or-discard question for an unrecognised call.
struct ProvisionalPromptView: View {
    let prompt: ProvisionalPrompt
    let onKeep: () -> Void
    let onDiscard: () -> Void
    let onNever: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("MeetTape is recording \(prompt.applicationName)")
                .font(.headline)
            Text(
                "It took the microphone and is playing audio, which usually means a "
                    + "call. Recording continues while you decide."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            if let title = prompt.title {
                Text(title).font(.callout)
            }
            Spacer()
            HStack {
                Button("Never Record This App") { onNever() }
                Spacer()
                Button("Discard") { onDiscard() }
                Button("Keep Recording") { onKeep() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
