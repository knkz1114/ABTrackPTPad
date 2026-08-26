import Foundation
import AppKit
import IOKit.hid
import ApplicationServices
import ServiceManagement
import Combine

/// Runs the engine and exposes permission / device state to the UI.
@MainActor
final class StatusModel: ObservableObject {
    @Published private(set) var accessibility = false
    @Published private(set) var inputMonitoring = false
    @Published private(set) var device: DeviceState = .disconnected
    @Published private(set) var lastReport: Date?
    @Published private(set) var reportsPerSecond = 0
    @Published private(set) var hidError: String?
    @Published var lastDiagnosticsURL: URL?
    @Published var lastError: String?

    private let settings: Settings
    private let diagnostics = Diagnostics()
    private var hid: HIDDevice!
    private var timer: Timer?
    private var lastCount = 0
    private var cancellables = Set<AnyCancellable>()

    init(settings: Settings) {
        self.settings = settings
        let engine = GestureEngine(settings: settings, sink: CGEventSink())
        hid = HIDDevice(engine: engine, diagnostics: diagnostics) { [weak self] state in
            self?.device = state
        }
        Log.write("ABTrackPTPad \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "") starting")
        refreshPermissions()
        requestPermissions()
        Log.write("permissions: accessibility=\(accessibility) inputMonitoring=\(inputMonitoring)")
        hid.start()

        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)   // keep updating while a menu is open
        timer = t
        settings.$recordDiagnostics
            .sink { [weak self] on in self?.diagnostics.enabled = on }
            .store(in: &cancellables)
        settings.$launchAtLogin
            .dropFirst()
            .sink { [weak self] on in self?.setLaunchAtLogin(on) }
            .store(in: &cancellables)
    }

    private func tick() {
        let hadAccessibility = accessibility
        refreshPermissions()
        // macOS does not apply a newly granted HID permission to an already-running process:
        // IOHIDManagerOpen keeps failing until the app is relaunched. Do that automatically.
        if !hadAccessibility && accessibility && device == .noPermission {
            Log.write("permission granted while running — relaunching")
            relaunch()
            return
        }
        lastReport = hid.lastReport
        hidError = hid.openError
        reportsPerSecond = hid.reportCount - lastCount
        lastCount = hid.reportCount
    }

    private func refreshPermissions() {
        accessibility = AXIsProcessTrusted()
        inputMonitoring = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// Shows the system prompts and creates the entries in System Settings.
    func requestPermissions() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        refreshPermissions()
    }

    func openSystemSettings(_ pane: String) {
        // pane: "Privacy_Accessibility" or "Privacy_ListenEvent"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    func saveDiagnostics() {
        do {
            lastDiagnosticsURL = try diagnostics.save()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func relaunch() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            lastError = nil
        } catch {
            lastError = L("Failed to set launch at login: %@", error.localizedDescription)
        }
    }

    var launchAtLoginEffective: Bool { SMAppService.mainApp.status == .enabled }

    var summary: String {
        switch device {
        case .noPermission: return L("Permission required")
        case .disconnected: return L("Trackpad: not connected")
        case .connected(ptp: false): return L("Trackpad: connected (mouse mode)")
        case .connected(ptp: true): return L("Trackpad: active")
        }
    }
}
