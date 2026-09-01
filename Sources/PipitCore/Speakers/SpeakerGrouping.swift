import Foundation

/// One speaker key and what is known about whose voice it is.
public struct SpeakerGroupMember: Sendable, Equatable {
    public var key: String
    /// The name stored for this key, or nil where nobody has named it. A
    /// generated fallback is not a name and must never be passed here: two
    /// unnamed clusters both reading "Speaker 1" are still two clusters.
    public var displayName: String?
    public var identityID: IdentityID?
    /// The meeting client's own identifier for the person, where an assignment
    /// carries one.
    public var participantID: String?

    public init(
        key: String, displayName: String? = nil, identityID: IdentityID? = nil,
        participantID: String? = nil
    ) {
        self.key = key
        self.displayName = displayName
        self.identityID = identityID
        self.participantID = participantID
    }

    /// The platform account behind this key, from the assignment or from the
    /// key itself. A sensor key is the participant identifier, so it says who
    /// it belongs to even before anything names it.
    var account: String? {
        if let participantID, !participantID.isEmpty { return participantID }
        return SpeakerLabel.sensorParticipantID(from: key)
    }

    var name: String? {
        guard let displayName else { return nil }
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Which of one recording's speaker keys are the same person.
///
/// The diarizer splits one voice across several clusters, and the meeting
/// client names every one of them from its roster. A two-person huddle came out
/// of processing with eleven keys, nine of them carrying one of two names, and
/// the speaker strip drew eleven chips. The keys stay separate on disk, because
/// each is a claim about a different stretch of audio, and a reader is shown one
/// row per person.
///
/// Three things make two keys the same person, in the order they are trusted:
/// the platform account, the voice identity, and a name a stage already agreed
/// on. Any one of them joins two keys, and joining is transitive, so a cluster
/// linked to an account and a cluster linked to an identity end up together
/// through the key that carries both.
public enum SpeakerGrouping {
    /// Groups the members that resolve to one person, in the order they arrived.
    ///
    /// A cluster nothing has named and no account points at stays on its own.
    /// It is an open question, and two open questions are not an answer.
    public static func groups(_ members: [SpeakerGroupMember]) -> [[SpeakerGroupMember]] {
        var parent = Array(members.indices)
        func find(_ index: Int) -> Int {
            var root = index
            while parent[root] != root { root = parent[root] }
            var walk = index
            while parent[walk] != walk {
                let next = parent[walk]
                parent[walk] = root
                walk = next
            }
            return root
        }
        func union(_ left: Int, _ right: Int) {
            let a = find(left)
            let b = find(right)
            guard a != b else { return }
            parent[max(a, b)] = min(a, b)
        }

        var firstSeen: [String: Int] = [:]
        for (index, member) in members.enumerated() {
            var signals: [String] = []
            if let account = member.account { signals.append("account:\(account)") }
            if let identity = member.identityID { signals.append("identity:\(identity)") }
            if let name = member.name { signals.append("name:\(name)") }
            for signal in signals {
                if let earlier = firstSeen[signal] {
                    union(earlier, index)
                } else {
                    firstSeen[signal] = index
                }
            }
        }

        var order: [Int] = []
        var grouped: [Int: [SpeakerGroupMember]] = [:]
        for (index, member) in members.enumerated() {
            let root = find(index)
            if grouped[root] == nil { order.append(root) }
            grouped[root, default: []].append(member)
        }
        return order.compactMap { grouped[$0] }
    }
}
