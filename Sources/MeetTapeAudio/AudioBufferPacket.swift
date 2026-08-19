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

/// Copies an `AudioBufferList` delivered by an IOProc into an owned buffer.
///
/// An aggregate device built around a process tap delivers one stream per
/// sub-device, and only one of them is the tap. A MacBook Pro reports
/// `[8ch/16384B, 2ch/4096B]` for a stereo tap: the output device's own eight
/// channels first, then the tap's two, both carrying the same 512 frames. The
/// stream whose channel count matches the tap is the meeting audio, and a frame
/// count has to be divided by that stream's channels. Reading the first stream's
/// byte count as frames recorded eight seconds of audio for every second of a
/// meeting.
public func makeBuffer(
    from bufferList: UnsafePointer<AudioBufferList>, format: AVAudioFormat
) -> AVAudioPCMBuffer? {
    let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
    guard !list.isEmpty else { return nil }
    let channels = Int(format.channelCount)
    guard channels > 0 else { return nil }

    // One buffer per channel, which is what a non-interleaved source produces.
    if list.count > 1, list.allSatisfy({ $0.mNumberChannels == 1 }) {
        let frames = Int(list[0].mDataByteSize) / MemoryLayout<Float>.size
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let destination = buffer.floatChannelData
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<channels {
            if channel < list.count, let source = list[channel].mData {
                destination[channel].update(from: source.assumingMemoryBound(to: Float.self), count: frames)
            } else {
                destination[channel].update(repeating: 0, count: frames)
            }
        }
        return buffer
    }

    // Otherwise every stream is interleaved. Take the one that matches the tap.
    let stream = list.first { Int($0.mNumberChannels) == channels && $0.mData != nil }
        ?? list.first { $0.mData != nil }
    guard let stream, let data = stream.mData else { return nil }
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
