import AppKit
import PipitCore
import PipitServices
import SwiftUI

/// Owns the app's windows. Pipit has no main window: everything is opened from
/// the menu bar and closes without affecting recording or processing.
@MainActor
public final class WindowManager {
    private let runtime: PipitRuntime
    private var settingsWindow: NSWindow?
    private var settingsModel: SettingsModel?
    private var peopleWindow: NSWindow?
    private var aboutWindow: NSWindow?
    private var peopleModel: PeopleDirectoryModel?
    private var setupWindow: NSWindow?
    private var setupModel: SetupModel?
    private var setupPlacementToken: NSObjectProtocol?
    private var meetingsWindow: NSWindow?
    private var meetingsModel: MeetingsWindowModel?
    private var provisionalWindow: NSWindow?
    private var provisionalPromptID: String?
    /// The windows currently on screen that Pipit has to stay reachable behind.
    private var openWindows: Set<ObjectIdentifier> = []
    /// One per open window, so a window closed by any route is noticed.
    private var closeTokens: [ObjectIdentifier: NSObjectProtocol] = [:]
    /// Puts the activation policy into force. Injected so a test can read the
    /// decision without turning the test process into a Dock application.
    private let applyPolicy: @MainActor (NSApplication.ActivationPolicy) -> Void

    public init(
        runtime: PipitRuntime,
        applyPolicy: @escaping @MainActor (NSApplication.ActivationPolicy) -> Void = DockPresence.apply
    ) {
        self.runtime = runtime
        self.applyPolicy = applyPolicy
        // An open meetings window tracks processing on its own. When a
        // transcript lands, the row and the pane show it without a manual
        // refresh.
        runtime.onProcessingUpdate = { [weak self] meetingID in
            guard let self, let model = self.meetingsModel else { return }
            // Resolved through the conversation the identifier belongs to. A
            // pane opened on the first half of a dropped call is keyed by that
            // recording, while the second half finishes processing under its
            // own: keying the lookup on the raw identifier meant the pane never
            // picked up the half it was showing.
            let logicalID = runtime.repository.logicalMeeting(id: meetingID)?.id ?? meetingID
            // The speaker rows come from the identity store, not the files, so
            // reloading only the files left the strip empty for a pane opened
            // before the transcript existed.
            Task { @MainActor in
                await model.refresh(meetingID: logicalID)
                // Only when the two differ. Each refresh reads the meeting's
                // files, and for a meeting recorded in one half the two
                // identifiers are the same, so asking twice did that work
                // twice.
                if logicalID != meetingID {
                    await model.refresh(meetingID: meetingID)
                }
            }
        }
    }

    /// Opens Settings on one page, for a menu item that is about that page.
    func showSettings(pane: SettingsPane) {
        showSettings()
        settingsModel?.pane = pane
    }

    public func showSettings() {
        if let window = settingsWindow {
            present(window)
            return
        }
        let model = SettingsModel(runtime: runtime)
        model.onOpenPeople = { [weak self] in self?.showPeople() }
        settingsModel = model
        let window = makeWindow(
            title: "Pipit Settings",
            size: NSSize(width: 720, height: 560),
            content: SettingsView(model: model)
        )
        window.setFrameAutosaveName("PipitSettings")
        settingsWindow = window
        present(window)
    }

    /// What Pipit is and where it puts things.
    ///
    /// Opened from the status menu, and from the About item in the menu bar
    /// menu while a window keeps Pipit in the Dock.
    public func showAbout() {
        if let window = aboutWindow {
            present(window)
            return
        }
        let window = makeWindow(
            title: "About Pipit",
            size: NSSize(width: 460, height: 520),
            content: AboutView(runtime: runtime)
        )
        window.setFrameAutosaveName("PipitAbout")
        aboutWindow = window
        present(window)
    }

    /// The people directory.
    ///
    /// Its own window rather than a settings tab: the two-pane layout needs more
    /// width than the settings window has, and a directory that grows to
    /// hundreds of voices is not a setting.
    public func showPeople() {
        if let window = peopleWindow {
            // Reloaded on every open, because meetings recorded since the last
            // one have named new voices.
            if let peopleModel { Task { @MainActor in await peopleModel.reload() } }
            present(window)
            return
        }
        let model = PeopleDirectoryModel(runtime: runtime)
        model.onOpenMeeting = { [weak self] meetingID in
            self?.showMeetings(select: meetingID)
        }
        peopleModel = model
        let window = makeWindow(
            title: "People",
            size: NSSize(width: 900, height: 600),
            content: PeopleDirectoryView(model: model)
        )
        window.setFrameAutosaveName("PipitPeople")
        peopleWindow = window
        present(window)
    }

