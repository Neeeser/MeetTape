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
    /// against `farEndFloorDBFS` and the recorded microphone against
    /// `microphoneFloorDBFS`.
    ///
    /// Levels alone. A microphone above its floor holds the user, the far
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
        /// The far end was above its floor and the microphone was not.
        case farEndOnly
        /// The microphone was above its floor and the far end was not.
        case userOnly
        /// Both were above their floors.
        case both
        /// Neither was.
        case neither
    }

    /// One quarter-second window, as classified and as measured.
    ///
    /// The whole series is carried in `Report.windowLog` and written to
    /// `--json`, so a question nobody thought to ask can be asked of a run
    /// made weeks earlier without measuring the meeting again. A two-hour
    /// meeting is about 29,000 of these, which is 9 MB of `--json`.
    public struct WindowRecord: Sendable, Codable, Equatable {
        /// Seconds from the microphone's first frame, which is the clock every
        /// transcript timestamp is already on.
        public let startSeconds: Double
        public let windowClass: WindowClass
        public let farEndDBFS: Double
        public let microphoneBeforeDBFS: Double
        public let microphoneAfterDBFS: Double
        /// Before minus after. Positive is level the canceller took out.
        public let changeDB: Double
        /// What the canceller said it had removed by the end of this window.
        public let echoRemovedDB: Double
    }

    /// One window class, with what the microphone held across it and how the
    /// individual windows in it fared.
    ///
    /// `microphoneBeforeDBFS` and `microphoneAfterDBFS` are mean power over
    /// the class, so a loud window counts for more than a quiet one, and
    /// `changeDB` is their ratio. That ratio is what the class lost in total.
    /// It is not what a window lost, and on its own it hides the failure this
    /// whole body of work exists to catch: a suppressor that gates one quiet
    /// passage of the user's speech to silence and leaves loud speech alone
    /// moves the ratio by a fraction of a decibel, because the loud speech
    /// carries nearly all the energy. The incident that started this deleted
    /// 3957 words while every summary figure looked fine.
    ///
    /// So the per-window distribution travels with it. `worstChangeDB` is the
    /// single window that lost the most, `p95ChangeDB` is the level ninety-five
    /// windows in a hundred stayed under, and `windowsOverLossThreshold`
    /// counts the windows that lost more than `notableLossDB`. A class whose
    /// ratio reads 0.2 dB and whose worst window reads 40 dB is a class with a
    /// hole in it, and on the speaker fixture the user-only class reads
    /// exactly that: 0.007 dB across the class, 36.5 dB in its worst window.
    ///
    /// `largestGainDB` is the other end of the same series, the window the
    /// canceller handed back the most level in. It is what separates a noise
    /// floor lifted throughout from a handful of windows lifted enormously,
    /// which a power ratio cannot tell apart.
    ///
    /// `changeDB` goes negative where the canceller hands back more level than
    /// it was given. The suppressor replaces what it removed with comfort
    /// noise, and on a fixture whose microphone holds -73 dBFS of room noise
    /// the far-end-only class comes back 29 dB louder. Every optional here is
    /// nil for a class with no windows in it.
    public struct ClassSummary: Sendable, Codable, Equatable {
        public let windowClass: WindowClass
        public let windows: Int
        public let seconds: Double
        public let microphoneBeforeDBFS: Double?
        public let microphoneAfterDBFS: Double?
        public let changeDB: Double?
        public let medianChangeDB: Double?
        public let p95ChangeDB: Double?
        public let worstChangeDB: Double?
        /// The window that came back loudest against its own input. Negative
        /// wherever the canceller added level rather than removing it.
        public let largestGainDB: Double?
        public let windowsOverLossThreshold: Int
    }

    public struct Report: Sendable, Codable, Equatable {
        /// Microphone seconds the pass read, which is the recording's length.
        public let seconds: Double
        public let windowSeconds: Double
        public let windowCount: Int
        /// The level the far end clears to count as playing in a window.
        public let farEndFloorDBFS: Double
        /// The level the microphone clears to count as holding something,
        /// derived from this recording.
        public let microphoneFloorDBFS: Double
        /// The microphone's own quietest twentieth of windows, which is what
        /// the floor above was derived from. Where this sits within 10 dB of
        /// the floor, the recording's own room tone decided the floor. Where
        /// it sits far below, the far end's -60 dBFS did.
        public let microphoneQuietWindowDBFS: Double?
        /// Seconds the far end was moved by to line up with the microphone.
        public let referenceOffsetSeconds: Double
        /// True when a caller supplied that offset instead of the timeline.
        public let referenceOffsetIsOverride: Bool
        /// Every class, in declaration order, including empty ones.
        public let classes: [ClassSummary]
        /// Every window, in order. What `classes` was summarised from.
        public let windowLog: [WindowRecord]
        /// A per-window drop above which a window is counted as having lost
        /// something a listener would notice.
        public let notableLossDB: Double
        /// Median `echoRemovedDB` over the far-end-active windows, which is
        /// the figure `MicrophoneCleaner` decides on. Nil where no window had
        /// the far end above its floor. What the canceller reported removing
        /// is not what it removed, and `classes` holds the second.
        public let reportedEnhancementMedianDB: Double?
        public let farEndActiveWindows: Int
        /// Share of all windows the far end was above its floor in.
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
            classes.first { $0.windowClass == windowClass } ?? .empty(windowClass)
        }
    }

    case measured(Report)
    case noReference(MissingReference)

    /// The level the far end clears to count as playing in a window.
    ///
    /// `MicrophoneCleaner.farEndActiveDBFS`, unchanged, so the far-end-active
    /// windows here are exactly the ones the cleaner takes its median over. It
    /// describes a process tap, which is a digital copy of what the meeting
    /// application rendered and carries no room in it at all.
    public static var farEndFloorDBFS: Double { MicrophoneCleaner.farEndActiveDBFS }

    /// How far above its own quietest windows a microphone has to be before a
    /// window counts as holding something.
    ///
    /// Ten decibels. Speech at a desk runs 20 to 40 dB over the room it is in,
    /// so ten leaves room for a quiet passage while keeping the room itself
    /// out.
    public static let microphoneActivationMarginDB = 10.0

    /// A per-window level drop large enough for a listener to hear.
    ///
    /// Six decibels is half the amplitude. Counted per window because a
    /// class-level power ratio cannot show these: a handful of quiet windows
    /// gated to nothing barely moves a ratio the loud windows dominate.
    public static let notableLossDB = 6.0

    /// The level the microphone clears to count as holding something.
    ///
    /// Derived from the recording rather than borrowed from the far end. A
    /// capsule records the room as well as the person, and where the room tone
    /// and the codec's own noise sit is a property of that room and that Mac.
    /// Borrowing the far end's -60 dBFS would classify a meeting whose room
    /// tone sits above it as the user speaking from end to end: `farEndOnly`
    /// and `neither` would come back empty on every meeting including the
    /// headphone calls, and `userOnly` would stop meaning "the user spoke" and
    /// start meaning "the far end was quiet".
    ///
    /// So the floor is this recording's own quietest twentieth plus
    /// `microphoneActivationMarginDB`, and never below the far end's floor,
    /// because nothing under -60 dBFS is speech either way. `Report` carries
    /// the quietest-twentieth figure beside the floor, so which of the two
    /// decided it is visible in the table.
    public static func microphoneFloorDBFS(quietWindowDBFS: Double?) -> Double {
        guard let quietWindowDBFS else { return farEndFloorDBFS }
        return max(farEndFloorDBFS, quietWindowDBFS + microphoneActivationMarginDB)
    }

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

        // The microphone's floor comes from the microphone, so it can only be
        // settled once the whole pass has been read.
        let quiet = percentile(pass.windows.map(\.microphoneBeforeDBFS), 0.05)
        let microphoneFloor = microphoneFloorDBFS(quietWindowDBFS: quiet)
        let log = pass.windows.enumerated().map { index, window in
            WindowRecord(
                startSeconds: Double(index) * EchoCancellationPass.windowSeconds,
                windowClass: classify(window, microphoneFloor: microphoneFloor),
                farEndDBFS: window.farEndDBFS,
                microphoneBeforeDBFS: window.microphoneBeforeDBFS,
                microphoneAfterDBFS: window.microphoneAfterDBFS,
                changeDB: window.microphoneBeforeDBFS - window.microphoneAfterDBFS,
                echoRemovedDB: window.echoRemovedDB
            )
        }

        let grouped = Dictionary(grouping: log, by: \.windowClass)
        let classes = WindowClass.allCases.map { summarize($0, grouped[$0] ?? []) }
        let active = pass.windows.filter { $0.farEndDBFS > farEndFloorDBFS }
        let median = EchoCancellationPass.median(of: active.map(\.echoRemovedDB))
        let (decision, reason) = decide(activeWindows: active.count, median: median)

        return .measured(Report(
            seconds: Double(pass.frames) / EchoCancellationPass.readFormat.sampleRate,
            windowSeconds: EchoCancellationPass.windowSeconds,
            windowCount: log.count,
            farEndFloorDBFS: farEndFloorDBFS,
            microphoneFloorDBFS: microphoneFloor,
            microphoneQuietWindowDBFS: quiet,
            referenceOffsetSeconds: offset,
            referenceOffsetIsOverride: referenceOffset != nil,
            classes: classes,
            windowLog: log,
            notableLossDB: notableLossDB,
            reportedEnhancementMedianDB: active.isEmpty ? nil : median,
            farEndActiveWindows: active.count,
            farEndDutyCycle: log.isEmpty ? 0 : Double(active.count) / Double(log.count),
            bypassThresholdDB: MicrophoneCleaner.bypassBelowDB,
            minimumActiveWindows: MicrophoneCleaner.minimumActiveWindows,
            decision: decision,
            decisionReason: reason
        ))
    }

    private static func classify(
        _ window: EchoCancellationPass.Window, microphoneFloor: Double
    ) -> WindowClass {
        let farEnd = window.farEndDBFS > farEndFloorDBFS
        let microphone = window.microphoneBeforeDBFS > microphoneFloor
        return switch (farEnd, microphone) {
        case (true, false): .farEndOnly
        case (false, true): .userOnly
        case (true, true): .both
        case (false, false): .neither
        }
    }

    private static func summarize(
        _ windowClass: WindowClass, _ windows: [WindowRecord]
    ) -> ClassSummary {
        guard !windows.isEmpty else { return .empty(windowClass) }
        let before = meanPowerDB(windows.map(\.microphoneBeforeDBFS))
        let after = meanPowerDB(windows.map(\.microphoneAfterDBFS))
        let changes = windows.map(\.changeDB)
        return ClassSummary(
            windowClass: windowClass,
            windows: windows.count,
            seconds: Double(windows.count) * EchoCancellationPass.windowSeconds,
            microphoneBeforeDBFS: before,
            microphoneAfterDBFS: after,
            changeDB: before - after,
            medianChangeDB: percentile(changes, 0.5),
            p95ChangeDB: percentile(changes, 0.95),
            worstChangeDB: changes.max(),
            largestGainDB: changes.min(),
            windowsOverLossThreshold: changes.filter { $0 > notableLossDB }.count
        )
    }

    /// The value at a fraction of the way up the sorted series, by nearest
    /// rank, so every figure reported is a window that actually happened
    /// rather than an interpolation between two that did.
    private static func percentile(_ values: [Double], _ fraction: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = Int((fraction * Double(sorted.count)).rounded(.up))
        return sorted[min(sorted.count - 1, max(0, rank - 1))]
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
                "the far end was above \(fixed(farEndFloorDBFS)) dBFS in \(activeWindows) "
                    + "windows, and the decision needs \(minimum)"
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

extension EchoMeasurement.ClassSummary {
    /// A class no window landed in. Every level is absent rather than zero: a
    /// zero before would read as full scale and a zero change as a canceller
    /// that did nothing.
    static func empty(_ windowClass: EchoMeasurement.WindowClass) -> Self {
        Self(
            windowClass: windowClass, windows: 0, seconds: 0,
            microphoneBeforeDBFS: nil, microphoneAfterDBFS: nil, changeDB: nil,
            medianChangeDB: nil, p95ChangeDB: nil, worstChangeDB: nil, largestGainDB: nil,
            windowsOverLossThreshold: 0
        )
    }
}
