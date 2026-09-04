import Foundation
import PipitCore

/// What the echo canceller does to one recorded meeting, measured without
/// changing it.
///
/// Every number the canceller ships against was taken on synthetic tones. A
/// tone is the easy case for both the linear filter and the residual
/// suppressor, and the claim that matters, that the user's own voice survives
/// while the far end is cancelled underneath it, is the one a tone supports
/// least. This runs `EchoCancellationPass` over the recording as it was
/// captured and reports what came out, so the same claim can be checked on
/// speech. Nothing is written. The cleaned samples are counted and dropped.
///
/// It does not read `mic.cleaned.m4a` and does not care whether one exists.
/// Most of the archive was recorded before the cleaner did, and those meetings
/// are the ones worth measuring.
public enum EchoMeasurement: Sendable, Equatable {
    /// Why a meeting had nothing to measure. None of these is a removal of
    /// zero decibels, and keeping them out of `Report` is what stops one being
    /// read as such.
    public enum MissingReference: String, Sendable, Codable, Equatable {
        /// One track holding everyone, which is every import and every
        /// in-person session.
        case oneTrack
        /// No far-end track was recorded at all.
        case notRecorded
        /// The tap opened and recorded silence, so the far-end track exists
        /// and holds nothing.
        case recordedSilence
    }

    /// What a quarter-second window held, decided from the recorded far end
    /// and the recorded microphone, each against `floorDBFS`.
    ///
    /// Levels alone. A microphone above the floor holds the user, the far
    /// end's own echo arriving through the air, or both, and nothing in a
    /// level separates them. So on a call taken on speakers every window the
    /// far end plays in lands in `both`, whether the user spoke or not, and
    /// `farEndOnly` stays empty. On a call taken on headphones the same
    /// windows land in `farEndOnly`. That ambiguity is the whole of the
    /// problem the canceller exists to solve, and it is why retention is
    /// reported separately for `userOnly` and `both` rather than as one
    /// number. `userOnly` is the only class in which the microphone is known
    /// to hold the user and nothing else.
    public enum WindowClass: String, Sendable, Codable, CaseIterable {
        /// The far end was above the floor and the microphone was not.
        case farEndOnly
        /// The microphone was above the floor and the far end was not.
        case userOnly
        /// Both were above the floor.
        case both
        /// Neither was.
        case neither
    }

    /// One window class, with what the microphone held across it before and
    /// after cancellation.
    ///
    /// The levels are mean power over the class, in dBFS, so a loud window
    /// counts for more than a quiet one. `changeDB` is before minus after,
    /// which is what the microphone level did rather than what was removed
    /// from it. In `userOnly` a positive figure is what the user lost. In
    /// `both` it is echo removal and user loss together, which is why it
    /// answers neither on its own. It goes negative where the canceller hands
    /// back more level than it was given: the suppressor replaces what it
    /// removed with comfort noise, and on a fixture whose microphone holds
    /// -73 dBFS of room noise the far-end-only class comes back 29 dB louder.
    /// All three are nil for a class with no windows in it.
    public struct ClassSummary: Sendable, Codable, Equatable {
        public let windowClass: WindowClass
        public let windows: Int
        public let seconds: Double
        public let microphoneBeforeDBFS: Double?
        public let microphoneAfterDBFS: Double?
        public let changeDB: Double?
    }

    public struct Report: Sendable, Codable, Equatable {
        /// Microphone seconds the pass read, which is the recording's length.
        public let seconds: Double
        public let windowSeconds: Double
        public let windows: Int
        /// The level a track has to clear to count as active in a window.
        public let floorDBFS: Double
        /// Seconds the far end was moved by to line up with the microphone.
        public let referenceOffsetSeconds: Double
        /// True when a caller supplied that offset instead of the timeline.
        public let referenceOffsetIsOverride: Bool
        /// Every class, in declaration order, including empty ones.
        public let classes: [ClassSummary]
        /// Median `echoRemovedDB` over the far-end-active windows, which is
        /// the figure `MicrophoneCleaner` decides on. Nil where no window had
        /// the far end above the floor. What the canceller reported removing
        /// is not what it removed, and `classes` holds the second.
        public let reportedEnhancementMedianDB: Double?
        public let farEndActiveWindows: Int
        /// Share of all windows the far end was above the floor in.
        public let farEndDutyCycle: Double
        public let bypassThresholdDB: Double
        public let minimumActiveWindows: Int
        /// What `MicrophoneCleaner` would decide about this meeting.
        ///
        /// Decided from the same windows against the same thresholds, up to
        /// the point the cleaner writes a file. The cleaner can still come
        /// back `.failed` after this, on an encode that stopped short or a
        /// container that will not open, and no measurement that writes
        /// nothing can see that.
        public let decision: CleaningOutcome
        public let decisionReason: String

        public func summary(_ windowClass: WindowClass) -> ClassSummary {
            classes.first { $0.windowClass == windowClass }
                ?? ClassSummary(
                    windowClass: windowClass, windows: 0, seconds: 0,
                    microphoneBeforeDBFS: nil, microphoneAfterDBFS: nil, changeDB: nil
                )
        }
    }

    case measured(Report)
    case noReference(MissingReference)

    /// The level a track clears to count as active in a window.
    ///
    /// The cleaner's own far-end threshold, used on the microphone too so that
    /// one number decides both sides and `farEndActiveWindows` here is the
    /// same set of windows the cleaner takes its median over.
    public static var floorDBFS: Double { MicrophoneCleaner.farEndActiveDBFS }

    /// How far the far end has to move to line up with the microphone, as the
    /// recording's own manifest says.
    public static func timelineReferenceOffset(_ timeline: RecordingTimeline) -> Double {
        EchoCancellationPass.referenceOffset(timeline: timeline)
    }

