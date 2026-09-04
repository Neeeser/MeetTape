import Foundation
import PipitCore
import PipitLocalAI
import PipitServices

/// Measures one meeting folder and prints what the speech gate makes of every
/// segment on the local user's track.
///
/// The developer tool for checking the numbers in `LocalSpeechPolicy` again on
/// real audio. It reads a meeting, runs the detector and the level pass, and
/// reports the measures beside each segment with the verdict, so a threshold
/// change can be looked at rather than argued about.
///
/// Writes nothing. The evidence it builds is thrown away with the process.
enum GateCommand {
    static func run(meeting: URL, applicationSupport: URL) async -> Int32 {
        let store = MeetingStore(layout: MeetingLayout(root: meeting))
        let metadata: MeetingMetadata
        let raw: RawTranscript
        let timeline: RecordingTimeline
        do {
            metadata = try store.readMetadata()
            raw = try store.readRawTranscriptForAssembly()
            timeline = try store.readTimeline()
        } catch {
            FileHandle.standardError.write(Data("cannot read \(meeting.path): \(error)\n".utf8))
            return 1
        }

        let manager = LocalModelManager(applicationSupport: applicationSupport)
        do {
            _ = try await manager.install(units: [.voiceActivity])
        } catch {
            FileHandle.standardError.write(Data("detector unavailable: \(error)\n".utf8))
        }

        let evidence: SpeechEvidence
        do {
            evidence = try await SpeechEvidenceBuilder.build(
                store: store, metadata: metadata, timeline: timeline,
                detector: FluidAudioVoiceActivityBackend(models: manager)
            )
        } catch {
            FileHandle.standardError.write(Data("cannot measure: \(error)\n".utf8))
            return 1
        }

        print("meeting         \(metadata.id)")
        print("detector        \(evidence.detector ?? "none")")
        print("level window    \(evidence.levelWindowSeconds)s over \(evidence.micLevels.count) samples")
        print("speech window   \(evidence.speechWindowSeconds)s over \(evidence.micSpeech.count) samples")
        print("")
        print("    start      end   voice    mic    far  verdict  text")

        var kept = 0
        var dropped = 0
        for chunk in raw.chunks(track: .mic, purpose: .words) {
            for segment in chunk.segments.sorted(by: { $0.start < $1.start }) {
                let start = chunk.timelineOffset + segment.start
                let end = chunk.timelineOffset + segment.end
                let text = segment.text.trimmingCharacters(in: .whitespaces)
                // A segment the evidence does not cover is one the assembler
                // keeps, so it is counted here as kept. Skipping it made the
                // totals disagree with the transcript they are meant to explain.
                guard let reading = evidence.reading(from: start, to: end) else {
                    kept += 1
                    print(String(
                        format: "%9.2f %8.2f  %6@ %6@ %6@  %-7@  %@",
                        start, end, "-" as NSString, "-" as NSString, "-" as NSString,
                        "keep" as NSString,
                        String(text.prefix(60))
                    ))
                    continue
                }
                let decision = LocalSpeechPolicy.decide(text: text, reading: reading)
                if decision == .spoken { kept += 1 } else { dropped += 1 }
                print(String(
                    format: "%9.2f %8.2f  %6.3f %6.1f %6.1f  %-7@  %@",
                    start, end, reading.speechProbability ?? -1, reading.loudestLocalDB,
                    reading.loudestFarDB ?? 0,
                    decision == .spoken ? "keep" : "DROP" as NSString,
                    String(text.prefix(60))
                ))
            }
        }
        print("")
        print("kept            \(kept)")
        print("dropped         \(dropped)")
        return 0
    }
}
