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
public func makeBuffer(
    from bufferList: UnsafePointer<AudioBufferList>, format: AVAudioFormat
) -> AVAudioPCMBuffer? {
    let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
    guard let first = list.first, let firstData = first.mData else { return nil }
    let channels = Int(format.channelCount)
    guard channels > 0 else { return nil }

    if list.count > 1 {
        // Non-interleaved: one buffer per channel.
        let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let destination = buffer.floatChannelData
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<min(channels, list.count) {
            guard let source = list[channel].mData else { continue }
            destination[channel].update(from: source.assumingMemoryBound(to: Float.self), count: frames)
        }
        return buffer
    }

    let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / channels
    guard frames > 0,
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
          let destination = buffer.floatChannelData
    else { return nil }
    buffer.frameLength = AVAudioFrameCount(frames)
    let source = firstData.assumingMemoryBound(to: Float.self)
    for channel in 0..<channels {
        for frame in 0..<frames {
            destination[channel][frame] = source[frame * channels + channel]
        }
    }
    return buffer
}
