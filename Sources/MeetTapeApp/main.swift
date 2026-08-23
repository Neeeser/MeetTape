import AppKit
import MeetTapeCore
import MeetTapeServices
import MeetTapeUI

/// MeetTape runs as a menu-bar utility with no Dock presence and no main window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var runtime: MeetTapeRuntime!
    private var windows: WindowManager!
    private var menuBar: MenuBarController!
    private var notificationRouter: NotificationRouter!
    private var isTerminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        runtime = MeetTapeRuntime()
        windows = WindowManager(runtime: runtime)
        menuBar = MenuBarController(runtime: runtime, windows: windows)
        notificationRouter = NotificationRouter(runtime: runtime, windows: windows)
        runtime.start()

        // Asynchronous, because reading notification permission is a call into
        // another process. Recording and detection are already running by then;
        // setup opening is not a precondition for either.
        Task { @MainActor in await windows.showSetupIfNeeded() }
        Log.app.info("MeetTape started")
    }

    /// Finalising a recording is asynchronous, and a terminating run loop does
    /// not run the work that `stop()` enqueues. Termination is deferred until the
    /// recording is closed, so the meeting is not left for crash recovery.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateNow }
        isTerminating = true
        Task { @MainActor in
            await runtime.stopAndWait()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        runtime.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Closing a panel must never stop recording.
        false
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
