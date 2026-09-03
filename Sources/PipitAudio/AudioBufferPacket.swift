import AVFoundation
import Foundation

/// A copied audio buffer being handed from an audio callback to another queue.
///
/// `AVAudioPCMBuffer` is not `Sendable`, and tap buffers are only valid inside
/// their callback. Every packet holds a fresh copy that the producer no longer
/// touches, which is what makes the hand-off safe.
public struct AudioBufferPacket: @unchecked Sendable {
    public let buffer: AVAudioPCMBuffer
    /// Host time of the first frame, from the same mach clock both sources use.
    public let hostTime: Double

    public init(buffer: AVAudioPCMBuffer, hostTime: Double) {
        self.buffer = buffer
        self.hostTime = hostTime
    }

    public var seconds: Double {
        buffer.format.sampleRate > 0 ? Double(buffer.frameLength) / buffer.format.sampleRate : 0
    }
}

public typealias AudioBufferSink = @Sendable (AudioBufferPacket) -> Void

/// One IOProc callback's audio, and whether the channel-count fallback read it.
public struct TapStreamSelection {
    public let buffer: AVAudioPCMBuffer?
    /// True when an index was known but its buffer was unusable, so a
    /// channel-count match was read instead. The caller logs it once per bind.
    public let usedFallback: Bool
}

/// Copies an `AudioBufferList` delivered by an IOProc into an owned buffer.
///
/// An aggregate device built around a process tap delivers one buffer per
/// interleaved input stream. A non-interleaved stream delivers one buffer per
/// channel instead, which the branch below handles on its own, so the
/// stream-index equation holds for the interleaved case only. A MacBook Pro
/// reports `[8ch/16384B, 2ch/4096B]` for a stereo tap, the output device's
/// eight channels and then the tap's two, both carrying the same 512 frames.
/// `tapStreamIndex` comes from the aggregate's input stream count, so the tap
/// is read by position.
///
/// That the sub-device's streams come first and the tap's comes last is
/// inferred from that one observed shape on one Mac, and Apple documents no
/// ordering. Matching on channel count is the fallback for a list where it does
/// not hold.
///
/// Channel count cannot be the first rule, because it picks whichever stream
/// happens to carry as many channels as the tap, and plenty of devices carry
/// two. A stereo USB interface or a virtual device sits ahead of the tap in the
/// list, and its silence gets recorded as the meeting.
///
/// A frame count is also per stream, so bytes are divided by that stream's own
/// channels. Reading the first stream's byte count as frames recorded eight
/// seconds of audio for every second of a meeting.
public func makeBuffer(
    from bufferList: UnsafePointer<AudioBufferList>, format: AVAudioFormat, tapStreamIndex: Int?
) -> TapStreamSelection {
    let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
    guard !list.isEmpty else { return TapStreamSelection(buffer: nil, usedFallback: false) }
    let channels = Int(format.channelCount)
    guard channels > 0 else { return TapStreamSelection(buffer: nil, usedFallback: false) }

    if let tapStreamIndex, tapStreamIndex >= 0, tapStreamIndex < list.count {
        let candidate = list[tapStreamIndex]
        if Int(candidate.mNumberChannels) == channels, candidate.mData != nil {
            // `copyInterleaved` returns nil when the stream carried no frames.
            // The dropped callback needs no log of its own. No packet means no
            // `noteBufferArrived`, so a tap that keeps doing this while its
            // target produces output is already reported as
            // `producingWithoutCallbacks`.
            return TapStreamSelection(
                buffer: copyInterleaved(candidate, into: format), usedFallback: false
            )
        }
    }

    // One buffer per channel, which is what a non-interleaved source produces.
    // The tap index counts streams, so it does not address these buffers and
    // missing it here is not the fallback the caller logs.
    if list.count > 1, list.allSatisfy({ $0.mNumberChannels == 1 }) {
        let frames = Int(list[0].mDataByteSize) / MemoryLayout<Float>.size
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let destination = buffer.floatChannelData
        else { return TapStreamSelection(buffer: nil, usedFallback: false) }
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<channels {
            if channel < list.count, let source = list[channel].mData {
                destination[channel].update(from: source.assumingMemoryBound(to: Float.self), count: frames)
            } else {
                destination[channel].update(repeating: 0, count: frames)
            }
        }
        return TapStreamSelection(buffer: buffer, usedFallback: false)
    }

    // Otherwise every stream is interleaved. Take the one that matches the tap.
    let usedFallback = tapStreamIndex != nil
    let stream = list.first { Int($0.mNumberChannels) == channels && $0.mData != nil }
        ?? list.first { $0.mData != nil }
    guard let stream else { return TapStreamSelection(buffer: nil, usedFallback: usedFallback) }
    return TapStreamSelection(
        buffer: copyInterleaved(stream, into: format), usedFallback: usedFallback
    )
}

/// Deinterleaves one stream into a buffer of `format`, padding channels the
/// stream does not carry with silence.
private func copyInterleaved(_ stream: AudioBuffer, into format: AVAudioFormat) -> AVAudioPCMBuffer? {
    guard let data = stream.mData else { return nil }
    let channels = Int(format.channelCount)
    let sourceChannels = max(1, Int(stream.mNumberChannels))
    let frames = Int(stream.mDataByteSize) / MemoryLayout<Float>.size / sourceChannels
    guard frames > 0,
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
          let destination = buffer.floatChannelData
    else { return nil }
    buffer.frameLength = AVAudioFrameCount(frames)
    let source = data.assumingMemoryBound(to: Float.self)
    for channel in 0..<channels {
        if channel < sourceChannels {
            for frame in 0..<frames {
                destination[channel][frame] = source[frame * sourceChannels + channel]
            }
        } else {
            destination[channel].update(repeating: 0, count: frames)
        }
    }
    return buffer
}
