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

    /// How this build gets the add-on in, which is not the same in a release
    /// build and a local one.
    private var installationInstructions: String {
        if FirefoxAddOn.bundledAddOn != nil {
            return "Firefox raises its own prompt to confirm the add-on, and keeps it "
                + "installed after that."
        }
        return "This build carries no signed add-on, so Firefox can only load it "
            + "temporarily and drops it when Firefox quits. Open "
            + "about:debugging#/runtime/this-firefox, choose Load Temporary Add-on, and "
            + "select the manifest below."
    }

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
                LabeledContent("Add-on") {
                    Text(runtime.status.sensorConnection.label)
                        .foregroundStyle(runtime.status.sensorConnection.color)
                }
                if let lastMessage = model.sensorStatus?.lastMessageAt {
                    LabeledContent("Last reported") {
                        Text(lastMessage, style: .relative) + Text(" ago")
                    }
                    .foregroundStyle(.secondary)
                }
                if !runtime.status.sensorConnection.isLoaded {
                    Text(
                        "Meet and Zoom still record without the add-on, from window titles "
                            + "and microphone state. Recording then starts at the prejoin "
                            + "screen rather than when the call is joined."
                    )
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Text(installationInstructions)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                FirefoxAddOnControls()
                if FirefoxAddOn.bundledAddOn == nil,
                   let manifest = NativeMessagingInstaller.bundledExtensionManifestURL() {
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

            Section("Firefox plumbing") {
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
                    "Pipit's half of the connection: the file that tells Firefox how to "
                        + "launch the host. It says nothing about whether the add-on itself "
                        + "is in Firefox."
                )
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section("What the add-on changes") {
                Text(
                    "With the add-on, recording starts when the call is joined and stops "
                        + "when it ends, and the participant list comes from the page. "
                        + "Without it, both come from window titles and microphone state."
                )
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
        case .fresh: "Loaded, reporting a meeting"
        case .stale: "Loaded"
        case .disconnected, .absent: "Not loaded"
        }
    }

    var color: Color {
        switch self {
        case .fresh, .stale: .green
        case .disconnected, .absent: .orange
        }
    }
}
