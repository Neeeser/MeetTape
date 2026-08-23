import MeetTapeCore
import SwiftUI

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
        } else if identity.initials.isEmpty {
            // An unnamed voice has no initials to take, and its number in a
            // circle reads as a label rather than as a person.
            Circle().fill(.quaternary).overlay {
                Image(systemName: "waveform")
                    .font(.system(size: side * 0.42))
                    .foregroundStyle(.secondary)
            }
        } else {
            Circle().fill(tint.opacity(0.22)).overlay {
                Text(identity.initials)
                    .font(.system(size: side * 0.38, weight: .medium))
                    .foregroundStyle(tint)
            }
        }
    }

    /// Stable per identity, so a person is the same colour everywhere and across
    /// launches.
    ///
    /// Mixed by hand rather than through `hashValue`, which Swift seeds per
    /// process: the colour changed on every launch, which is the one thing a
    /// colour used for recognition must not do.
    private var tint: Color {
        let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green, .brown]
        var bits = UInt64(bitPattern: identity.id.rawValue)
        bits = (bits ^ (bits >> 33)) &* 0xff51_afd7_ed55_8ccd
        bits = (bits ^ (bits >> 33)) &* 0xc4ce_b9fe_1a85_ec53
        return palette[Int((bits ^ (bits >> 33)) % UInt64(palette.count))]
    }
}
