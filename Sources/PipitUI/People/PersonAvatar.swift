import PipitCore
import SwiftUI

/// The colour a person is drawn in, everywhere they appear.
///
/// Mixed by hand rather than through `hashValue`, which Swift seeds per process:
/// the colour changed on every launch, which is the one thing a colour used for
/// recognition must not do.
enum PersonTint {
    static let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green, .brown]

    /// Keyed on the identity where there is one, and on the name otherwise, so
    /// the same person is the same colour in the people list, the meetings list
    /// and the transcript.
    static func color(identity: IdentityID?, name: String = "") -> Color {
        if let identity { return colour(of: UInt64(bitPattern: identity.rawValue)) }
        guard !name.isEmpty else { return .secondary }
        var bits: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in name.utf8 {
            bits = (bits ^ UInt64(byte)) &* 0x1000_0000_01b3
        }
        return colour(of: bits)
    }

    private static func colour(of seed: UInt64) -> Color {
        var bits = seed
        bits = (bits ^ (bits >> 33)) &* 0xff51_afd7_ed55_8ccd
        bits = (bits ^ (bits >> 33)) &* 0xc4ce_b9fe_1a85_ec53
        return palette[Int((bits ^ (bits >> 33)) % UInt64(palette.count))]
    }

    /// Up to two letters, the same rule `Identity.initials` uses.
    static func initials(of name: String) -> String {
        let words = name.split(separator: " ").filter { !$0.isEmpty }
        return String(words.prefix(2).compactMap { $0.first }).uppercased()
    }
}

/// A person's picture, or their initials, with their platform badge on the
/// corner.
///
/// Initials on a colour derived from the identifier mean nobody has to set a
/// picture for the list to be scannable, and the same person keeps the same
/// colour in every window.
struct PersonAvatar: View {
    let identity: Identity
    let image: NSImage?
    var side: CGFloat = 26
    var showsBadge = true

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            base
                .frame(width: side, height: side)
                .clipShape(Circle())
            if showsBadge, let badge = identity.badges.first {
                Image(systemName: badge.symbolName)
                    .font(.system(size: side * 0.36))
                    .foregroundStyle(.secondary)
                    .padding(side * 0.06)
                    .background(Circle().fill(.background))
                    .offset(x: side * 0.1, y: side * 0.1)
                    .accessibilityLabel(badge.label)
            }
        }
        .frame(width: side, height: side)
    }

    @ViewBuilder private var base: some View {
        if let image {
            Image(nsImage: image).resizable().scaledToFill()
        } else {
            SpeakerFace(
                name: identity.isNamed ? identity.resolvedName : "",
                identityID: identity.id, side: side
            )
        }
    }
}

/// One speaker as a circle, drawn from a name and an identifier rather than
/// from a whole identity.
///
/// The meetings list draws these for every meeting on disk. Reading an identity
/// per speaker would be one database query per row, so the list works from the
/// name and identifier already in the meeting's own speaker map.
struct SpeakerFace: View {
    /// Empty for a voice nobody has named.
    let name: String
    var identityID: IdentityID?
    var side: CGFloat = 26

    var body: some View {
        let initials = PersonTint.initials(of: name)
        Circle()
            .fill(initials.isEmpty ? AnyShapeStyle(.quaternary) : AnyShapeStyle(tint.opacity(0.22)))
            .frame(width: side, height: side)
            .overlay {
                if initials.isEmpty {
                    // An unnamed voice has no initials to take, and its number
                    // in a circle reads as a label rather than as a person.
                    Image(systemName: "waveform")
                        .font(.system(size: side * 0.42))
                        .foregroundStyle(.secondary)
                } else {
                    Text(initials)
                        .font(.system(size: side * 0.38, weight: .medium))
                        .foregroundStyle(tint)
                }
            }
            .accessibilityLabel(name.isEmpty ? "Unnamed voice" : name)
    }

    private var tint: Color { PersonTint.color(identity: identityID, name: name) }
}
