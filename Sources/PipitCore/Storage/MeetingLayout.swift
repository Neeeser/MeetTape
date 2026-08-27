import Foundation

/// Every path inside one meeting directory.
///
/// The archive is ordinary files in ordinary folders. Deleting Pipit leaves a
/// readable recording, a readable transcript and readable notes behind.
///
/// The root holds only files a person opens directly: the transcript, the
/// recording, the summary and the notes. Everything the application maintains
/// lives under `raw/`.
public struct MeetingLayout: Sendable, Equatable {
    public let root: URL

    public init(root: URL) { self.root = root }

    /// Application-maintained files: metadata, manifests, source audio, model
    /// output. Users read the root; tooling reads here.
    public var raw: URL { root.appendingPathComponent("raw", isDirectory: true) }

    public var segments: URL { raw.appendingPathComponent("segments", isDirectory: true) }
    /// Outside `segments/` because compaction deletes that directory and the
    /// manifest is the durable record of the recording timeline.
    public var manifest: URL { raw.appendingPathComponent("manifest.jsonl") }
    public var metadata: URL { raw.appendingPathComponent("metadata.json") }
    public var rawTranscript: URL { raw.appendingPathComponent("transcript.raw.json") }
    /// Who spoke when, as the diarizer produced it. Immutable, and separate from
    /// the words because the two come from independently chosen backends and
    /// re-analysing speakers must never invalidate a transcription.
    public var rawDiarization: URL { raw.appendingPathComponent("diarization.raw.json") }
    /// What the recorded audio holds, sampled on a fixed grid. Derived from
    /// audio that never changes, so it is written once and read on every
    /// assembly rather than measured again.
    public var speechEvidence: URL { raw.appendingPathComponent("speech.json") }
    public var speakerMap: URL { raw.appendingPathComponent("speakers.map.json") }
    /// Names the cloud model proposes for speakers the meeting could not name.
    /// Deliberately not part of `speakers.map.json`: that file is what the
    /// meeting concluded, and a proposal is not a conclusion.
    public var speakerSuggestions: URL { raw.appendingPathComponent("speaker.suggestions.json") }
    /// What the meeting client said about the call: the roster, who was seen
    /// unmuted, and who held the floor when. Immutable like the diarization beside it,
    /// because it is evidence about a recording rather than a conclusion about
    /// one, and re-analysing speakers reads it again.
    public var rawSensors: URL { raw.appendingPathComponent("sensors.raw.json") }
    public var canonicalTranscript: URL { raw.appendingPathComponent("transcript.json") }
    public var transcriptMarkdown: URL { root.appendingPathComponent("transcript.md") }
    public var notes: URL { root.appendingPathComponent("notes.md") }
    public var summary: URL { root.appendingPathComponent("summary.md") }
    /// The listenable mixdown of both tracks.
    public var recordingAudio: URL { root.appendingPathComponent("recording.m4a") }
    /// Raw API responses, kept verbatim as ground truth for what the model said.
    public var apiResponses: URL { raw.appendingPathComponent("api", isDirectory: true) }
    /// Derived timings for chunks whose model returned text alone. Regenerable
    /// from the segments and the raw transcript, like every derived file, and
    /// application-maintained, so it lives under `raw/` rather than beside the
    /// files a person opens.
    public var alignments: URL { raw.appendingPathComponent("alignments", isDirectory: true) }
    /// Imported originals live here untouched.
    public var originals: URL { raw.appendingPathComponent("original", isDirectory: true) }
    /// Per-track archive files that replace the segment chain after compaction.
    public var trackArchiveDirectory: URL { raw.appendingPathComponent("audio", isDirectory: true) }

    public func trackArchiveFile(track: CaptureTrack) -> URL {
        trackArchiveDirectory.appendingPathComponent(trackArchiveFileName(track: track))
    }

    public func trackArchiveFileName(track: CaptureTrack) -> String {
        "\(track.segmentPrefix).m4a"
    }

    public func segmentFile(track: CaptureTrack, index: Int) -> URL {
        segments.appendingPathComponent(String(format: "%@.%04d.caf", track.segmentPrefix, index))
    }

