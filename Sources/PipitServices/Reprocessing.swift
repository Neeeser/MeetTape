import Foundation
import PipitCore

/// Puts a finished meeting back to the point where processing starts, so the
/// pipeline runs cleaning, transcription and diarization over it again.
///
/// The recording and the manifest are never touched. What goes is what was
/// derived from them: the raw and assembled transcripts, the diarization, the
/// speech evidence, the cleaned microphone, the alignments, the model
/// responses, the markdown and the summary. The speaker map stays, because it
/// holds the names a person typed and the line corrections they made, and the
/// pipeline reads those back the way it does after a re-analysis.
public enum Reprocessing {
    /// What was on disk before the reset, for a caller that wants a copy.
    public static func derivedFiles(in layout: MeetingLayout) -> [URL] {
        [
            layout.rawTranscript, layout.canonicalTranscript, layout.rawDiarization,
            layout.speechEvidence, layout.speakerMap, layout.speakerSuggestions,
            layout.alignments, layout.apiResponses, layout.transcriptMarkdown,
            layout.summary, layout.cleanedMicFile,
        ]
    }

    /// Copies every derived file that exists into `directory`, keeping the
    /// meeting folder's own layout under it.
    public static func backUp(store: MeetingStore, to directory: URL) throws {
        let root = store.layout.root
        for url in derivedFiles(in: store.layout) + [store.layout.metadata] {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let relative = url.path.dropFirst(root.path.count + 1)
            let destination = directory.appendingPathComponent(String(relative))
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: url, to: destination)
        }
    }

    /// Removes the derived files and rewinds the processing state.
    ///
    /// Returns the metadata as written. The speaker map is kept on disk, and
    /// the cleaned microphone's record is cleared so the cleaner runs again
    /// from the recording.
    @discardableResult
    public static func reset(store: MeetingStore, now: Date = Date()) throws -> MeetingMetadata {
        var metadata = try store.readMetadata()
        for url in derivedFiles(in: store.layout) where url != store.layout.speakerMap {
            try? FileManager.default.removeItem(at: url)
        }
        metadata.processing = ProcessingStatus(state: .audioSafe, updatedAt: now)
        metadata.cleanedMic = nil
        metadata.cleaningOutcome = nil
        try store.writeMetadata(metadata)
        return metadata
    }
}
