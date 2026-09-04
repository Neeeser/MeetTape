import CWebRTCAEC3
import Foundation

/// Subtracts the far end from the microphone, using the recording of the far
/// end as the reference.
///
/// A call taken on speakers puts the far end into the microphone: it leaves the
/// speakers, crosses the room and arrives back at the capsule. By the time any
/// software sees the microphone the two are one signal, and no amount of
/// separating streams afterwards unmixes them, because the mixing happened in
/// the air.
///
/// Every application that solves this subtracts a copy of what it played. Apple
/// ships one for it, and it cancels only what its own host renders, so it did
/// nothing here and was removed: Pipit renders nothing, the meeting application
/// does. What Pipit holds instead is the process tap, a clean recording of that
/// same far end, which is the reference an echo canceller wants.
///
/// Measured on two recordings from 3 September 2026: 36 dB of the far end
/// removed, with the user's own speech within 0.4 dB of untouched.
public final class EchoCanceller {
    /// Frames per call, for both streams. The canceller works in 10 ms blocks.
    public let blockFrames: Int

    private let handle: OpaquePointer

    /// Nil below 8 kHz, which is the lowest rate the library accepts. Pipit
    /// hands it 16 kHz.
    ///
    /// Mono only. Pipit resamples both tracks to 16 kHz mono before they reach
    /// here, and one channel is the whole of what the canceller sees.
    public init?(sampleRate: Int) {
        guard let handle = pipit_aec3_create(Int32(sampleRate)) else {
            return nil
        }
        self.handle = handle
        blockFrames = Int(pipit_aec3_frame_size(handle))
    }

    deinit { pipit_aec3_destroy(handle) }

    /// How much of the microphone the canceller removed over the most recent
    /// blocks, in decibels.
    ///
    /// This is the enhancement, what subtraction took out. It is not the loss
    /// along the path from the speakers back to the microphone, which the
    /// library reports separately and which says only what the room did to the
    /// sound.
    ///
    /// Near zero on headphones, where there is no path from the speakers to
    /// the microphone and nothing to subtract. Reading it is what says to throw
    /// the cleaned track away. With a loud reference and no echo to lock onto,
    /// the canceller works from render power and an assumed path gain and takes
    /// tens of decibels out of a microphone that holds only the user. The
    /// measured figure is asserted in `AudioTests`.
    public var echoRemovedDB: Double { Double(pipit_aec3_echo_removed_db(handle)) }

    /// Cleans one block of microphone audio in place.
    ///
    /// The far end's block for the same moment goes in first, because the
    /// canceller has to know what was played before it can recognise it coming
    /// back. Both arrays are `blockFrames` long.
    public func process(microphone: inout [Float], reference: [Float]) -> Bool {
        guard microphone.count == blockFrames, reference.count == blockFrames else {
            return false
        }
        let played = reference.withUnsafeBufferPointer {
            pipit_aec3_process_reverse(handle, $0.baseAddress, blockFrames)
        }
        guard played == 0 else { return false }
        return microphone.withUnsafeMutableBufferPointer {
            pipit_aec3_process(handle, $0.baseAddress, blockFrames)
        } == 0
    }
}
