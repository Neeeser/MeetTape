import AppKit
import PipitCore
import PipitDetection
import PipitServices
import SwiftUI

/// Whether each browser can tell Pipit what it sees of a call.
///
/// One card per browser, leading with the add-on rather than with the plumbing
/// underneath it: a person reads this page to find out whether the add-on is in
/// their browser, and the host and its manifest only matter when it is not
/// working. Those live in the details below, closed.
struct BrowsersSettingsPane: View {
    let model: SettingsModel
    private var runtime: PipitRuntime { model.runtime }

    private var addOnState: FirefoxAddOnState {
        FirefoxAddOnState(
            connection: runtime.status.sensorConnection,
            hasBundledAddOn: FirefoxAddOn.bundledAddOn != nil
        )
    }

    var body: some View {
        Form {
            Section("Firefox") {
                BrowserAddOnRow(
                    symbol: "globe",
                    title: addOnState.title,
                    detail: addOnState.detail,
                    statusSymbol: addOnState.symbol,
                    statusColor: addOnState.color
                )
                if addOnState == .missing {
                    FirefoxAddOnInstallButton()
                }
                if addOnState.isInstalled, let lastMessage = model.sensorStatus?.lastMessageAt {
                    Text("Last heard from ") + Text(lastMessage, style: .relative) + Text(" ago.")
                }
            }

            Section("Chrome") {
                BrowserAddOnRow(
                    symbol: "globe",
                    title: "No add-on yet",
                    detail: "Chrome calls are detected from window titles and microphone state.",
                    statusSymbol: nil,
                    statusColor: .secondary
                )
            }

            Section {
                DisclosureGroup("Connection details") {
                    connectionDetails
                }
            }
        }
        .formStyle(.grouped)
        .task {
            await model.refresh()
            await model.pollSensor()
        }
    }

    @ViewBuilder
    private var connectionDetails: some View {
        if let version = model.sensorStatus?.lastHello?.extensionVersion {
            LabeledContent("Add-on version") { Text(version) }
        }
        if let lastMessage = model.sensorStatus?.lastMessageAt {
            LabeledContent("Last reported") {
                Text(lastMessage, style: .relative) + Text(" ago")
            }
        }
        LabeledContent("Relay") {
            Text(model.hostStatus?.hostInstalled == true ? "Installed" : "Not installed")
                .foregroundStyle(model.hostStatus?.hostInstalled == true ? .green : .orange)
        }
        if let path = model.hostStatus?.installedHostPath {
            Text(path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
        LabeledContent("Firefox host manifest") {
            Text(model.hostStatus?.firefoxManifestInstalled == true ? "Installed" : "Not installed")
                .foregroundStyle(
                    model.hostStatus?.firefoxManifestInstalled == true ? .green : .orange
                )
        }
        Text(NativeMessagingInstaller().firefoxManifestURL.path)
            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)

        HStack {
            Button("Repair connection") { model.installHost() }
            if addOnState.isInstalled, FirefoxAddOn.bundledAddOn != nil {
                FirefoxAddOnInstallButton(isReinstall: true)
            }
        }
        Text(
            "The relay is the small program Firefox launches to reach Pipit. Repairing "
                + "writes it and the host manifest again, which is what an add-on that "
                + "cannot connect needs."
        )
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

        if let rejected = model.sensorStatus?.rejectedConnections, rejected > 0 {
            Label(
                "\(rejected) connection\(rejected == 1 ? "" : "s") refused. Only Pipit's own "
                    + "relay, launched by a browser, may report meetings.",
                systemImage: "shield.lefthalf.filled"
            )
            .font(.caption)
            .foregroundStyle(.orange)
        }
    }
}

/// One browser's headline: what its add-on is doing, and what follows from it.
private struct BrowserAddOnRow: View {
    let symbol: String
    let title: String
    let detail: String
    let statusSymbol: String?
    let statusColor: Color

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.tertiary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if let statusSymbol {
                        Image(systemName: statusSymbol).foregroundStyle(statusColor)
                    }
                    Text(title).fontWeight(.medium)
                        .foregroundStyle(statusSymbol == nil ? .secondary : .primary)
                }
                Text(detail)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }
}
