import Foundation

/// What a CAF file actually contains, read from the file rather than trusted from
/// the manifest.
public struct AudioFileInfo: Sendable, Equatable {
    public let frameCount: Int64
    public let sampleRate: Double
    public let channelCount: Int
    public let byteCount: Int64

    public init(frameCount: Int64, sampleRate: Double, channelCount: Int, byteCount: Int64) {
        self.frameCount = frameCount
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.byteCount = byteCount
    }

    public var seconds: Double { sampleRate > 0 ? Double(frameCount) / sampleRate : 0 }
}

public protocol AudioFileInspecting: Sendable {
    func inspect(url: URL) throws -> AudioFileInfo
}

public struct RecoveredMeeting: Sendable, Equatable {
    public let meetingID: String
    public let directory: URL
    public let adoptedSegments: Int
    public let reconstructedSegments: Int
    public let recoveredSeconds: Double
    public let resumedFrom: ProcessingState?

    public init(
        meetingID: String, directory: URL, adoptedSegments: Int, reconstructedSegments: Int,
        recoveredSeconds: Double, resumedFrom: ProcessingState?
    ) {
        self.meetingID = meetingID
        self.directory = directory
        self.adoptedSegments = adoptedSegments
        self.reconstructedSegments = reconstructedSegments
        self.recoveredSeconds = recoveredSeconds
        self.resumedFrom = resumedFrom
    }
}

public struct RecoveryReport: Sendable, Equatable {
    public var recovered: [RecoveredMeeting] = []
    public var resumable: [String] = []
    public var unreadable: [String] = []

    public init() {}
}

/// Startup recovery.
///
/// A meeting whose manifest has an open segment and no close record was killed
/// while recording. CAF declares its data chunk size as -1, so readers fall back
/// to end-of-file and the tail is intact. Recovery adopts it from the file rather
/// than discarding the meeting.
public struct RecoveryScanner: Sendable {
    private let repository: MeetingRepository
    private let inspector: any AudioFileInspecting
    private let clock: any Clock

    public init(repository: MeetingRepository, inspector: any AudioFileInspecting, clock: any Clock = SystemClock()) {
        self.repository = repository
        self.inspector = inspector
        self.clock = clock
    }

    public func scan() -> RecoveryReport {
        var report = RecoveryReport()
        for summary in repository.listMeetings() {
            let store = MeetingStore(layout: MeetingLayout(root: summary.directory))
            guard var metadata = try? store.readMetadata() else {
                report.unreadable.append(summary.id)
                continue
            }
            guard metadata.processing.state != .complete else { continue }

            let needsRecovery = metadata.processing.state == .recording
                || metadata.processing.state == .finalizing
            if needsRecovery {
                do {
                    let recovery = try recoverAudio(store: store, metadata: &metadata)
                    try store.writeMetadata(metadata)
                    report.recovered.append(
                        RecoveredMeeting(
                            meetingID: metadata.id,
                            directory: summary.directory,
                            adoptedSegments: recovery.adopted,
                            reconstructedSegments: recovery.reconstructed,
                            recoveredSeconds: recovery.seconds,
                            resumedFrom: metadata.processing.resumeStage
                        )
                    )
                } catch {
                    // The meeting id embeds its title, so it is logged privately.
                    Log.storage.error("recovery failed for \(metadata.id, privacy: .private): \(logSafeDescription(error), privacy: .public)")
                    report.unreadable.append(metadata.id)
                }
                continue
            }

            if metadata.processing.resumeStage != nil {
                report.resumable.append(metadata.id)
            }
        }
        return report
    }

    private struct AudioRecovery {
        var adopted = 0
        var reconstructed = 0
        /// Per track, so a two-track meeting is not reported as twice its length.
        var secondsByTrack: [CaptureTrack: Double] = [:]

        var seconds: Double { secondsByTrack.values.max() ?? 0 }
    }

