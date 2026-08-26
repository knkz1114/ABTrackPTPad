import Foundation
import IOKit.hid
import CoreGraphics
import ApplicationServices

enum DeviceState: Equatable {
    case noPermission          // HID manager could not be opened
    case disconnected
    case connected(ptp: Bool)  // ptp == true once digitizer reports arrive
}

/// Owns the IOHIDManager: seizes the pad, switches it into PTP mode and feeds reports to the engine.
@MainActor
final class HIDDevice {
    static let vendorID = 0x248A
    static let productID = 0x8208

    private let engine: GestureEngine
    private let diagnostics: Diagnostics
    private let onState: (DeviceState) -> Void
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var reportBuf = [UInt8](repeating: 0, count: 256)
    private var retryTimer: Timer?
    private var ptpRetryTimer: Timer?
    private var ptpAttempts = 0
    private var mousePassthrough = MousePassthrough()

    private(set) var state: DeviceState = .disconnected { didSet { if state != oldValue { onState(state) } } }
    private(set) var lastReport: Date?
    private(set) var reportCount = 0
    /// Human-readable reason the HID manager could not be opened, if any.
    private(set) var openError: String?
    private var sawDigitizer = false
    private var seenReportIDs = Set<UInt32>()

    init(engine: GestureEngine, diagnostics: Diagnostics, onState: @escaping (DeviceState) -> Void) {
        self.engine = engine
        self.diagnostics = diagnostics
        self.onState = onState
    }

    func start() {
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(m, [kIOHIDVendorIDKey: Self.vendorID, kIOHIDProductIDKey: Self.productID] as CFDictionary)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(m, { ctx, _, _, dev in
            MainActor.assumeIsolated { Unmanaged<HIDDevice>.fromOpaque(ctx!).takeUnretainedValue().attached(dev) }
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(m, { ctx, _, _, _ in
            MainActor.assumeIsolated { Unmanaged<HIDDevice>.fromOpaque(ctx!).takeUnretainedValue().detached() }
        }, ctx)
        // commonModes: keep receiving reports while a menu is open (menu tracking runs a nested run loop mode).
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let r = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        Log.write("IOHIDManagerOpen(seize) = 0x\(String(UInt32(bitPattern: r), radix: 16)) accessibility=\(AXIsProcessTrusted()) inputMonitoring=\(IOHIDCheckAccess(kIOHIDRequestTypeListenEvent).rawValue)")
        if r == kIOReturnSuccess {
            manager = m
            openError = nil
            retryTimer?.invalidate(); retryTimer = nil
            if state == .noPermission { state = .disconnected }
        } else {
            // Typically kIOReturnNotPermitted: Input Monitoring / Accessibility not granted yet. Retry until it is.
            IOHIDManagerUnscheduleFromRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            openError = String(format: "IOHIDManagerOpen failed: 0x%08x%@", UInt32(bitPattern: r),
                               r == kIOReturnNotPermitted ? " (not permitted)" : (r == kIOReturnExclusiveAccess ? " (device in use by another process)" : ""))
            state = .noPermission
            if retryTimer == nil {
                let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.start() }
                }
                RunLoop.main.add(t, forMode: .common)
                retryTimer = t
            }
        }
    }

    private func attached(_ dev: IOHIDDevice) {
        Log.write("device attached: \(IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String ?? "?")")
        device = dev
        sawDigitizer = false
        seenReportIDs = []
        enablePTPMode(dev)
        schedulePTPCheck()
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        reportBuf.withUnsafeMutableBufferPointer { p in
            IOHIDDeviceRegisterInputReportCallback(dev, p.baseAddress!, p.count, { ctx, _, _, _, id, report, len in
                let bytes = Array(UnsafeBufferPointer(start: report, count: len))
                MainActor.assumeIsolated { Unmanaged<HIDDevice>.fromOpaque(ctx!).takeUnretainedValue().input(id: id, bytes: bytes) }
            }, ctx)
        }
        state = .connected(ptp: false)
    }

    private func detached() {
        Log.write("device detached")
        ptpRetryTimer?.invalidate(); ptpRetryTimer = nil
        device = nil
        state = .disconnected
    }

