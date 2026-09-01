import AppKit
import PipitCore
import PipitDetection
import SwiftUI

/// Getting the sensor add-on into Firefox, and saying whether it is there.
///
/// A release build carries an add-on signed by Mozilla, which Firefox installs
/// permanently from the file. A local build carries none: release Firefox
/// refuses an unsigned add-on, so there is nothing to offer and the page says
/// so. Loading one temporarily from `about:debugging` is how the extension is
/// developed, and it lives in the docs rather than in the app.
///
/// The file goes to Firefox's executable as an argument. A running Firefox
/// forwards the argument to itself and the launched process exits.
enum FirefoxAddOn {
    /// The first installed Firefox build, release before developer builds.
    static func installedApplication() -> URL? {
        BrowserKind.firefox.bundleIdentifiers.lazy
            .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .first
    }

    static var isFirefoxInstalled: Bool { installedApplication() != nil }

    /// The signed add-on this build ships, if it ships one.
    static var bundledAddOn: URL? { NativeMessagingInstaller.bundledFirefoxAddOnURL() }

    /// Hands the signed add-on to Firefox, which raises its own install prompt.
    @discardableResult
    static func install() -> Bool {
        guard
            let addOn = bundledAddOn,
            let application = installedApplication(),
            let executable = Bundle(url: application)?.executableURL
        else { return false }
        let process = Process()
        process.executableURL = executable
        process.arguments = [addOn.path]
        do {
            try process.run()
        } catch {
            return false
        }
        return true
    }
}

/// What the Firefox card reports, from the two facts that decide it.
public enum FirefoxAddOnState: Equatable {
    /// Installed and holding a connection, with no meeting on screen.
    case installed
    /// Installed and reporting a meeting right now.
    case reporting
    /// Not connected, and this build has an add-on to install.
    case missing
    /// Not connected, and this build carries no signed add-on to offer.
    case unavailable

    public init(connection: BrowserSensorTracker.Connection, hasBundledAddOn: Bool) {
        switch (connection, hasBundledAddOn) {
        case (.fresh, _): self = .reporting
        case (.stale, _): self = .installed
        case (_, true): self = .missing
        case (_, false): self = .unavailable
        }
    }

    public var isInstalled: Bool { self == .installed || self == .reporting }

    var title: String {
        isInstalled ? "Add-on installed" : "Add-on not installed"
    }

    var symbol: String {
        switch self {
        case .installed, .reporting: "checkmark.circle.fill"
        case .missing: "exclamationmark.circle.fill"
        case .unavailable: "circle.slash"
        }
    }

    var color: Color {
        switch self {
        case .installed, .reporting: .green
        case .missing: .orange
        case .unavailable: .secondary
        }
    }

    /// The line under the title, which says what follows from the state rather
    /// than repeating it.
    var detail: String {
        switch self {
        case .reporting: "Reporting a meeting."
        case .installed: "Watching for Meet and Zoom calls."
        case .missing:
            "Meet and Zoom still record, from window titles and microphone state. "
                + "Recording starts at the prejoin screen rather than when you join."
        case .unavailable:
            "This build carries no signed add-on, so there is nothing to install. "
                + "Developing the extension is covered in docs/RELEASING.md."
        }
    }
}

/// The install button, and what it says after Firefox has been asked.
///
/// Shown by both the settings page and setup, so one wording covers both.
struct FirefoxAddOnInstallButton: View {
    /// A second install over one already there, which needs no urgency.
    var isReinstall = false
    @State private var launchFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if isReinstall {
                    Button("Reinstall add-on") { install() }
                        .disabled(!FirefoxAddOn.isFirefoxInstalled)
                } else {
                    Button("Install in Firefox") { install() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!FirefoxAddOn.isFirefoxInstalled)
                    Text("Firefox asks you to confirm")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            if launchFailed {
                Text("Firefox did not open. Open it and try again.")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func install() {
        launchFailed = !FirefoxAddOn.install()
    }
}
