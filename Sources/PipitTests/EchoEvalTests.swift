import Foundation
import PipitCore
import PipitServices
import TestKit

/// What `pipit-eval echo` measures, on fixtures whose echo path is known.
///
/// The command exists because every number supporting the canceller so far
/// came from a continuous tone. These fixtures are still tones, so they pin
/// the arithmetic and the classification rather than the canceller's behaviour
/// on speech. Speech numbers come from running the command over real
/// recordings, which no test does.
enum EchoEvalTests {
    static let rate = MicrophoneCleanerTests.rate
    /// Seconds of fixture. Long enough that the far end is above the floor in
    /// more than the forty windows the cleaner's decision needs.
    static let seconds = 32.0
    /// The room noise a real capsule always has, well under the -60 dBFS floor
    /// the classification uses. Digital silence would make every quiet window
    /// read -120 dBFS and would hide what the canceller does to a microphone
    /// that holds nothing.
    static let noiseTone = 3_100.0
    static let noiseAmplitude: Float = 0.0003

    // MARK: - fixtures

    /// A call whose far end plays in bursts, so the pair can be moved.
    ///
    /// The far end plays over its own seconds 0 to 8 and 18 to 26, which land
    /// in the microphone two seconds later. The user talks over microphone
    /// seconds 12 to 18, where the far end is quiet, and again over 21 to 27,
    /// where it is not. That gives one stretch of the user alone and one of
    /// both at once, which is the split the retention figures are reported on.
    ///
    /// `micHoldsEcho` false is the same call taken on headphones: the far end
    /// plays and nothing of it comes back to the capsule.
    static func makeBurstyCall(
        root: URL, micHoldsEcho: Bool = true, userSpeaks: Bool = true,
        remoteStartOffset: Double = 2, roomNoise: Float = noiseAmplitude
    ) throws -> (metadata: MeetingMetadata, store: MeetingStore, repository: MeetingRepository) {
        let count = Int(seconds * rate)
        var remote = MicrophoneCleanerTests.tone(
            count: count, frequency: MicrophoneCleanerTests.farToneA, amplitude: 0.5
        )
        for index in 0..<count {
            let at = Double(index) / rate
            let playing = (at >= 0 && at < 8) || (at >= 18 && at < 26)
            if !playing { remote[index] = 0 }
        }

        var mic = MicrophoneCleanerTests.tone(
            count: count, frequency: noiseTone, amplitude: roomNoise
        )
        if userSpeaks {
            for (from, upTo) in [(12.0, 18.0), (21.0, 27.0)] {
                let user = MicrophoneCleanerTests.tone(
                    count: count, frequency: MicrophoneCleanerTests.nearTone, amplitude: 0.3,
                    from: Int(from * rate), upTo: Int(upTo * rate)
                )
                for index in 0..<count { mic[index] += user[index] }
            }
        }
        if micHoldsEcho {
            let shift = Int(remoteStartOffset * rate) + MicrophoneCleanerTests.echoDelaySamples
            for index in max(0, shift)..<count {
                mic[index] += MicrophoneCleanerTests.echoGain * remote[index - shift]
            }
        }
        return try MicrophoneCleanerTests.makeMeeting(
            root: root, mic: mic, remote: remote, remoteStartOffset: remoteStartOffset
        )
    }

