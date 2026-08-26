import Foundation
import CoreGraphics

struct Contact {
    var id: Int
    var x: Double
    var y: Double
}

/// Interprets Precision Touchpad reports and drives an `EventSink`.
@MainActor
final class GestureEngine {
    enum Mode { case idle, pointer, twoUndecided, scroll, pinch, multiUndecided, swipeH, swipeV, buttonDrag }

    private let settings: Settings
    private let sink: EventSink
    private let momentum: Momentum

    private var contacts: [Int: Contact] = [:]
    private var prevCentroid: (Double, Double)?
    private var prevSpread: Double?
    private var prevTime = 0.0
    private var mode: Mode = .idle
    private var lastCount = 0
    private var fingersInSession = 0
    private var sessionStart = 0.0
    private var sessionTravel = 0.0
    private var lockTravel = 0.0
    private var lockSpread = 0.0
    private var lockDx = 0.0, lockDy = 0.0
    private var pinchBase = 0.0
    private var lastScroll = (dx: 0.0, dy: 0.0, t: 0.0)
    private var buttonDown = false
    private var lastTapUp = -Double.infinity
    private var tapDragging = false
    private var touching = false

    init(settings: Settings, sink: EventSink) {
        self.settings = settings
        self.sink = sink
        self.momentum = Momentum(settings: settings, sink: sink)
    }

    /// Feed one PTP input report (payload after the report ID).
    ///
    /// Per contact (4 bytes): [confidence:1 tip:1 id:3 pad:3][x:12][y:12]; then scan time u16, contact count u8, button u8.
    /// The descriptor declares 5 slots but the pad sends 4 (20 bytes + report ID). Unused slots are all-zero, so only
    /// the first `contactCount` slots are examined; the confidence bit is unreliable on this firmware and is ignored.
    func handleReport(_ d: [UInt8], time t: TimeInterval) {
        guard d.count >= 8 else { return }
        let nSlots = (d.count - 4) / 4
        let count = Int(d[4 * nSlots + 2])
        let valid = count > 0 ? min(count, nSlots) : nSlots
        for i in 0..<valid {
            let b = d[4 * i]
            let tip = (b >> 1) & 1 != 0, id = Int((b >> 2) & 7)
            let x = Double(Int(d[4 * i + 1]) | (Int(d[4 * i + 2] & 0x0F) << 8))
            let y = Double(Int(d[4 * i + 2] >> 4) | (Int(d[4 * i + 3]) << 4))
            if tip { contacts[id] = Contact(id: id, x: x, y: y) } else { contacts[id] = nil }
        }
        processFrame(button: d[4 * nSlots + 3] & 1 != 0, time: t)
    }

    private func processFrame(button: Bool, time t: TimeInterval) {
        let active = Array(contacts.values)
        let n = active.count
        let dt = prevTime == 0 ? 0.008 : max(0.001, t - prevTime)
        prevTime = t

        // Physical click (click pad): two fingers → right button
        if button != buttonDown {
            buttonDown = button
            if button {
                sink.button(n >= 2 ? .right : .left, down: true)
            } else {
                if sink.leftDown { sink.button(.left, down: false) }
                if sink.rightDown { sink.button(.right, down: false) }
            }
        }

        // Touch session: first finger down … last finger up
        if n > 0 && !touching {
            touching = true; sessionStart = t; sessionTravel = 0; fingersInSession = 0
            momentum.stop(sendEnd: true)
            if settings.tapDrag && t - lastTapUp < settings.tapDragGap && n == 1 && !sink.leftDown {
                tapDragging = true
                sink.button(.left, down: true)
            }
        }
        fingersInSession = max(fingersInSession, n)

        // Centroid and spread
        var cx = 0.0, cy = 0.0
        for c in active { cx += c.x; cy += c.y }
        if n > 0 { cx /= Double(n); cy /= Double(n) }
        var spread = 0.0
        if n >= 2 { spread = hypot(active[0].x - active[1].x, active[0].y - active[1].y) }
        var ddx = 0.0, ddy = 0.0, dspread = 0.0
        if let p = prevCentroid, n > 0 { ddx = cx - p.0; ddy = cy - p.1 }
        if let s = prevSpread, n >= 2 { dspread = spread - s }
        let countChanged = n != lastCount
        if countChanged { ddx = 0; ddy = 0; dspread = 0 }      // the centroid jumps when a finger is added/removed
        sessionTravel += hypot(ddx, ddy)

        if countChanged {
            endMode(time: t)
            switch n {
            case 0: mode = .idle
            case 1: mode = sink.leftDown ? .buttonDrag : .pointer
            case 2: mode = .twoUndecided; lockTravel = 0; lockSpread = 0; lockDx = 0; lockDy = 0
            default: mode = .multiUndecided; lockDx = 0; lockDy = 0
            }
            if n == 2 && !sink.leftDown { sink.scroll(dx: 0, dy: 0, phase: .mayBegin, momentum: .none, natural: settings.naturalScroll) }
            lastCount = n
        }

        switch mode {
        case .idle:
            break
        case .pointer, .buttonDrag:
            movePointer(ddx, ddy, dt: dt)
        case .twoUndecided:
            if sink.leftDown { movePointer(ddx, ddy, dt: dt); break }
            lockTravel += hypot(ddx, ddy); lockSpread += abs(dspread)
            lockDx += ddx; lockDy += ddy
            if max(lockTravel, lockSpread) > settings.gestureLockDistance {
                if lockSpread > lockTravel * settings.pinchRatio {
                    mode = .pinch; pinchBase = spread
                    sink.magnify(0, phase: .began)
                } else {
                    mode = .scroll
                    let (sx, sy) = scrollDelta(lockDx, lockDy)
                    sink.scroll(dx: sx, dy: sy, phase: .began, momentum: .none, natural: settings.naturalScroll)
                    lastScroll = (sx, sy, t)
                }
            }
        case .scroll:
            if ddx != 0 || ddy != 0 {
                let (sx, sy) = scrollDelta(ddx, ddy)
                sink.scroll(dx: sx, dy: sy, phase: .changed, momentum: .none, natural: settings.naturalScroll)
                lastScroll = (sx / dt, sy / dt, t)
            }
        case .pinch:
            if dspread != 0, pinchBase > 0 { sink.magnify(dspread / pinchBase, phase: .changed) }
        case .multiUndecided:
            lockDx += ddx; lockDy += ddy
            if hypot(lockDx, lockDy) > settings.gestureLockDistance {
                if abs(lockDx) > abs(lockDy) {
                    mode = .swipeH
                    sink.dockSwipe(delta: hDelta(lockDx), motion: .horizontal, phase: .began)
                } else {
                    mode = .swipeV
                    sink.dockSwipe(delta: vDelta(lockDy), motion: .vertical, phase: .began)
                }
            }
        case .swipeH:
            if ddx != 0 { sink.dockSwipe(delta: hDelta(ddx), motion: .horizontal, phase: .changed) }
        case .swipeV:
            if ddy != 0 { sink.dockSwipe(delta: vDelta(ddy), motion: .vertical, phase: .changed) }
        }

        // Last finger up: tap detection
        if n == 0 && touching {
            touching = false
            if tapDragging {
                tapDragging = false
                sink.button(.left, down: false)
            } else if settings.tapToClick && !buttonDown && t - sessionStart < settings.tapMaxDuration && sessionTravel < settings.tapMaxMovement {
                switch fingersInSession {
                case 1: sink.click(.left); lastTapUp = t
                case 2: if settings.twoFingerTapRightClick { sink.click(.right) }
                case 3: sink.click(.center)
                default: break
                }
            }
        }

        prevCentroid = n > 0 ? (cx, cy) : nil
        prevSpread = n >= 2 ? spread : nil
    }

