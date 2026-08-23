import Foundation

/// Where a person is usually heard, shown as a small mark on their avatar.
///
/// A closed set rather than free text: the badge exists to be recognised at
/// 12 points, which means it has to map to an icon, and an icon needs a case to
/// map from. A platform nobody can draw is a platform nobody can read.
public enum PersonBadge: String, Codable, Sendable, CaseIterable, Identifiable {
    case slack
    case zoom
    case meet
    case teams
    case webex
    case discord
    case phone
    case inPerson = "in_person"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .slack: "Slack"
        case .zoom: "Zoom"
        case .meet: "Google Meet"
        case .teams: "Microsoft Teams"
        case .webex: "Webex"
        case .discord: "Discord"
        case .phone: "Phone"
        case .inPerson: "In person"
        }
    }

    /// None of these ship as a symbol under their own name, so each one is the
    /// nearest shape that reads at badge size.
    public var symbolName: String {
        switch self {
        case .slack: "number.square.fill"
        case .zoom: "video.fill"
        case .meet: "video.circle.fill"
        case .teams: "person.2.square.stack.fill"
        case .webex: "record.circle.fill"
        case .discord: "gamecontroller.fill"
        case .phone: "phone.fill"
        case .inPerson: "person.fill"
        }
    }
}
