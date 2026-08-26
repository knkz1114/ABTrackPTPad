import Foundation
import CoreGraphics

/// Interprets Precision Touchpad reports and drives an `EventSink`.
///
/// Pointer motion uses Apple's parametric acceleration (see `PointerAcceleration`) on
/// one-euro-smoothed finger positions; tap, drag, palm and thumb handling follow libinput's
/// thresholds; two-finger scrolling maps 1:1 to the screen with Apple-style momentum.
@MainActor
final class GestureEngine {
    // Pad geometry from the HID descriptor
    static let unitsPerMM = 12.66
    static let padWidthMM = 1973 / unitsPerMM      // 155.8
    static let padHeightMM = 1458 / unitsPerMM     // 115.2

    // Thresholds (mm, seconds). The user-adjustable ones come from Settings (defaults follow libinput / Apple).
    private var edgeZoneX: Double { settings.edgeZone }
    private let edgeZoneTop = 5.0
    private var thumbZone: Double { settings.thumbZone }   // bottom band where a second touch is treated as a thumb
    private let edgeRelease = 3.0          // movement that promotes an edge touch to a finger
    private let thumbReleaseSpeed = 20.0   // mm/s
    private let thumbReleaseTravel = 2.0   // mm
    private let thumbLandingDelay = 0.15   // s: fingers landing within this of each other are never thumbs
    private let restingAge = 0.5           // a finger down this long without moving is a resting finger
    private var tapTimeout: Double { settings.tapTimeout }
    private var tapMoveThreshold: Double { settings.tapMoveThreshold }
    private let dragTimeout = 0.16
    private var dragLockTimeout: Double { settings.dragLockTimeout }
    private let gestureThreshold = 1.5     // scroll / pinch decision
    private let swipeThreshold = 5.0       // three-finger swipe decision
    private var swipeSpaceMM: Double { 118.0 / settings.swipeSensitivity }     // horizontal swipe distance for one space
    private var swipeMissionMM: Double { 71.0 / settings.swipeSensitivity }    // vertical swipe distance for a full Mission Control pull

    private let settings: Settings
    private let sink: EventSink
    private let momentum: Momentum
    private var accel: PointerAcceleration
    private var accelSpeed: Double

    private var touches: [Int: Touch] = [:]
    private var prevTime = 0.0
    private var lastCount = 0

    enum Mode { case idle, pointer, twoUndecided, scroll, pinch, multiUndecided, swipeH, swipeV }
    private var mode: Mode = .idle
    private var lockDx = 0.0, lockDy = 0.0, lockSpread = 0.0
    private var spreadBase = 0.0
    private var prevSpread: Double?
    private var swipeMotion: SwipeMotion = .horizontal

    // Touch session (first finger down … last finger up)
    private var touching = false
    private var sessionStart = 0.0
    private var maxFingers = 0
    private var tapCandidate = false
    private var buttonDown = false
    private var lastTapUp = -Double.infinity
    private var tapDragging = false
    private var dragLockPending = false

    private var scrollHistory: [(vx: Double, vy: Double, t: Double)] = []

    init(settings: Settings, sink: EventSink) {
        self.settings = settings
        self.sink = sink
        momentum = Momentum(settings: settings, sink: sink)
        accelSpeed = settings.pointerSpeed
        accel = PointerAcceleration(trackingSpeed: accelSpeed)
    }

    // MARK: report parsing

