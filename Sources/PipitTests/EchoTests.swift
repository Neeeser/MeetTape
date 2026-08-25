import Foundation
import PipitAudio
import PipitCore
import TestKit

/// Pins the measurement that separates the far end coming back through the
/// speakers from the local user's own voice.
///
/// The signals here are synthetic, and deliberately so: a room's response and a
/// speaker's delay are the two things the measurement has to survive, and
/// building them by hand is the only way to know what the answer should be. The
/// numbers the thresholds came from are in `LocalSpeechPolicy`.
enum EchoTests {
    static let rate = 16_000.0

    /// Repeatable pseudo-random noise. A fixed generator rather than
    /// `Float.random`, so a failure here is the same failure tomorrow.
    struct Noise {
        var state: UInt64
        mutating func next() -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(Int32(truncatingIfNeeded: state >> 32)) / Float(Int32.max)
        }
        mutating func signal(count: Int, amplitude: Float = 0.2) -> [Float] {
            (0..<count).map { _ in next() * amplitude }
        }
    }

    /// Speech-like rather than flat: bursts with pauses between them, because a
    /// track that is loud everywhere makes every measure look good.
    static func bursty(count: Int, seed: UInt64) -> [Float] {
        var noise = Noise(state: seed)
        var out = noise.signal(count: count)
        let burst = Int(rate * 0.6)
        let gap = Int(rate * 0.4)
        var index = 0
        while index < count {
            // Both ends clamped: a track whose length is not a whole number of
            // burst-and-gap cycles ends mid-cycle, and the last gap then starts
            // past the end of it.
            let quietStart = min(count, index + burst)
            let quietEnd = min(count, index + burst + gap)
            for position in quietStart..<quietEnd {
                out[position] *= 0.02
            }
            index = index + burst + gap
        }
        return out
    }

    /// What a laptop's speakers and microphone do to the far end: a delay, a few
    /// reflections, and a gain.
    static func echoed(_ source: [Float], delay: Int, gain: Float = 0.5) -> [Float] {
        let response: [Float] = [1.0, 0.0, -0.4, 0.2, 0.0, 0.1, -0.05]
        var out = [Float](repeating: 0, count: source.count)
        for (offset, tap) in response.enumerated() {
            let shift = delay + offset
            guard shift < source.count else { continue }
            for index in shift..<source.count {
                out[index] += source[index - shift] * tap * gain
            }
        }
        return out
    }

    /// The microphone's energy per window, which is how the gate weights the
    /// profile: a loud window's measurement counts for more than a quiet one's.
    static func energies(_ mic: [Float], windowSeconds: Double) -> [Double] {
        let size = Int(windowSeconds * rate)
        return stride(from: 0, to: mic.count - mic.count % size, by: size).map { start in
            var total = 0.0
            for index in start..<(start + size) { total += Double(mic[index] * mic[index]) }
            return total
        }
    }

    static func meanDecibels(_ profile: [Int16], weights: [Double]) -> Double {
        var weighted = 0.0
        var total = 0.0
        for (value, weight) in zip(profile, weights) {
            weighted += weight * Double(value) / 10
            total += weight
        }
        return total > 0 ? weighted / total : 0
    }

    static var suite: Suite {
        Suite("Echo", [
            test("the delay the far end reaches the microphone at is found") { expect in
                let remote = bursty(count: Int(rate * 20), seed: 1)
                let delay = 2_035  // 127 ms, what the Capital One call measured
                let mic = echoed(remote, delay: delay)
                let found = EchoReturnLossProfile.delay(
                    mic: mic, remote: remote, maxLag: Int(rate * 0.6)
                )
                expect.isTrue(
                    abs(found.samples - delay) <= 16,
                    "found \(found.samples) samples against \(delay), within a millisecond"
                )
                expect.isTrue(found.sharpness > 20, "and the peak stands well clear of the range")
            },

            test("a microphone holding only the far end reports the echo") { expect in
                let remote = bursty(count: Int(rate * 20), seed: 2)
                var noise = Noise(state: 99)
                let floor = noise.signal(count: remote.count, amplitude: 0.002)
                let mic = zip(echoed(remote, delay: 1_600), floor).map(+)

                let delay = EchoReturnLossProfile.delay(
                    mic: mic, remote: remote, maxLag: Int(rate * 0.6)
                ).samples
                let profile = EchoReturnLossProfile.measure(
                    mic: mic, remote: remote, delay: delay, sampleRate: rate,
                    windowSeconds: 0.25
                )
                let weights = energies(mic, windowSeconds: 0.25)
                expect.isTrue(
                    meanDecibels(profile, weights: weights) > 3,
                    "a track that is nothing but echo reads far above the threshold"
                )
            },

            test("a microphone holding a different voice reports no echo") { expect in
                // The user talking on headphones: both tracks hold speech, and
                // neither is a copy of the other. This is the case the clause
                // must never fire on, so the bar is the threshold itself.
                let remote = bursty(count: Int(rate * 20), seed: 3)
                let mic = bursty(count: Int(rate * 20), seed: 4)
                let delay = EchoReturnLossProfile.delay(
                    mic: mic, remote: remote, maxLag: Int(rate * 0.6)
                ).samples
                let profile = EchoReturnLossProfile.measure(
                    mic: mic, remote: remote, delay: delay, sampleRate: rate,
                    windowSeconds: 0.25
                )
                let weights = energies(mic, windowSeconds: 0.25)
                let reading = meanDecibels(profile, weights: weights)
                expect.isTrue(
                    reading < LocalSpeechPolicy.echoReturnLossDB,
                    "read \(reading) dB, under the \(LocalSpeechPolicy.echoReturnLossDB) dB the gate drops at"
                )
            },

            test("the user speaking over the echo keeps their own words") { expect in
                // Both at once: the far end leaking in at half gain while the
                // user speaks into the microphone at full. The echo is real and
                // the filter finds it, but it accounts for little of the energy,
                // which is what has to keep the segment.
                let remote = bursty(count: Int(rate * 20), seed: 5)
                let user = bursty(count: Int(rate * 20), seed: 6)
                let mic = zip(user, echoed(remote, delay: 1_600, gain: 0.12)).map(+)
                let delay = EchoReturnLossProfile.delay(
                    mic: mic, remote: remote, maxLag: Int(rate * 0.6)
                ).samples
                let profile = EchoReturnLossProfile.measure(
                    mic: mic, remote: remote, delay: delay, sampleRate: rate,
                    windowSeconds: 0.25
                )
                let weights = energies(mic, windowSeconds: 0.25)
                let reading = meanDecibels(profile, weights: weights)
                expect.isTrue(
                    reading < LocalSpeechPolicy.echoReturnLossDB,
                    "read \(reading) dB with the user's own voice carrying the segment"
                )
            },

            test("measuring a meeting in pieces reads the same as measuring it whole") { expect in
                // The builder never has both tracks in memory at once. It hands
                // over a few minutes at a time with the far end's history
                // attached in front, and `remoteLead` says how much of that
                // history is there. A sign error in that arithmetic fits the
                // filter against the wrong instant, which reads as no echo and
                // would look exactly like a meeting on headphones, so nothing
                // else in this suite would catch it.
                let remote = bursty(count: Int(rate * 24), seed: 11)
                let mic = echoed(remote, delay: 1_600)
                let delay = EchoReturnLossProfile.delay(
                    mic: mic, remote: remote, maxLag: Int(rate * 0.6)
                ).samples

                let whole = EchoReturnLossProfile.measure(
                    mic: mic, remote: remote, delay: delay, sampleRate: rate,
                    windowSeconds: 0.25, blockSeconds: 8
                )
                let lead = EchoReturnLossProfile.filterTaps + max(0, delay)
                let piece = Int(rate * 8)
                var streamed: [Int16] = []
                var start = 0
                while start < mic.count {
                    let end = min(mic.count, start + piece)
                    let history = (0..<lead).map { offset -> Float in
                        let index = start - lead + offset
                        return index >= 0 ? remote[index] : 0
                    }
                    streamed += EchoReturnLossProfile.measure(
                        mic: Array(mic[start..<end]),
                        remote: history + Array(remote[start..<end]),
                        delay: delay, sampleRate: rate, windowSeconds: 0.25,
                        remoteLead: lead, blockSeconds: 8
                    )
                    start = end
                }
                expect.equal(streamed.count, whole.count, "the same windows come out")
                expect.equal(streamed, whole, "and the same measurements in them")
            },

            test("the pieces still agree when the far end's copy arrives early") { expect in
                // A delay found below zero puts the far end ahead of the
                // microphone rather than behind it, so a chunk needs far-end
                // samples from after its own end as well as before its start.
                // Only a meeting with no acoustic path measures below zero, so
                // nothing on disk exercises this and only a test can.
                let remote = bursty(count: Int(rate * 24), seed: 16)
                let mic = bursty(count: Int(rate * 24), seed: 17)
                let delay = -2_400  // 150 ms early
                let whole = EchoReturnLossProfile.measure(
                    mic: mic, remote: remote, delay: delay, sampleRate: rate,
                    windowSeconds: 0.25, blockSeconds: 8
                )
                let lead = EchoReturnLossProfile.filterTaps + max(0, delay)
                let ahead = max(0, -delay)
                let piece = Int(rate * 8)
                var streamed: [Int16] = []
                var start = 0
                while start < mic.count {
                    let end = min(mic.count, start + piece)
                    // What the builder assembles: history in front, and the
                    // look-ahead past the chunk's own end.
                    let window = (0..<(lead + (end - start) + ahead)).map { offset -> Float in
                        let index = start - lead + offset
                        return index >= 0 && index < remote.count ? remote[index] : 0
                    }
                    streamed += EchoReturnLossProfile.measure(
                        mic: Array(mic[start..<end]), remote: window, delay: delay,
                        sampleRate: rate, windowSeconds: 0.25, remoteLead: lead,
                        blockSeconds: 8
                    )
                    start = end
                }
                expect.equal(streamed, whole, "the same measurements either way")
            },

            test("a far end that stopped recording first reads as silence, not as echo") { expect in
                // The process tap delivers nothing while the application is idle,
                // so the far end's track can end while the microphone is still
                // running. The builder pads the rest with silence. Silence
                // explains nothing, so those windows have to read zero rather
                // than deleting whatever the user said after the call dropped.
                let remote = bursty(count: Int(rate * 10), seed: 12)
                let mic = bursty(count: Int(rate * 20), seed: 13)
                let padded = remote + [Float](repeating: 0, count: mic.count - remote.count)
                let profile = EchoReturnLossProfile.measure(
                    mic: mic, remote: padded, delay: 1_600, sampleRate: rate,
                    windowSeconds: 0.25
                )
                let afterTheTap = profile.suffix(profile.count / 2)
                expect.isTrue(
                    afterTheTap.allSatisfy { $0 == 0 },
                    "nothing to subtract once the far end's track ends"
                )
            },

            test("a short remainder is measured against the block before it") { expect in
                // Fitting 512 taps to one window of 4,000 samples explains most
                // of whatever is in it, echo or not. A meeting whose length
                // leaves a window or two over must not have its closing words
                // measured that way.
                let remote = bursty(count: Int(rate * 20) + Int(rate * 0.3), seed: 14)
                let mic = bursty(count: remote.count, seed: 15)
                let profile = EchoReturnLossProfile.measure(
                    mic: mic, remote: remote, delay: 1_600, sampleRate: rate,
                    windowSeconds: 0.25, blockSeconds: 10
                )
                let tail = profile.suffix(4).map { Double($0) / 10 }
                expect.isTrue(
                    tail.allSatisfy { $0 < LocalSpeechPolicy.echoReturnLossDB },
                    "the last windows read \(tail) with no echo in them"
                )
            },

            test("a silent far end measures nothing rather than everything") { expect in
                // Nobody on the call is speaking. There is no echo to find, and
                // fitting a filter to silence must not produce a reading that
                // deletes the user's words.
                let remote = [Float](repeating: 0, count: Int(rate * 10))
                let mic = bursty(count: Int(rate * 10), seed: 7)
                let profile = EchoReturnLossProfile.measure(
                    mic: mic, remote: remote, delay: 0, sampleRate: rate,
                    windowSeconds: 0.25
                )
                expect.isTrue(profile.allSatisfy { $0 == 0 }, "nothing to subtract, nothing removed")
            },
        ])
    }
}
