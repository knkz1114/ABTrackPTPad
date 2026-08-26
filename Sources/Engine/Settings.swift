import Foundation
import Combine

/// User-adjustable settings, persisted in UserDefaults. Independent from the
/// built-in trackpad settings in System Settings.
@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()

    @Published var pointerSpeed: Double { didSet { save("pointerSpeed", pointerSpeed) } }       // 0…3
    @Published var naturalScroll: Bool { didSet { save("naturalScroll", naturalScroll) } }
    @Published var scrollSpeed: Double { didSet { save("scrollSpeed", scrollSpeed) } }          // pt per pad unit
    @Published var tapToClick: Bool { didSet { save("tapToClick", tapToClick) } }
    @Published var tapDrag: Bool { didSet { save("tapDrag", tapDrag) } }
    @Published var twoFingerTapRightClick: Bool { didSet { save("twoFingerTapRightClick", twoFingerTapRightClick) } }
    @Published var invertSwipeH: Bool { didSet { save("invertSwipeH", invertSwipeH) } }
    @Published var invertSwipeV: Bool { didSet { save("invertSwipeV", invertSwipeV) } }
    @Published var launchAtLogin: Bool { didSet { save("launchAtLogin", launchAtLogin) } }
    @Published var recordDiagnostics: Bool { didSet { save("recordDiagnostics", recordDiagnostics) } }
    @Published var language: String { didSet { save("language", language) } }                   // "system", "en", "ja"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func d<T>(_ key: String, _ fallback: T) -> T { defaults.object(forKey: key) as? T ?? fallback }
        pointerSpeed = d("pointerSpeed", 1.5)
        naturalScroll = d("naturalScroll", true)
        scrollSpeed = d("scrollSpeed", 0.30)
        tapToClick = d("tapToClick", true)
        tapDrag = d("tapDrag", true)
        twoFingerTapRightClick = d("twoFingerTapRightClick", true)
        invertSwipeH = d("invertSwipeH", false)
        invertSwipeV = d("invertSwipeV", false)
        launchAtLogin = d("launchAtLogin", false)
        recordDiagnostics = d("recordDiagnostics", false)
        language = d("language", "system")
    }

    private func save(_ key: String, _ value: Any) { defaults.set(value, forKey: key) }

    // Derived engine parameters

    /// pt per pad unit before acceleration (≈ 4.4 … 14 pt/mm)
    var pointerGain: Double { 0.35 + 0.25 * pointerSpeed }

    // Fixed tuning
    let pointerAccelMax = 3.2            // max multiplier at high speed
    let pointerAccelSpeed = 5.0          // units/ms at which the multiplier saturates
    let tapMaxDuration: TimeInterval = 0.25
    let tapMaxMovement = 18.0            // units (~1.4 mm)
    let tapDragGap: TimeInterval = 0.30
    let momentumDecay = 3.2              // 1/s exponential decay
    let momentumStop = 20.0              // pt/s
    let gestureLockDistance = 22.0       // units of movement before a 2/3-finger gesture is classified
    let pinchRatio = 1.4                 // spread change must exceed this × translation to count as a pinch
    let swipeHScale = 1.0 / 1500.0       // progress per unit (1.0 == one space)
    let swipeVScale = 1.0 / 900.0        // progress per unit (1.0 == a full Mission Control pull)
}
