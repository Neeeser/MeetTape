import AppKit
import PipitCore

/// The mark a source draws, where that source is somebody else's product and
/// this Mac has it installed.
///
/// Read from the installed copy rather than redrawn. A logo copied by eye is
/// somebody else's trademark, and it is wrong at 26 points besides. Nothing is
/// committed to the repository this way: the artwork belongs to the application
/// and the system renders it.
///
/// A source with no mark falls back to the glyph and tint the enum carries, so
/// the list is complete on a Mac with nothing installed.
@MainActor
public enum SourceMark {
    /// The application a source is recorded from.
    ///
    /// Slack alone. FaceTime's mark is a plain video camera once its plate
    /// comes off, which is the glyph already, and Zoom's would appear only on
    /// the Macs that have Zoom installed. Google Meet runs in a browser and has
    /// no application at all, and drawing the browser's icon would put a
    /// Firefox mark on a row that means Meet.
    public nonisolated static func bundleIdentifier(for source: MeetingSource) -> String? {
        switch source {
        case .slackHuddle: "com.tinyspeck.slackmacgap"
        case .googleMeet, .zoom, .faceTime, .genericCall, .manual, .inPerson, .imported: nil
        }
    }

    /// The application's mark, plate removed, or nil where this Mac does not
    /// have the application.
    ///
    /// Looked up once per source. `NSWorkspace` reads the disk and the keying
    /// walks sixty-five thousand pixels, while the sidebar redraws on every
    /// keystroke. An application installed while Pipit is running is picked up
    /// at the next launch, which is the price of not doing that mid-scroll.
    public static func icon(for source: MeetingSource) -> NSImage? {
        // The outer optional says whether the lookup has happened. Assigning
        // nil to a dictionary removes the key, so an absent application is
        // recorded with `updateValue` instead and is not looked up again.
        if let known = cache[source] { return known }
        guard let identifier = bundleIdentifier(for: source),
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier),
            let keyed = plateRemoved(NSWorkspace.shared.icon(forFile: url.path))
        else {
            cache.updateValue(nil, forKey: source)
            return nil
        }
        cache.updateValue(keyed, forKey: source)
        return keyed
    }

    /// The mark inside an application icon, with the icon's own coloured plate
    /// taken off.
    ///
    /// An application icon is a mark sitting on a filled rounded square. Drawn
    /// whole, that square fights the sidebar: Slack's is white and glares
    /// against a dark window. Keyed, the mark sits on the source's own tint
    /// like every other row.
    ///
    /// Two passes. The first floods out from points that land on the plate
    /// rather than the mark, so white inside a mark survives while the white
    /// plate behind it does not. The second comes in from the edges and takes
    /// what the first leaves: the plate's anti-aliased rim and the drop shadow
    /// the system draws under every icon, which together read as a ghost
    /// outline around the mark. The mark itself is opaque, so the second pass
    /// stops on it.
    ///
    /// Nil when the icon is empty or has no plate to seed from.
    public static func plateRemoved(_ image: NSImage, raster: Int = 256) -> NSImage? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: raster, pixelsHigh: raster,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: raster * 4, bitsPerPixel: 32
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: raster, height: raster))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.bitmapData else { return nil }

        func pixel(_ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double, a: Double) {
            let offset = y * rep.bytesPerRow + x * 4
            return (Double(data[offset]) / 255, Double(data[offset + 1]) / 255,
                    Double(data[offset + 2]) / 255, Double(data[offset + 3]) / 255)
        }
        // Colour as well as alpha. The buffer is premultiplied, so a pixel left
        // white with alpha zero is not transparent white, it is invalid, and
        // CoreGraphics draws it back at full strength when the mark is scaled
        // into the badge. Measured: the plate returned in full.
        func clear(_ x: Int, _ y: Int) {
            let offset = y * rep.bytesPerRow + x * 4
            data[offset] = 0
            data[offset + 1] = 0
            data[offset + 2] = 0
            data[offset + 3] = 0
        }

        // Points that land on the plate rather than on a centred mark.
        let onThePlate: [(Double, Double)] = [
            (0.5, 0.06), (0.5, 0.94), (0.06, 0.5), (0.94, 0.5),
            (0.16, 0.16), (0.84, 0.16), (0.16, 0.84), (0.84, 0.84),
        ]
        var seeds: [(Int, Int)] = []
        var samples: [(Double, Double, Double)] = []
        for (fx, fy) in onThePlate {
            let x = Int(fx * Double(raster - 1)), y = Int(fy * Double(raster - 1))
            let sample = pixel(x, y)
            guard sample.a > 0.5 else { continue }
            seeds.append((x, y))
            samples.append((sample.r, sample.g, sample.b))
        }
        guard !samples.isEmpty else { return nil }
        let count = Double(samples.count)
        let plate = (
            samples.map(\.0).reduce(0, +) / count,
            samples.map(\.1).reduce(0, +) / count,
            samples.map(\.2).reduce(0, +) / count
        )

        let tolerance = 0.22
        var seen = [Bool](repeating: false, count: raster * raster)
        var queue = seeds
        for (x, y) in seeds { seen[y * raster + x] = true }
        while let (x, y) = queue.popLast() {
            clear(x, y)
            for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, nx < raster, ny >= 0, ny < raster, !seen[ny * raster + nx]
                else { continue }
                let sample = pixel(nx, ny)
                guard sample.a > 0.02 else { seen[ny * raster + nx] = true; continue }
                let distance = max(
                    abs(sample.r - plate.0), max(abs(sample.g - plate.1), abs(sample.b - plate.2))
                )
                guard distance <= tolerance else { continue }
                seen[ny * raster + nx] = true
                queue.append((nx, ny))
            }
        }

        var outside = [Bool](repeating: false, count: raster * raster)
        var edge: [(Int, Int)] = []
        for i in 0..<raster {
            for point in [(i, 0), (i, raster - 1), (0, i), (raster - 1, i)]
            where !outside[point.1 * raster + point.0] {
                outside[point.1 * raster + point.0] = true
                edge.append(point)
            }
        }
        while let (x, y) = edge.popLast() {
            clear(x, y)
            for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, nx < raster, ny >= 0, ny < raster, !outside[ny * raster + nx]
                else { continue }
                guard pixel(nx, ny).a < 0.92 else { continue }
                outside[ny * raster + nx] = true
                edge.append((nx, ny))
            }
        }

        // Nothing survived, so there was no mark to find and the glyph is the
        // better answer. An empty badge says less than the glyph it replaced.
        var kept = 0
        for y in stride(from: 0, to: raster, by: 2) {
            for x in stride(from: 0, to: raster, by: 2) where pixel(x, y).a > 0.5 { kept += 1 }
        }
        guard kept > raster * raster / 400 else { return nil }

        let mark = NSImage(size: NSSize(width: raster, height: raster))
        mark.addRepresentation(rep)
        return mark
    }

    private static var cache: [MeetingSource: NSImage?] = [:]
}
