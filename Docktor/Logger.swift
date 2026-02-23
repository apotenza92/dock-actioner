import Foundation

/// Lightweight logger that writes to unified logging (NSLog) and a per-run log file
/// under ~/Code/Docktor/logs/Docktor-<timestamp>.log so you can find it alongside the project.
enum Logger {
    private static let debugEnabled: Bool = {
        let v = ProcessInfo.processInfo.environment["DOCKTOR_DEBUG_LOG"]?.lowercased()
        return v == "1" || v == "true" || v == "yes"
    }()

    private static let queue = DispatchQueue(label: "com.dockappexpose.logger")
    private static let logDirectory: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Code/Docktor/logs")
    }()

    private static let logURL: URL = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        return logDirectory.appendingPathComponent("Docktor-\(stamp).log")
    }()

    static func log(_ message: String) {
        let line = "Docktor: \(message)"
        NSLog("%@", line)
        queue.async {
            writeLine(line)
        }
    }

    static func debug(_ message: String) {
        guard debugEnabled else { return }
        log(message)
    }

    private static func writeLine(_ line: String) {
        do {
            let fm = FileManager.default
            if !fm.fileExists(atPath: logDirectory.path) {
                try fm.createDirectory(at: logDirectory, withIntermediateDirectories: true)
            }
            let data = (line + "\n").data(using: .utf8) ?? Data()
            if fm.fileExists(atPath: logURL.path), let handle = try? FileHandle(forWritingTo: logURL) {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } else {
                try data.write(to: logURL, options: .atomic)
            }
        } catch {
            // Ignore file logging failures; keep the app running.
        }
    }
}
