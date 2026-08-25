import Accelerate
import Foundation
import PipitCore

/// Measures how much of the microphone track the far end's own audio accounts
/// for, so the gate can tell the speakers playing the call back into the
/// microphone from the local user speaking.
///
/// The two tracks make this answerable. The far end is captured from the
/// application's own output, before it reaches the speakers, so it is a clean
/// reference for whatever comes back through the room. What returns is that
/// reference delayed by the output path and coloured by the room, which is a
/// linear filter of it: fit the filter, subtract what it predicts, and whatever
/// is left is what the microphone heard that the far end cannot explain.
///
/// The measurement is deliberately not an echo canceller. Nothing here rewrites
/// the recorded audio, which stays exactly as it was captured. Only the ratio
/// between the microphone and the residual is kept, one figure per window.
public enum EchoReturnLossProfile {
    /// Length of the fitted filter, in samples at 16 kHz: 32 ms, which covers a
    /// laptop's direct path and its first reflections once the bulk delay has
    /// been taken out separately.
    ///
    /// Measured against the labelled segments at 256, 512, 1024 and 2048 taps.
    /// Longer filters have enough freedom to explain a little of any microphone
    /// track, which lifts genuine speech from 0.11 dB to 0.93 and eats the
    /// margin the threshold depends on. Shorter ones stop capturing the
    /// reflections and halve the reading on real leakage.
    public static let filterTaps = 512

    /// How much audio one fitted filter covers.
    ///
    /// The room changes over a meeting: the user moves, the volume is adjusted,
    /// the output device is switched. One filter per minute tracks that. Fitting
    /// per 15 or 30 seconds tracks it more closely but starts fitting the
    /// microphone's own content as well, and genuine speech climbs from 0.11 dB
    /// to 0.87. Five-minute blocks stop tracking the room and halve the reading
    /// on leakage.
    public static let blockSeconds = 60.0

    /// How far apart the two tracks are allowed to be. The Capital One call
    /// measured 127 ms between the far end being captured and it arriving back
    /// through the speakers; 600 ms leaves room for a slower output chain
    /// without letting the search wander.
    public static let searchSeconds = 0.6

    /// Stored in tenths of a decibel, and never below zero: a filter that made
    /// the residual louder found no echo, which is the same answer as finding
    /// none at all.
    static let maximumTenths: Int16 = 400

    /// Where the far end reaches the microphone, and how much the answer is
    /// worth.
    public struct Delay: Sendable, Equatable {
        /// The offset in samples. Meaningless on its own; `sharpness` says
        /// whether to believe it.
        public var samples: Int
        /// How far the peak stands above the rest of the search range. A real
        /// acoustic path reads in the tens; a meeting on headphones has no peak
        /// to speak of and reads near ten or below.
        public var sharpness: Double

        public static let none = Delay(samples: 0, sharpness: 0)
    }

    /// The delay at which the far end reaches the microphone, over one stretch.
    ///
    /// Cross-correlation with a phase transform, which weights every frequency
    /// equally and so peaks on the path itself rather than on whichever band the
    /// speech happens to be loudest in. On a meeting with no acoustic path the
    /// peak is meaningless, and nothing downstream depends on it being
    /// meaningful: the filter then explains nothing and the profile reads zero.
    public static func delay(mic: [Float], remote: [Float], maxLag: Int) -> Delay {
        let count = min(mic.count, remote.count)
        guard count > maxLag * 2, maxLag > 0 else { return .none }
        let size = FFT.size(atLeast: count + maxLag)
        guard let fft = FFT(size: size) else { return .none }
        var real = padded(mic, to: size)
        var imaginary = [Double](repeating: 0, count: size)
        fft.transform(&real, &imaginary, forward: true)
        var otherReal = padded(remote, to: size)
        var otherImaginary = [Double](repeating: 0, count: size)
        fft.transform(&otherReal, &otherImaginary, forward: true)

        // The cross-power spectrum, divided by its own magnitude so only the
        // phase survives.
        for index in 0..<size {
            let productReal = real[index] * otherReal[index] + imaginary[index] * otherImaginary[index]
            let productImaginary =
                imaginary[index] * otherReal[index] - real[index] * otherImaginary[index]
            let magnitude = (productReal * productReal + productImaginary * productImaginary)
                .squareRoot()
            if magnitude > 1e-12 {
                real[index] = productReal / magnitude
                imaginary[index] = productImaginary / magnitude
            } else {
                real[index] = 0
                imaginary[index] = 0
            }
        }
        fft.transform(&real, &imaginary, forward: false)

        var best = 0
        var peak = -Double.infinity
        var total = 0.0
        var considered = 0
        for lag in -maxLag...maxLag {
            let index = lag >= 0 ? lag : size + lag
            guard index >= 0, index < size else { continue }
            let value = abs(real[index] / Double(size))
            total += value
            considered += 1
            if value > peak {
                peak = value
                best = lag
            }
        }
        let mean = considered > 0 ? total / Double(considered) : 0
        return Delay(samples: best, sharpness: mean > 1e-15 ? peak / mean : 0)
    }

