import Foundation
import Combine

/// User-adjustable settings, persisted in UserDefaults. Independent from the
/// built-in trackpad settings in System Settings.
@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()

    @Published var pointerSpeed: Double { didSet { save("pointerSpeed", pointerSpeed) } }       // 0…3
    @Published var naturalScroll: Bool { didSet { save("naturalScroll", naturalScroll) } }
    @Published var momentumScroll: Bool { didSet { save("momentumScroll", momentumScroll) } }
    @Published var scrollSpeed: Double { didSet { save("scrollSpeed", scrollSpeed) } }          // pt per pad unit
    @Published var tapToClick: Bool { didSet { save("tapToClick", tapToClick) } }
    @Published var tapDrag: Bool { didSet { save("tapDrag", tapDrag) } }
    @Published var twoFingerTapRightClick: Bool { didSet { save("twoFingerTapRightClick", twoFingerTapRightClick) } }
    @Published var rotateEnabled: Bool { didSet { save("rotateEnabled", rotateEnabled) } }
    @Published var smartZoom: Bool { didSet { save("smartZoom", smartZoom) } }
    @Published var threeFingerDrag: Bool { didSet { save("threeFingerDrag", threeFingerDrag) } }
    @Published var invertSwipeH: Bool { didSet { save("invertSwipeH", invertSwipeH) } }
    @Published var invertSwipeV: Bool { didSet { save("invertSwipeV", invertSwipeV) } }
    @Published var launchAtLogin: Bool { didSet { save("launchAtLogin", launchAtLogin) } }
    @Published var recordDiagnostics: Bool { didSet { save("recordDiagnostics", recordDiagnostics) } }
    @Published var language: String { didSet { save("language", language) } }                   // "system", "en", "ja"

    // Advanced tuning (see GestureEngine for how each is used)
    @Published var smoothing: Double { didSet { save("smoothing", smoothing) } }                 // one-euro min cutoff, Hz (lower = smoother)
    @Published var tapTimeout: Double { didSet { save("tapTimeout", tapTimeout) } }              // s
    @Published var tapMoveThreshold: Double { didSet { save("tapMoveThreshold", tapMoveThreshold) } }   // mm
    @Published var dragLockTimeout: Double { didSet { save("dragLockTimeout", dragLockTimeout) } }      // s
    @Published var edgeZone: Double { didSet { save("edgeZone", edgeZone) } }                    // mm, left/right palm zone
    @Published var thumbZone: Double { didSet { save("thumbZone", thumbZone) } }                 // mm, bottom thumb zone
    @Published var momentumDecay: Double { didSet { save("momentumDecay", momentumDecay) } }     // per-millisecond factor (0.998 = Apple)
    @Published var swipeSensitivity: Double { didSet { save("swipeSensitivity", swipeSensitivity) } }   // 1.0 = 118 mm per space

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func d<T>(_ key: String, _ fallback: T) -> T { defaults.object(forKey: key) as? T ?? fallback }
        pointerSpeed = d("pointerSpeed", 1.5)
        naturalScroll = d("naturalScroll", true)
        momentumScroll = d("momentumScroll", true)
        scrollSpeed = d("scrollSpeed", 0.30)
        tapToClick = d("tapToClick", true)
        tapDrag = d("tapDrag", true)
        twoFingerTapRightClick = d("twoFingerTapRightClick", true)
        rotateEnabled = d("rotateEnabled", true)
        smartZoom = d("smartZoom", true)
        threeFingerDrag = d("threeFingerDrag", false)
        invertSwipeH = d("invertSwipeH", false)
        invertSwipeV = d("invertSwipeV", false)
        launchAtLogin = d("launchAtLogin", false)
        recordDiagnostics = d("recordDiagnostics", false)
        language = d("language", "system")
        smoothing = d("smoothing", Settings.defaultSmoothing)
        tapTimeout = d("tapTimeout", Settings.defaultTapTimeout)
        tapMoveThreshold = d("tapMoveThreshold", Settings.defaultTapMoveThreshold)
        dragLockTimeout = d("dragLockTimeout", Settings.defaultDragLockTimeout)
        edgeZone = d("edgeZone", Settings.defaultEdgeZone)
        thumbZone = d("thumbZone", Settings.defaultThumbZone)
        momentumDecay = d("momentumDecay", Settings.defaultMomentumDecay)
        swipeSensitivity = d("swipeSensitivity", Settings.defaultSwipeSensitivity)
    }

    private func save(_ key: String, _ value: Any) { defaults.set(value, forKey: key) }

    static let defaultSmoothing = 1.5
    static let defaultTapTimeout = 0.18
    static let defaultTapMoveThreshold = 1.3
    static let defaultDragLockTimeout = 0.3
    static let defaultEdgeZone = 8.0
    static let defaultThumbZone = 12.0
    static let defaultMomentumDecay = 0.9952   // measured on the built-in trackpad
    static let defaultSwipeSensitivity = 1.0

    func resetAdvanced() {
        smoothing = Self.defaultSmoothing
        tapTimeout = Self.defaultTapTimeout
        tapMoveThreshold = Self.defaultTapMoveThreshold
        dragLockTimeout = Self.defaultDragLockTimeout
        edgeZone = Self.defaultEdgeZone
        thumbZone = Self.defaultThumbZone
        momentumDecay = Self.defaultMomentumDecay
        swipeSensitivity = Self.defaultSwipeSensitivity
    }

}
