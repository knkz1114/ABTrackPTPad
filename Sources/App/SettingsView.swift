import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: Settings

    var body: some View {
        Form {
            Section(L("Pointer")) {
                LabeledContent(L("Tracking speed")) {
                    Slider(value: $settings.pointerSpeed, in: 0...3, step: 0.25) {
                        EmptyView()
                    } minimumValueLabel: { Text(L("Slow")) } maximumValueLabel: { Text(L("Fast")) }
                }
                Toggle(L("Tap to click"), isOn: $settings.tapToClick)
                Toggle(L("Tap then drag"), isOn: $settings.tapDrag)
                    .disabled(!settings.tapToClick)
                Toggle(L("Two-finger tap for right click"), isOn: $settings.twoFingerTapRightClick)
                    .disabled(!settings.tapToClick)
                Toggle(L("Three-finger drag"), isOn: $settings.threeFingerDrag)
            }
            Section(L("Scroll & zoom")) {
                Toggle(L("Natural scrolling (content follows fingers)"), isOn: $settings.naturalScroll)
                Toggle(L("Momentum scrolling"), isOn: $settings.momentumScroll)
                Toggle(L("Rotate with two fingers"), isOn: $settings.rotateEnabled)
                Toggle(L("Smart zoom (two-finger double tap)"), isOn: $settings.smartZoom)
                LabeledContent(L("Scrolling speed")) {
                    Slider(value: $settings.scrollSpeed, in: 0.1...1.5, step: 0.05) {
                        EmptyView()
                    } minimumValueLabel: { Text(L("Slow")) } maximumValueLabel: { Text(L("Fast")) }
                }
            }
            Section(L("Three-finger swipes")) {
                Toggle(L("Invert left/right (switch Spaces)"), isOn: $settings.invertSwipeH)
                Toggle(L("Invert up/down (Mission Control)"), isOn: $settings.invertSwipeV)
            }
            Section {
                Toggle(L("Launch ABTrackPTPad at login"), isOn: $settings.launchAtLogin)
                Picker(L("Language"), selection: $settings.language) {
                    ForEach(L10n.available, id: \.self) { code in
                        Text(L10n.name(of: code)).tag(code)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
