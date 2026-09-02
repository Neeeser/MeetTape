import PipitCore
import SwiftUI

/// The colour a source draws its badge in.
///
/// Semantic colours rather than each vendor's own, for the reason `FolderTint`
/// uses them: a fixed value at 18 percent fill goes muddy against a dark
/// sidebar, and the glyph is what says which service a recording came from.
/// The colour only has to separate one row from the next.
public enum SourceTint {
    public static func color(_ source: MeetingSource) -> Color {
        switch source {
        case .slackHuddle: .purple
        case .googleMeet: .green
        case .zoom: .blue
        case .faceTime: .mint
        case .genericCall: .indigo
        case .manual: .teal
        case .inPerson: .orange
        case .imported: .secondary
        }
    }
}