    public func segmentFileName(track: CaptureTrack, index: Int) -> String {
        String(format: "%@.%04d.caf", track.segmentPrefix, index)
    }

    public func apiResponseFile(named name: String) -> URL {
        apiResponses.appendingPathComponent(name)
    }

    public func alignmentFile(chunkID: String) -> URL {
        alignments.appendingPathComponent("\(chunkID).json")
    }

    // MARK: - the layout before raw/ existed

    /// Where files lived before the `raw/` reorganisation: everything at the
    /// root, the manifest inside `segments/`, the mixdown as `mixed.caf`.
    /// `MeetingLayoutMigration` moves a folder forward; the metadata read path
    /// falls back here so an unmigrated folder still lists.
    public var legacyMetadata: URL { root.appendingPathComponent("metadata.json") }
    public var legacySegments: URL { root.appendingPathComponent("segments", isDirectory: true) }
    public var legacyManifest: URL { legacySegments.appendingPathComponent("manifest.jsonl") }
    public var legacyMixedAudio: URL { root.appendingPathComponent("mixed.caf") }
    public var legacyRawTranscript: URL { root.appendingPathComponent("transcript.raw.json") }
    public var legacyRawDiarization: URL { root.appendingPathComponent("diarization.raw.json") }
    public var legacySpeakerMap: URL { root.appendingPathComponent("speakers.map.json") }
    public var legacyCanonicalTranscript: URL { root.appendingPathComponent("transcript.json") }
    public var legacyAPIResponses: URL { root.appendingPathComponent("api", isDirectory: true) }
    public var legacyOriginals: URL { root.appendingPathComponent("original", isDirectory: true) }
}

/// Builds meeting directory identifiers and locates them under the archive root.
public struct MeetingArchiveLayout: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public static var defaultRoot: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Documents/Pipit/Meetings", isDirectory: true)
    }

    public func directory(forMeetingID id: String, startedAt: Date) -> URL {
        let components = Calendar.current.dateComponents([.year, .month], from: startedAt)
        let year = String(format: "%04d", components.year ?? 1970)
        let month = String(format: "%02d", components.month ?? 1)
        return root
            .appendingPathComponent(year, isDirectory: true)
            .appendingPathComponent(month, isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
    }

    public func layout(forMeetingID id: String, startedAt: Date) -> MeetingLayout {
        MeetingLayout(root: directory(forMeetingID: id, startedAt: startedAt))
    }

    /// `2026-08-18-1418-slack-engineering-huddle`
    public static func meetingID(startedAt: Date, source: MeetingSource, title: String?) -> String {
        let stamp = timestampSlug(startedAt)
        let sourceSlug = slugify(source.rawValue)
        let titleSlug = title.map { slugify($0) } ?? ""
        let parts = [stamp, sourceSlug, titleSlug].filter { !$0.isEmpty }
        return parts.joined(separator: "-")
    }

    public static func timestampSlug(_ date: Date) -> String {
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: date
        )
        return String(
            format: "%04d-%02d-%02d-%02d%02d",
            components.year ?? 1970, components.month ?? 1, components.day ?? 1,
            components.hour ?? 0, components.minute ?? 0
        )
    }

    /// Lowercase ASCII, hyphen separated, bounded length. Non-ASCII titles fold to
    /// their closest ASCII form so the directory name stays typeable.
    public static func slugify(_ text: String, maxLength: Int = 48) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US"))
        var out = ""
        var lastWasSeparator = true
        for character in folded {
            if character.isLetter || character.isNumber, character.isASCII {
                out.append(character)
                lastWasSeparator = false
            } else if !lastWasSeparator {
                out.append("-")
                lastWasSeparator = true
            }
            if out.count >= maxLength { break }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }

    /// A directory name that does not collide with an existing one.
    public func uniqueMeetingID(base: String, startedAt: Date) -> String {
        var candidate = base
        var suffix = 2
        while FileManager.default.fileExists(atPath: directory(forMeetingID: candidate, startedAt: startedAt).path) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        return candidate
    }
}