    /// Feed one PTP input report (payload after the report ID).
    ///
    /// Per contact (4 bytes): [confidence:1 tip:1 id:3 pad:3][x:12][y:12]; then scan time u16, contact count u8, button u8.
    /// The descriptor declares 5 slots but the pad sends 4 (20 bytes + report ID). Unused slots are all-zero, so only
    /// the first `contactCount` slots are examined; the confidence bit is unreliable on this firmware and is ignored.
    func handleReport(_ d: [UInt8], time t: TimeInterval) {
        guard d.count >= 8 else { return }
        let dt = prevTime == 0 ? 0.008 : min(0.05, max(0.001, t - prevTime))
        let nSlots = (d.count - 4) / 4
        let count = Int(d[4 * nSlots + 2])
        let valid = count > 0 ? min(count, nSlots) : nSlots
        for i in 0..<valid {
            let b = d[4 * i]
            let tip = (b >> 1) & 1 != 0, id = Int((b >> 2) & 7)
            let x = Double(Int(d[4 * i + 1]) | (Int(d[4 * i + 2] & 0x0F) << 8)) / Self.unitsPerMM
            let y = Double(Int(d[4 * i + 2] >> 4) | (Int(d[4 * i + 3]) << 4)) / Self.unitsPerMM
            if tip {
                if touches[id] != nil {
                    touches[id]!.update(x: x, y: y, time: t, dt: dt)
                } else {
                    touches[id] = newTouch(id: id, x: x, y: y, time: t)
                }
            } else {
                touches[id] = nil
            }
        }
        processFrame(button: d[4 * nSlots + 3] & 1 != 0, time: t, dt: dt)
    }

    private func newTouch(id: Int, x: Double, y: Double, time t: TimeInterval) -> Touch {
        var touch = Touch(id: id, x: x, y: y, time: t, minCutoff: settings.smoothing, beta: 0.03)
        // A touch in the bottom band is a thumb only when another finger has clearly been in use
        // already; two fingers landing together (scrolling) are both fingers.
        let establishedFinger = touches.values.contains { $0.role == .finger && t - $0.start > thumbLandingDelay }
        if x < edgeZoneX || x > Self.padWidthMM - edgeZoneX || y < edgeZoneTop {
            touch.role = .edge
        } else if y > Self.padHeightMM - thumbZone && establishedFinger {
            touch.role = .thumb
        }
        return touch
    }

    // MARK: per-frame processing

