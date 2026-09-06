import Foundation

/// Apple's parametric pointer acceleration, as implemented by IOHIDFamily
/// (IOHIDParametricAcceleration) with the curve set the Magic Trackpad driver ships.
///
/// Input is the finger speed in inches per second; the curve gives the pointer speed in
/// "cursor units" that IOHIDFamily scales by 96/67 per 67 Hz frame, i.e. output pixels per
/// second = f(v) × 96.
struct PointerAcceleration {
    struct Curve {
        var index: Double          // value of the "tracking speed" setting this curve belongs to
        var gainLinear: Double
        var gainParabolic: Double
        var gainCubic: Double
        var tangentLinear: Double  // in/s: end of the polynomial segment
        var tangentRoot: Double    // in/s: end of the linear tangent, start of the square-root tail
    }

    /// Magic Trackpad curves (AppleBluetoothMultitouch.kext, BNBTrackpadDriver, HIDAccelCurves).
    static let magicTrackpad: [Curve] = [
        Curve(index: 0.0,    gainLinear: 1.00, gainParabolic: 0.00, gainCubic: 0.00, tangentLinear: 7.4, tangentRoot: 40),
        Curve(index: 0.125,  gainLinear: 1.08, gainParabolic: 0.50, gainCubic: 0.08, tangentLinear: 7.4, tangentRoot: 30),
        Curve(index: 0.5,    gainLinear: 1.16, gainParabolic: 0.66, gainCubic: 0.10, tangentLinear: 7.4, tangentRoot: 24),
        Curve(index: 0.6875, gainLinear: 1.24, gainParabolic: 0.83, gainCubic: 0.12, tangentLinear: 7.5, tangentRoot: 19),
        Curve(index: 0.875,  gainLinear: 1.32, gainParabolic: 1.00, gainCubic: 0.15, tangentLinear: 7.6, tangentRoot: 18),
        Curve(index: 1.0,    gainLinear: 1.40, gainParabolic: 1.15, gainCubic: 0.18, tangentLinear: 7.8, tangentRoot: 17),
        Curve(index: 1.5,    gainLinear: 1.48, gainParabolic: 1.30, gainCubic: 0.22, tangentLinear: 8.0, tangentRoot: 16),
        Curve(index: 2.0,    gainLinear: 1.56, gainParabolic: 1.45, gainCubic: 0.27, tangentLinear: 8.3, tangentRoot: 15),
        Curve(index: 2.5,    gainLinear: 1.63, gainParabolic: 1.66, gainCubic: 0.33, tangentLinear: 8.7, tangentRoot: 14),
        Curve(index: 3.0,    gainLinear: 1.70, gainParabolic: 1.88, gainCubic: 0.40, tangentLinear: 9.0, tangentRoot: 13),
    ]

    private static let cursorScale = 96.0 / 67.0
    private static let frameRate = 67.0
    /// Measured against the built-in trackpad (devtools captures/internal2.csv): the theoretical
    /// f(v)×96 overshoots the real pointer speed by a constant ≈2.05 across 16…230 mm/s.
    private static let calibration = 0.49

    private let c: Curve
    private let m0: Double, b0: Double     // tangent line after tangentLinear
    private let m1: Double, b1: Double     // sqrt tail after tangentRoot

    /// - Parameter trackingSpeed: the System-Settings-style value 0…3 (interpolated between curves).
    init(trackingSpeed: Double, curves: [Curve] = PointerAcceleration.magicTrackpad) {
        let s = min(max(trackingSpeed, curves.first!.index), curves.last!.index)
        var lo = curves[0], hi = curves[0]
        for i in 0..<curves.count where curves[i].index <= s {
            lo = curves[i]; hi = i + 1 < curves.count ? curves[i + 1] : curves[i]
        }
        let t = hi.index > lo.index ? (s - lo.index) / (hi.index - lo.index) : 0
        func mix(_ a: Double, _ b: Double) -> Double { a + t * (b - a) }
        c = Curve(index: s,
                  gainLinear: mix(lo.gainLinear, hi.gainLinear),
                  gainParabolic: mix(lo.gainParabolic, hi.gainParabolic),
                  gainCubic: mix(lo.gainCubic, hi.gainCubic),
                  tangentLinear: mix(lo.tangentLinear, hi.tangentLinear),
                  tangentRoot: mix(lo.tangentRoot, hi.tangentRoot))

        // Tangent line to the polynomial at tangentLinear.
        let x0 = c.tangentLinear
        let y0 = c.gainLinear * x0 + pow(c.gainParabolic * x0, 2) + pow(c.gainCubic * x0, 3)
        m0 = c.gainLinear + 2 * x0 * pow(c.gainParabolic, 2) + 3 * x0 * x0 * pow(c.gainCubic, 3)
        b0 = y0 - m0 * x0
        // Square-root tail tangent to the line at tangentRoot.
        let x1 = c.tangentRoot
        let y1 = m0 * x1 + b0
        m1 = 2 * y1 * m0
        b1 = y1 * y1 - m1 * x1
    }

    /// Curve value for an input speed in inches per second (the "multiplier" before cursor scaling).
    func curve(inchesPerSecond v: Double) -> Double {
        if v <= c.tangentLinear {
            return c.gainLinear * v + pow(c.gainParabolic * v, 2) + pow(c.gainCubic * v, 3)
        } else if v <= c.tangentRoot {
            return m0 * v + b0
        } else {
            return sqrt(max(0, m1 * v + b1))
        }
    }

    /// Pointer speed in points per second for a finger speed in millimetres per second.
    func pointerSpeed(mmPerSecond: Double) -> Double {
        curve(inchesPerSecond: mmPerSecond / 25.4) * Self.cursorScale * Self.frameRate * Self.calibration
    }

    /// Gain in points per millimetre at a given finger speed.
    func gain(mmPerSecond v: Double) -> Double {
        v > 0.01 ? pointerSpeed(mmPerSecond: v) / v
                 : c.gainLinear * Self.cursorScale * Self.frameRate * Self.calibration / 25.4
    }
}
