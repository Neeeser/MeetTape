import Foundation

/// A conferencing provider Pipit can recognise. `unknown` covers a detected
/// call in an application Pipit has no adapter for.
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

    /// What a list row calls this source, which is shorter than `displayName`
    /// for three of the eight.
    ///
    /// The row spends a 272 point sidebar on the source, the date, the duration
    /// and sometimes a state, so "Imported recording · Aug 30, 11:20 AM ·
    /// 1h 12m" ran off the end. `displayName` stays as it is because folder
    /// names on disk are built from it and they are already written.
    public var listName: String {
        switch self {
        case .manual: "Manual"
        case .inPerson: "In person"
        case .imported: "Imported"
        case .slackHuddle, .googleMeet, .zoom, .faceTime, .genericCall: displayName
        }
    }

    /// The glyph a list draws for this kind of recording, one per source.
    ///
    /// Not a vendor's own mark, which is unreadable at 13 points and not ours
    /// to draw. Each of these is the nearest shape that reads at badge size,
    /// the way `PersonBadge` picks one for a platform. They are all different
    /// from each other on purpose: five of them drew the same camera, and a row
    /// could not say whether a call had been a huddle or a Zoom.
    public var symbolName: String {
        switch self {
        case .slackHuddle: "headphones"
        case .googleMeet: "video.fill"
        case .zoom: "square.grid.2x2.fill"
        case .faceTime: "person.crop.rectangle.fill"
        case .genericCall: "phone.fill"
        case .manual: "waveform"
        case .inPerson: "mic"
        case .imported: "tray.and.arrow.down"
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

/// Browsers Pipit can accept sensor events from.
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