    /// Switch the pad from mouse emulation to Precision Touchpad reporting.
    ///
    /// The descriptor has no Input Mode (usage 0x52) feature; this firmware uses feature report 3
    /// for it instead. Writing 3 (Windows Precision Touchpad mode) stops mouse report 1 and starts
    /// digitizer report 2. The mode resets when the pad reconnects, so this runs on every attach.
    private func enablePTPMode(_ dev: IOHIDDevice) {
        // The firmware acts on the *change* of the value: after re-pairing the register already
        // reads 3 while the pad is still in mouse mode, so write 0 first, then 3.
        // Windows reads the THQA certification blob (feature 4) during enumeration; on a fresh
        // pairing the pad seems to require this before it honours the mode switch.
        var thqa = [UInt8](repeating: 0, count: 257); thqa[0] = 4; var thqaLen: CFIndex = 257
        let r4 = IOHIDDeviceGetReport(dev, kIOHIDReportTypeFeature, 4, &thqa, &thqaLen)
        Log.write("read feature 4 (THQA): 0x\(String(UInt32(bitPattern: r4), radix: 16)) len=\(thqaLen)")
        var off: [UInt8] = [0x03, 0x00]
        let r0 = IOHIDDeviceSetReport(dev, kIOHIDReportTypeFeature, 3, &off, off.count)
        var mode: [UInt8] = [0x03, 0x03]
        let r = IOHIDDeviceSetReport(dev, kIOHIDReportTypeFeature, 3, &mode, mode.count)
        Log.write("set feature 3 = 0 then 3 (PTP mode): 0x\(String(UInt32(bitPattern: r0), radix: 16)) / 0x\(String(UInt32(bitPattern: r), radix: 16))")
    }

    private func readFeature3(_ dev: IOHIDDevice) -> UInt8? {
        var f: [UInt8] = [3, 0]; var len: CFIndex = 2
        let r = IOHIDDeviceGetReport(dev, kIOHIDReportTypeFeature, 3, &f, &len)
        return r == kIOReturnSuccess && len >= 2 ? f[1] : nil
    }

    /// Right after (re)pairing the first write is sometimes accepted but not applied and the pad keeps
    /// sending mouse reports. Verify by reading feature 3 back and by waiting for digitizer reports;
    /// rewrite a few times if needed.
    private func schedulePTPCheck() {
        ptpRetryTimer?.invalidate()
        ptpAttempts = 0
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, let dev = self.device, !self.sawDigitizer, self.ptpAttempts < 10 else { timer.invalidate(); return }
                self.ptpAttempts += 1
                let v = self.readFeature3(dev)
                Log.write("PTP check \(self.ptpAttempts): feature 3 = \(v.map { "0x" + String($0, radix: 16) } ?? "read failed"), no digitizer reports yet — rewriting")
                self.enablePTPMode(dev)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        ptpRetryTimer = t
    }

    private func input(id: UInt32, bytes: [UInt8]) {
        let t = CFAbsoluteTimeGetCurrent()
        lastReport = Date()
        reportCount += 1
        diagnostics.record(id: id, bytes: bytes)
        if seenReportIDs.insert(id).inserted { Log.write("first report id=\(id) (\(bytes.count) bytes)") }
        switch id {
        case 2:
            if !sawDigitizer { sawDigitizer = true; state = .connected(ptp: true); Log.write("digitizer reports active (\(bytes.count) bytes)") }
            engine.handleReport(Array(bytes.dropFirst()), time: t)
        case 1:
            // Only used if the pad never entered PTP mode, so the seized device still works as a mouse.
            if !sawDigitizer { mousePassthrough.handle(Array(bytes.dropFirst())) }
        default:
            break
        }
    }
}

/// Relays plain mouse reports (report 1) as mouse events.
@MainActor
struct MousePassthrough {
    private var buttons: UInt8 = 0
    private let sink = CGEventSink()

    mutating func handle(_ d: [UInt8]) {
        guard d.count >= 4 else { return }
        let b = d[0], dx = Double(Int8(bitPattern: d[1])), dy = Double(Int8(bitPattern: d[2])), wheel = Int32(Int8(bitPattern: d[3]))
        let changed = b ^ buttons
        for (bit, btn) in [(UInt8(1), CGMouseButton.left), (2, .right), (4, .center)] where changed & bit != 0 {
            sink.button(btn, down: b & bit != 0)
        }
        buttons = b
        if dx != 0 || dy != 0 { sink.moveCursor(dx: dx, dy: dy) }
        if wheel != 0, let e = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: wheel, wheel2: 0, wheel3: 0) {
            e.post(tap: .cghidEventTap)
        }
    }
}
