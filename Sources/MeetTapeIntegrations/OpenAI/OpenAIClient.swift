import Foundation
import MeetTapeCore

/// Supplies the API key without holding it in memory longer than a request needs.
public protocol APIKeyProviding: Sendable {
    func apiKey() throws -> String
    /// Whether the store positively says there is no key, as opposed to being
    /// unable to answer. Defaults to "cannot say", so a provider that does not
    /// know keeps the stages attempting and failing visibly.
    var isKnownAbsent: Bool { get }
}

extension APIKeyProviding {
    public var isKnownAbsent: Bool { false }
}

public struct OpenAIClient: AIBackend {
    public struct Configuration: Sendable {
        public var baseURL: URL
        public var requestTimeout: TimeInterval
        /// Transcription of a 30-minute chunk took 79 s in measurement, and
        /// diarization is slower still, so the audio endpoints get a long window.
        public var audioTimeout: TimeInterval

        public init(
            baseURL: URL = URL(string: "https://api.openai.com/v1")!,
            requestTimeout: TimeInterval = 120,
            audioTimeout: TimeInterval = 900
        ) {
            self.baseURL = baseURL
            self.requestTimeout = requestTimeout
            self.audioTimeout = audioTimeout
        }
    }

    private let configuration: Configuration
    private let keyProvider: any APIKeyProviding
    private let session: URLSession

    public init(
        configuration: Configuration = Configuration(),
        keyProvider: any APIKeyProviding,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.keyProvider = keyProvider
        self.session = session
    }

    // MARK: - credentials

    /// Whether an optional cloud stage is worth attempting.
    ///
    /// False only when the store positively says no key was ever stored. A read
    /// that merely failed leaves this true, so the stage runs, fails visibly and
    /// offers a retry rather than completing the meeting with no title and no
    /// explanation. Proving the key works costs a request; this does not.
    public func isConfigured() async -> Bool {
        if (try? keyProvider.apiKey())?.isEmpty == false { return true }
        return !keyProvider.isKnownAbsent
    }