    /// Every file under a meeting folder, with its size. The command is
    /// read-only on the archive, and this is what says so.
    static func contents(of root: URL) -> [String: Int] {
        var out: [String: Int] = [:]
        let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.fileSizeKey]
        )
        while let url = enumerator?.nextObject() as? URL {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            out[url.path.replacingOccurrences(of: root.path, with: "")] = size
        }
        return out
    }

    static func summary(
        _ report: EchoMeasurement.Report, _ windowClass: EchoMeasurement.WindowClass
    ) -> EchoMeasurement.ClassSummary {
        report.summary(windowClass)
    }

    // MARK: - the suite

    static let suite = Suite("EchoEval", [
        test("a call on speakers reports the user surviving and the far end leaving") { expect in
            let root = try ManifestTests.makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let meeting = try makeBurstyCall(root: root)
            let measurement = try EchoMeasurement.measure(
                store: meeting.store, metadata: meeting.metadata,
                timeline: try meeting.store.readTimeline()
            )
            guard case .measured(let report) = measurement else {
                expect.fail("a two-track call came back \(measurement)")
                return
            }

            expect.equal(report.decision, CleaningOutcome.cleaned)
            expect.close(report.seconds, seconds, tolerance: 0.2)

            // The far end plays for sixteen of the thirty-two seconds.
            expect.close(report.farEndDutyCycle, 0.5, tolerance: 0.05)
            expect.equal(
                report.farEndActiveWindows,
                summary(report, .farEndOnly).windows + summary(report, .both).windows,
                "far-end-active is the two classes the far end is above its floor in"
            )

            // This fixture's room tone sits under the far end's floor, so that
            // floor is the one that decided the microphone's.
            expect.close(try expect.unwrap(report.microphoneQuietWindowDBFS), -73.5, tolerance: 0.5)
            expect.equal(report.microphoneFloorDBFS, report.farEndFloorDBFS)

            // A speaker call has no far-end-only windows. The echo keeps the
            // microphone above its floor for every second the far end plays,
            // and levels alone cannot tell that echo from the user. This is
            // the limit the retention figures are split around.
            expect.equal(summary(report, .farEndOnly).windows, 0)
            expect.isNil(
                summary(report, .farEndOnly).changeDB,
                "a class with no windows reports no level rather than zero"
            )
            expect.isNil(summary(report, .farEndOnly).worstChangeDB)

            // The user alone, with the far end quiet, is where a class-level
            // power ratio is at its most misleading. Across the class the
            // microphone came down 0.007 dB, which reads as untouched. Two of
            // its twenty-six windows lost 36 dB, at the transition where the
            // far end stops and the suppressor is still gating. That is the
            // shape of the incident this work exists to stop repeating, and
            // the ratio alone does not show it.
            let solo = summary(report, .userOnly)
            expect.equal(solo.windows, 26)
            expect.close(try expect.unwrap(solo.changeDB), 0, tolerance: 0.5)
            expect.close(try expect.unwrap(solo.worstChangeDB), 36.5, tolerance: 2)
            expect.close(try expect.unwrap(solo.p95ChangeDB), 31.8, tolerance: 3)
            expect.equal(solo.windowsOverLossThreshold, 2)

            // And the log is what lets a run be re-read later without being
            // measured again, so the summary has to be recoverable from it.
            let soloLog = report.windowLog.filter { $0.windowClass == .userOnly }
            expect.equal(soloLog.count, solo.windows)
            expect.equal(
                soloLog.filter { $0.changeDB > report.notableLossDB }.count,
                solo.windowsOverLossThreshold
            )
            expect.equal(report.windowLog.count, report.windowCount)
            expect.close(report.windowLog[1].startSeconds, report.windowSeconds, tolerance: 0.001)

            // Both at once, where the same ratio understates in the other
            // direction. The class reads 3.2 dB because six seconds of
            // retained user tone carries most of the energy, while the median
            // window gave up 55 dB of echo. The per-window figure is the one
            // that answers how much of the far end left.
            let together = summary(report, .both)
            expect.equal(together.windows, 64)
            expect.close(try expect.unwrap(together.changeDB), 3.2, tolerance: 0.5)
            expect.close(try expect.unwrap(together.medianChangeDB), 54.7, tolerance: 3)
            expect.equal(together.windowsOverLossThreshold, 40)

            let median = try expect.unwrap(report.reportedEnhancementMedianDB)
            expect.close(median, 48.5, tolerance: 2)
            // The user alone was left alone, which is what the decision is
            // made on.
            let harm = try expect.unwrap(report.userHarmMedianDB)
            expect.isTrue(harm < report.harmMedianLimitDB, "the user's own windows lost \(harm) dB")
            expect.isTrue(report.userWindowsJudged >= report.minimumUserWindows)
        },

        test("a call on headphones is kept cleaned when the user is left alone") { expect in
            let root = try ManifestTests.makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let meeting = try makeBurstyCall(root: root, micHoldsEcho: false)
            let measurement = try EchoMeasurement.measure(
                store: meeting.store, metadata: meeting.metadata,
                timeline: try meeting.store.readTimeline()
            )
            guard case .measured(let report) = measurement else {
                expect.fail("a two-track call came back \(measurement)")
                return
            }

            // The canceller reports almost nothing removed, because there was
            // nothing to remove. That figure decides nothing: what does is
            // that the user's own windows came through untouched, so the
            // cleaned track is as good as the recording and is kept.
            let median = try expect.unwrap(report.reportedEnhancementMedianDB)
            expect.close(median, 0.2, tolerance: 0.5)
            expect.equal(report.decision, CleaningOutcome.cleaned)
            let harm = try expect.unwrap(report.userHarmMedianDB)
            expect.isTrue(abs(harm) < 0.5, "the user's own windows moved \(harm) dB")

            // With no echo returning, the far end plays over a microphone that
            // holds only room noise, and those windows are far-end-only. This
            // is the class a speaker call cannot populate.
            let farOnly = summary(report, .farEndOnly)
            expect.equal(farOnly.windows, 40)

            // Across the class the microphone comes back 29.1 dB louder than
            // it went in, which reads as a noise floor lifted throughout. The
            // per-window figures say otherwise: the median window moved 0.05 dB
            // and one window came back 45 dB louder. The canceller replaces
            // what it suppressed with comfort noise in a few windows, and the
            // power ratio spreads that over all of them.
            expect.close(try expect.unwrap(farOnly.changeDB), -29.1, tolerance: 2)
            expect.close(try expect.unwrap(farOnly.medianChangeDB), -0.05, tolerance: 0.5)
            expect.close(try expect.unwrap(farOnly.largestGainDB), -45.1, tolerance: 3)
            expect.equal(farOnly.windowsOverLossThreshold, 0)

            // The user is untouched here, by the ratio and window by window
            // both. A filter that never locked on has nothing to subtract.
            for windowClass in [EchoMeasurement.WindowClass.userOnly, .both] {
                let held = summary(report, windowClass)
                expect.isTrue(
                    abs(try expect.unwrap(held.changeDB)) < 0.5,
                    "\(windowClass) moved \(String(describing: held.changeDB)) dB"
                )
                expect.isTrue(
                    abs(try expect.unwrap(held.worstChangeDB)) < 0.5,
                    "\(windowClass) worst window \(String(describing: held.worstChangeDB)) dB"
                )
                expect.equal(held.windowsOverLossThreshold, 0)
            }
        },

        test("a room louder than the far end's floor gets a floor of its own") { expect in
            // A real capsule records the room. Where its tone sits above
            // -60 dBFS, borrowing the far end's floor would call every window
            // microphone-active: `farEndOnly` and `neither` would come back
            // empty on every meeting, `userOnly` would stop meaning "the user
            // spoke", and the comfort noise above would never appear in a
            // table. Room tone here is -44.9 dBFS, which is that regime.
            let root = try ManifestTests.makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let meeting = try makeBurstyCall(root: root, micHoldsEcho: false, roomNoise: 0.008)
            let measurement = try EchoMeasurement.measure(
                store: meeting.store, metadata: meeting.metadata,
                timeline: try meeting.store.readTimeline()
            )
            guard case .measured(let report) = measurement else {
                expect.fail("a two-track call came back \(measurement)")
                return
            }

            let quiet = try expect.unwrap(report.microphoneQuietWindowDBFS)
            expect.close(quiet, -44.9, tolerance: 0.5)
            expect.isTrue(
                quiet > report.farEndFloorDBFS,
                "this room tone at \(quiet) dBFS has to sit above the far end's floor"
            )
            expect.close(
                report.microphoneFloorDBFS,
                quiet + EchoMeasurement.microphoneActivationMarginDB, tolerance: 0.001
            )

            // The counterfactual, measured rather than argued: with the far
            // end's floor every window would have been microphone-active.
            expect.equal(
                report.windowLog.filter { $0.microphoneBeforeDBFS > report.farEndFloorDBFS }.count,
                report.windowCount,
                "every window clears -60 dBFS in this room"
            )
            // With the derived floor the two quiet classes are populated.
            expect.equal(summary(report, .farEndOnly).windows, 40)
            expect.equal(summary(report, .neither).windows, 40)

            // And what the canceller does to a microphone holding only room
            // tone is then visible. The class ratio reads -0.9 dB, which is
            // nothing, while thirty-seven of forty windows lost more than 6 dB.
            let farOnly = summary(report, .farEndOnly)
            expect.close(try expect.unwrap(farOnly.changeDB), -0.9, tolerance: 1)
            expect.close(try expect.unwrap(farOnly.medianChangeDB), 14.3, tolerance: 2)
            expect.equal(farOnly.windowsOverLossThreshold, 37)
        },

        test("a far end that holds nothing reports no reference, not zero removal") { expect in
            let root = try ManifestTests.makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let count = Int(15 * rate)
            let meeting = try MicrophoneCleanerTests.makeMeeting(
                root: root,
                mic: MicrophoneCleanerTests.tone(
                    count: count, frequency: MicrophoneCleanerTests.nearTone, amplitude: 0.3
                ),
                remote: [Float](repeating: 0, count: count)
            )
            let measurement = try EchoMeasurement.measure(
                store: meeting.store, metadata: meeting.metadata,
                timeline: try meeting.store.readTimeline()
            )
            expect.equal(
                measurement, EchoMeasurement.noReference(.recordedSilence),
                "a tap that opened and recorded nothing has no reference to subtract"
            )
        },

        test("a recording holding everyone on one track reports no reference") { expect in
            let root = try ManifestTests.makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let count = Int(2 * rate)
            let meeting = try MicrophoneCleanerTests.makeMeeting(
                root: root, source: .imported,
                mic: MicrophoneCleanerTests.tone(
                    count: count, frequency: MicrophoneCleanerTests.nearTone, amplitude: 0.3
                ),
                remote: nil
            )
            let measurement = try EchoMeasurement.measure(
                store: meeting.store, metadata: meeting.metadata,
                timeline: try meeting.store.readTimeline()
            )
            expect.equal(measurement, EchoMeasurement.noReference(.oneTrack))
        },

        test("measuring leaves the meeting folder exactly as it found it") { expect in
            let root = try ManifestTests.makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let meeting = try makeBurstyCall(root: root)
            let folder = meeting.store.layout.root
            let before = contents(of: folder)
            expect.isTrue(before.count > 3, "the fixture wrote something to compare against")

            _ = try EchoMeasurement.measure(
                store: meeting.store, metadata: meeting.metadata,
                timeline: try meeting.store.readTimeline()
            )

            expect.equal(contents(of: folder), before, "the command wrote into the meeting")
            expect.isFalse(
                FileManager.default.fileExists(
                    atPath: meeting.store.layout.cleanedMicFile.path
                ),
                "no cleaned track was left behind"
            )
            expect.isNil(try meeting.store.readMetadata().cleanedMic)
        },

        test("a reference offset given by hand replaces the one the timeline holds") { expect in
            // What Task 2 runs to show the threshold does not catch a
            // misaligned pair. The far end here plays in bursts, so moving it
            // moves the echo away from where the filter is told to look for
            // it. A far end that never stops is the same far end after any
            // shift and would hide this.
            let root = try ManifestTests.makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let meeting = try makeBurstyCall(root: root)
            let timeline = try meeting.store.readTimeline()
            expect.close(
                EchoMeasurement.timelineReferenceOffset(timeline), 2, tolerance: 0.01,
                "the far end started two seconds after the microphone"
            )

            func measure(offset: Double?) throws -> EchoMeasurement.Report? {
                let measurement = try EchoMeasurement.measure(
                    store: meeting.store, metadata: meeting.metadata, timeline: timeline,
                    referenceOffset: offset
                )
                guard case .measured(let report) = measurement else { return nil }
                return report
            }

            let aligned = try expect.unwrap(try measure(offset: nil))
            expect.isFalse(aligned.referenceOffsetIsOverride)
            expect.close(aligned.referenceOffsetSeconds, 2, tolerance: 0.01)

            let reversed = try expect.unwrap(try measure(offset: -2))
            expect.isTrue(reversed.referenceOffsetIsOverride)
            expect.close(reversed.referenceOffsetSeconds, -2, tolerance: 0.01)

            // The far end is read through the offset, so a reversed one moves
            // the classification as well as the cancellation: the two tracks
            // are compared at moments that are not the same moment.
            expect.notEqual(
                summary(reversed, .both).windows, summary(aligned, .both).windows,
                "the classification moved with the far end"
            )

            // And the filter has nothing to lock onto, which the reported
            // enhancement says: 48.5 dB aligned against 0.2 dB reversed. The
            // decision no longer reads that figure, so a misaligned pair is
            // caught by what the far end lost, not by the outcome value.
            let alignedMedian = try expect.unwrap(aligned.reportedEnhancementMedianDB)
            let reversedMedian = try expect.unwrap(reversed.reportedEnhancementMedianDB)
            expect.isTrue(alignedMedian > reversedMedian + 20, "\(alignedMedian) against \(reversedMedian)")
            expect.equal(aligned.decision, CleaningOutcome.cleaned)
            let alignedFar = try expect.unwrap(summary(aligned, .both).medianChangeDB)
            let reversedFar = try expect.unwrap(summary(reversed, .both).medianChangeDB)
            expect.isTrue(alignedFar > reversedFar + 20, "aligned removed \(alignedFar) dB, reversed \(reversedFar) dB")
        },

        test("the judgement keeps a pass that left the user alone and drops one that did not") { expect in
            func window(far: Double, before: Double, after: Double) -> EchoCancellationPass.Window {
                EchoCancellationPass.Window(
                    farEndDBFS: far, echoRemovedDB: 0, microphoneBeforeDBFS: before,
                    microphoneAfterDBFS: after
                )
            }
            // Room tone, so the microphone has a floor to be judged against.
            let room = (0..<30).map { _ in window(far: -90, before: -80, after: -80) }
            // A call on speakers: the far end plays for most of it and the
            // user's own windows lose nothing.
            let speakers = (0..<60).map { _ in window(far: -25, before: -30, after: -55) }
                + (0..<30).map { _ in window(far: -90, before: -30, after: -30.3) } + room
            let kept = EchoCancellationPass.judge(windows: speakers)
            expect.equal(kept.outcome, CleaningOutcome.cleaned)
            expect.equal(kept.userWindows, 30)
            expect.close(try expect.unwrap(kept.userHarmMedianDB), 0.3, tolerance: 0.01)

            // The same call with the user's solo speech gutted.
            let gutted = (0..<60).map { _ in window(far: -25, before: -30, after: -55) }
                + (0..<30).map { _ in window(far: -90, before: -30, after: -45) } + room
            let dropped = EchoCancellationPass.judge(windows: gutted)
            expect.equal(dropped.outcome, CleaningOutcome.bypassedNoEchoPath)
            expect.close(try expect.unwrap(dropped.userHarmMedianDB), 15, tolerance: 0.01)

            // Enough gated windows is enough: the median holds and the share
            // does not.
            let tail = (0..<60).map { _ in window(far: -25, before: -30, after: -55) }
                + (0..<26).map { _ in window(far: -90, before: -30, after: -30) }
                + (0..<4).map { _ in window(far: -90, before: -30, after: -60) } + room
            expect.equal(EchoCancellationPass.judge(windows: tail).outcome, CleaningOutcome.bypassedNoEchoPath)

            // Too few user-only windows to judge harm on: kept.
            let brief = (0..<60).map { _ in window(far: -25, before: -30, after: -55) }
                + (0..<5).map { _ in window(far: -90, before: -30, after: -60) } + room
            let unjudged = EchoCancellationPass.judge(windows: brief)
            expect.equal(unjudged.outcome, CleaningOutcome.cleaned)
            expect.isNil(unjudged.userHarmMedianDB)

            // Too little far end to have been judged on at all.
            let quiet = (0..<10).map { _ in window(far: -25, before: -30, after: -55) }
                + (0..<60).map { _ in window(far: -90, before: -30, after: -30) } + room
            expect.equal(EchoCancellationPass.judge(windows: quiet).outcome, CleaningOutcome.skippedNoReference)
        },
    ])
}
