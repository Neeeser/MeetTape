import Foundation
import PipitCore
import PipitDetection
import TestKit

/// Reads a huddle that is actually running.
///
/// Skipped unless `PIPIT_LIVE_SLACK=1`, because it needs Slack open, a live
/// huddle, and accessibility granted to whatever runs the tests. Nothing else in
/// the suite can prove the accessibility walk still finds Slack's tiles, and
/// that walk depends entirely on names Slack chose and can rename.
///
/// Run it with a second person, or a phone joined to the same huddle, so the
/// remote path is exercised rather than only the local user's own tile.
enum LiveSlackHuddleTests {
    private static var enabled: Bool {
        ProcessInfo.processInfo.environment["PIPIT_LIVE_SLACK"] == "1"
    }

    static var suite: Suite {
        Suite("LiveSlackHuddle", [
            test("a running huddle yields a roster with Slack user ids") { expect in
                guard enabled else {
                    throw TestSkip("set PIPIT_LIVE_SLACK=1 with a huddle running")
                }
                let reader = SlackAccessibilityReader()
                let observation = reader.read()
                expect.isFalse(
                    observation.accessibilityUnavailable,
                    "grant accessibility to the terminal running the tests"
                )
                expect.isTrue(
                    observation.hasLeaveHuddleControl,
                    "no huddle is running: the leave control is what proves one is"
                )
                expect.isFalse(observation.tiles.isEmpty, "the huddle grid read empty")
                for tile in observation.tiles {
                    // A Slack user id, not a display name. This is the identity
                    // the whole feature keys on.
                    expect.isTrue(
                        tile.userID.hasPrefix("U") && tile.userID.count >= 9,
                        "tile id does not look like a Slack user id: \(tile.userID)"
                    )
                }
                expect.equal(
                    observation.tiles.filter(\.isSelf).count, 1,
                    "exactly one tile is the local user"
                )
                // Counts and states only. A display name is meeting content and
                // does not belong on a console any more than in a log.
                print(
                    "    huddle: \(observation.tiles.count) tiles, "
                        + "\(observation.tiles.filter { $0.isMuted == false }.count) unmuted, "
                        + "\(observation.tiles.filter(\.isSpeaking).count) speaking"
                )
            },

            test("a reading folds into a timeline the attribution can use") { expect in
                guard enabled else {
                    throw TestSkip("set PIPIT_LIVE_SLACK=1 with a huddle running")
                }
                let reader = SlackAccessibilityReader()
                var recorder = SensorRecorder(anchorMonotonic: 0)
                // Two seconds of real polling at the rate detection uses.
                for tick in 0..<4 {
                    let observation = reader.read()
                    guard !observation.tiles.isEmpty else { continue }
                    recorder.record(SensorReading(
                        source: "slack-huddle-ax", provider: .slack,
                        at: Double(tick) * 0.5,
                        participants: observation.tiles.map {
                            SensorParticipant(
                                id: $0.userID, displayName: $0.displayName, isSelf: $0.isSelf
                            )
                        },
                        speakingID: observation.tiles.first(where: \.isSpeaking)?.userID,
                        unmutedIDs: Set(
                            observation.tiles.filter { $0.isMuted == false }.map(\.userID)
                        )
                    ))
                }
                // Origin zero: this test folds readings that were stamped from
                // zero, so the shift is a no-op and the fold is what is under test.
                let raw = try expect.unwrap(
                    recorder.finish(timelineOriginHostTime: 0),
                    "a reading was taken but no record came out"
                )
                expect.isFalse(raw.participants.isEmpty, "no roster survived the fold")
                print("    timeline: \(raw.participants.count) people, \(raw.turns.count) turns")
            },
        ])
    }
}
