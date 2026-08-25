import Foundation
import PipitCore
import PipitIntegrations
import TestKit

/// Opt-in tests that talk to the real API.
///
/// Skipped unless `PIPIT_LIVE_OPENAI=1` and `OPENAI_API_KEY` are both set, so
/// an ordinary run costs nothing. The audio is synthesised locally by
/// `scripts/make-live-fixture.sh`, which keeps the fixture free and reproducible;
/// only the requests are live.
enum LiveOpenAITests {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["PIPIT_LIVE_OPENAI"] == "1"
    }

    static var fixtureDirectory: URL? {
        if let path = ProcessInfo.processInfo.environment["PIPIT_LIVE_FIXTURE"] {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// Synthesised speech transcribes with some variation, so assertions count how
    /// many expected terms survived rather than demanding one exact word.
    static func mentions(_ text: String, atLeast count: Int, of terms: [String]) -> Bool {
        terms.filter { text.localizedCaseInsensitiveContains($0) }.count >= count
    }

    static let expectedTerms = [
        "replica", "provision", "capacity", "rollback", "runbook",
        "production", "staging", "morning", "twenty",
    ]

    static func requireLive() throws -> (client: OpenAIClient, fixtures: URL) {
        guard isEnabled else {
            throw TestSkip("set PIPIT_LIVE_OPENAI=1 to run live API tests")
        }
        let store = EnvironmentAPIKeyStore()
        guard (try? store.apiKey()) != nil else {
            throw TestSkip("OPENAI_API_KEY is not set")
        }
        guard let fixtures = fixtureDirectory,
              FileManager.default.fileExists(atPath: fixtures.appendingPathComponent("conversation.wav").path)
        else {
            throw TestSkip("run scripts/make-live-fixture.sh and set PIPIT_LIVE_FIXTURE")
        }
        return (OpenAIClient(keyProvider: store), fixtures)
    }

    static var suite: Suite {
        Suite("LiveOpenAI", [
            test("the key and the diarization model are both reachable") { expect in
                let (client, _) = try requireLive()
                try await client.verifyCredentials(model: AIModelSettings().diarization)
                // An invalid key must fail loudly rather than silently degrade.
                let broken = OpenAIClient(keyProvider: StaticKey(value: "sk-not-a-real-key"))
                await expect.throwsError {
                    try await broken.verifyCredentials(model: AIModelSettings().diarization)
                }
            },

            test("transcription returns the segment timings the timeline needs") { expect in
                let (client, fixtures) = try requireLive()
                let response = try await client.transcribe(TranscriptionRequest(
                    audio: fixtures.appendingPathComponent("conversation.mic.wav"),
                    model: AIModelSettings().transcription
                ))
                expect.isTrue(!response.segments.isEmpty, "no segments returned")
                expect.isTrue(
                    mentions(response.text, atLeast: 2, of: expectedTerms),
                    "transcript does not look like the fixture: \(response.text.prefix(200))"
                )
                for segment in response.segments {
                    expect.isTrue(segment.end >= segment.start, "segment times are inverted")
                }
                expect.isTrue(
                    (response.segments.last?.end ?? 0) > 5,
                    "timings should span the recording"
                )
            },

            test("diarization separates the remote speakers") { expect in
                let (client, fixtures) = try requireLive()
                let response = try await client.diarize(DiarizationRequest(
                    audio: fixtures.appendingPathComponent("conversation.remote.wav"),
                    model: AIModelSettings().diarization
                ))
                let labels = Set(response.segments.compactMap(\.speaker))
                expect.isTrue(
                    labels.count >= 2,
                    "expected at least two remote speakers, got \(labels.sorted())"
                )
                expect.isTrue(
                    mentions(response.text, atLeast: 3, of: expectedTerms),
                    "transcript does not look like the fixture: \(response.text.prefix(200))"
                )
            },

            test("the assembled transcript keeps the local speaker separate") { expect in
                let (client, fixtures) = try requireLive()
                async let micResponse = client.transcribe(TranscriptionRequest(
                    audio: fixtures.appendingPathComponent("conversation.mic.wav"),
                    model: AIModelSettings().transcription
                ))
                async let remoteResponse = client.diarize(DiarizationRequest(
                    audio: fixtures.appendingPathComponent("conversation.remote.wav"),
                    model: AIModelSettings().diarization
                ))
                let (mic, remote) = try await (micResponse, remoteResponse)

                let raw = RawTranscript(chunks: [
                    RawTranscriptChunk(
                        id: "mic_chunk_001", track: .mic, timelineOffset: 0,
                        durationSeconds: 40, model: AIModelSettings().transcription,
                        responseFormat: "verbose_json", segments: mic.segments
                    ),
                    RawTranscriptChunk(
                        id: "remote_chunk_001", track: .remote, timelineOffset: 0,
                        durationSeconds: 40, model: AIModelSettings().diarization,
                        responseFormat: "diarized_json", segments: remote.segments
                    ),
                ])
                let transcript = TranscriptAssembler().assemble(
                    raw: raw, micTrackIsLocalUser: true, generatedAt: Date()
                )
                let micUtterances = transcript.utterances.filter { $0.track == .mic }
                expect.isTrue(!micUtterances.isEmpty)
                for utterance in micUtterances {
                    expect.equal(
                        utterance.speakerKey, SpeakerLabel.localUser,
                        "the microphone track is the local user by construction"
                    )
                }
                let remoteKeys = Set(
                    transcript.utterances.filter { $0.track == .remote }.map(\.speakerKey)
                )
                expect.isTrue(remoteKeys.count >= 2, "got remote speakers \(remoteKeys.sorted())")
                for key in remoteKeys {
                    expect.isTrue(key.hasPrefix("remote_chunk_001_speaker_"), "unexpected key \(key)")
                }
            },

            test("speaker resolution names the remote speakers from their introductions") { expect in
                let (client, fixtures) = try requireLive()
                let remote = try await client.diarize(DiarizationRequest(
                    audio: fixtures.appendingPathComponent("conversation.remote.wav"),
                    model: AIModelSettings().diarization
                ))
                let raw = RawTranscript(chunks: [
                    RawTranscriptChunk(
                        id: "remote_chunk_001", track: .remote, timelineOffset: 0,
                        durationSeconds: 40, model: AIModelSettings().diarization,
                        responseFormat: "diarized_json", segments: remote.segments
                    ),
                ])
                let transcript = TranscriptAssembler().assemble(
                    raw: raw, micTrackIsLocalUser: true, generatedAt: Date()
                )
                let renderer = TranscriptRenderer()
                let anonymous = transcript.utterances
                    .map { "[\(renderer.timecode($0.start))] \($0.speakerKey): \($0.text)" }
                    .joined(separator: "\n")

                let suggestions = try await client.resolveSpeakers(
                    SpeakerResolutionRequest(
                        transcript: anonymous,
                        labels: transcript.speakerKeys,
                        humanContext: "Call with me (Andrew), my boss Chris, and Tim from the platform team.",
                        calendarAttendees: [],
                        browserParticipants: [],
                        localUserName: "Andrew"
                    ),
                    model: AIModelSettings().metadata
                )
                let names = Set(suggestions.map { $0.name.split(separator: " ").first.map(String.init) ?? $0.name })
                expect.isTrue(names.contains("Chris"), "expected Chris among \(names.sorted())")
                expect.isTrue(names.contains("Tim"), "expected Tim among \(names.sorted())")
                for suggestion in suggestions {
                    expect.isTrue(
                        transcript.speakerKeys.contains(suggestion.label),
                        "suggested a label that is not in the transcript: \(suggestion.label)"
                    )
                }
            },

            test("enrichment writes a title and a summary from the transcript") { expect in
                let (client, fixtures) = try requireLive()
                let response = try await client.transcribe(TranscriptionRequest(
                    audio: fixtures.appendingPathComponent("conversation.wav"),
                    model: AIModelSettings().transcription
                ))
                let enrichment = try await client.enrich(
                    EnrichmentRequest(
                        transcript: response.text,
                        humanNotes: nil,
                        participants: ["Andrew", "Chris", "Tim"],
                        provider: .googleMeet,
                        durationSeconds: 40,
                        wantsTitle: true,
                        wantsDescription: false,
                        wantsSummary: true,
                        wantsNotes: true
                    ),
                    model: AIModelSettings().metadata
                )
                let title = try expect.unwrap(enrichment.title)
                expect.isTrue(!title.isEmpty)
                expect.isTrue(title.count < 80, "a title should be short, got: \(title)")
                let summary = try expect.unwrap(enrichment.summary)
                expect.isTrue(summary.count > 40, "summary looks empty")
            },
        ])
    }
}

struct StaticKey: APIKeyProviding {
    let value: String
    func apiKey() throws -> String { value }
}
