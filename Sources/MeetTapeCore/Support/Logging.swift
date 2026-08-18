import Foundation
import os

/// Structured logging for MeetTape.
///
/// Meeting content never reaches the log. Titles, transcripts, notes, URLs and
/// participant names are meeting content; identifiers, counts, durations and
/// health states are operational and safe. Anything in between is logged through
/// `redacted:` so it is hidden in release builds.
public enum Log {
    public static let capture = Logger(subsystem: subsystem, category: "capture")
    public static let detection = Logger(subsystem: subsystem, category: "detection")
    public static let session = Logger(subsystem: subsystem, category: "session")
    public static let storage = Logger(subsystem: subsystem, category: "storage")
    public static let processing = Logger(subsystem: subsystem, category: "processing")
    public static let integrations = Logger(subsystem: subsystem, category: "integrations")
    public static let ui = Logger(subsystem: subsystem, category: "ui")
    public static let app = Logger(subsystem: subsystem, category: "app")

    public static let subsystem = "com.meettape.app"
}

/// Describes an error for a log line without leaking the payload that produced it.
public func logSafeDescription(_ error: Error) -> String {
    if let described = error as? LogSafeError { return described.logSafeDescription }
    let nsError = error as NSError
    return "\(nsError.domain)#\(nsError.code)"
}

/// Errors that know how to describe themselves without meeting content.
public protocol LogSafeError: Error {
    var logSafeDescription: String { get }
}