    /// Adopts crash tails and any segment file the manifest never recorded, then
    /// moves the meeting to `audio_safe` so processing can run.
    private func recoverAudio(store: MeetingStore, metadata: inout MeetingMetadata) throws -> AudioRecovery {
        var recovery = AudioRecovery()
        let timeline = try store.readTimeline()
        let writer = try ManifestWriter(url: store.layout.manifest)
        defer { writer.close() }

        for segment in timeline.openSegments {
            let url = store.layout.segments.appendingPathComponent(segment.file)
            guard let info = try? inspector.inspect(url: url) else {
                Log.storage.notice("crash tail unreadable: \(segment.file, privacy: .public)")
                continue
            }
            writer.append(
                .crashTailAdopted(
                    .init(
                        track: segment.track, index: segment.index, frameCount: info.frameCount,
                        byteCount: info.byteCount, seconds: info.seconds
                    )
                ),
                hostTime: clock.monotonicSeconds,
                wallClock: clock.now
            )
            recovery.adopted += 1
            recovery.secondsByTrack[segment.track, default: 0] += info.seconds
        }

        // A segment file with no manifest record at all: the open line was lost.
        // Reconstruct it from the filename and the file's own format.
        let known = Set(timeline.segments.map(\.file))
        let files = (try? FileManager.default.contentsOfDirectory(
            at: store.layout.segments, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        for url in files where url.pathExtension == "caf" {
            let name = url.lastPathComponent
            guard !known.contains(name), let parsed = Self.parseSegmentFileName(name) else { continue }
            guard let info = try? inspector.inspect(url: url), info.frameCount > 0 else { continue }
            writer.append(
                .segmentOpen(
                    .init(
                        track: parsed.track, index: parsed.index, file: name, firstFrameHostTime: nil,
                        startFrame: 0, sampleRate: info.sampleRate, channelCount: info.channelCount,
                        reason: "reconstructed"
                    )
                ),
                hostTime: clock.monotonicSeconds,
                wallClock: clock.now
            )
            writer.append(
                .crashTailAdopted(
                    .init(
                        track: parsed.track, index: parsed.index, frameCount: info.frameCount,
                        byteCount: info.byteCount, seconds: info.seconds
                    )
                ),
                hostTime: clock.monotonicSeconds,
                wallClock: clock.now
            )
            recovery.reconstructed += 1
            recovery.secondsByTrack[parsed.track, default: 0] += info.seconds
        }

        if !timeline.isComplete {
            let refreshed = try store.readTimeline()
            writer.append(
                .sessionEnd(
                    .init(
                        reason: "recovered_after_interruption",
                        micSeconds: refreshed.duration(track: .mic),
                        remoteSeconds: refreshed.duration(track: .remote)
                    )
                ),
                hostTime: clock.monotonicSeconds,
                wallClock: clock.now
            )
        }

        let finalTimeline = try store.readTimeline()
        metadata.durationSeconds = finalTimeline.duration
        metadata.endedAt = metadata.endedAt ?? finalTimeline.endedAt ?? clock.now
        if var run = metadata.runs.last, run.endedAt == nil {
            run.endedAt = metadata.endedAt
            run.durationSeconds = finalTimeline.duration
            run.wasInterrupted = true
            run.endReason = "interrupted"
            metadata.runs[metadata.runs.count - 1] = run
        } else if metadata.runs.isEmpty {
            metadata.runs = [
                RecordingRun(
                    id: "run-001", startedAt: metadata.startedAt, endedAt: metadata.endedAt,
                    durationSeconds: finalTimeline.duration, wasInterrupted: true, endReason: "interrupted"
                ),
            ]
        }

        if finalTimeline.duration > 0 {
            metadata.processing.advance(to: .audioSafe, at: clock.now)
        } else {
            metadata.processing.recordFailure(
                ProcessingFailure(
                    stage: .finalizing,
                    message: "No readable audio was recovered for this recording.",
                    isRetryable: false,
                    occurredAt: clock.now
                ),
                at: clock.now
            )
        }
        return recovery
    }

    /// `mic.0007.caf` / `system.0012.caf`
    public static func parseSegmentFileName(_ name: String) -> (track: CaptureTrack, index: Int)? {
        let parts = name.split(separator: ".")
        guard parts.count == 3, parts[2] == "caf", let index = Int(parts[1]) else { return nil }
        for track in CaptureTrack.allCases where track.segmentPrefix == parts[0] {
            return (track, index)
        }
        return nil
    }
}
