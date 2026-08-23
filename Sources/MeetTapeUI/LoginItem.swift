import Foundation
import MeetTapeCore
import ServiceManagement

/// Registers the application to start when the user logs in.
///
/// The setting was stored and shown in the General tab and nothing read it, so
/// the toggle did nothing at all. Applied here rather than in the runtime
/// because a login item is a fact about this application bundle, not a decision
/// the pipeline makes, and `MeetTapeCore` imports only Foundation.
public enum LoginItem {
    /// What reconciling the setting against the system requires.
    public enum Action: Sendable, Equatable {
        case register
        case unregister
    }

    /// The pure decision, so re-applying a state already in force costs
    /// nothing. `SMAppService.register` on an already-registered item throws,
    /// and this runs on every settings change.
    public static func action(wanted: Bool, isRegistered: Bool) -> Action? {
        if wanted == isRegistered { return nil }
        return wanted ? .register : .unregister
    }

    /// Brings the system in line with the setting, at launch and whenever the
    /// toggle changes.
    public static func apply(launchAtLogin: Bool) {
        let service = SMAppService.mainApp
        let registered = service.status == .enabled
        guard let action = action(wanted: launchAtLogin, isRegistered: registered) else { return }
        do {
            switch action {
            case .register: try service.register()
            case .unregister: try service.unregister()
            }
        } catch {
            // A login item is a convenience, and the user can set one in System
            // Settings. Failing the launch over it would be worse than not
            // having it.
            Log.app.error("login item \(String(describing: action)) failed")
        }
    }
}
