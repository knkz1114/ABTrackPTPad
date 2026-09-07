// Minimal test runner (no XCTest): compiled together with Sources/Engine by Tests/run.sh.
import Foundation
import CoreGraphics

@MainActor
final class RecordingSink: EventSink {
    enum Call: Equatable {
        case move(dx: Double, dy: Double)
        case button(CGMouseButton, Bool)
        case scroll(dx: Double, dy: Double, phase: Phase, momentum: MomentumPhase)
        case magnify(Double, Phase)
        case rotate(Double, Phase)
        case smartZoom
        case dockSwipe(Double, SwipeMotion, Phase)
    }
    var calls: [Call] = []
    private(set) var leftDown = false
    private(set) var rightDown = false
    func moveCursor(dx: Double, dy: Double) { calls.append(.move(dx: dx, dy: dy)) }
    func button(_ b: CGMouseButton, down: Bool) {
        if b == .left { leftDown = down } else if b == .right { rightDown = down }
        calls.append(.button(b, down))
    }
    func scroll(dx: Double, dy: Double, phase: Phase, momentum: MomentumPhase, natural: Bool) { calls.append(.scroll(dx: dx, dy: dy, phase: phase, momentum: momentum)) }
    func magnify(_ d: Double, phase: Phase) { calls.append(.magnify(d, phase)) }
    func rotate(_ d: Double, phase: Phase) { calls.append(.rotate(d, phase)) }
    func smartZoom() { calls.append(.smartZoom) }
    func dockSwipe(delta: Double, motion: SwipeMotion, phase: Phase) { calls.append(.dockSwipe(delta, motion, phase)) }
}

/// Builds a 20-byte PTP report payload (report ID stripped) for the given contacts.
func makeReport(_ contacts: [(id: Int, x: Int, y: Int)], button: Bool = false) -> [UInt8] {
    var d = [UInt8](repeating: 0, count: 20)
    for (i, c) in contacts.prefix(4).enumerated() {
        d[4 * i] = UInt8(0x03 | (c.id << 2))                    // confidence + tip + id
        d[4 * i + 1] = UInt8(c.x & 0xFF)
        d[4 * i + 2] = UInt8((c.x >> 8) & 0x0F) | UInt8((c.y & 0x0F) << 4)
        d[4 * i + 3] = UInt8(c.y >> 4)
    }
    d[18] = UInt8(contacts.count)
    d[19] = button ? 1 : 0
    return d
}

@MainActor
func freshEngine() -> (GestureEngine, RecordingSink) {
    let defaults = UserDefaults(suiteName: "io.github.knkz1114.abtrackptpad.tests")!
    defaults.removePersistentDomain(forName: "io.github.knkz1114.abtrackptpad.tests")
    let sink = RecordingSink()
    return (GestureEngine(settings: Settings(defaults: defaults), sink: sink), sink)
}

var failures = 0
func check(_ cond: Bool, _ name: String) {
    print((cond ? "PASS " : "FAIL ") + name)
    if !cond { failures += 1 }
}

@MainActor
func gb() -> Double { CFAbsoluteTimeGetCurrent() }

