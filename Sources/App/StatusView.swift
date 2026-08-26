import SwiftUI

struct StatusView: View {
    @EnvironmentObject private var status: StatusModel
    @EnvironmentObject private var settings: Settings

    var body: some View {
        Form {
            Section(L("Permissions")) {
                permissionRow(L("Accessibility"), granted: status.accessibility, pane: "Privacy_Accessibility")
                permissionRow(L("Input Monitoring"), granted: status.inputMonitoring, pane: "Privacy_ListenEvent")
                if !(status.accessibility && status.inputMonitoring) {
                    Text(L("Grant both to use the trackpad. A rebuilt app counts as a new program: remove the old entry and enable the new one."))
                        .font(.caption).foregroundStyle(.secondary)
                    Button(L("Request permissions")) { status.requestPermissions() }
                }
            }
            Section(L("Trackpad")) {
                LabeledContent(L("Status")) { Text(deviceText) }
                if let err = status.hidError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
                LabeledContent(L("Reports")) {
                    if let t = status.lastReport {
                        Text(L("%d/s · last %@", status.reportsPerSecond, t.formatted(date: .omitted, time: .standard)))
                    } else {
                        Text(L("None")).foregroundStyle(.secondary)
                    }
                }
            }
            Section(L("Diagnostics")) {
                Toggle(L("Record raw reports (keeps the last 10 s in memory)"), isOn: $settings.recordDiagnostics)
                HStack {
                    Button(L("Save diagnostics log")) { status.saveDiagnostics() }
                        .disabled(!settings.recordDiagnostics)
                    if let url = status.lastDiagnosticsURL {
                        Text(url.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(L("Turn recording on, reproduce the problem, then save: the file goes to ~/Downloads. The app log is at ~/Library/Logs/ABTrackPTPad.log."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let err = status.lastError {
                Section { Text(err).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
    }

    private func permissionRow(_ name: String, granted: Bool, pane: String) -> some View {
        LabeledContent {
            HStack {
                Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(granted ? .green : .red)
                Text(granted ? L("Granted") : L("Not granted"))
                Button(L("Open System Settings")) { status.openSystemSettings(pane) }
                    .controlSize(.small)
            }
        } label: { Text(name) }
    }

    private var deviceText: String {
        switch status.device {
        case .noPermission: return L("Cannot open: permission missing")
        case .disconnected: return L("Not connected (pair it over Bluetooth)")
        case .connected(ptp: false): return L("Connected — mouse mode (waiting for PTP switch)")
        case .connected(ptp: true): return L("Connected — running in PTP mode")
        }
    }
}
