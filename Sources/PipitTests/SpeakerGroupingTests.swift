import Foundation
import PipitCore
import TestKit

/// One person, one row.
///
/// The diarizer splits a voice across several clusters and the meeting client
/// names each piece from its roster, so the same person arrives as four or five
/// keys carrying one name and one participant identifier. Everything here is
/// about collapsing those back to the person, and about the cases where two keys
/// are not evidence of one person and must stay apart.
enum SpeakerGroupingTests {
    private static func member(
        _ key: String, _ name: String? = nil, identity: Int64? = nil, participant: String? = nil
    ) -> SpeakerGroupMember {
        SpeakerGroupMember(
            key: key, displayName: name,
            identityID: identity.map { IdentityID($0) }, participantID: participant
        )
    }

    private static func keys(_ groups: [[SpeakerGroupMember]]) -> [[String]] {
        groups.map { $0.map(\.key) }
    }

    static var suite: Suite {
        Suite("SpeakerGrouping", [
            test("clusters the meeting client named for one account are one person") { expect in
                let groups = SpeakerGrouping.groups([
                    member("remote-001_speaker_00", "Chris Latimer", participant: "U06"),
                    member("remote-001_speaker_01", "Chris Latimer", participant: "U06"),
                    member("remote-001_speaker_02", "Chris Latimer", participant: "U06"),
                    member("sensor_U06", "Chris Latimer", participant: "U06"),
                ])
                expect.equal(keys(groups), [[
                    "remote-001_speaker_00", "remote-001_speaker_01",
                    "remote-001_speaker_02", "sensor_U06",
                ]])
            },

            test("two accounts in one meeting stay two people") { expect in
                let groups = SpeakerGrouping.groups([
                    member("remote-001_speaker_00", "Brian McNamara", participant: "U0B"),
                    member("remote-001_speaker_01", "Chris Latimer", participant: "U06"),
                    member("remote-001_speaker_02", "Chris Latimer", participant: "U06"),
                    member("remote-001_speaker_03", "Brian McNamara", participant: "U0B"),
                ])
                expect.equal(keys(groups), [
                    ["remote-001_speaker_00", "remote-001_speaker_03"],
                    ["remote-001_speaker_01", "remote-001_speaker_02"],
                ])
            },

            test("clusters matched to one voice profile are one person") { expect in
                let groups = SpeakerGrouping.groups([
                    member("remote-001_speaker_00", "Ada Lovelace", identity: 4),
                    member("remote-001_speaker_01", "Ada Lovelace", identity: 4),
                ])
                expect.equal(keys(groups), [["remote-001_speaker_00", "remote-001_speaker_01"]])
            },

            // The account and the identity name different keys, and the key
            // carrying both is what puts all three together.
            test("an account and an identity join through the key holding both") { expect in
                let groups = SpeakerGrouping.groups([
                    member("remote-001_speaker_00", "Ada Lovelace", participant: "U06"),
                    member("remote-001_speaker_01", "Ada Lovelace", identity: 4),
                    member("sensor_U06", "Ada Lovelace", identity: 4, participant: "U06"),
                ])
                expect.equal(keys(groups), [[
                    "remote-001_speaker_00", "remote-001_speaker_01", "sensor_U06",
                ]])
            },

            // A name is the weakest of the three and still enough. Two chips
            // reading the same thing are a duplicate to whoever is looking at
            // them, whatever wrote them.
            test("the same name with nothing else behind it is still one person") { expect in
                let groups = SpeakerGrouping.groups([
                    member("remote-001_speaker_00", "Chris Latimer"),
                    member("remote-001_speaker_01", "chris latimer"),
                ])
                expect.equal(keys(groups), [["remote-001_speaker_00", "remote-001_speaker_01"]])
            },

            test("clusters nobody has named stay apart") { expect in
                let groups = SpeakerGrouping.groups([
                    member("remote-001_speaker_00"),
                    member("remote-001_speaker_01"),
                ])
                expect.equal(keys(groups), [["remote-001_speaker_00"], ["remote-001_speaker_01"]])
            },

            // A sensor key says whose account it is in the key itself, so it
            // joins that person before anything has named either of them.
            test("an unnamed sensor key joins the account it names") { expect in
                let groups = SpeakerGrouping.groups([
                    member("remote-001_speaker_00", "Chris Latimer", participant: "U06"),
                    member("sensor_U06"),
                ])
                expect.equal(keys(groups), [["remote-001_speaker_00", "sensor_U06"]])
            },

            test("the microphone track is left alone by an unrelated name") { expect in
                let groups = SpeakerGrouping.groups([
                    member("local", "Andrew", identity: 1),
                    member("remote-001_speaker_00", "Chris Latimer", participant: "U06"),
                ])
                expect.equal(keys(groups), [["local"], ["remote-001_speaker_00"]])
            },
        ])
    }
}
