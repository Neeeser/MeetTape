import AppKit
import MeetTapeCore
import MeetTapeServices
import SwiftUI
import UniformTypeIdentifiers

/// The menu bar item and its menu.
///
/// Whether capture is running has to be readable at a glance, so the icon changes
/// while recording and the menu leads with the elapsed time and source health.
@MainActor
public final class MenuBarController: NSObject, NSMenuDelegate {
    private let runtime: MeetTapeRuntime
    private let windows: WindowManager
    private let statusItem: NSStatusItem
    /// Ticks the elapsed-time display. Held as a cancellable so teardown does not
    /// need a deinit, which cannot touch main-actor state.
    private var elapsedTimer: DispatchSourceTimer?

    public init(runtime: MeetTapeRuntime, windows: WindowManager) {
        self.runtime = runtime
        self.windows = windows
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        refreshButton()

        runtime.observeStatus { [weak self] in
            self?.refreshButton()
            self?.syncProvisionalPrompt()
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
        let symbol: String
        if status.isRecording {
            symbol = status.displayHealth.isLosingAudio
                ? "exclamationmark.circle.fill"
                : "record.circle.fill"
        } else if status.isInReconnectWindow {
            symbol = "arrow.triangle.2.circlepath.circle.fill"
        } else if status.detectionPaused {
            symbol = "pause.circle"
        } else {
            symbol = "waveform.circle"
        }
        button.image = NSImage(
            systemSymbolName: symbol, accessibilityDescription: accessibilityLabel(for: status)
        )
        button.image?.isTemplate = !(status.isRecording || status.isInReconnectWindow)
        button.contentTintColor = status.isRecording
            ? .systemRed
            : (status.isInReconnectWindow ? .systemOrange : nil)
        if status.isRecording {
            // With a non-template image the status item loses the menu bar's
            // vibrant styling and a plain title draws black regardless of the
            // menu bar's appearance. Resolving the label colour against the
            // button's own appearance keeps the duration readable on both a
            // dark and a light menu bar. This runs on the 1-second tick, so a
            // mid-session appearance change is picked up.
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

    private func accessibilityLabel(for status: RuntimeStatus) -> String {
        if status.isInReconnectWindow {
            let title = status.title ?? status.provider.displayName
            return "MeetTape, \(title) disconnected, recording paused"
        }
        guard status.isRecording else {
            return status.detectionPaused
                ? "MeetTape, automatic detection paused"
                : "MeetTape, waiting for a meeting"
        }
        let title = status.title ?? status.provider.displayName
        return "MeetTape recording \(title), \(Format.shortDuration(status.elapsed(now: Date())))"
    }

    // MARK: - menu

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = runtime.status

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
        menu.addItem(recentMeetingsItem())

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

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit MeetTape", action: #selector(quit), keyEquivalent: "q")
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

    private func recentMeetingsItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Recent Meetings", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let meetings = runtime.recentMeetings.prefix(12)
        if meetings.isEmpty {
            submenu.addItem(Self.informationItem("No meetings yet"))
        } else {
            for meeting in meetings {
                let subtitle = [
                    Format.day(meeting.startedAt),
                    Format.shortDuration(meeting.durationSeconds),
                    meeting.processingState == .complete ? nil : meeting.processingState.displayName,
                ].compactMap { $0 }.joined(separator: " · ")
                let entry = NSMenuItem(
                    title: meeting.title, action: #selector(openMeeting(_:)), keyEquivalent: ""
                )
                entry.target = self
                entry.representedObject = meeting.id
                entry.toolTip = subtitle
                // The label colour is explicit: an attributed title without one
                // draws in black, which is unreadable on a dark menu.
                let attributed = NSMutableAttributedString(
                    string: meeting.title,
                    attributes: [
                        .font: NSFont.menuFont(ofSize: 0),
                        .foregroundColor: NSColor.labelColor,
                    ]
                )
                attributed.append(NSAttributedString(
                    string: "\n\(subtitle)",
                    attributes: [
                        .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                        .foregroundColor: NSColor.secondaryLabelColor,
                    ]
                ))
                entry.attributedTitle = attributed
                submenu.addItem(entry)
            }
            submenu.addItem(.separator())
            let all = NSMenuItem(title: "Open Meetings Folder", action: #selector(openFolder), keyEquivalent: "")
            all.target = self
            submenu.addItem(all)
        }
        item.submenu = submenu
        return item
    }

    // MARK: - actions

    @objc private func startManual() { runtime.startManualRecording() }
    @objc private func startInPerson() { runtime.startInPersonRecording() }
    @objc private func stopRecording() { runtime.stopRecording() }
    @objc private func keepProvisional() { runtime.resolveProvisional(keep: true) }
    @objc private func discardProvisional() { runtime.resolveProvisional(keep: false) }
    @objc private func openSettings() { windows.showSettings() }

    @objc private func togglePause() {
        runtime.setDetectionPaused(!runtime.status.detectionPaused)
    }

    @objc private func openMeeting(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        windows.showReview(meetingID: id)
    }

    @objc private func openFolder() {
        NSWorkspace.shared.open(runtime.repository.archive.root)
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
                // The review window is not opened here. Transcription takes a
                // while, so the import shows progress in this menu and posts a
                // notification when the transcript is ready.
                _ = try await runtime.importRecording(from: url)
            } catch {
                let alert = NSAlert()
                alert.messageText = "MeetTape could not import that file"
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
