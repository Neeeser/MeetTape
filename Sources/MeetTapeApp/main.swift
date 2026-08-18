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

    func applicationDidFinishLaunching(_ notification: Notification) {
        runtime = MeetTapeRuntime()
        windows = WindowManager(runtime: runtime)
        menuBar = MenuBarController(runtime: runtime, windows: windows)
        runtime.start()

        if !runtime.settings.hasCompletedOnboarding {
            windows.showOnboarding()
        }
        Log.app.info("MeetTape started")
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
