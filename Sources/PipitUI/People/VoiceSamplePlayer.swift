import AVFoundation
import Foundation
import Observation
import PipitCore
import PipitServices

/// Plays one stretch of a meeting's audio and stops at the end of it.
///
/// A sample answers "is this who I think it is" by ear, which no name, score or
/// count on the page can. It plays from the meeting's own mixdown rather than a
/// stored clip, because the audio is already on disk and copying seconds of a
/// person's voice into a second place is a copy nothing later deletes.
@MainActor
@Observable
public final class VoiceSamplePlayer {
    /// What is playing, named by whoever asked for it. Nil when nothing is.
    public private(set) var playing: String?

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var ending: Task<Void, Never>?

    public init() {}

    public func play(_ sample: VoiceSample, tagged tag: String) {
        stop()
        guard sample.duration > 0 else { return }
        do {
            let player = try AVAudioPlayer(contentsOf: sample.audio)
            player.prepareToPlay()
            player.currentTime = sample.start
            guard player.play() else { return }
            self.player = player
            playing = tag
            // The player has no "stop at" of its own, and the span is the point:
            // running on into the next speaker would answer the question with
            // somebody else's voice.
            ending = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(Int(sample.duration * 1000)))
                guard !Task.isCancelled else { return }
                self?.stop()
            }
        } catch {
            Log.ui.notice("sample unplayable: \(logSafeDescription(error), privacy: .public)")
        }
    }

    public func stop() {
        ending?.cancel()
        ending = nil
        player?.stop()
        player = nil
        playing = nil
    }
}
