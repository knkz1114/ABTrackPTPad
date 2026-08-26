import SwiftUI

/// Tuning parameters for the gesture engine. Defaults follow libinput and Apple's own values.
struct AdvancedView: View {
    @EnvironmentObject private var settings: Settings

    var body: some View {
        Form {
            Section(L("Pointer")) {
                slider(L("Smoothing"), $settings.smoothing, 0.5...4, step: 0.1, format: "%.1f Hz",
                       help: L("Lower is smoother but adds lag. One-euro filter cutoff."))
            }
            Section(L("Tap")) {
                slider(L("Tap timeout"), $settings.tapTimeout, 0.1...0.4, step: 0.01, format: "%.0f ms", scale: 1000)
                slider(L("Tap movement limit"), $settings.tapMoveThreshold, 0.5...3, step: 0.1, format: "%.1f mm")
                slider(L("Drag lock timeout"), $settings.dragLockTimeout, 0...0.8, step: 0.05, format: "%.0f ms", scale: 1000)
            }
            Section(L("Palm rejection")) {
                slider(L("Edge zone (left/right)"), $settings.edgeZone, 0...15, step: 0.5, format: "%.1f mm")
                slider(L("Thumb zone (bottom)"), $settings.thumbZone, 0...25, step: 0.5, format: "%.1f mm")
            }
            Section(L("Scroll & swipes")) {
                slider(L("Momentum"), $settings.momentumDecay, 0.990...0.9995, step: 0.0005, format: "%.4f",
                       help: L("Velocity kept per millisecond. 0.998 matches Apple."))
                slider(L("Three-finger swipe sensitivity"), $settings.swipeSensitivity, 0.5...2, step: 0.05, format: "×%.2f")
            }
            Section {
                Button(L("Reset to defaults")) { settings.resetAdvanced() }
            }
        }
        .formStyle(.grouped)
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, step: Double,
                        format: String, scale: Double = 1, help: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent(title) {
                HStack {
                    Slider(value: value, in: range, step: step)
                    Text(String(format: format, value.wrappedValue * scale))
                        .font(.caption.monospacedDigit()).frame(width: 64, alignment: .trailing)
                }
            }
            if let help { Text(help).font(.caption).foregroundStyle(.secondary) }
        }
    }
}
