import Foundation

/// The committed description of the benchmark data: where the audio comes from,
/// what it must hash to, and which meetings each suite runs.
///
/// One file, read by `scripts/fetch-bench-audio.sh` and by the harness, because
/// two copies of a checksum list drift.
public struct BenchManifest: Codable, Sendable, Equatable {
    /// Printf-style template taking the meeting identifier twice.
    public var mirror: String
    /// The annotations archive the truth is generated from.
    public var annotations: Archive
    /// Meeting identifier to SHA-256 of its Mix-Headset recording.
    public var audio: [String: String]
    /// Suite name to the meetings it runs, in order.
    public var suites: [String: [String]]

    public struct Archive: Codable, Sendable, Equatable {
        public var url: String
        public var sha256: String
    }

    public static func read(from url: URL) throws -> BenchManifest {
        try JSONDecoder().decode(BenchManifest.self, from: Data(contentsOf: url))
    }
}

/// Where the committed benchmark material lives, relative to a repository root.
public struct BenchLayout: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public var manifest: URL { root.appendingPathComponent("manifest.json") }
    public func truth(meeting: String) -> URL {
        root.appendingPathComponent("ground-truth/\(meeting).json")
    }
}