    /// Echo return loss per window, in tenths of a decibel.
    ///
    /// - Parameters:
    ///   - mic: the microphone track, on the meeting timeline.
    ///   - remote: the far end's track, on the same timeline.
    ///   - delay: what `delay(mic:remote:maxLag:)` found for this meeting.
    ///   - remoteLead: how many samples of `remote` come before `mic` starts.
    ///     A caller measuring a meeting a few minutes at a time passes the far
    ///     end with the history the filter reaches back over already attached.
    public static func measure(
        mic: [Float],
        remote: [Float],
        delay: Int,
        sampleRate: Double,
        windowSeconds: Double,
        remoteLead: Int = 0,
        taps: Int = filterTaps,
        blockSeconds: Double = blockSeconds
    ) -> [Int16] {
        let windowSize = Int(windowSeconds * sampleRate)
        guard windowSize > 0, taps > 0, !mic.isEmpty else { return [] }
        // Whole windows only, so the series lines up with the level series the
        // gate weights it by.
        let windows = mic.count / windowSize
        guard windows > 0 else { return [] }

        var profile = [Int16](repeating: 0, count: windows)
        // Blocks are a whole number of windows, so no window is ever measured
        // against two different filters.
        let windowsPerBlock = max(1, Int(blockSeconds / windowSeconds))
        // A block has to be long enough that fitting the filter to it means
        // something. Given the freedom of `taps` coefficients, a block of a few
        // hundred samples is fitted almost exactly whatever it holds: a single
        // window of 4,000 samples against 512 taps reads about 0.59 dB on audio
        // with no echo in it at all, which is over the threshold the gate drops
        // at. So a short remainder joins the block before it rather than being
        // fitted on its own, and the last block of a meeting runs long instead
        // of the last utterance being measured against nothing.
        let minimumWindows = max(1, windowsPerBlock / 4)
        var first = 0
        while first < windows {
            var last = min(windows, first + windowsPerBlock)
            if windows - last < minimumWindows { last = windows }
            let start = first * windowSize
            let end = last * windowSize
            measure(
                into: &profile, windowRange: first..<last, sampleRange: start..<end,
                mic: mic, remote: remote, delay: delay, remoteLead: remoteLead,
                taps: taps, windowSize: windowSize
            )
            first = last
        }
        return profile
    }

    /// One block: fit a filter over it, subtract, and record what each window
    /// lost.
    private static func measure(
        into profile: inout [Int16],
        windowRange: Range<Int>,
        sampleRange: Range<Int>,
        mic: [Float],
        remote: [Float],
        delay: Int,
        remoteLead: Int,
        taps: Int,
        windowSize: Int
    ) {
        // The far end lined up with this block, plus the history the filter
        // reaches back over. Samples the far end's track does not cover read as
        // silence, which is what they were.
        var reference = [Double](repeating: 0, count: sampleRange.count + taps - 1)
        let shift = delay + taps - 1
        for index in 0..<reference.count {
            let source = sampleRange.lowerBound + index - shift + remoteLead
            if source >= 0, source < remote.count { reference[index] = Double(remote[source]) }
        }
        let target = mic[sampleRange].map(Double.init)
        guard let filter = leastSquaresFilter(reference: reference, target: target, taps: taps)
        else { return }

        // What the filter says the far end put into the microphone, over the
        // whole block at once. Written as a correlation against the reversed
        // filter, which is the form Accelerate takes.
        var predicted = [Double](repeating: 0, count: target.count)
        let reversed = Array(filter.reversed())
        vDSP_convD(
            reference, 1, reversed, 1, &predicted, 1,
            vDSP_Length(target.count), vDSP_Length(taps)
        )

        for window in windowRange {
            let start = (window - windowRange.lowerBound) * windowSize
            var before = 0.0
            var after = 0.0
            for offset in 0..<windowSize {
                let index = start + offset
                let sample = target[index]
                let residual = sample - predicted[index]
                before += sample * sample
                after += residual * residual
            }
            guard before > 1e-18 else { continue }
            // A residual of nothing is the far end accounting for the window
            // whole, which is the strongest evidence there is. Reading it as no
            // echo would turn the clearest case into the safest one.
            guard after > 0 else {
                profile[window] = maximumTenths
                continue
            }
            let decibels = 10 * log10(before / after)
            guard decibels > 0 else { continue }
            profile[window] = Int16(min(Double(maximumTenths), (decibels * 10).rounded()))
        }
    }

