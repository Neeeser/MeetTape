import Foundation
import PipitCore

/// Reads what Firefox has written about its own add-ons.
///
/// The sensor connection only says the add-on is talking. It talks when Firefox
/// starts and when a meeting page opens, and after Pipit restarts it waits out a
/// backoff before calling in again, so a silent sensor is not the same thing as
/// a missing add-on. Firefox stores an installed add-on as one file per profile,
/// which answers that immediately.
public enum FirefoxProfile {
    public static let sensorExtensionID = "sensor@pipit.app"

    public static var profilesDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Firefox/Profiles")
    }

    /// Whether any profile on this Mac holds the add-on.
    ///
    /// A temporary add-on is not on disk, so it reads as absent here and is
    /// recognised by its connection instead.
    public static func hasInstalledAddOn(
        extensionID: String = sensorExtensionID,
        profilesDirectory: URL = FirefoxProfile.profilesDirectory
    ) -> Bool {
        let manager = FileManager.default
        guard
            let profiles = try? manager.contentsOfDirectory(
                at: profilesDirectory, includingPropertiesForKeys: nil
            )
        else { return false }
        return profiles.contains { profile in
            let addOn = profile
                .appendingPathComponent("extensions")
                .appendingPathComponent("\(extensionID).xpi")
            return manager.fileExists(atPath: addOn.path)
        }
    }
}