    private func processFrame(button: Bool, time t: TimeInterval, dt: Double) {
        prevTime = t
        if settings.pointerSpeed != accelSpeed {
            accelSpeed = settings.pointerSpeed
            accel = PointerAcceleration(trackingSpeed: accelSpeed)
        }
        classifyTouches(time: t, dt: dt)

        let active = touches.values.filter { $0.role == .finger }.sorted { $0.start < $1.start }
        let n = active.count

        // Physical click (click pad): two fingers → right button
        if button != buttonDown {
            buttonDown = button
            if button {
                sink.button(n >= 2 ? .right : .left, down: true)
            } else {
                if sink.leftDown && !tapDragging { sink.button(.left, down: false) }
                if sink.rightDown { sink.button(.right, down: false) }
            }
        }

        // Session start
        if n > 0 && !touching {
            touching = true
            sessionStart = t
            maxFingers = 0
            tapCandidate = true
            momentum.stop(sendEnd: true)
            if dragLockPending {
                dragLockPending = false                      // finger came back: drag continues
            } else if settings.tapToClick && settings.tapDrag && n == 1 && t - lastTapUp < dragTimeout && !sink.leftDown {
                tapDragging = true
                sink.button(.left, down: true)
            }
        }
        maxFingers = max(maxFingers, n)
        if tapCandidate && (t - sessionStart > tapTimeout || active.contains { $0.rawTravelFromOrigin > tapMoveThreshold }) {
            tapCandidate = false
        }

        // Centroid, spread and their deltas (smoothed positions)
        var dx = 0.0, dy = 0.0, spread = 0.0, dspread = 0.0
        if n > 0 {
            for f in active { dx += f.delta.x; dy += f.delta.y }
            dx /= Double(n); dy /= Double(n)
        }
        if n >= 2 {
            spread = hypot(active[0].smooth.x - active[1].smooth.x, active[0].smooth.y - active[1].smooth.y)
            if let p = prevSpread { dspread = spread - p }
        }
        let countChanged = n != lastCount
        if countChanged { dx = 0; dy = 0; dspread = 0 }   // the centroid jumps when a finger is added or removed

        if countChanged {
            endMode(time: t)
            switch n {
            case 0: mode = .idle
            case 1: mode = .pointer
            case 2: mode = .twoUndecided; lockDx = 0; lockDy = 0; lockSpread = 0
            default: mode = .multiUndecided; lockDx = 0; lockDy = 0
            }
            if n == 2 && !sink.leftDown { sink.scroll(dx: 0, dy: 0, phase: .mayBegin, momentum: .none, natural: settings.naturalScroll) }
            lastCount = n
        }

        switch mode {
        case .idle:
            break
        case .pointer:
            movePointer(dx, dy, dt: dt)
        case .twoUndecided:
            if sink.leftDown { movePointer(dx, dy, dt: dt); break }   // dragging with a second finger down
            lockDx += dx; lockDy += dy; lockSpread += dspread
            let translation = hypot(lockDx, lockDy)
            if abs(lockSpread) > gestureThreshold && abs(lockSpread) > translation {
                mode = .pinch; spreadBase = spread
                sink.magnify(0, phase: .began)
            } else if translation > gestureThreshold {
                mode = .scroll
                scrollHistory.removeAll()
                emitScroll(lockDx, lockDy, dt: dt, phase: .began, time: t)
            }
        case .scroll:
            if dx != 0 || dy != 0 { emitScroll(dx, dy, dt: dt, phase: .changed, time: t) }
        case .pinch:
            if dspread != 0, spreadBase > 0 { sink.magnify(dspread / spreadBase, phase: .changed) }
        case .multiUndecided:
            lockDx += dx; lockDy += dy
            if hypot(lockDx, lockDy) > swipeThreshold {
                if abs(lockDx) > abs(lockDy) {
                    mode = .swipeH; swipeMotion = .horizontal
                    sink.dockSwipe(delta: hDelta(lockDx), motion: .horizontal, phase: .began)
                } else {
                    mode = .swipeV; swipeMotion = .vertical
                    sink.dockSwipe(delta: vDelta(lockDy), motion: .vertical, phase: .began)
                }
            }
        case .swipeH:
            if dx != 0 { sink.dockSwipe(delta: hDelta(dx), motion: .horizontal, phase: .changed) }
        case .swipeV:
            if dy != 0 { sink.dockSwipe(delta: vDelta(dy), motion: .vertical, phase: .changed) }
        }

        // Last finger up
        if n == 0 && touching {
            touching = false
            if tapDragging {
                dragLockPending = true                       // keep the button down for a moment (drag lock)
                DispatchQueue.main.asyncAfter(deadline: .now() + dragLockTimeout) { [weak self] in
                    guard let self, self.dragLockPending else { return }
                    self.dragLockPending = false
                    self.tapDragging = false
                    self.sink.button(.left, down: false)
                }
            } else if settings.tapToClick && tapCandidate && !buttonDown {
                switch maxFingers {
                case 1: sink.click(.left); lastTapUp = t
                case 2: if settings.twoFingerTapRightClick { sink.click(.right) }
                case 3: sink.click(.center)
                default: break
                }
            }
        }

        prevSpread = n >= 2 ? spread : nil
    }

    /// Promote / demote edge, thumb and resting touches.
    private func classifyTouches(time t: TimeInterval, dt: Double) {
        let fingers = touches.values.filter { $0.role == .finger }
        let someoneMoving = fingers.contains { hypot($0.delta.x, $0.delta.y) > 0.1 }
        for (id, touch) in touches {
            switch touch.role {
            case .edge:
                let inZone = touch.raw.x < edgeZoneX || touch.raw.x > Self.padWidthMM - edgeZoneX || touch.raw.y < edgeZoneTop
                if !inZone && touch.rawTravelFromOrigin > edgeRelease { touches[id]!.role = .finger }
            case .thumb:
                let speed = hypot(touch.delta.x, touch.delta.y) / dt
                if speed > thumbReleaseSpeed || touch.travel > thumbReleaseTravel || fingers.isEmpty { touches[id]!.role = .finger }
            case .finger:
                // A finger that has been resting while another one moves is ignored (Apple lets you rest a finger).
                if fingers.count >= 2, someoneMoving, t - touch.start > restingAge, touch.travel < 1.0 {
                    touches[id]!.role = .resting
                }
            case .resting:
                if touch.travel > 2.0 { touches[id]!.role = .finger }
            }
        }
    }

    // MARK: outputs

    private func movePointer(_ dx: Double, _ dy: Double, dt: Double) {
        guard dx != 0 || dy != 0 else { return }
        let speed = hypot(dx, dy) / dt                       // mm/s
        let gain = accel.gain(mmPerSecond: speed)            // pt per mm
        sink.moveCursor(dx: dx * gain, dy: dy * gain)
    }

