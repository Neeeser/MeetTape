import AppKit
import PipitCore
import PipitServices
import SwiftUI

/// What Pipit is, what version this is, and where it puts things.
///
/// The explanations that used to sit inside Settings panes live here. None of
/// them is a control, and a person looking for one is looking for a control.
struct AboutView: View {
    let runtime: PipitRuntime

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pipit").font(.title2.weight(.semibold))
                    Text(Self.version).font(.callout).foregroundStyle(.secondary)
                    Text("Records meetings and stores the results as files on disk.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            SectionCard(title: "What is on disk") {
                Text(
                    """
                    Each meeting is a folder of ordinary files: the transcript as Markdown, \
                    the recording as M4A, your notes and summary, and a raw folder holding \
                    the per-track source audio, the manifest, the API responses and the \
                    speaker map. Every file can be read without Pipit, and uninstalling \
                    the application leaves the recordings in place.
                    """
                )
                .font(.callout).foregroundStyle(.secondary)
                Text(runtime.settings.storageRootPath)
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Button("Reveal in Finder") {
                    NSWorkspace.shared.open(runtime.settings.storageRoot)
                }
                .controlSize(.small)
            }

            SectionCard(title: "How recording works") {
                Text(
                    "Audio is written in segments of \(Int(runtime.settings.segmentSeconds)) "
                        + "seconds, so a crash loses less than a tenth of a second. Capture "
                        + "begins before a call is confirmed and the last "
                        + "\(Int(runtime.settings.preRollSeconds)) seconds are kept in memory, "
                        + "which covers the opening of the meeting."
                )
                .font(.callout).foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        switch (short, build) {
        case let (short?, build?): return "Version \(short) (\(build))"
        case let (short?, nil): return "Version \(short)"
        // A debug binary run outside the bundle has neither.
        default: return "Development build"
        }
    }
}