    /// Fetching one model description proves both the key and access to that
    /// model, costs nothing, and is what Settings uses for Test Connection.
    public func verifyCredentials(model: String) async throws {
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent("models/\(model)"))
        request.httpMethod = "GET"
        request.timeoutInterval = configuration.requestTimeout
        try authorize(&request)
        _ = try await perform(request)
    }

    // MARK: - audio

    public func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResponse {
        var fields: [(String, String)] = [("model", request.model)]
        let timing = AIModelSettings.transcriptionTiming(for: request.model)
        if AIModelSettings.diarizationChoices.contains(request.model) {
            // The diarize model transcribing a single track: same endpoint,
            // its own format, and the mandatory chunking flag.
            fields.append(("response_format", "diarized_json"))
            fields.append(("chunking_strategy", "auto"))
        } else {
            switch timing {
            case .text:
                // The timing-free models reject verbose_json outright.
                fields.append(("response_format", "json"))
                for keyword in request.keywords { fields.append(("keywords[]", keyword)) }
            case .words:
                fields.append(("response_format", "verbose_json"))
                fields.append(("timestamp_granularities[]", "segment"))
                fields.append(("timestamp_granularities[]", "word"))
            case .segments:
                fields.append(("response_format", "verbose_json"))
                fields.append(("timestamp_granularities[]", "segment"))
            }
        }
        if let language = request.language { fields.append(("language", language)) }
        // The diarize model rejects prompts; every other transcription model
        // takes one.
        if let prompt = request.prompt,
            !AIModelSettings.diarizationChoices.contains(request.model) {
            fields.append(("prompt", prompt))
        }

        let body = try await multipartBody(fields: fields, audio: request.audio, extraFiles: [])
        let data = try await postAudio(path: "audio/transcriptions", body: body)
        return try Self.parseTranscription(data, allowTextOnly: timing == .text)
    }

    public func diarize(_ request: DiarizationRequest) async throws -> TranscriptionResponse {
        var fields: [(String, String)] = [
            ("model", request.model),
            ("response_format", "diarized_json"),
            // The endpoint returns 400 without this.
            ("chunking_strategy", "auto"),
        ]
        for speaker in request.knownSpeakers {
            fields.append(("known_speaker_names[]", speaker.name))
            // Plain base64 is rejected: the value has to be a data URI.
            fields.append((
                "known_speaker_references[]",
                "data:audio/wav;base64,\(speaker.wavData.base64EncodedString())"
            ))
        }
        let body = try await multipartBody(fields: fields, audio: request.audio, extraFiles: [])
        let data = try await postAudio(path: "audio/transcriptions", body: body)
        return try Self.parseTranscription(data, allowTextOnly: false)
    }

    // MARK: - reasoning

    public func resolveSpeakers(
        _ request: SpeakerResolutionRequest, model: String
    ) async throws -> [SpeakerSuggestion] {
        let schema: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "mapping": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "properties": [
                            "label": ["type": "string"],
                            "name": ["type": "string"],
                            "confidence": ["type": "number"],
                            "evidence": ["type": "string"],
                        ],
                        "required": ["label", "name", "confidence", "evidence"],
                    ],
                ],
                "unresolved": ["type": "array", "items": ["type": "string"]],
            ],
            "required": ["mapping", "unresolved"],
        ]

        var context: [String] = []
        if let name = request.localUserName {
            context.append(
                "The local microphone track belongs to \(name), so their speech is already "
                    + "labelled and is not in this transcript."
            )
        }
        if let humanContext = request.humanContext, !humanContext.isEmpty {
            context.append("Notes from the user: \(humanContext)")
        }
        if !request.calendarAttendees.isEmpty {
            context.append("Calendar attendees: \(request.calendarAttendees.joined(separator: ", "))")
        }
        if !request.browserParticipants.isEmpty {
            context.append("Participants reported by the browser: \(request.browserParticipants.joined(separator: ", "))")
        }
        context.append("Labels to identify: \(request.labels.joined(separator: ", "))")

        let instructions = """
        You map anonymous diarization labels to real names using only evidence in \
        the transcript and the context given. Self-introductions and people \
        addressing each other by name are the strongest evidence. Use a confidence \
        in [0,1]. If a label cannot be identified, give your best guess with low \
        confidence and list it in unresolved. Labels from different chunks may \
        belong to the same person; map them to the same name when the evidence says so.
        """

        var body: [String: Any] = [
            "model": model,
            "input": [
                ["role": "system", "content": instructions],
                [
                    "role": "user",
                    "content": "\(context.joined(separator: "\n"))\n\nTranscript:\n\(request.transcript)",
                ],
            ],
            "text": [
                "format": [
                    "type": "json_schema",
                    "name": "speaker_map",
                    "schema": schema,
                    "strict": true,
                ],
            ],
        ]
        // Mapping labels to names is extraction, not problem solving; low effort
        // returns the same mapping in a fraction of the time.
        if AIModelSettings.acceptsReasoningEffort(model) {
            body["reasoning"] = ["effort": "low"]
        }

        let data = try await postJSON(path: "responses", body: body)
        let text = try extractOutputText(from: data)
        guard let payload = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let mapping = object["mapping"] as? [[String: Any]]
        else {
            throw ProcessingError.malformedResponse(reason: "speaker mapping")
        }
        return mapping.compactMap { entry in
            guard let label = entry["label"] as? String, let name = entry["name"] as? String else {
                return nil
            }
            return SpeakerSuggestion(
                label: label,
                name: name,
                confidence: (entry["confidence"] as? Double) ?? 0,
                evidence: (entry["evidence"] as? String) ?? ""
            )
        }
    }

    public func enrich(_ request: EnrichmentRequest, model: String) async throws -> MeetingEnrichment {
        var properties: [String: Any] = [:]
        var required: [String] = []
        if request.wantsTitle {
            properties["title"] = ["type": "string"]
            required.append("title")
        }
        if request.wantsDescription {
            properties["description"] = ["type": "string"]
            required.append("description")
        }
        if request.wantsSummary {
            properties["summary"] = ["type": "string"]
            required.append("summary")
        }
        if request.wantsNotes {
            properties["notes"] = ["type": "string"]
            required.append("notes")
        }
        guard !required.isEmpty else { return MeetingEnrichment() }

        let schema: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "properties": properties,
            "required": required,
        ]
        let instructions = """
        You summarise meeting transcripts. Write plainly and specifically: state \
        what was decided, who owns what, and what happens next. The title is a \
        short noun phrase naming the meeting, under eight words, with no trailing \
        punctuation. The summary is a few short paragraphs. Notes are bullet points \
        of decisions and action items. Never invent participants, dates or figures \
        that are not in the transcript.
        """
        var context = "Provider: \(request.provider.displayName). Duration: \(Int(request.durationSeconds / 60)) minutes."
        if !request.participants.isEmpty {
            context += "\nParticipants: \(request.participants.joined(separator: ", "))"
        }
        if let notes = request.humanNotes, !notes.isEmpty {
            context += "\nThe user's own notes (do not repeat them verbatim): \(notes)"
        }

        var body: [String: Any] = [
            "model": model,
            "input": [
                ["role": "system", "content": instructions],
                ["role": "user", "content": "\(context)\n\nTranscript:\n\(request.transcript)"],
            ],
            "text": [
                "format": [
                    "type": "json_schema",
                    "name": "meeting_enrichment",
                    "schema": schema,
                    "strict": true,
                ],
            ],
        ]
        // Titles and summaries need no deliberation; low effort keeps enrichment
        // fast and cheap.
        if AIModelSettings.acceptsReasoningEffort(model) {
            body["reasoning"] = ["effort": "low"]
        }
        let data = try await postJSON(path: "responses", body: body)
        let text = try extractOutputText(from: data)
        guard let payload = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else {
            throw ProcessingError.malformedResponse(reason: "enrichment")
        }
        return MeetingEnrichment(
            title: object["title"] as? String,
            summary: object["summary"] as? String,
            description: object["description"] as? String,
            notes: object["notes"] as? String
        )
    }

    // MARK: - transport

    private func authorize(_ request: inout URLRequest) throws {
        let key = try keyProvider.apiKey()
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    }

    private func postAudio(path: String, body: MultipartBody) async throws -> Data {
        guard body.data.count <= AILimits.maximumRequestBytes else {
            throw ProcessingError.requestTooLarge(
                bytes: body.data.count, limit: AILimits.maximumRequestBytes
            )
        }
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.audioTimeout
        request.setValue(body.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = body.data
        try authorize(&request)
        return try await perform(request)
    }

    private func postJSON(path: String, body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        try authorize(&request)
        return try await perform(request)
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ProcessingError.transport(reason: (error as NSError).domain)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ProcessingError.malformedResponse(reason: "no HTTP response")
        }
        switch http.statusCode {
        case 200..<300:
            return data
        case 401, 403:
            throw ProcessingError.authenticationFailed
        case 413:
            throw ProcessingError.requestTooLarge(
                bytes: request.httpBody?.count ?? 0, limit: AILimits.maximumRequestBytes
            )
        case 429:
            let retryAfter = http.value(forHTTPHeaderField: "retry-after").flatMap(Double.init)
            throw ProcessingError.rateLimited(retryAfter: retryAfter)
        case 400:
            // The duration cap surfaces as a 400 with an explanatory message.
            if let message = errorMessage(from: data), message.lowercased().contains("duration") {
                throw ProcessingError.durationTooLong(
                    seconds: 0, limit: AILimits.maximumDiarizationSeconds
                )
            }
            throw ProcessingError.malformedResponse(reason: "http 400")
        default:
            throw ProcessingError.serverError(status: http.statusCode)
        }
    }

    private func errorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any]
        else { return nil }
        return error["message"] as? String
    }

    /// `verbose_json` and `diarized_json` both come back as a segment list; only
    /// the diarized form carries a speaker on each segment, and only whisper-1
    /// with word granularity adds a flat top-level `words` array. Plain `json`
    /// is text alone, which is valid exactly when the model was chosen for its
    /// words rather than its timings — `allowTextOnly` says which.
    ///
    /// Static and public so the format handling is testable without a network.
    public static func parseTranscription(
        _ data: Data, allowTextOnly: Bool
    ) throws -> TranscriptionResponse {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProcessingError.malformedResponse(reason: "not JSON")
        }
        let rawSegments = (object["segments"] as? [[String: Any]]) ?? []
        var segments: [RawTranscriptSegment] = rawSegments.compactMap { segment in
            guard let start = segment["start"] as? Double,
                  let end = segment["end"] as? Double,
                  let text = segment["text"] as? String
            else { return nil }
            return RawTranscriptSegment(
                start: start, end: end, text: text, speaker: segment["speaker"] as? String
            )
        }
        nest(words: object["words"] as? [[String: Any]] ?? [], into: &segments)
        let text = (object["text"] as? String) ?? segments.map(\.text).joined()
        if segments.isEmpty, !text.isEmpty, !allowTextOnly {
            // A model that promised timings and returned none cannot feed the
            // timeline, and storing the text would hide the failure.
            throw ProcessingError.malformedResponse(reason: "response carried no segment timings")
        }
        return TranscriptionResponse(
            segments: segments,
            text: text,
            durationSeconds: object["duration"] as? Double,
            rawBody: data
        )
    }

    /// The API returns word timings as one flat list beside the segments; the
    /// canonical form nests each word in the segment covering its start.
    private static func nest(words: [[String: Any]], into segments: inout [RawTranscriptSegment]) {
        guard !words.isEmpty, !segments.isEmpty else { return }
        for raw in words {
            guard let text = raw["word"] as? String,
                  let start = raw["start"] as? Double,
                  let end = raw["end"] as? Double
            else { continue }
            let index = segments.lastIndex { $0.start <= start } ?? 0
            var nested = segments[index].words ?? []
            // The API returns bare words; the canonical convention is
            // Whisper's, a leading space per word, which is what the
            // assembler concatenates by.
            nested.append(RawTranscriptWord(
                start: start, end: end, text: text.hasPrefix(" ") ? text : " " + text
            ))
            segments[index].words = nested
        }
    }

    private func extractOutputText(from data: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProcessingError.malformedResponse(reason: "not JSON")
        }
        if let text = object["output_text"] as? String, !text.isEmpty { return text }
        guard let output = object["output"] as? [[String: Any]] else {
            throw ProcessingError.malformedResponse(reason: "no output")
        }
        var collected = ""
        for item in output where (item["type"] as? String) == "message" {
            guard let content = item["content"] as? [[String: Any]] else { continue }
            for part in content where (part["type"] as? String) == "output_text" {
                collected += (part["text"] as? String) ?? ""
            }
        }
        guard !collected.isEmpty else {
            throw ProcessingError.malformedResponse(reason: "empty output text")
        }
        return collected
    }

    private func multipartBody(
        fields: [(String, String)], audio: URL, extraFiles: [(String, String, Data)]
    ) async throws -> MultipartBody {
        guard let audioData = try? Data(contentsOf: audio) else {
            throw ProcessingError.audioUnreadable(path: audio.lastPathComponent)
        }
        var files = extraFiles
        files.append(("file", audio.lastPathComponent, audioData))
        return MultipartBody(fields: fields, files: files)
    }
}

/// Multipart encoding built by hand: the payloads are large and a streaming
/// upload body is not worth the complexity for one endpoint.
struct MultipartBody: Sendable {
    let data: Data
    let contentType: String

    init(fields: [(String, String)], files: [(String, String, Data)]) {
        let boundary = "meettape-\(UUID().uuidString)"
        var body = Data()
        for (name, value) in fields {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data("\(value)\r\n".utf8))
        }
        for (name, filename, payload) in files {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data(
                "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".utf8
            ))
            body.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))
            body.append(payload)
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        self.data = body
        self.contentType = "multipart/form-data; boundary=\(boundary)"
    }
}