    /// The filter of `reference` that comes closest to `target`, by least
    /// squares.
    ///
    /// Solved through the Wiener-Hopf equations, whose matrix is Toeplitz, so
    /// Levinson-Durbin recursion does it in the square of the tap count rather
    /// than the cube. Returns nil where the far end held nothing to fit.
    static func leastSquaresFilter(reference: [Double], target: [Double], taps: Int) -> [Double]? {
        guard reference.count >= target.count + taps - 1, taps > 0 else { return nil }
        let usable = target.count
        // Both correlations come out reversed, because Accelerate's correlation
        // walks the longer signal forward while the lag counts backwards from
        // the filter's most recent tap.
        var autocorrelation = [Double](repeating: 0, count: taps)
        var crossCorrelation = [Double](repeating: 0, count: taps)
        let recent = Array(reference[(taps - 1)...])
        vDSP_convD(
            reference, 1, recent, 1, &autocorrelation, 1,
            vDSP_Length(taps), vDSP_Length(usable)
        )
        vDSP_convD(
            reference, 1, target, 1, &crossCorrelation, 1,
            vDSP_Length(taps), vDSP_Length(usable)
        )
        autocorrelation.reverse()
        crossCorrelation.reverse()

        guard autocorrelation[0] > 0 else { return nil }
        // A little energy added to the diagonal, so a far end that barely moves
        // over a block cannot produce a filter of enormous coefficients that
        // happens to fit the microphone.
        autocorrelation[0] *= 1.001
        return solveToeplitz(autocorrelation, crossCorrelation)
    }

    /// Levinson-Durbin: solves a symmetric Toeplitz system built from `row`.
    static func solveToeplitz(_ row: [Double], _ righthand: [Double]) -> [Double]? {
        let count = row.count
        guard count > 0, row[0] != 0, righthand.count == count else { return nil }
        var forward = [Double](repeating: 0, count: count)
        var solution = [Double](repeating: 0, count: count)
        forward[0] = 1 / row[0]
        solution[0] = righthand[0] / row[0]
        guard count > 1 else { return solution }

        for step in 1..<count {
            // How far the current forward vector misses the next row by.
            var forwardMismatch = 0.0
            for index in 0..<step { forwardMismatch += row[step - index] * forward[index] }
            let beta = 1 - forwardMismatch * forwardMismatch
            guard abs(beta) > 1e-15 else { return nil }

            var next = [Double](repeating: 0, count: count)
            for index in 0...step {
                let head = index < step ? forward[index] : 0
                let tail = index > 0 ? forward[step - index] : 0
                next[index] = (head - forwardMismatch * tail) / beta
            }
            forward = next

            var solutionMismatch = 0.0
            for index in 0..<step { solutionMismatch += row[step - index] * solution[index] }
            let correction = righthand[step] - solutionMismatch
            for index in 0...step {
                solution[index] += correction * forward[step - index]
            }
        }
        return solution.allSatisfy(\.isFinite) ? solution : nil
    }

    private static func padded(_ values: [Float], to size: Int) -> [Double] {
        var out = [Double](repeating: 0, count: size)
        for index in 0..<min(values.count, size) { out[index] = Double(values[index]) }
        return out
    }
}

/// The complex transform the delay search needs, over Accelerate.
///
/// A class rather than a struct so the setup Accelerate allocates is released
/// when the last reference goes.
final class FFT {
    let size: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetupD

    init?(size: Int) {
        guard size > 1, size & (size - 1) == 0 else { return nil }
        let log2n = vDSP_Length(log2(Double(size)).rounded())
        guard let setup = vDSP_create_fftsetupD(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        self.size = size
        self.log2n = log2n
        self.setup = setup
    }

    deinit { vDSP_destroy_fftsetupD(setup) }

    static func size(atLeast minimum: Int) -> Int {
        var size = 1
        while size < minimum { size <<= 1 }
        return size
    }

    /// In place, both directions. The inverse is left unscaled, which is why the
    /// caller divides by the size.
    func transform(_ real: inout [Double], _ imaginary: inout [Double], forward: Bool) {
        real.withUnsafeMutableBufferPointer { realBuffer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                var split = DSPDoubleSplitComplex(
                    realp: realBuffer.baseAddress!, imagp: imaginaryBuffer.baseAddress!
                )
                vDSP_fft_zipD(
                    setup, &split, 1, log2n,
                    FFTDirection(forward ? kFFTDirection_Forward : kFFTDirection_Inverse)
                )
            }
        }
    }
}
