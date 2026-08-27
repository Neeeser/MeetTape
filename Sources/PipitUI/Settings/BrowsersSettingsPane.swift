import AppKit
import PipitCore
import PipitDetection
import PipitServices
import SwiftUI

/// Installing the browser extension and seeing whether it is talking.
///
/// One block per browser over a shared host section, so adding Chrome is
/// adding an entry rather than reshaping the page.
struct BrowsersSettingsPane: View {
    let model: SettingsModel
    private var runtime: PipitRuntime { model.runtime }

    var body: some View {
        Form {
            Section("Native messaging host") {
                LabeledContent("Host") {
                    Text(model.hostStatus?.hostInstalled == true ? "Installed" : "Not installed")
                        .foregroundStyle(model.hostStatus?.hostInstalled == true ? .green : .orange)
                }
                if let path = model.hostStatus?.installedHostPath {
                    Text(path)
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Button("Re-install Host") { model.installHost() }
                Text(
                    "The browser launches this to report what it can see of a call. Every "
                        + "browser below talks to the same one."
                )
                .font(.caption).foregroundStyle(.secondary)
            }

            Section("Firefox") {
                LabeledContent("Extension") {
                    Text(runtime.status.sensorConnection.label)
                        .foregroundStyle(runtime.status.sensorConnection.color)
                }
                LabeledContent("Host manifest") {
                    Text(
                        model.hostStatus?.firefoxManifestInstalled == true
                            ? "Installed" : "Not installed"
                    )
                    .foregroundStyle(
                        model.hostStatus?.firefoxManifestInstalled == true ? .green : .orange
                    )
                }
                Text(
                    "Firefox loads the extension as a temporary add-on, which lasts until "
                        + "Firefox quits. Open about:debugging#/runtime/this-firefox, choose "
                        + "Load Temporary Add-on, and select the manifest below."
                )
                .font(.caption).foregroundStyle(.secondary)
                if let manifest = NativeMessagingInstaller.bundledExtensionManifestURL() {
                    Text(manifest.path)
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    HStack {
                        Button("Copy Path") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(manifest.path, forType: .string)
                        }
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([manifest])
                        }
                    }
                }
            }

            Section("What the extension changes") {
                Text(
                    "Meet and Zoom are recorded whether or not the extension is installed. "
                        + "Without it, a prejoin screen cannot be distinguished from a joined "
                        + "call, so recordings start earlier and run somewhat longer."
                )
                .font(.caption).foregroundStyle(.secondary)
                if let rejected = model.sensorStatus?.rejectedConnections, rejected > 0 {
                    Label(
                        "\(rejected) connection\(rejected == 1 ? "" : "s") refused. Only "
                            + "Pipit's own relay, launched by a browser, may report meetings.",
                        systemImage: "shield.lefthalf.filled"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .task { await model.refresh() }
    }
}

extension BrowserSensorTracker.Connection {
    /// One wording for the sensor, shown wherever it is reported.
    var label: String {
        switch self {
        case .fresh: "Connected"
        case .stale: "Connected but silent, using native detection"
        case .disconnected: "Disconnected, using native detection"
        case .absent: "Not installed, using native detection"
        }
    }

    var color: Color {
        switch self {
        case .fresh: .green
        case .stale, .disconnected: .orange
        case .absent: .secondary
        }
    }
}
