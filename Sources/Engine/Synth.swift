import Foundation
import CoreGraphics
import ApplicationServices

enum Phase: Int64 { case none = 0, began = 1, changed = 2, ended = 4, cancelled = 8, mayBegin = 0x80 }
enum MomentumPhase: Int64 { case none = 0, begin = 1, cont = 2, end = 3 }
enum SwipeMotion: Int64 { case horizontal = 1, vertical = 2 }

/// Where the gesture engine sends its output. `CGEventSink` posts real events;
/// tests use a recording implementation.
@MainActor
protocol EventSink: AnyObject {
    var leftDown: Bool { get }
    var rightDown: Bool { get }
    func moveCursor(dx: Double, dy: Double)
    func button(_ b: CGMouseButton, down: Bool)
    func scroll(dx: Double, dy: Double, phase: Phase, momentum: MomentumPhase, natural: Bool)
    func magnify(_ delta: Double, phase: Phase)
    func dockSwipe(delta: Double, motion: SwipeMotion, phase: Phase)
}

extension EventSink {
    func click(_ b: CGMouseButton) { button(b, down: true); button(b, down: false) }
}

// MARK: - CGEvent synthesis
//
// Scroll, magnify and DockSwipe events use undocumented CGEvent fields:
//   55  event type            110 IOHID event subtype     132/134 gesture phase
//   116/119 gesture dx/dy     113 magnification          88/99/123 scroll continuous/phase/momentum
//   11/12 line delta          96/97 point delta          93/94 fixed-point delta   137 direction inverted
//   124 swipe progress        123 swipe motion            129/130 swipe velocity   4205 raw IOHID payload

@MainActor
final class CGEventSink: EventSink {
    private(set) var leftDown = false
    private(set) var rightDown = false

    private func field(_ e: CGEvent, _ f: UInt32, _ v: Int64) { e.setIntegerValueField(CGEventField(rawValue: f)!, value: v) }
    private func field(_ e: CGEvent, _ f: UInt32, _ v: Double) { e.setDoubleValueField(CGEventField(rawValue: f)!, value: v) }

