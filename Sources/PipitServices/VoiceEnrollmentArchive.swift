import Foundation
import PipitCore

/// Where a spoken enrolment's audio lives.
///
/// Under Application Support beside the voice database, never in a meeting
/// folder: the archive is what a person copies, syncs and shares, and this is a
/// recording of one person's voice that belongs to no meeting.
///
/// The audio is kept rather than deleted after the vector is taken. A vector
/// whose audio cannot be heard again is a vector nobody can check and nothing
/// can re-derive when the embedding model changes.
public struct VoiceEnrollmentArchive: Sendable {
    private let root: URL

    public init(applicationSupport: URL) {
        self.root = applicationSupport.appendingPathComponent("VoiceEnrollment", isDirectory: true)
    }

    public func directory(for identityID: IdentityID) -> URL {
        root.appendingPathComponent("\(identityID.rawValue)", isDirectory: true)
    }

    /// A path for a new recording. Nothing is created here; the recorder writes
    /// the file and this decides where it goes.
    public func newRecording(for identityID: IdentityID, id: String) throws -> URL {
        let directory = directory(for: identityID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(id).wav")
    }

    /// Every recording this person has read, oldest first.
    public func recordings(for identityID: IdentityID) -> [URL] {
        let directory = directory(for: identityID)
        let found = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        return found.filter { $0.pathExtension == "wav" }.sorted { $0.path < $1.path }
    }

    /// Removes what this person read. Called when their learned voice is
    /// forgotten and when they are deleted, so neither leaves audio behind.
    public func remove(for identityID: IdentityID) {
        try? FileManager.default.removeItem(at: directory(for: identityID))
    }
}
