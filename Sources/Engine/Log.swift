import Foundation

/// Appends timestamped lines to ~/Library/Logs/ABTrackPTPad.log (and stdout when run from a terminal).
enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/ABTrackPTPad.log")
    private static let handle: FileHandle? = {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        let h = try? FileHandle(forWritingTo: url)
        h?.seekToEndOfFile()
        return h
    }()
    private static let formatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f
    }()

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        print(line, terminator: "")
        handle?.write(line.data(using: .utf8)!)
    }
}