@MainActor
func runTests() {
    // 1. one finger moving right → cursor moves right
    do {
        let (e, s) = freshEngine()
        var t = 0.0
        for x in stride(from: 500, through: 600, by: 5) { e.handleReport(makeReport([(0, x, 700)]), time: t); t += 0.008 }
        let moves = s.calls.compactMap { if case .move(let dx, _) = $0 { return dx } else { return nil } }
        check(moves.count >= 10 && moves.allSatisfy { $0 > 0 }, "one finger moves cursor right (\(moves.count) moves)")
    }
    // 2. quick touch and release without movement → left click
    do {
        let (e, s) = freshEngine()
        e.handleReport(makeReport([(0, 500, 700)]), time: 0)
        e.handleReport(makeReport([(0, 502, 701)]), time: 0.05)
        e.handleReport(makeReport([]), time: 0.1)
        let buttons = s.calls.filter { if case .button = $0 { return true } else { return false } }
        check(buttons == [.button(.left, true), .button(.left, false)], "tap → left click")
    }
    // 3. two fingers moving down → scroll began, natural direction (positive dy)
    do {
        let (e, s) = freshEngine()
        var t = 0.0
        for y in stride(from: 600, through: 700, by: 5) { e.handleReport(makeReport([(0, 500, y), (1, 700, y)]), time: t); t += 0.008 }
        let began = s.calls.first { if case .scroll(_, _, .began, _) = $0 { return true } else { return false } }
        var dy = 0.0
        if case .scroll(_, let d, _, _)? = began { dy = d }
        check(began != nil && dy > 0, "two fingers → scroll began with natural dy > 0 (\(dy))")
        check(s.calls.first == .scroll(dx: 0, dy: 0, phase: .mayBegin, momentum: .none), "two fingers → mayBegin first")
    }
    // 4. two fingers spreading → pinch
    do {
        let (e, s) = freshEngine()
        var t = 0.0
        for i in 0..<20 { e.handleReport(makeReport([(0, 600 - i * 4, 700), (1, 800 + i * 4, 700)]), time: t); t += 0.008 }
        let mag = s.calls.contains { if case .magnify(_, .began) = $0 { return true } else { return false } }
        check(mag, "two fingers spreading → magnify began")
    }
    // 5. three fingers moving up → vertical dock swipe with positive progress
    do {
        let (e, s) = freshEngine()
        var t = 0.0
        for i in 0..<20 { e.handleReport(makeReport([(0, 500, 800 - i * 5), (1, 700, 800 - i * 5), (2, 900, 800 - i * 5)]), time: t); t += 0.008 }
        e.handleReport(makeReport([]), time: t)
        var began: Double? = nil
        for c in s.calls { if case .dockSwipe(let d, .vertical, .began) = c { began = d } }
        let ended = s.calls.contains { if case .dockSwipe(_, .vertical, .ended) = $0 { return true } else { return false } }
        check((began ?? -1) > 0 && ended, "three fingers up → vertical swipe began (\(began ?? -1)) and ended")
    }
    // 6. unused slots must not delete contact 0 (regression)
    do {
        let (e, s) = freshEngine()
        var t = 0.0
        for x in stride(from: 500, through: 560, by: 5) { e.handleReport(makeReport([(0, x, 700)]), time: t); t += 0.008 }
        check(s.calls.contains { if case .move = $0 { return true } else { return false } }, "contact id 0 survives empty slots")
    }
    // 7a. two fingers rotating → rotate began
    do {
        let (e, s) = freshEngine()
        var t = gb()
        for i in 0..<25 {
            let a = Double(i) * 0.03
            let cx = 700.0, cy = 700.0, r = 300.0
            let x0 = Int(cx + r * cos(a)), y0 = Int(cy + r * sin(a))
            let x1 = Int(cx - r * cos(a)), y1 = Int(cy - r * sin(a))
            e.handleReport(makeReport([(0, x0, y0), (1, x1, y1)]), time: t); t += 0.008
        }
        let rot = s.calls.contains { if case .rotate(_, .began) = $0 { return true } else { return false } }
        check(rot, "two fingers rotating → rotate began")
    }
    // 7b. two two-finger taps → smart zoom
    do {
        let (e, s) = freshEngine()
        var t = gb()
        e.handleReport(makeReport([(0, 600, 700), (1, 800, 700)]), time: t)
        e.handleReport(makeReport([]), time: t + 0.08)
        t += 0.2
        e.handleReport(makeReport([(0, 600, 700), (1, 800, 700)]), time: t)
        e.handleReport(makeReport([]), time: t + 0.08)
        let zoom = s.calls.contains { if case .smartZoom = $0 { return true } else { return false } }
        check(zoom, "two-finger double tap → smart zoom")
    }
    // 7. tap-to-click disabled → no click
    do {
        let (e, s) = freshEngine()
        // settings from fresh defaults: tapToClick on. Toggle off via a second Settings instance sharing the suite.
        let defaults = UserDefaults(suiteName: "io.github.knkz1114.abtrackptpad.tests")!
        let settings = Settings(defaults: defaults); settings.tapToClick = false
        let sink = RecordingSink()
        let e2 = GestureEngine(settings: settings, sink: sink)
        e2.handleReport(makeReport([(0, 500, 700)]), time: 0)
        e2.handleReport(makeReport([]), time: 0.1)
        check(sink.calls.isEmpty, "tapToClick off → no click")
        _ = e; _ = s
    }
}

@main
struct TestMain {
    static func main() {
        MainActor.assumeIsolated { runTests() }
        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
