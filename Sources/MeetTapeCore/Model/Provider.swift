import Foundation

/// A conferencing provider MeetTape can recognise. `unknown` covers a detected
/// call in an application MeetTape has no adapter for.
public enum MeetingProvider: String, Codable, Sendable, CaseIterable {
    case slack
    case googleMeet = "google_meet"
    case zoom
    case faceTime = "facetime"
    case unknown

    public var displayName: String {
        switch self {
        case .slack: "Slack Huddle"
        case .googleMeet: "Google Meet"
        case .zoom: "Zoom"
        case .faceTime: "FaceTime"
        case .unknown: "Call"
        }
    }
}

/// How a recording came to exist. Downstream processing is identical for all of
/// them; only capture differs, and only `inPerson` and `imported` have no remote
/// track by construction.
public enum MeetingSource: String, Codable, Sendable, CaseIterable {
    case slackHuddle = "slack_huddle"
    case googleMeet = "google_meet"
    case zoom
    case faceTime = "facetime"
    case genericCall = "generic_call"
    case manual
    case inPerson = "in_person"
    case imported

    public var capturesRemoteAudio: Bool {
        switch self {
        case .inPerson, .imported: false
        case .slackHuddle, .googleMeet, .zoom, .faceTime, .genericCall, .manual: true
        }
    }

    /// True when the microphone track is the local user by construction.
    ///
    /// A remote meeting has two tracks and the microphone is only ever the person
    /// holding it, so diarizing it would be wasted effort and a source of error.
    /// An in-person or imported recording has one track holding everyone, so its
    /// raw diarization labels are kept.
    public var micTrackIsLocalUser: Bool {
        switch self {
        case .inPerson, .imported: false
        case .slackHuddle, .googleMeet, .zoom, .faceTime, .genericCall, .manual: true
        }
    }

    public var provider: MeetingProvider {
        switch self {
        case .slackHuddle: .slack
        case .googleMeet: .googleMeet
        case .zoom: .zoom
        case .faceTime: .faceTime
        case .genericCall, .manual, .inPerson, .imported: .unknown
        }
    }

    public var displayName: String {
        switch self {
        case .slackHuddle: "Slack Huddle"
        case .googleMeet: "Google Meet"
        case .zoom: "Zoom"
        case .faceTime: "FaceTime"
        case .genericCall: "Call"
        case .manual: "Manual recording"
        case .inPerson: "In-person meeting"
        case .imported: "Imported recording"
        }
    }
}

/// Which capture stream a segment or utterance belongs to. The distinction is
/// load-bearing: the microphone track is the local user by construction, so it is
/// never diarized.
public enum CaptureTrack: String, Codable, Sendable, CaseIterable {
    case mic
    case remote

    /// Segment filenames use `system` for the remote track, matching the
    /// documented archive layout. The internal name stays `remote` because the
    /// health model for it is about a tapped application, not about the system.
    public var segmentPrefix: String {
        switch self {
        case .mic: "mic"
        case .remote: "system"
        }
    }

    public var displayName: String {
        switch self {
        case .mic: "Microphone"
        case .remote: "Meeting audio"
        }
    }
}

/// Browsers MeetTape can accept sensor events from.
public enum BrowserKind: String, Codable, Sendable, CaseIterable {
    case firefox
    case chrome
    case safari
    case unknown

    public var bundleIdentifiers: [String] {
        switch self {
        case .firefox: ["org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly"]
        case .chrome: ["com.google.Chrome", "com.google.Chrome.beta", "com.brave.Browser", "com.microsoft.edgemac"]
        case .safari: ["com.apple.Safari"]
        case .unknown: []
        }
    }
}
