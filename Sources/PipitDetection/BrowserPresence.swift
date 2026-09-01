import AppKit
import PipitCore

/// Whether a browser is running right now.
///
/// Used to decide whether a missing sensor is worth reporting: an add-on that
/// is not loaded matters while the browser is open and not at all while it is
/// closed.
public enum BrowserPresence {
    public static func isRunning(_ kind: BrowserKind) -> Bool {
        let identifiers = Set(kind.bundleIdentifiers)
        return NSWorkspace.shared.runningApplications.contains { application in
            guard let identifier = application.bundleIdentifier else { return false }
            return identifiers.contains(identifier)
        }
    }
}
