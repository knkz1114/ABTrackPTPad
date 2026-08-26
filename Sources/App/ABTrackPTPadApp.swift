import SwiftUI

@main
struct ABTrackPTPadApp: App {
    @StateObject private var settings = Settings.shared
    @StateObject private var status: StatusModel
    @Environment(\.openWindow) private var openWindow

    init() {
        let s = Settings.shared
        _status = StateObject(wrappedValue: StatusModel(settings: s))
    }

    var body: some Scene {
        MenuBarExtra("ABTrackPTPad", systemImage: menuIcon) {
            Text(status.summary)
            Divider()
            Button(L("Settings…")) {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "settings")
            }
            .keyboardShortcut(",")
            Divider()
            Button(L("Quit ABTrackPTPad")) { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }

        Window("ABTrackPTPad", id: "settings") {
            TabView {
                SettingsView().tabItem { Label(L("Gestures"), systemImage: "hand.draw") }
                AdvancedView().tabItem { Label(L("Advanced"), systemImage: "slider.horizontal.3") }
                StatusView().tabItem { Label(L("Permissions"), systemImage: "lock.shield") }
            }
            .frame(width: 520, height: 560)
            .id(settings.language)   // rebuild the view tree when the language changes
            .padding()
            .environmentObject(settings)
            .environmentObject(status)
        }
        .windowResizability(.contentSize)
    }

    private var menuIcon: String {
        switch status.device {
        case .connected(ptp: true): return "hand.tap.fill"
        case .connected(ptp: false): return "hand.tap"
        case .disconnected: return "hand.raised.slash"
        case .noPermission: return "exclamationmark.triangle"
        }
    }
}
