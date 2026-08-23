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
    private var setupWindow: NSWindow?
    private var setupModel: SetupModel?
    private var setupPlacementToken: NSObjectProtocol?
    /// Until when a permission prompt's aftermath should be treated as focus
    /// MeetTape is owed rather than as the user choosing another application.
    private var setupRaiseDeadline: Date?
    private var reviewWindows: [String: NSWindow] = [:]
    private var reviewModels: [String: MeetingReviewModel] = [:]
    private var provisionalWindow: NSWindow?
    private var provisionalPromptID: String?

    public init(runtime: MeetTapeRuntime) {
        self.runtime = runtime
        // An open review window tracks processing on its own: when the
        // transcript lands, the window shows it without a manual refresh.
        runtime.onProcessingUpdate = { [weak self] meetingID in
            guard let self else { return }
            // Resolved through the conversation the identifier belongs to. A
            // panel opened on the first half of a dropped call is keyed by that
            // recording, while the second half finishes processing under its
            // own: keying the lookup on the raw identifier meant the panel never
            // picked up the half it was showing.
            let logicalID = runtime.repository.logicalMeeting(id: meetingID)?.id ?? meetingID
            guard let model = self.reviewModels[logicalID] ?? self.reviewModels[meetingID]
            else { return }
            // The speaker rows come from the identity store, not the files, so
            // reloading only the files left the Speakers card empty for a
            // window opened before the transcript existed.
            Task { @MainActor in await model.reloadAll() }
        }
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

    /// Opens setup at launch when it has never been finished, or when a
    /// permission MeetTape cannot record without has gone away since.
    ///
    /// The permission read is asynchronous, so this cannot be answered before
    /// the application finishes launching.
    public func showSetupIfNeeded() async {
        var snapshot = SetupSnapshot(settings: runtime.settings)
        snapshot.permissions = Dictionary(
            uniqueKeysWithValues: await runtime.permissions.allStatuses().map { ($0.kind, $0.state) }
        )
        guard SetupFlow.shouldOpenAtLaunch(snapshot) else { return }
        Log.ui.info(
            "opening setup at launch: completed=\(snapshot.settings.hasCompletedOnboarding, privacy: .public) requiredGranted=\(SetupFlow.requiredPermissionsGranted(snapshot), privacy: .public)"
        )
        showSetup()
    }

    public func showSetup() {
        if let window = setupWindow {
            present(window)
            return
        }
        let model = SetupModel(runtime: runtime)
        setupModel = model
        let window = makeWindow(
            title: "MeetTape Setup",
            size: NSSize(width: 760, height: 580),
            content: SetupWizardView(model: model, onFinish: { [weak self] in
                self?.closeSetup()
            })
        )
        // An ordinary window level, deliberately.
        //
        // Floating was tried, to stop the wizard sinking behind other
        // applications after a permission prompt. It also put the wizard above
        // macOS's own permission prompt, which is the one window that must never
        // be covered: the user cannot answer a dialog they cannot see. Staying
        // out of the way of the system beats staying in front of it.
        //
        // What is left of the problem is handled without a window level: the
        // wizard asks for focus back when a prompt closes, and steps aside when
        // System Settings comes forward, so it is beside the pane rather than
        // lost behind it.
        //
        // Follows the user rather than making them find it: ordered front, the
        // window comes to whichever space they are on, including alongside a
        // full-screen application. Neither of these raises the window level, so
        // system prompts still sit above it.
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.collectionBehavior.insert(.fullScreenAuxiliary)
        model.onNeedsFocus = { [weak self] in
            guard let self else { return }
            // A permission prompt belongs to another process, and closing it
            // hands activation back to what macOS considers the previous
            // application, which for an accessory application with no Dock
            // presence is usually not us. Anything activating in the next couple
            // of seconds is that handover rather than the user picking an
            // application, so the workspace observer re-raises instead of
            // standing down.
            self.setupRaiseDeadline = Date().addingTimeInterval(2.5)
            self.raiseSetup()
        }
        setupWindow = window
        setupPlacementToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let self else { return }
                // Reacting to the activation itself rather than to a timer: the
                // window drops and comes back within one frame instead of
                // blinking out for as long as the next scheduled attempt.
                if let deadline = self.setupRaiseDeadline, Date() < deadline,
                    app?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                    self.raiseSetup()
                }
                if app?.bundleIdentifier == SetupWindowPlacement.systemSettingsBundleID {
                    self.moveSetupAsideFromSystemSettings()
                }
            }
        }
        present(window)
    }

    /// Brings the setup window to the front.
    ///
    /// `orderFrontRegardless` does the work. macOS refuses to make an accessory
    /// application active at all: measured here, MeetTape stayed behind Finder as
    /// the active application while its window sat ahead of Finder's in the
    /// window list. Activation is the part that is refused; raising is not.
    private func raiseSetup() {
        guard let window = setupWindow else { return }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    /// Moves the setup window off System Settings when it comes forward.
    ///
    /// Deferred, because the window is not on screen yet when the activation
    /// notification arrives, and a settings window restored from a previous
    /// session moves again after it appears.
    private func moveSetupAsideFromSystemSettings() {
        // System Settings takes a variable time to put a window on screen, and
        // measured just over a second here on a warm launch. Each attempt is a
        // window-list read and a frame comparison, and stops at the first one
        // that finds nothing to do.
        for delay in [0.3, 0.8, 1.5, 2.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, let window = self.setupWindow else { return }
                // Nothing is logged when there is nothing to do: this runs four
                // times per activation and the quiet case is the common one.
                guard let obstacle = SetupWindowPlacement.systemSettingsFrame(),
                    window.frame.intersects(obstacle)
                else { return }
                let target = SetupWindowPlacement.frame(
                    for: window.frame.size,
                    avoiding: obstacle,
                    within: SetupWindowPlacement.screen(containing: obstacle)
                )
                guard target != window.frame else { return }
                Log.ui.info(
                    "moving setup \(NSStringFromRect(window.frame), privacy: .public) to \(NSStringFromRect(target), privacy: .public)"
                )
                window.setFrame(target, display: true, animate: true)
            }
        }
    }

    public func closeSetup() {
        if let setupPlacementToken {
            NSWorkspace.shared.notificationCenter.removeObserver(setupPlacementToken)
        }
        setupPlacementToken = nil
        setupRaiseDeadline = nil
        // The observer polls while the window is up, so closing it by any route
        // has to stop that, not only pressing Done.
        setupModel?.end()
        setupWindow?.close()
        setupWindow = nil
        setupModel = nil
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
