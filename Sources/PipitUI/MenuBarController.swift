import AppKit
import PipitCore
import PipitServices
import SwiftUI
import UniformTypeIdentifiers

/// The menu bar item and its menu.
///
/// Whether capture is running has to be readable at a glance, so the icon changes
/// while recording and the menu leads with the elapsed time and source health.
@MainActor
public final class MenuBarController: NSObject, NSMenuDelegate {
    private let runtime: PipitRuntime
    private let windows: WindowManager
    private let statusItem: NSStatusItem
    /// Ticks the elapsed-time display. Held as a cancellable so teardown does not
    /// need a deinit, which cannot touch main-actor state.
    private var elapsedTimer: DispatchSourceTimer?
    /// The value of the launch-at-login setting last handed to `LoginItem`.
    /// The status observer fires on every capture health update, warning and
    /// list refresh, and `LoginItem.apply` reads `SMAppService.mainApp.status`,
    /// a synchronous launchd query on the main thread. Only a changed setting
    /// reaches launchd; the launch-time reconcile below still runs once.
    private var appliedLaunchAtLogin: Bool?

    public init(runtime: PipitRuntime, windows: WindowManager) {
        self.runtime = runtime
        self.windows = windows
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        refreshButton()

        MainMenu.install(
            target: self, showAbout: #selector(openAbout), showSettings: #selector(openSettings)
        )
        runtime.observeStatus { [weak self, weak windows] in
            self?.refreshButton()
            self?.syncProvisionalPrompt()
            windows?.refreshDockPresence()
            self?.applyLoginItemIfChanged(runtime.settings.launchAtLogin)
        }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.refreshButton() }
        }
        timer.resume()
        elapsedTimer = timer

        Log.ui.info(
            "menu bar item ready: \(self.statusItem.button != nil, privacy: .public), visible: \(self.statusItem.isVisible, privacy: .public)"
        )
    }

    /// Hands a changed setting to `LoginItem`, and nothing otherwise.
    private func applyLoginItemIfChanged(_ launchAtLogin: Bool) {
        guard appliedLaunchAtLogin != launchAtLogin else { return }
        appliedLaunchAtLogin = launchAtLogin
        LoginItem.apply(launchAtLogin: launchAtLogin)
    }

    /// Removes the status item and stops the timer.
    public func teardown() {
        elapsedTimer?.cancel()
        elapsedTimer = nil
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    /// Shows or hides the keep-or-discard window as the runtime raises and
    /// resolves the question.
    private func syncProvisionalPrompt() {
        if let prompt = runtime.provisionalPrompt {
            windows.showProvisionalPrompt(prompt)
        } else {
            windows.closeProvisionalPrompt()
        }
    }

    private func refreshButton() {
        guard let button = statusItem.button else { return }
        let status = runtime.status
        button.image = Self.iconImage(for: status)
        button.contentTintColor = Self.iconTintColor(for: status)
        if status.isRecording {
            // The template image and duration both resolve against whichever
            // menu-bar material is under them. This runs on the 1-second tick,
            // so a mid-session appearance change is picked up.
            var resolved = NSColor.labelColor
            button.effectiveAppearance.performAsCurrentDrawingAppearance {
                resolved = NSColor(cgColor: NSColor.labelColor.cgColor) ?? .labelColor
            }
            button.attributedTitle = NSAttributedString(
                string: " \(Format.duration(status.elapsed(now: Date())))",
                attributes: [
                    .foregroundColor: resolved,
                    .font: NSFont.monospacedDigitSystemFont(
                        ofSize: NSFont.systemFontSize, weight: .regular
                    ),
                ]
            )
        } else {
            button.attributedTitle = NSAttributedString(string: "")
            button.title = ""
        }
        button.toolTip = accessibilityLabel(for: status)
        button.setAccessibilityLabel(accessibilityLabel(for: status))
    }

    /// The bundle resource that represents a runtime state.
    public static func iconAssetName(for status: RuntimeStatus) -> String {
        if status.isRecording {
            return status.displayHealth.isLosingAudio ? "pipit-warning" : "pipit-recording"
        }
        if status.isInReconnectWindow || status.detectionPaused {
            return "pipit-paused"
        }
        return "pipit-idle"
    }

    /// A nil tint lets AppKit draw the template image in the menu bar's
    /// adaptive foreground colour. In particular, the recording icon stays
    /// light while the status item has its dark active background.
    public static func iconTintColor(for status: RuntimeStatus) -> NSColor? {
        // The red icon carries its own colour; a tint would be ignored anyway,
        // since it is not a template.
        if iconIsRed(for: status) { return nil }
        return status.isInReconnectWindow ? .systemOrange : nil
    }

    /// Whether the icon is the whole bird in red with a mark beside it. A
    /// missing grant outranks everything until it is seen.
    public static func iconIsRed(for status: RuntimeStatus) -> Bool {
        status.permissionNotice != nil
    }

    /// Whether the exclamation mark is stamped into the icon's corner.
    public static func iconIsBadged(for status: RuntimeStatus) -> Bool {
        if iconIsRed(for: status) { return false }
        // A recording icon already carries the state that matters most. The
        // add-on warning waits until the icon is otherwise idle.
        return status.sensorNeedsAttention && !status.isCapturing
    }

    private static func iconImage(for status: RuntimeStatus) -> NSImage? {
        let asset = NSImage(named: NSImage.Name(iconAssetName(for: status)))
        let image = asset ?? NSImage(
            systemSymbolName: fallbackSymbolName(for: status),
            accessibilityDescription: nil
        )
        guard let copy = image?.copy() as? NSImage else { return nil }
        copy.size = NSSize(width: 18, height: 18)
        copy.isTemplate = true
        if iconIsRed(for: status) { return flagged(copy) }
        return iconIsBadged(for: status) ? badged(copy) : copy
    }

    /// The whole icon in red, with a red exclamation mark beside it.
    ///
    /// Beside, not over: a mark stamped into the corner cut a hole through the
    /// bird's body. The colour is baked in rather than tinted, because the
    /// status bar button ignored `contentTintColor` on the template and drew
    /// the bird in the ordinary menu bar colour.
    private static func flagged(_ base: NSImage) -> NSImage {
        let markWidth = base.size.height * 0.5
        let gap: CGFloat = 1.5
        let size = NSSize(width: base.size.width + gap + markWidth, height: base.size.height)
        let mark = NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: nil)
        let image = NSImage(size: size, flipped: false) { rect in
            let bird = NSRect(x: rect.minX, y: rect.minY, width: base.size.width, height: base.size.height)
            tinted(base, .systemRed).draw(in: bird)
            if let mark {
                let box = NSRect(x: bird.maxX + gap, y: rect.minY, width: markWidth, height: markWidth)
                tinted(mark, .systemRed).draw(in: box)
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// A template image filled with one colour wherever it has ink.
    private static func tinted(_ base: NSImage, _ color: NSColor) -> NSImage {
        let image = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Stamps a warning mark into the corner of the menu bar icon.
    ///
    /// The icon is a template, so the mark cannot be a second colour. A hole
    /// cleared around it is what keeps it readable against the icon behind.
    private static func badged(_ base: NSImage) -> NSImage {
        guard let mark = NSImage(
            systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: nil
        ) else { return base }
        let badged = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            let diameter = rect.width * 0.6
            let box = NSRect(
                x: rect.maxX - diameter, y: rect.minY, width: diameter, height: diameter
            )
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSColor.black.setFill()
            NSBezierPath(ovalIn: box.insetBy(dx: -1.5, dy: -1.5)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            mark.draw(in: box)
            return true
        }
        badged.isTemplate = true
        return badged
    }

    /// Keeps `swift run Pipit` usable outside the assembled application
    /// bundle, where the image resources do not exist.
    private static func fallbackSymbolName(for status: RuntimeStatus) -> String {
        if status.isRecording {
            return status.displayHealth.isLosingAudio
                ? "exclamationmark.circle.fill"
                : "record.circle.fill"
        }
        if status.isInReconnectWindow { return "arrow.triangle.2.circlepath.circle.fill" }
        if status.detectionPaused { return "pause.circle" }
        return "waveform.circle"
    }

    private func accessibilityLabel(for status: RuntimeStatus) -> String {
        if status.sensorNeedsAttention, !status.isCapturing {
            return "Pipit, the Firefox add-on is not loaded"
        }
        if status.isInReconnectWindow {
            let title = status.title ?? status.provider.displayName
            return "Pipit, \(title) disconnected, recording paused"
        }
        guard status.isRecording else {
            return status.detectionPaused
                ? "Pipit, automatic detection paused"
                : "Pipit, waiting for a meeting"
        }
        let title = status.title ?? status.provider.displayName
        return "Pipit recording \(title), \(Format.shortDuration(status.elapsed(now: Date())))"
    }

    // MARK: - menu

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = runtime.status

        if let notice = status.permissionNotice {
            let item = NSMenuItem(
                title: notice.menuTitle, action: #selector(openSetup), keyEquivalent: ""
            )
            item.image = NSImage(
                systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil
            )?.withSymbolConfiguration(.init(paletteColors: [.systemRed]))
            item.target = self
            menu.addItem(item)
            menu.addItem(.separator())
        }

        if status.sensorNeedsAttention {
            let warning = NSMenuItem(
                title: "Firefox add-on not loaded",
                action: #selector(openBrowserSettings),
                keyEquivalent: ""
            )
            warning.image = NSImage(
                systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil
            )
            warning.target = self
            menu.addItem(warning)
            menu.addItem(.separator())
        }

        if status.isRecording {
            addRecordingSection(to: menu, status: status)
        } else if status.isInReconnectWindow {
            addReconnectSection(to: menu, status: status)
        } else {
            addIdleSection(to: menu)
        }

        if !runtime.processing.isEmpty {
            menu.addItem(.separator())
            menu.addItem(Self.informationItem("Processing", emphasis: true))
            for progress in runtime.processing.values.sorted(by: { $0.meetingID < $1.meetingID }) {
                let detail = progress.totalChunks > 0
                    ? "\(progress.state.displayName) \(progress.completedChunks)/\(progress.totalChunks)"
                    : progress.state.displayName
                menu.addItem(Self.informationItem("  \(progress.title): \(detail)"))
            }
        }

        menu.addItem(.separator())
        let meetings = NSMenuItem(
            title: "Meetings…", action: #selector(openMeetings), keyEquivalent: "m"
        )
        meetings.target = self
        menu.addItem(meetings)

        let people = NSMenuItem(title: "People…", action: #selector(openPeople), keyEquivalent: "p")
        people.target = self
        menu.addItem(people)

        menu.addItem(.separator())
        let pause = NSMenuItem(
            title: status.detectionPaused ? "Resume Automatic Detection" : "Pause Automatic Detection",
            action: #selector(togglePause), keyEquivalent: ""
        )
        pause.target = self
        pause.state = status.detectionPaused ? .on : .off
        menu.addItem(pause)

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let setup = NSMenuItem(title: "Setup…", action: #selector(openSetup), keyEquivalent: "")
        setup.target = self
        menu.addItem(setup)

        let about = NSMenuItem(title: "About Pipit", action: #selector(openAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Pipit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func addRecordingSection(to menu: NSMenu, status: RuntimeStatus) {
        let title = status.title ?? status.provider.displayName
        menu.addItem(Self.informationItem("● Recording", emphasis: true))
        menu.addItem(Self.informationItem("  \(title)"))
        menu.addItem(Self.informationItem("  \(Format.duration(status.elapsed(now: Date())))"))

        // Source health is only spelled out when it is not simply fine.
        if status.displayHealth != .healthy {
            menu.addItem(Self.informationItem("  \(healthText(status))"))
        }

        menu.addItem(.separator())
        let stop = NSMenuItem(title: "Stop Recording", action: #selector(stopRecording), keyEquivalent: "")
        stop.target = self
        menu.addItem(stop)

        let note = NSMenuItem(title: "Add Note…", action: #selector(addNote), keyEquivalent: "")
        note.target = self
        menu.addItem(note)

        if status.isProvisional {
            menu.addItem(.separator())
            let keep = NSMenuItem(title: "Keep This Recording", action: #selector(keepProvisional), keyEquivalent: "")
            keep.target = self
            menu.addItem(keep)
            let discard = NSMenuItem(
                title: "Discard This Recording", action: #selector(discardProvisional), keyEquivalent: ""
            )
            discard.target = self
            menu.addItem(discard)
        }
    }

    /// Shown while the meeting's evidence is gone and the reconnect window is
    /// open. Nothing is being written; the recording resumes if the meeting
    /// comes back and ends otherwise.
    private func addReconnectSection(to menu: NSMenu, status: RuntimeStatus) {
        let title = status.title ?? status.provider.displayName
        menu.addItem(Self.informationItem("◌ Meeting disconnected", emphasis: true))
        menu.addItem(Self.informationItem("  \(title)"))
        menu.addItem(Self.informationItem("  Recording is paused. It resumes if the meeting comes back, and ends after 90 seconds."))

        menu.addItem(.separator())
        let stop = NSMenuItem(title: "End Meeting Now", action: #selector(stopRecording), keyEquivalent: "")
        stop.target = self
        menu.addItem(stop)
    }

    /// A menu row that carries information rather than a command.
    ///
    /// A disabled item is drawn in the system's disabled colour, which on a dark
    /// menu is barely distinguishable from the background. An attributed title
    /// with an explicit label colour stays readable in both appearances while the
    /// row remains unclickable.
    public static func informationItem(_ text: String, emphasis: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        let size = NSFont.menuFont(ofSize: 0).pointSize
        let font = emphasis
            ? NSFont.systemFont(ofSize: size, weight: .semibold)
            : NSFont.menuFont(ofSize: 0)
        item.attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .foregroundColor: emphasis ? NSColor.labelColor : NSColor.secondaryLabelColor,
                .font: font,
            ]
        )
        return item
    }

    private func healthText(_ status: RuntimeStatus) -> String {
        switch status.displayHealth {
        case .recovering: "Reconnecting to audio"
        case .degraded, .failed:
            status.health.mic.isLosingAudio
                ? "Microphone unavailable"
                : "Meeting audio unavailable"
        case .idleButBound: "Meeting audio is silent"
        case .healthy, .idle: ""
        }
    }

    private func addIdleSection(to menu: NSMenu) {
        let record = NSMenuItem(title: "Start Recording", action: #selector(startManual), keyEquivalent: "r")
        record.target = self
        menu.addItem(record)

        let inPerson = NSMenuItem(
            title: "Start In-Person Meeting", action: #selector(startInPerson), keyEquivalent: ""
        )
        inPerson.target = self
        menu.addItem(inPerson)

        let importItem = NSMenuItem(title: "Import Recording…", action: #selector(importFile), keyEquivalent: "i")
        importItem.target = self
        menu.addItem(importItem)
    }

    // MARK: - actions

    @objc private func startManual() { runtime.startManualRecording() }
    @objc private func startInPerson() { runtime.startInPersonRecording() }
    @objc private func stopRecording() { runtime.stopRecording() }
    @objc private func keepProvisional() { runtime.resolveProvisional(keep: true) }
    @objc private func discardProvisional() { runtime.resolveProvisional(keep: false) }
    @objc private func openSetup() {
        windows.showSetup()
    }

    @objc private func openSettings() { windows.showSettings() }
    @objc private func openBrowserSettings() { windows.showSettings(pane: .browsers) }

    @objc private func openAbout() { windows.showAbout() }

    @objc private func openPeople() { windows.showPeople() }

    @objc private func openMeetings() { windows.showMeetings() }

    @objc private func togglePause() {
        runtime.setDetectionPaused(!runtime.status.detectionPaused)
    }

    @objc private func addNote() {
        let alert = NSAlert()
        alert.messageText = "Add a note to this meeting"
        alert.informativeText = "Notes are saved with the recording and are used as context during enrichment."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "Decision, action item, or context"
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        runtime.addNote(text)
    }

    @objc private func importFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .movie, .mpeg4Movie, .mp3, .wav, .aiff]
        panel.message = "Choose a recording to import. The original file is copied and left unchanged."
        panel.prompt = "Import"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task { @MainActor in
            do {
                // The meetings window is not opened here. Transcription takes a
                // while, so the import shows progress in this menu and posts a
                // notification when the transcript is ready.
                _ = try await runtime.importRecording(from: url)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Pipit could not import that file"
                alert.informativeText = "\(url.lastPathComponent) could not be decoded."
                alert.runModal()
            }
        }
    }

    @objc private func quit() {
        // The delegate's applicationShouldTerminate stops the runtime and waits
        // for the recording to be finalised before the process exits.
        NSApp.terminate(nil)
    }
}