    /// Scroll gain in points per millimetre: the setting is expressed in pt per pad unit (0.30 ≈ 1:1 on screen).
    private var scrollGain: Double { settings.scrollSpeed * Self.unitsPerMM }

    private func emitScroll(_ dx: Double, _ dy: Double, dt: Double, phase: Phase, time t: Double) {
        let s = settings.naturalScroll ? 1.0 : -1.0
        let sx = dx * scrollGain * s, sy = dy * scrollGain * s
        sink.scroll(dx: sx, dy: sy, phase: phase, momentum: .none, natural: settings.naturalScroll)
        scrollHistory.append((sx / dt, sy / dt, t))
        if scrollHistory.count > 4 { scrollHistory.removeFirst() }
    }

    // Finger moving left → next space (negative progress); finger moving up → Mission Control (positive progress).
    private func hDelta(_ dx: Double) -> Double { (settings.invertSwipeH ? -dx : dx) / swipeSpaceMM }
    private func vDelta(_ dy: Double) -> Double { (settings.invertSwipeV ? dy : -dy) / swipeMissionMM }

    private func endMode(time t: TimeInterval) {
        switch mode {
        case .twoUndecided:
            if !sink.leftDown { sink.scroll(dx: 0, dy: 0, phase: .cancelled, momentum: .none, natural: settings.naturalScroll) }
        case .scroll:
            sink.scroll(dx: 0, dy: 0, phase: .ended, momentum: .none, natural: settings.naturalScroll)
            // Momentum only if the fingers were still moving when they left the pad.
            if let last = scrollHistory.last, t - last.t < 0.05, hypot(last.vx, last.vy) > 40 {
                let vx = scrollHistory.map(\.vx).reduce(0, +) / Double(scrollHistory.count)
                let vy = scrollHistory.map(\.vy).reduce(0, +) / Double(scrollHistory.count)
                momentum.start(vx: vx, vy: vy)
            }
            scrollHistory.removeAll()
        case .pinch:
            sink.magnify(0, phase: .ended)
        case .swipeH, .swipeV:
            sink.dockSwipe(delta: 0, motion: swipeMotion, phase: .ended)
        default:
            break
        }
    }
}

// MARK: - Momentum scrolling

/// Apple-style deceleration: velocity decays by 0.998 per millisecond (UIScrollView's normal rate).
@MainActor
final class Momentum {
    private let settings: Settings
    private let sink: EventSink
    private var timer: DispatchSourceTimer?
    private var vx = 0.0, vy = 0.0
    private var last = 0.0
    private var decayPerMS: Double { min(0.9995, max(0.98, settings.momentumDecay)) }
    private let stopSpeed = 20.0            // pt/s

    init(settings: Settings, sink: EventSink) { self.settings = settings; self.sink = sink }

    func start(vx: Double, vy: Double) {
        stop(sendEnd: false)
        self.vx = vx; self.vy = vy; last = CFAbsoluteTimeGetCurrent()
        sink.scroll(dx: 0, dy: 0, phase: .none, momentum: .begin, natural: settings.naturalScroll)
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + .milliseconds(8), repeating: .milliseconds(16))
        t.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.tick() } }
        t.resume(); timer = t
    }

    private func tick() {
        let t = CFAbsoluteTimeGetCurrent(); let dt = t - last; last = t
        let k = pow(decayPerMS, dt * 1000)
        // Integrate the exponential exactly over the frame.
        let dist = (1 - k) / (-log(decayPerMS) * 1000)
        let dx = vx * dist, dy = vy * dist
        vx *= k; vy *= k
        if hypot(vx, vy) < stopSpeed { stop(sendEnd: true); return }
        sink.scroll(dx: dx, dy: dy, phase: .none, momentum: .cont, natural: settings.naturalScroll)
    }

    func stop(sendEnd: Bool) {
        guard let t = timer else { return }
        t.cancel(); timer = nil
        if sendEnd { sink.scroll(dx: 0, dy: 0, phase: .none, momentum: .end, natural: settings.naturalScroll) }
    }
}
