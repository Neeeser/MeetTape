import AppKit
import PipitCore
import PipitDetection
import SwiftUI

/// Getting the sensor add-on into Firefox.
///
/// Two routes, and which one is available depends on the build. A release build
/// carries an add-on signed by Mozilla, which Firefox installs permanently from
/// the file. A local build carries none, so the only way in is the temporary
/// add-on, loaded by hand from `about:debugging` and dropped when Firefox quits.
///
/// Both hand the address or the file to Firefox's executable as an argument.
/// Firefox does not take `about:` addresses through the system URL handler, and
/// a running Firefox forwards the argument to itself and exits.
enum FirefoxAddOn {
    static let debuggingPageAddress = "about:debugging#/runtime/this-firefox"

    /// The first installed Firefox build, release before developer builds.
    static func installedApplication() -> URL? {
        BrowserKind.firefox.bundleIdentifiers.lazy
            .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .first
    }

    static var isFirefoxInstalled: Bool { installedApplication() != nil }

    static var isFirefoxRunning: Bool {
        let identifiers = Set(BrowserKind.firefox.bundleIdentifiers)
        return NSWorkspace.shared.runningApplications.contains { application in
            guard let identifier = application.bundleIdentifier else { return false }
            return identifiers.contains(identifier)
        }
    }

    /// The signed add-on this build ships, if it ships one.
    static var bundledAddOn: URL? { NativeMessagingInstaller.bundledFirefoxAddOnURL() }

    /// Hands the signed add-on to Firefox, which raises its own install prompt.
    @discardableResult
    static func install() -> Bool {
        guard let addOn = bundledAddOn else { return false }
        return launch(argument: addOn.path)
    }

    /// Opens the page that loads a temporary add-on.
    @discardableResult
    static func openDebuggingPage() -> Bool {
        launch(argument: debuggingPageAddress)
    }

    private static func launch(argument: String) -> Bool {
        guard
            let application = installedApplication(),
            let executable = Bundle(url: application)?.executableURL
        else { return false }
        let process = Process()
        process.executableURL = executable
        process.arguments = [argument]
        do {
            try process.run()
        } catch {
            return false
        }
        return true
    }
}

/// The buttons that get the add-on into Firefox, shown in setup and in settings.
///
/// A build carrying the signed add-on offers one button. Everything else offers
/// the manual route, which needs the address and the folder.
struct FirefoxAddOnControls: View {
    /// Reveals the unpacked extension folder, which the file picker in
    /// `about:debugging` needs. Absent where the caller has its own.
    var revealExtension: (() -> Void)?
    @State private var launchFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if FirefoxAddOn.bundledAddOn != nil {
                    Button("Install in Firefox") { launchFailed = !FirefoxAddOn.install() }
                        .disabled(!FirefoxAddOn.isFirefoxInstalled)
                } else {
                    Button("Open about:debugging") {
                        launchFailed = !FirefoxAddOn.openDebuggingPage()
                    }
                    .disabled(!FirefoxAddOn.isFirefoxInstalled)
                    Button("Copy Address") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            FirefoxAddOn.debuggingPageAddress, forType: .string
                        )
                    }
                }
                if let revealExtension {
                    Button("Show extension folder") { revealExtension() }
                }
            }
            if launchFailed {
                Text("Firefox did not open. Open it and try again.")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
