import Foundation

/// Keeps the last few seconds of raw HID reports so users can attach them to bug reports.
/// Recording is off unless `enabled` is set (Settings.recordDiagnostics).
@MainActor
final class Diagnostics {
    private struct Entry { let time: Date; let id: UInt32; let bytes: [UInt8] }
    private var entries: [Entry] = []
    private let window: TimeInterval = 10
    var enabled = false { didSet { if !enabled { entries.removeAll() } } }

    func record(id: UInt32, bytes: [UInt8]) {
        guard enabled else { return }
        let now = Date()
        entries.append(Entry(time: now, id: id, bytes: bytes))
        if let first = entries.first, now.timeIntervalSince(first.time) > window * 2 {
            entries.removeAll { now.timeIntervalSince($0.time) > window }
        }
    }

    /// Writes the buffered reports to ~/Downloads and returns the file URL.
    func save() throws -> URL {
        let now = Date()
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let url = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ABTrackPTPad-diag-\(f.string(from: now)).log")
        var text = "ABTrackPTPad diagnostics \(now)\nmacOS \(ProcessInfo.processInfo.operatingSystemVersionString)\n\n"
        for e in entries where now.timeIntervalSince(e.time) <= window {
            text += String(format: "%.3f rid=%d ", e.time.timeIntervalSince1970, e.id)
            text += e.bytes.map { String(format: "%02x", $0) }.joined(separator: " ") + "\n"
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