    /// Opens setup at launch when it has never been finished, or when a
    /// permission Pipit cannot record without has gone away since.
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
            title: "Pipit Setup",
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
        // lost behind it. The Dock icon a window brings with it is what makes
        // that focus request land.
        //
        // Follows the user rather than making them find it: ordered front, the
        // window comes to whichever space they are on, including alongside a
        // full-screen application. Neither of these raises the window level, so
        // system prompts still sit above it.
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.collectionBehavior.insert(.fullScreenAuxiliary)
        model.onNeedsFocus = { [weak self] in self?.raiseSetup() }
        setupWindow = window
        setupPlacementToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let self else { return }
                if app?.bundleIdentifier == SetupWindowPlacement.systemSettingsBundleID {
                    self.moveSetupAsideFromSystemSettings()
                }
            }
        }
        present(window)
    }

    /// Brings the setup window back after a permission prompt closes.
    ///
    /// The prompt belongs to another process. macOS hands activation back to
    /// the previous application, which is Pipit while a window keeps it in the
    /// Dock, so this asks for the front rather than fighting for it.
    private func raiseSetup() {
        guard let window = setupWindow else { return }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
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
        // The observer polls while the window is up, so closing it by any route
        // has to stop that, not only pressing Done.
        setupModel?.end()
        setupWindow?.close()
        setupWindow = nil
        setupModel = nil
    }

    /// The meetings window: everything ever recorded, and one of them open.
    ///
    /// One window rather than a panel per meeting. The panel only existed for as
    /// long as somebody left it open, so a meeting that scrolled out of the
    /// menu's recent list could only be reached through the Finder, where
    /// nothing can rename a speaker.
    ///
    /// `select` is what a finished recording passes. It never steals focus:
    /// saving a meeting should not pull the user out of what they are doing.
    public func showMeetings(select meetingID: String? = nil, activating: Bool = true) {
        let model = meetingsModel ?? MeetingsWindowModel(runtime: runtime)
        model.onOpenSettings = { [weak self] in self?.showSettings() }
        meetingsModel = model
        let window = meetingsWindow ?? {
            let created = makeWindow(
                title: "Meetings",
                size: NSSize(width: 1_120, height: 720),
                content: MeetingsWindowView(model: model)
            )
            created.setFrameAutosaveName("PipitMeetings")
            created.isReleasedWhenClosed = false
            meetingsWindow = created
            return created
        }()
        // Reloaded on every open, because meetings recorded since the last one
        // are not in the list this window is holding.
        Task { @MainActor in
            await model.reload()
            if let meetingID { model.show(meetingID: meetingID) }
        }
        present(window, activating: activating)
    }

    /// Where a finished recording lands.
    public func showReview(meetingID: String) {
        showMeetings(select: meetingID, activating: false)
    }

    /// Asks whether to keep a recording of an application Pipit does not
    /// recognise.
    ///
    /// The notification carries the same question, and macOS refuses to deliver
    /// notifications at all under an ad-hoc signature, so the recording would
    /// otherwise run with nothing on screen to say it had started.
    public func showProvisionalPrompt(_ prompt: ProvisionalPrompt) {
        if provisionalPromptID == prompt.id, let window = provisionalWindow {
            present(window, activating: false, holdsDockPresence: false)
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
        present(window, activating: false, holdsDockPresence: false)
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

    /// Shows a window, and with it the Dock icon that keeps the window
    /// reachable.
    ///
    /// `holdsDockPresence` is false only for the keep-or-discard prompt, which
    /// sits at the floating level and is answered where it stands.
    private func present(
        _ window: NSWindow, activating: Bool = true, holdsDockPresence: Bool = true
    ) {
        // Before activating, not after. A policy raised while the application is
        // already inactive does not bring it back: measured, an inactive
        // application stayed inactive across the change.
        if holdsDockPresence { hold(window) }
        if activating {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        } else {
            // Saving a meeting should not pull the user out of what they are doing.
            window.orderFrontRegardless()
        }
    }

    /// Counts a window as open until it closes.
    private func hold(_ window: NSWindow) {
        let key = ObjectIdentifier(window)
        if openWindows.insert(key).inserted {
            closeTokens[key] = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.release(key) }
            }
        }
        refreshDockPresence()
    }

    private func release(_ key: ObjectIdentifier) {
        openWindows.remove(key)
        if let token = closeTokens.removeValue(forKey: key) {
            NotificationCenter.default.removeObserver(token)
        }
        refreshDockPresence()
    }

    /// Whether a window Pipit has to stay reachable behind is on screen.
    public var hasOpenWindow: Bool { !openWindows.isEmpty }

    /// Applies the policy the setting and the open windows ask for. Called at
    /// launch, on every settings change, and whenever a window opens or closes.
    public func refreshDockPresence() {
        applyPolicy(
            DockPresence.policy(
                showsDockIcon: runtime.settings.showsDockIcon, hasOpenWindow: hasOpenWindow
            )
        )
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
            Text("Pipit is recording \(prompt.applicationName)")
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