    /// Runs the canceller over the recorded pair and reports what happened.
    ///
    /// - Parameter referenceOffset: seconds to move the far end by, replacing
    ///   the timeline's own. For measuring a misalignment deliberately. Nil is
    ///   what a real run uses. The far end is classified through this offset
    ///   as well as cancelled through it, so a wrong one compares the two
    ///   tracks at moments that are not the same moment and moves the window
    ///   classes along with the cancellation.
    public static func measure(
        store: MeetingStore, metadata: MeetingMetadata, timeline: RecordingTimeline,
        referenceOffset: Double? = nil
    ) throws -> EchoMeasurement {
        guard metadata.source.micTrackIsLocalUser else { return .noReference(.oneTrack) }
        // Both read as recorded. A meeting that has already been cleaned has
        // to be measured on the microphone it captured, or the pass would
        // subtract the far end from a track it has already left.
        let microphone = store.rawTrackAudioLocation(
            track: .mic, metadata: metadata, timeline: timeline
        )
        let reference = store.rawTrackAudioLocation(
            track: .remote, metadata: metadata, timeline: timeline
        )
        guard !microphone.isEmpty, !reference.isEmpty else { return .noReference(.notRecorded) }
        guard try EchoCancellationPass.referenceHoldsAudio(reference) else {
            return .noReference(.recordedSilence)
        }

        let offset = referenceOffset ?? timelineReferenceOffset(timeline)
        let pass = try EchoCancellationPass.run(
            microphone: microphone, reference: reference, referenceOffset: offset
        ) { _ in }

        let grouped = Dictionary(grouping: pass.windows, by: classify)
        let classes = WindowClass.allCases.map { summarize($0, grouped[$0] ?? []) }
        let active = pass.windows.filter { $0.farEndDBFS > floorDBFS }
        let median = EchoCancellationPass.median(of: active.map(\.echoRemovedDB))
        let (decision, reason) = decide(activeWindows: active.count, median: median)

        return .measured(Report(
            seconds: Double(pass.frames) / EchoCancellationPass.readFormat.sampleRate,
            windowSeconds: EchoCancellationPass.windowSeconds,
            windows: pass.windows.count,
            floorDBFS: floorDBFS,
            referenceOffsetSeconds: offset,
            referenceOffsetIsOverride: referenceOffset != nil,
            classes: classes,
            reportedEnhancementMedianDB: active.isEmpty ? nil : median,
            farEndActiveWindows: active.count,
            farEndDutyCycle: pass.windows.isEmpty
                ? 0
                : Double(active.count) / Double(pass.windows.count),
            bypassThresholdDB: MicrophoneCleaner.bypassBelowDB,
            minimumActiveWindows: MicrophoneCleaner.minimumActiveWindows,
            decision: decision,
            decisionReason: reason
        ))
    }

    private static func classify(_ window: EchoCancellationPass.Window) -> WindowClass {
        switch (window.farEndDBFS > floorDBFS, window.microphoneBeforeDBFS > floorDBFS) {
        case (true, false): .farEndOnly
        case (false, true): .userOnly
        case (true, true): .both
        case (false, false): .neither
        }
    }

    private static func summarize(
        _ windowClass: WindowClass, _ windows: [EchoCancellationPass.Window]
    ) -> ClassSummary {
        guard !windows.isEmpty else {
            return ClassSummary(
                windowClass: windowClass, windows: 0, seconds: 0,
                microphoneBeforeDBFS: nil, microphoneAfterDBFS: nil, changeDB: nil
            )
        }
        let before = meanPowerDB(windows.map(\.microphoneBeforeDBFS))
        let after = meanPowerDB(windows.map(\.microphoneAfterDBFS))
        return ClassSummary(
            windowClass: windowClass,
            windows: windows.count,
            seconds: Double(windows.count) * EchoCancellationPass.windowSeconds,
            microphoneBeforeDBFS: before,
            microphoneAfterDBFS: after,
            changeDB: before - after
        )
    }

    /// Mean power across windows, back in decibels.
    ///
    /// Averaging the decibels themselves would answer a different question:
    /// the level a window held is a power, and the level a stretch held is the
    /// mean of those powers rather than the mean of their logarithms.
    private static func meanPowerDB(_ levels: [Double]) -> Double {
        guard !levels.isEmpty else { return EmptyTranscriptPolicy.silenceFloorDBFS }
        let mean = levels.reduce(0.0) { $0 + pow(10, $1 / 10) } / Double(levels.count)
        guard mean > 0 else { return EmptyTranscriptPolicy.silenceFloorDBFS }
        return max(EmptyTranscriptPolicy.silenceFloorDBFS, 10 * log10(mean))
    }

    /// The cleaner's decision, made again from the same windows.
    private static func decide(
        activeWindows: Int, median: Double
    ) -> (CleaningOutcome, String) {
        let threshold = MicrophoneCleaner.bypassBelowDB
        let minimum = MicrophoneCleaner.minimumActiveWindows
        guard activeWindows >= minimum else {
            return (
                .skippedNoReference,
                "the far end was above \(fixed(floorDBFS)) dBFS in \(activeWindows) windows, "
                    + "and the decision needs \(minimum)"
            )
        }
        guard median >= threshold else {
            return (
                .bypassedNoEchoPath,
                "the canceller reported \(fixed(median)) dB removed against a "
                    + "\(fixed(threshold)) dB threshold, so its filter never locked on"
            )
        }
        return (
            .cleaned,
            "the canceller reported \(fixed(median)) dB removed over \(activeWindows) "
                + "far-end-active windows, against a \(fixed(threshold)) dB threshold"
        )
    }

    private static func fixed(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}
