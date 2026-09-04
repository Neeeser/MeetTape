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
        remoteStartOffset: Double = 2
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
            count: count, frequency: noiseTone, amplitude: noiseAmplitude
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
            expect.equal(
                report.windows,
                EchoMeasurement.WindowClass.allCases.reduce(0) { $0 + summary(report, $1).windows },
                "every window is in exactly one class"
            )

            // The far end plays for sixteen of the thirty-two seconds.
            expect.close(report.farEndDutyCycle, 0.5, tolerance: 0.05)
            expect.equal(
                report.farEndActiveWindows,
                summary(report, .farEndOnly).windows + summary(report, .both).windows,
                "far-end-active is the two classes the far end is above the floor in"
            )

            // A speaker call has no far-end-only windows. The echo keeps the
            // microphone above the floor for every second the far end plays,
            // and levels alone cannot tell that echo from the user. This is
            // the limit the retention figures are split around, and the number
            // that would answer "how much of the far end left" on its own is
            // therefore not available from this class.
            expect.equal(summary(report, .farEndOnly).windows, 0)
            expect.isNil(
                summary(report, .farEndOnly).changeDB,
                "a class with no windows reports no level rather than zero"
            )

            // The user alone, with the far end quiet. This is the number every
            // earlier attempt got wrong.
            let solo = summary(report, .userOnly)
            expect.isTrue(solo.windows > 20, "only \(solo.windows) user-only windows")
            let soloLost = try expect.unwrap(solo.changeDB)
            expect.isTrue(soloLost < 3, "the user lost \(soloLost) dB speaking alone")

            // Both at once. The class holds the double-talk stretch and the
            // stretches where only the echo was in the microphone, so its
            // figure is the two together rather than either one.
            let together = summary(report, .both)
            expect.isTrue(together.windows > 20, "only \(together.windows) double-talk windows")
            let togetherChange = try expect.unwrap(together.changeDB)
            expect.isTrue(
                togetherChange > 0.5,
                "the microphone came down only \(togetherChange) dB where both were above the floor"
            )

            let median = try expect.unwrap(report.reportedEnhancementMedianDB)
            expect.isTrue(
                median >= report.bypassThresholdDB,
                "the canceller reported \(median) dB against \(report.bypassThresholdDB) dB"
            )
        },

        test("a call on headphones reports the bypass and what was taken anyway") { expect in
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

            expect.equal(report.decision, CleaningOutcome.bypassedNoEchoPath)
            let median = try expect.unwrap(report.reportedEnhancementMedianDB)
            expect.isTrue(
                median < report.bypassThresholdDB,
                "a microphone with no echo in it reported \(median) dB removed"
            )

            // With no echo returning, the far end plays over a microphone that
            // holds only room noise, and those windows are far-end-only. This
            // is the class a speaker call cannot populate.
            let farOnly = summary(report, .farEndOnly)
            expect.isTrue(farOnly.windows > 20, "only \(farOnly.windows) far-end-only windows")
            // And the microphone comes back louder than it went in. The
            // canceller replaces what it suppressed with comfort noise, so
            // room noise at -73 dBFS returns at about -44. Measured at
            // -29.1 dB. A negative change is why `changeDB` is what the
            // microphone level did rather than what was removed.
            let taken = try expect.unwrap(farOnly.changeDB)
            expect.isTrue(taken < -10, "the canceller left the noise floor at \(taken) dB")

            // The user is untouched here. A filter that never locked on has
            // nothing to subtract, and on this fixture the suppressor does not
            // gate the user either. Measured at 0.006 dB both ways.
            for windowClass in [EchoMeasurement.WindowClass.userOnly, .both] {
                let lost = try expect.unwrap(summary(report, windowClass).changeDB)
                expect.isTrue(lost < 1, "\(windowClass) lost \(lost) dB")
            }
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
            // enhancement says and the threshold acts on. Measured at 48.5 dB
            // aligned against 0.2 dB reversed. On this fixture the threshold
            // does catch the reversal. The fixture in `MicrophoneCleanerTests`
            // where the far end started first is one where it does not, so
            // neither result generalises.
            let alignedMedian = try expect.unwrap(aligned.reportedEnhancementMedianDB)
            let reversedMedian = try expect.unwrap(reversed.reportedEnhancementMedianDB)
            expect.isTrue(
                alignedMedian >= aligned.bypassThresholdDB,
                "the aligned pair reported \(alignedMedian) dB"
            )
            expect.isTrue(
                reversedMedian < reversed.bypassThresholdDB,
                "the reversed pair reported \(reversedMedian) dB"
            )
            expect.equal(aligned.decision, CleaningOutcome.cleaned)
            expect.equal(reversed.decision, CleaningOutcome.bypassedNoEchoPath)
        },
    ])
}
