import Foundation

/// The committed description of the benchmark data: where the audio comes from,
/// what it must hash to, and which meetings each suite runs.
///
/// One file, read by `scripts/fetch-bench-audio.sh` and by the harness, because
/// two copies of a checksum list drift.
public struct BenchManifest: Codable, Sendable, Equatable {
    /// The AMI mirror template, taking the meeting identifier twice.
    public var mirror: String
    /// Full download URL for a recording the mirror template does not name,
    /// which is every ICSI and NOTSOFAR meeting: the corpora publish under
    /// different paths and under different file names.
    public var audioURL: [String: String]?
    /// The local file name a download is saved under when the URL's own last
    /// component would collide: every NOTSOFAR recording is published as
    /// `ch0.wav` inside its meeting's folder. Absent means the URL's last
    /// component, which is what the ground truth names as its source.
    public var audioFilename: [String: String]?
    /// Corpus name to the annotations archive its truth is generated from.
    public var annotations: [String: Archive]
    /// Meeting identifier to SHA-256 of its Mix-Headset recording.
    public var audio: [String: String]
    /// Suite name to the meetings it runs, in order.
    public var suites: [String: [String]]
    /// Meeting identifier to where it sits relative to model training data:
    /// `ami-train`, `ami-dev` and `ami-eval` follow AMI's published
    /// full-corpus-ASR split, `excluded` is a meeting that split leaves out,
    /// and `clean` is a corpus with no known presence in any candidate's
    /// training data. Parakeet's model card lists AMI among its training
    /// corpora, so a suite that ranks engines may hold only `ami-eval` and
    /// `clean` meetings; the rest regression-test a fixed engine against
    /// itself, where contamination sits on both sides of the comparison.
    public var partition: [String: String]?

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
