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

/// The mark beside a step in the rail.
public enum SetupStepMark: Sendable, Equatable {
    /// Required and done, or optional with everything on its page switched on.
    case done
    /// Optional, continued past with something on its page left off. A choice
    /// the person made, kept so the rail does not keep asking.
    case skipped
    /// Required and not done. Setup cannot finish, and recording may not work.
    case missing
    /// Optional and never continued past.
    case notVisited
}

/// One row of the wizard: which screen, and whether it is done.
public struct SetupStep: Sendable, Equatable, Identifiable {
    public let id: SetupStepID
    public let isRequired: Bool
    public let isSatisfied: Bool
    public let mark: SetupStepMark

    public init(id: SetupStepID, isRequired: Bool, isSatisfied: Bool, mark: SetupStepMark) {
        self.id = id
        self.isRequired = isRequired
        self.isSatisfied = isSatisfied
        self.mark = mark
    }
}

/// Decides which steps are done and whether setup may finish.
public enum SetupFlow {
    public static func steps(for snapshot: SetupSnapshot) -> [SetupStep] {
        SetupStepID.allCases.map { id in
            SetupStep(
                id: id, isRequired: id.isRequired, isSatisfied: isSatisfied(id, in: snapshot),
                mark: mark(for: id, in: snapshot)
            )
        }
    }

    /// A required step is done or missing, whatever the person has seen. An
    /// optional step is done when everything on its page is on, skipped when
    /// it was continued past with something off, and unmarked until then.
    public static func mark(for id: SetupStepID, in snapshot: SetupSnapshot) -> SetupStepMark {
        if id.isRequired { return isSatisfied(id, in: snapshot) ? .done : .missing }
        let visited = snapshot.settings.setupStepsVisited.contains(id.rawValue)
        switch id {
        case .welcome:
            return visited ? .done : .notVisited
        case .optionalPermissions:
            let both = snapshot.state(of: .calendar) == .granted
                && snapshot.state(of: .notifications) == .granted
            if both { return .done }
            return visited ? .skipped : .notVisited
        case .firefox:
            if snapshot.nativeHostInstalled { return .done }
            return visited ? .skipped : .notVisited
        case .finish:
            return snapshot.settings.hasCompletedOnboarding ? .done : .notVisited
        case .backend, .models, .microphone, .screenRecording, .accessibility:
            return isSatisfied(id, in: snapshot) ? .done : .missing
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
    /// Someone who has finished setup before is sent straight at the first
    /// step that needs work, since walking them from Welcome through choices
    /// they already made to reach one revoked permission is nine screens of
    /// nothing.
    ///
    /// A first run opens at Finish when there is nothing left to do, which is
    /// what a reinstall onto a machine that kept its models and permissions looks
    /// like, and at Welcome otherwise. Not at the first unsatisfied step: the
    /// backend choice is satisfied by its own local default, so resuming past it
    /// would hide the local-or-cloud decision entirely.
    public static func openingStep(for snapshot: SetupSnapshot) -> SetupStepID {
        if snapshot.settings.hasCompletedOnboarding {
            return firstMissingStep(in: snapshot) ?? .finish
        }
        return canFinish(snapshot) ? .finish : .welcome
    }

    /// The first required step that is not done, in rail order.
    public static func firstMissingStep(in snapshot: SetupSnapshot) -> SetupStepID? {
        SetupStepID.allCases.first { mark(for: $0, in: snapshot) == .missing }
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
