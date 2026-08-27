import AVFoundation
import Foundation
import PipitCore
import Synchronization

/// Records the microphone to one file, for a person reading a few sentences.
///
/// Nothing about meetings: no segments, no manifest, no second track. One wav
/// with one voice in it, which is what an embedding needs and all it needs.
///
/// Voice processing is off. It exists to subtract what the speakers are playing
/// from the microphone, and there is nothing playing here; leaving it on would
/// gate and duck a person reading in a quiet room.
public final class VoiceEnrollmentRecorder: Sendable {
    private struct State {
        var file: AVAudioFile?
        var frames: Int64 = 0
        var sampleRate: Double = 0
        var level: Float = 0
        /// Seconds of audio loud enough to be somebody talking, summed over
        /// every take since the last reset.
        var speechSeconds: Double = 0
        /// Set by `stop`, because the tap creates the file when it finds none.
        /// A buffer still in flight past `removeTap` would otherwise write a
        /// fresh file at a path the caller has just deleted, and leave it there.
        var closed = true
    }

    private let state = LockedBox(State())
    /// Held apart from the state the tap closure captures. Both in one box is a
    /// cycle: the box holds the source, the source holds the tap, and the tap
    /// holds the box, so nothing is ever released and the microphone indicator
    /// stays lit for the rest of the session.
    private let engine = LockedBox<MicrophoneSource?>(nil)

    public init() {}

    deinit {
        // The tap has to be removed explicitly. Releasing the engine alone
        // leaves the microphone open, which is what `MicrophoneSource.deinit`
        // exists to prevent, and a recorder dropped with the window it was on
        // never reaches `stop()`.
        engine.withLock { $0 }?.teardown()
    }

    public var isRecording: Bool { engine.withLock { $0 != nil } }

    /// The loudest sample of the last buffer, between 0 and 1. What a level
    /// meter draws, and the only proof on screen that the microphone is live.
    public var level: Float { state.withLock { $0.level } }

    /// How much audio has been written so far.
    public var recordedSeconds: Double {
        state.withLock { $0.sampleRate > 0 ? Double($0.frames) / $0.sampleRate : 0 }
    }

    /// Roughly how much of it was speech, across every take since `reset`.
    ///
    /// What a profile needs is speech, not elapsed time, and the two differ by
    /// however long the reader pauses and by how fast they talk. A bar drawn
    /// from the clock told a quick reader they had done enough when they had
    /// not, and the rejection came minutes later from something they could not
    /// see.
    ///
    /// An energy gate rather than the voice detector: that model reads a whole
    /// track and answers at the end, which is the wrong shape for a bar that
    /// has to move while somebody reads. It counts a noisy room as speech, so
    /// what it drives is a target set above what the profile actually requires,
    /// and the real measurement still happens where enrolment happens.
    public var estimatedSpeechSeconds: Double { state.withLock { $0.speechSeconds } }

    /// Forgets what earlier takes were worth. For a sheet that is opening, or
    /// a reading somebody abandoned.
    public func reset() {
        stop()
        state.withLock { $0.speechSeconds = 0 }
    }

    /// Quieter than this is a room rather than a person. Speech at a normal
    /// distance from a laptop microphone sits far above it, and it is low
    /// enough that the end of a sentence still counts.
    public static let speechFloor: Float = 0.02

    /// Starts capture. The file is created from the first buffer's own format,
    /// because the input node decides the format and reports it only once it is
    /// running.
    public func start(writingTo url: URL) throws {
        stop()
        try? FileManager.default.removeItem(at: url)
        let box = state
        let source = MicrophoneSource(
            sink: { packet in
                box.withLock { state in
                    guard !state.closed else { return }
                    let buffer = packet.buffer
                    if state.file == nil {
                        state.file = try? AVAudioFile(
                            forWriting: url, settings: buffer.format.settings,
                            commonFormat: .pcmFormatFloat32, interleaved: false
                        )
                        state.sampleRate = buffer.format.sampleRate
                    }
                    guard let file = state.file else { return }
                    do {
                        try file.write(from: buffer)
                        state.frames += Int64(buffer.frameLength)
                    } catch {
                        Log.capture.notice(
                            "enrolment write failed: \(logSafeDescription(error), privacy: .public)"
                        )
                    }
                    state.level = Self.peak(of: buffer)
                    state.speechSeconds += Self.speechSeconds(in: buffer)
                }
            },
            onConfigurationChange: {},
            voiceProcessing: { false }
        )
        state.withLock { $0.closed = false }
        engine.withLock { $0 = source }
        do {
            try source.buildAndStart(preferred: AudioFormatDescriptor(sampleRate: 48_000, channelCount: 1))
        } catch {
            engine.withLock { $0 = nil }
            state.withLock { $0.closed = true }
            throw error
        }
    }

    /// Stops capture and closes the file. Returns how many seconds were written.
    @discardableResult
    public func stop() -> Double {
        let source = engine.withLock { source -> MicrophoneSource? in
            let running = source
            source = nil
            return running
        }
        source?.teardown()
        // `speechSeconds` deliberately survives: a reader told they are short
        // carries on from where they got to rather than from zero.
        return state.withLock { state in
            let seconds = state.sampleRate > 0 ? Double(state.frames) / state.sampleRate : 0
            state.closed = true
            state.file = nil
            state.frames = 0
            state.sampleRate = 0
            state.level = 0
            return seconds
        }
    }

    /// How much of one buffer to count towards the bar: all of it when it is
    /// loud enough to be somebody talking, none of it otherwise.
    public static func speechSeconds(in buffer: AVAudioPCMBuffer) -> Double {
        guard buffer.format.sampleRate > 0, peak(of: buffer) >= speechFloor else { return 0 }
        return Double(buffer.frameLength) / buffer.format.sampleRate
    }

    private static func peak(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        var loudest: Float = 0
        for frame in 0..<Int(buffer.frameLength) {
            loudest = max(loudest, abs(channels[0][frame]))
        }
        return min(1, loudest)
    }
}
