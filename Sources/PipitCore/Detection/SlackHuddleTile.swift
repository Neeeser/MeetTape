import Foundation

/// One person's tile in a Slack huddle, as the accessibility tree describes it.
public struct SlackHuddleTile: Sendable, Equatable {
    public var userID: String
    public var displayName: String?
    public var isSelf: Bool
    /// Nil when the tile did not say, which a truncated read can produce.
    public var isMuted: Bool?
    public var isSpeaking: Bool

    public init(
        userID: String, displayName: String? = nil, isSelf: Bool = false,
        isMuted: Bool? = nil, isSpeaking: Bool = false
    ) {
        self.userID = userID
        self.displayName = displayName
        self.isSelf = isSelf
        self.isMuted = isMuted
        self.isSpeaking = isSpeaking
    }
}

/// Reads a huddle tile out of the strings Slack exposes.
///
/// Slack is an Electron app, so setting `AXManualAccessibility` builds the web
/// tree and every node then carries `AXDOMIdentifier` and `AXDOMClassList`.
/// Slack names its classes after what they mean, which is what makes this
/// possible at all. Kept separate from the accessibility walk so the parsing can
/// be tested without a running huddle.
public enum SlackHuddleTileParser {
    static let identifierPrefix = "huddle-grid-gridcell"
    /// The offscreen node that describes a tile is not a tile.
    static let descriptionSuffix = "a11y_huddle_peer_tile_description"
    static let speakingClass = "p-huddle_peer_tile__overlay--active_speaker"

    /// Own tile:    `huddle-grid-gridcell-self_U0BSR53NYHG`
    /// Other tile:  `huddle-grid-gridcell-<session-uuid>_U0BSR50GN82`
    ///
    /// The identifier after the last underscore is the person either way. What
    /// comes before it is the session, so one person joined from a laptop and a
    /// phone is two tiles carrying one id.
    public static func userID(from identifier: String) -> String? {
        guard identifier.hasPrefix(identifierPrefix) else { return nil }
        guard !identifier.contains(descriptionSuffix) else { return nil }
        guard let id = identifier.split(separator: "_").last.map(String.init),
              !id.isEmpty, id != identifier
        else { return nil }
        return id
    }

    public static func isSelf(_ identifier: String) -> Bool {
        identifier.contains("-self_")
    }

    /// `View Andrew Neeser's profile` names the person. Anything else does not.
    public static func displayName(from description: String) -> String? {
        let prefix = "View "
        let suffix = "'s profile"
        guard description.hasPrefix(prefix), description.hasSuffix(suffix) else { return nil }
        let name = description.dropFirst(prefix.count).dropLast(suffix.count)
        return name.isEmpty ? nil : String(name)
    }

    /// The tile's name overlay reads `video is off, audio is on` and inverts
    /// while muted. Nil where the description is about something else.
    public static func isMuted(description: String) -> Bool? {
        if description.contains("audio is on") { return false }
        if description.contains("audio is off") { return true }
        return nil
    }

    /// The speaking class sits on a node that only exists while it is set.
    ///
    /// Measured behaviour, so the timeline knows what it is holding: at most one
    /// tile carries it at a time, it moves between tiles atomically, and it
    /// releases about 1.5 s after the voice stops. That makes it a turn, not a
    /// voice-activity flag, and overlapping speech is invisible to it.
    public static func isSpeaking(classList: String) -> Bool {
        classList.contains(speakingClass)
    }
}