    // Finger moving left → next space (negative progress); finger moving up → Mission Control (positive progress).
    private func hDelta(_ dx: Double) -> Double { (settings.invertSwipeH ? -dx : dx) * settings.swipeHScale }
    private func vDelta(_ dy: Double) -> Double { (settings.invertSwipeV ? dy : -dy) * settings.swipeVScale }

    private func scrollDelta(_ dx: Double, _ dy: Double) -> (Double, Double) {
        let s = settings.naturalScroll ? 1.0 : -1.0
        return (dx * settings.scrollSpeed * s, dy * settings.scrollSpeed * s)
    }

    private func movePointer(_ dx: Double, _ dy: Double, dt: Double) {
        guard dx != 0 || dy != 0 else { return }
        let speed = hypot(dx, dy) / (dt * 1000)                 // units per ms
        let accel = 1 + (settings.pointerAccelMax - 1) * min(1, speed / settings.pointerAccelSpeed)
        sink.moveCursor(dx: dx * settings.pointerGain * accel, dy: dy * settings.pointerGain * accel)
    }

    private func endMode(time t: TimeInterval) {
        switch mode {
        case .twoUndecided:
            if !sink.leftDown { sink.scroll(dx: 0, dy: 0, phase: .cancelled, momentum: .none, natural: settings.naturalScroll) }
        case .scroll:
            sink.scroll(dx: 0, dy: 0, phase: .ended, momentum: .none, natural: settings.naturalScroll)
            if t - lastScroll.t < 0.08 { momentum.start(vx: lastScroll.dx, vy: lastScroll.dy) }
        case .pinch:
            sink.magnify(0, phase: .ended)
        case .swipeH:
            sink.dockSwipe(delta: 0, motion: .horizontal, phase: .ended)
        case .swipeV:
            sink.dockSwipe(delta: 0, motion: .vertical, phase: .ended)
        default:
            break
        }
    }
}

// MARK: - Momentum scrolling

@MainActor
final class Momentum {
    private let settings: Settings
    private let sink: EventSink
    private var timer: DispatchSourceTimer?
    private var vx = 0.0, vy = 0.0
    private var last = 0.0

    init(settings: Settings, sink: EventSink) { self.settings = settings; self.sink = sink }

    func start(vx: Double, vy: Double) {
        stop(sendEnd: false)
        guard hypot(vx, vy) > settings.momentumStop * 4 else { return }
        self.vx = vx; self.vy = vy; last = CFAbsoluteTimeGetCurrent()
        sink.scroll(dx: 0, dy: 0, phase: .none, momentum: .begin, natural: settings.naturalScroll)
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + .milliseconds(8), repeating: .milliseconds(16))
        t.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.tick() } }
        t.resume(); timer = t
    }

    private func tick() {
        let t = CFAbsoluteTimeGetCurrent(); let dt = t - last; last = t
        let k = exp(-settings.momentumDecay * dt)
        vx *= k; vy *= k
        if hypot(vx, vy) < settings.momentumStop { stop(sendEnd: true); return }
        sink.scroll(dx: vx * dt, dy: vy * dt, phase: .none, momentum: .cont, natural: settings.naturalScroll)
    }

    func stop(sendEnd: Bool) {
        guard let t = timer else { return }
        t.cancel(); timer = nil
        if sendEnd { sink.scroll(dx: 0, dy: 0, phase: .none, momentum: .end, natural: settings.naturalScroll) }
    }
}
