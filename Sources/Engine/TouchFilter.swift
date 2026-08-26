import Foundation

/// One-euro filter (Casiez, Roussel, Vogel 2012): a low-pass whose cutoff rises with speed,
/// so slow movements are smoothed strongly (hiding the pad's 0.08 mm quantisation) while fast
/// movements pass through with little lag.
struct OneEuroFilter {
    var minCutoff: Double    // Hz
    var beta: Double         // cutoff increase per unit of speed
    var derivativeCutoff: Double = 1.0

    private var x: Double?
    private var dx = 0.0

    init(minCutoff: Double, beta: Double) {
        self.minCutoff = minCutoff
        self.beta = beta
    }

    private static func alpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1 / (2 * .pi * cutoff)
        return 1 / (1 + tau / dt)
    }

    mutating func filter(_ value: Double, dt: Double) -> Double {
        guard let prev = x else { x = value; return value }
        let rawDx = (value - prev) / dt
        dx += Self.alpha(cutoff: derivativeCutoff, dt: dt) * (rawDx - dx)
        let cutoff = minCutoff + beta * abs(dx)
        let filtered = prev + Self.alpha(cutoff: cutoff, dt: dt) * (value - prev)
        x = filtered
        return filtered
    }
}

/// A finger on the pad: raw and smoothed position in millimetres, and bookkeeping for classification.
struct Touch {
    let id: Int
    let start: TimeInterval
    let origin: (x: Double, y: Double)        // raw, mm
    var raw: (x: Double, y: Double)
    var smooth: (x: Double, y: Double)
    var previous: (x: Double, y: Double)      // smoothed position of the previous frame
    var travel = 0.0                          // accumulated smoothed distance, mm
    var lastMoved: TimeInterval
    var role: Role = .finger
    private var fx: OneEuroFilter
    private var fy: OneEuroFilter

    enum Role { case finger, edge, thumb, resting }

    init(id: Int, x: Double, y: Double, time: TimeInterval, minCutoff: Double, beta: Double) {
        self.id = id
        start = time
        origin = (x, y); raw = (x, y); smooth = (x, y); previous = (x, y)
        lastMoved = time
        fx = OneEuroFilter(minCutoff: minCutoff, beta: beta)
        fy = OneEuroFilter(minCutoff: minCutoff, beta: beta)
        _ = fx.filter(x, dt: 0.008); _ = fy.filter(y, dt: 0.008)
    }

    mutating func update(x: Double, y: Double, time: TimeInterval, dt: Double) {
        raw = (x, y)
        previous = smooth
        smooth = (fx.filter(x, dt: dt), fy.filter(y, dt: dt))
        let d = hypot(smooth.x - previous.x, smooth.y - previous.y)
        travel += d
        if d > 0.02 { lastMoved = time }
    }

    var delta: (x: Double, y: Double) { (smooth.x - previous.x, smooth.y - previous.y) }
    var rawTravelFromOrigin: Double { hypot(raw.x - origin.x, raw.y - origin.y) }
}
