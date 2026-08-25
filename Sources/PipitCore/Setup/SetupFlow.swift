import Foundation

/// The screens of first-run setup, in order.
public enum SetupStepID: String, Sendable, CaseIterable, Identifiable {
    case welcome
    case backend
    case models
    case microphone
    case screenRecording
    case accessibility
    case optionalPermissions
    case firefox
    case finish

    public var id: String { rawValue }

    /// The rail label. Short enough for a 172pt column.
    public var railTitle: String {
        switch self {
        case .welcome: "Welcome"
        case .backend: "Where it runs"
        case .models: "Speech models"
        case .microphone: "Microphone"
        case .screenRecording: "Screen recording"
        case .accessibility: "Accessibility"
        case .optionalPermissions: "Calendar and alerts"
        case .firefox: "Firefox"
        case .finish: "Finish"
        }
    }

    /// The permission a step grants, for the steps that grant exactly one.
    public var permission: PermissionKind? {
        switch self {
        case .microphone: .microphone
        case .screenRecording: .screenRecording
        case .accessibility: .accessibility
        case .welcome, .backend, .models, .optionalPermissions, .firefox, .finish: nil
        }
    }

    /// Whether setup refuses to finish until this step is satisfied.
    public var isRequired: Bool {
        if let permission { return permission.isRequired }
        switch self {
        case .backend, .models: return true
        case .welcome, .optionalPermissions, .firefox, .finish: return false
        case .microphone, .screenRecording, .accessibility: return true
        }
    }
}

/// Everything a step's satisfaction is decided from.
///
/// A value rather than a set of live services, so the whole flow is decided
/// without I/O and tested directly.
public struct SetupSnapshot: Sendable, Equatable {
    public var settings: AppSettings
    /// Whether a stored OpenAI key has answered a real request.
    public var cloudKeyVerified: Bool
    public var permissions: [PermissionKind: PermissionState]
    public var installedUnits: Set<LocalModelUnit>
    public var isDownloadingModels: Bool
    public var nativeHostInstalled: Bool

    public init(
        settings: AppSettings = AppSettings(),
        cloudKeyVerified: Bool = false,
        permissions: [PermissionKind: PermissionState] = [:],
        installedUnits: Set<LocalModelUnit> = [],
        isDownloadingModels: Bool = false,
        nativeHostInstalled: Bool = false
    ) {
        self.settings = settings
        self.cloudKeyVerified = cloudKeyVerified
        self.permissions = permissions
        self.installedUnits = installedUnits
        self.isDownloadingModels = isDownloadingModels
        self.nativeHostInstalled = nativeHostInstalled
    }

    /// The units this configuration needs, whichever backends are chosen.
    public var requiredUnits: Set<LocalModelUnit> {
        LocalModelUnit.required(for: settings)
    }

    public var missingUnits: Set<LocalModelUnit> {
        requiredUnits.subtracting(installedUnits)
    }

    public func state(of kind: PermissionKind) -> PermissionState {
        permissions[kind] ?? .notDetermined
    }
}

/// One row of the wizard: which screen, and whether it is done.
public struct SetupStep: Sendable, Equatable, Identifiable {
    public let id: SetupStepID
    public let isRequired: Bool
    public let isSatisfied: Bool

    public init(id: SetupStepID, isRequired: Bool, isSatisfied: Bool) {
        self.id = id
        self.isRequired = isRequired
        self.isSatisfied = isSatisfied
    }
}

/// Decides which steps are done and whether setup may finish.
public enum SetupFlow {
    public static func steps(for snapshot: SetupSnapshot) -> [SetupStep] {
        SetupStepID.allCases.map { id in
            SetupStep(
                id: id, isRequired: id.isRequired, isSatisfied: isSatisfied(id, in: snapshot)
            )
        }
    }

    public static func isSatisfied(_ id: SetupStepID, in snapshot: SetupSnapshot) -> Bool {
        if let permission = id.permission {
            return snapshot.state(of: permission) == .granted
        }
        switch id {
        case .backend:
            // Local needs nothing. Cloud needs a key that has answered a real
            // request: storing an unverified one moves the failure to the first
            // meeting, where it costs a recording instead of a click.
            return snapshot.settings.processing.isFullyLocal || snapshot.cloudKeyVerified
        case .models:
            // A download under way counts. Recording works while models arrive,
            // and meetings that finish first are queued until they do, so holding
            // the user here for 2.1 GB buys nothing.
            return snapshot.missingUnits.isEmpty || snapshot.isDownloadingModels
        case .welcome, .optionalPermissions, .firefox, .finish:
            return true
        case .microphone, .screenRecording, .accessibility:
            return false
        }
    }

    /// Whether Done may be pressed.
    public static func canFinish(_ snapshot: SetupSnapshot) -> Bool {
        steps(for: snapshot).allSatisfy { !$0.isRequired || $0.isSatisfied }
    }

    /// Whether every permission Pipit cannot record without is in effect.
    public static func requiredPermissionsGranted(_ snapshot: SetupSnapshot) -> Bool {
        PermissionKind.allCases
            .filter(\.isRequired)
            .allSatisfy { snapshot.state(of: $0) == .granted }
    }

    /// Whether launching should put setup in front of the user.
    ///
    /// Setup has never been finished, or one of the permissions Pipit cannot
    /// record without has gone away since it was. The second case is not
    /// nagging: without the microphone the next meeting records nothing at all,
    /// and a menu bar icon that looks exactly the same as always is the only
    /// thing saying so. macOS revokes these on its own after an update or a
    /// re-signed build, so it happens to people who never touched a setting.
    ///
    /// Only permissions reopen it. A model deleted from disk or an API key that
    /// stopped working are repaired in Settings and do not cost a recording.
    public static func shouldOpenAtLaunch(_ snapshot: SetupSnapshot) -> Bool {
        if !snapshot.settings.hasCompletedOnboarding { return true }
        return !requiredPermissionsGranted(snapshot)
    }

    /// Where the wizard opens.
    ///
    /// Someone who has finished setup before is sent straight at whatever broke,
    /// since walking them from Welcome through choices they already made to reach
    /// one revoked permission is nine screens of nothing.
    ///
    /// A first run opens at Finish when there is nothing left to do, which is
    /// what a reinstall onto a machine that kept its models and permissions looks
    /// like, and at Welcome otherwise. Not at the first unsatisfied step: the
    /// backend choice is satisfied by its own local default, so resuming past it
    /// would hide the local-or-cloud decision entirely.
    public static func openingStep(for snapshot: SetupSnapshot) -> SetupStepID {
        if snapshot.settings.hasCompletedOnboarding {
            let broken = SetupStepID.allCases.first { step in
                guard let permission = step.permission, permission.isRequired else { return false }
                return !isSatisfied(step, in: snapshot)
            }
            return broken ?? .finish
        }
        return canFinish(snapshot) ? .finish : .welcome
    }

    /// The step after this one, or nil at the end.
    public static func step(after id: SetupStepID) -> SetupStepID? {
        let all = SetupStepID.allCases
        guard let index = all.firstIndex(of: id), index + 1 < all.count else { return nil }
        return all[index + 1]
    }

    /// The step before this one, or nil at the start.
    public static func step(before id: SetupStepID) -> SetupStepID? {
        let all = SetupStepID.allCases
        guard let index = all.firstIndex(of: id), index > 0 else { return nil }
        return all[index - 1]
    }
}
