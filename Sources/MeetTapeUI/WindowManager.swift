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