    private var cursor: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    private func clampToScreens(_ p: CGPoint) -> CGPoint {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16); var n: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &n)
        var best = p; var bestD = Double.infinity
        for i in 0..<Int(n) {
            let b = CGDisplayBounds(ids[i])
            let cx = min(max(p.x, b.minX), b.maxX - 1), cy = min(max(p.y, b.minY), b.maxY - 1)
            let d = hypot(cx - p.x, cy - p.y)
            if d < bestD { bestD = d; best = CGPoint(x: cx, y: cy) }
        }
        return best
    }

    func moveCursor(dx: Double, dy: Double) {
        let p = clampToScreens(CGPoint(x: cursor.x + dx, y: cursor.y + dy))
        let type: CGEventType = leftDown ? .leftMouseDragged : (rightDown ? .rightMouseDragged : .mouseMoved)
        guard let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left) else { return }
        e.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx.rounded()))
        e.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy.rounded()))
        e.post(tap: .cghidEventTap)
    }

    func button(_ b: CGMouseButton, down: Bool) {
        let type: CGEventType
        switch (b, down) {
        case (.left, true): type = .leftMouseDown
        case (.left, false): type = .leftMouseUp
        case (.right, true): type = .rightMouseDown
        case (.right, false): type = .rightMouseUp
        default: type = down ? .otherMouseDown : .otherMouseUp
        }
        if b == .left { leftDown = down } else if b == .right { rightDown = down }
        guard let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: cursor, mouseButton: b) else { return }
        e.post(tap: .cghidEventTap)
    }

    /// Trackpad-style scroll: a continuous scroll-wheel event with phase, plus the matching gesture event.
    func scroll(dx: Double, dy: Double, phase: Phase, momentum: MomentumPhase, natural: Bool) {
        guard let e = CGEvent(source: nil) else { return }
        field(e, 55, Int64(22))                                 // NSEventTypeScrollWheel
        field(e, 88, Int64(1))                                  // continuous
        field(e, 137, Int64(natural ? 1 : 0))
        let ly = dy / 10.0, lx = dx / 10.0
        field(e, 11, Int64(ly.rounded()))
        field(e, 96, Int64(dy.rounded()))
        field(e, 93, Int64((ly * 65536.0).rounded()))
        field(e, 12, Int64(lx.rounded()))
        field(e, 97, Int64(dx.rounded()))
        field(e, 94, Int64((lx * 65536.0).rounded()))
        field(e, 99, phase.rawValue)
        field(e, 123, momentum.rawValue)
        e.location = cursor
        e.post(tap: .cgSessionEventTap)

        if phase != .none {
            guard let g = CGEvent(source: nil) else { return }
            field(g, 55, Int64(29))                             // NSEventTypeGesture
            field(g, 110, Int64(6))                             // kIOHIDEventTypeScroll
            field(g, 116, dx == 0 ? -0.0 : dx)
            field(g, 119, dy == 0 ? -0.0 : dy)
            field(g, 132, phase.rawValue)
            g.location = cursor
            g.post(tap: .cgSessionEventTap)
        }
    }

    func magnify(_ delta: Double, phase: Phase) {
        guard let e = CGEvent(source: nil) else { return }
        e.type = CGEventType(rawValue: 29)!                     // NSEventTypeGesture
        field(e, 110, Int64(8))                                 // kIOHIDEventTypeZoom
        field(e, 132, phase.rawValue)
        field(e, 113, delta)
        e.location = cursor
        e.post(tap: .cghidEventTap)
    }

    // MARK: DockSwipe (Spaces / Mission Control / App Exposé)
    //
    // Since macOS 26.5 the Dock ignores the plain CGEvent fields and requires a serialized IOHID
    // event appended to the CGEvent data as field 4205 (layout after joshuarli/iss, ISC license):
    //   IOHIDSystemQueueElementHeader (28): timestamp u64, senderID u64, options u32, attrLen u32, eventCount u32
    //   IOHIDFluidTouchGestureData   (40): size u32, type u32 (23), options u32 (phase << 24), depth u8 + pad[3],
    //                                      x/y/z fixed16.16, swipeMask u32, motion u16, flavor u16 (3), progress fixed16.16
    //   IOHIDVelocityEventData       (28): size u32, type u32 (9), options u32, depth u8 (1) + pad[3], vx/vy/vz fixed16.16

    private var swipeProgress = 0.0
    private var swipeLastDelta = 0.0

    private func fixed1616(_ v: Double) -> Int32 {
        let f = Int32(clamping: Int64((v * 65536.0).rounded()))
        return (f == 0 && v != 0) ? (v > 0 ? 1 : -1) : f
    }

    private func iohidPayload(phase: Phase, motion: SwipeMotion, progress: Double, velX: Double, velY: Double) -> [UInt8] {
        let includeVelocity = velX != 0 || velY != 0 || phase == .ended
        var p = [UInt8]()
        func u8(_ v: UInt8) { p.append(v) }
        func u16(_ v: UInt16) { p.append(UInt8(v & 0xFF)); p.append(UInt8(v >> 8)) }
        func u32(_ v: UInt32) { for i in 0..<4 { p.append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) } }
        func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
        func u64(_ v: UInt64) { for i in 0..<8 { p.append(UInt8((v >> (8 * UInt64(i))) & 0xFF)) } }

        u64(mach_absolute_time()); u64(0); u32(0); u32(0); u32(includeVelocity ? 2 : 1)
        u32(40); u32(23); u32(UInt32((phase.rawValue & 0xFF) << 24)); u8(0); u8(0); u8(0); u8(0)
        i32(fixed1616(0.1)); i32(0); i32(0)
        u32(0); u16(UInt16(motion.rawValue)); u16(3); i32(fixed1616(progress))
        if includeVelocity {
            u32(28); u32(9); u32(0); u8(1); u8(0); u8(0); u8(0)
            i32(fixed1616(velX)); i32(fixed1616(velY)); i32(0)
        }
        return p
    }

    private func withPayload(_ e: CGEvent, _ payload: [UInt8]) -> CGEvent? {
        guard let d = CGEventCreateData(nil, e) else { return nil }
        var bytes = [UInt8](d.takeRetainedValue() as Data)
        guard bytes.count >= 4, bytes[0] == 0, bytes[1] == 0, bytes[2] == 0, bytes[3] == 2 else { return nil }
        let n = payload.count
        bytes += [UInt8(n >> 8), UInt8(n & 0xFF), UInt8(4205 >> 8), UInt8(4205 & 0xFF)]
        bytes += payload
        return CGEvent(withDataAllocator: nil, data: Data(bytes) as CFData)
    }

    /// delta: progress increment (1.0 ≈ one space / a full Mission Control pull).
    func dockSwipe(delta d: Double, motion: SwipeMotion, phase: Phase) {
        if phase == .began { swipeProgress = d }
        else if phase == .changed { if d == 0 { return }; swipeProgress += d }
        var vx = 0.0, vy = 0.0
        if phase == .ended || phase == .cancelled {
            let v = swipeLastDelta * 300
            if motion == .horizontal { vx = v } else { vy = v }
        }
        guard let e = CGEvent(source: nil) else { return }
        field(e, 55, Int64(30))                                 // DockControl
        field(e, 110, Int64(23))                                // kIOHIDEventTypeDockSwipe
        field(e, 132, phase.rawValue)
        field(e, 134, phase.rawValue)
        field(e, 124, swipeProgress)
        field(e, 123, motion.rawValue)
        field(e, 138, 3.0)
        field(e, 169, Double(mach_absolute_time()))
        field(e, 125, 0.1)
        if vx != 0 || vy != 0 { field(e, 129, vx); field(e, 130, vy) }
        let payload = iohidPayload(phase: phase, motion: motion, progress: swipeProgress, velX: vx, velY: vy)
        guard let event = withPayload(e, payload), let companion = CGEvent(source: nil) else { return }
        field(companion, 55, Int64(29))
        event.post(tap: .cgSessionEventTap)
        companion.post(tap: .cgSessionEventTap)
        swipeLastDelta = d
    }
}

@_silgen_name("CGEventCreateData")
private func CGEventCreateData(_ allocator: CFAllocator?, _ event: CGEvent) -> Unmanaged<CFData>?
