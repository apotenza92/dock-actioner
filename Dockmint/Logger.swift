import Foundation
import os

final class PersistentLogWriter {
    let url: URL
    private var handle: FileHandle?

    init(url: URL) throws {
        self.url = url
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        self.handle = handle
    }

    func append(line: String) throws {
        guard let handle else { throw CocoaError(.fileNoSuchFile) }
        guard let data = (line + "\n").data(using: .utf8) else { return }
        try handle.write(contentsOf: data)
    }

    func close() throws {
        guard let handle else { return }
        try handle.close()
        self.handle = nil
    }

    deinit {
        try? handle?.close()
    }
}

/// Lightweight logger that writes operational events to unified logging, and only writes
/// diagnostic/debug output when the user opts in or a local debug override is enabled.
/// Persistent logs are separated by app identity so development and release runs do not share folders.
enum Logger {
    private static let persistentFileLoggingPreferenceKey = "persistentDiagnosticFileLoggingEnabled"
    private static let maxRetainedLogFiles = 5
    private static let maxRetainedLogAge: TimeInterval = 7 * 24 * 60 * 60

    private static let debugOverrideEnabled: Bool = {
        let environment = ProcessInfo.processInfo.environment
        let value = environment["DOCKMINT_DEBUG_LOG"] ?? environment["DOCKTOR_DEBUG_LOG"] ?? ""
        switch value.lowercased() {
        case "1", "true", "yes":
            return true
        default:
            return false
        }
    }()

    private static let oslog = os.Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "pzc.Dockter",
        category: "general"
    )

    private static let queue = DispatchQueue(label: "com.dockappexpose.logger")
    private static var preparedForLaunch = false
    private static var runLogURL: URL?
    private static var persistentWriter: PersistentLogWriter?

    static func prepareForLaunch() {
        queue.sync {
            performStartupMaintenanceIfNeeded()
        }
    }

    static func log(_ message: String) {
        let line = "Dockmint: \(message)"
        oslog.log("\(line, privacy: .public)")
        NSLog("%@", line)
        queue.async {
            performStartupMaintenanceIfNeeded()
            guard shouldWritePersistentFileLogs else { return }
            writeLine(line)
        }
    }

    static func debug(_ message: @autoclosure () -> String) {
        guard shouldWritePersistentFileLogs else { return }
        let line = "Dockmint: \(message())"
        oslog.debug("\(line, privacy: .public)")
        queue.async {
            if let data = (line + "\n").data(using: .utf8) {
                try? FileHandle.standardError.write(contentsOf: data)
            }
            performStartupMaintenanceIfNeeded()
            guard shouldWritePersistentFileLogs else { return }
            writeLine(line)
        }
    }

    private static var shouldWritePersistentFileLogs: Bool {
        debugOverrideEnabled || UserDefaults.standard.bool(forKey: persistentFileLoggingPreferenceKey)
    }

    private static var logDirectory: URL {
        AppIdentity.persistentLogDirectory
    }

    private static func performStartupMaintenanceIfNeeded() {
        guard !preparedForLaunch else { return }
        preparedForLaunch = true
        cleanupObsoleteLogDirectoriesIfNeeded()
        if shouldWritePersistentFileLogs {
            pruneLogFiles()
        } else {
            clearPersistentLogFiles()
        }
    }

    private static func writeLine(_ line: String) {
        do {
            let fm = FileManager.default
            if !fm.fileExists(atPath: logDirectory.path) {
                try fm.createDirectory(at: logDirectory, withIntermediateDirectories: true)
            }
            let targetURL = try ensureRunLogURL(fileManager: fm)
            if persistentWriter?.url != targetURL {
                try persistentWriter?.close()
                persistentWriter = try PersistentLogWriter(url: targetURL)
            }
            try persistentWriter?.append(line: line)
        } catch {
            // Ignore file logging failures; keep the app running.
        }
    }

    private static func ensureRunLogURL(fileManager: FileManager) throws -> URL {
        if let runLogURL {
            return runLogURL
        }
        if !fileManager.fileExists(atPath: logDirectory.path) {
            try fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let targetURL = logDirectory.appendingPathComponent("Dockmint-\(stamp).log")
        runLogURL = targetURL
        return targetURL
    }

    private static func pruneLogFiles() {
        let fileManager = FileManager.default
        guard let items = try? fileManager.contentsOfDirectory(
            at: logDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let now = Date()
        let logFiles = items.filter { $0.pathExtension.lowercased() == "log" }
        let sortedLogFiles = logFiles.sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey]).contentModificationDate)
                ?? (try? lhs.resourceValues(forKeys: [.creationDateKey]).creationDate)
                ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey]).contentModificationDate)
                ?? (try? rhs.resourceValues(forKeys: [.creationDateKey]).creationDate)
                ?? .distantPast
            return lhsDate > rhsDate
        }

        for fileURL in sortedLogFiles.dropFirst(maxRetainedLogFiles) {
            try? fileManager.removeItem(at: fileURL)
        }

        for fileURL in sortedLogFiles.prefix(maxRetainedLogFiles) {
            let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
            let date = values?.contentModificationDate ?? values?.creationDate ?? .distantPast
            if now.timeIntervalSince(date) > maxRetainedLogAge {
                try? fileManager.removeItem(at: fileURL)
            }
        }
    }

    private static func clearPersistentLogFiles() {
        let fileManager = FileManager.default
        try? persistentWriter?.close()
        persistentWriter = nil
        runLogURL = nil
        guard fileManager.fileExists(atPath: logDirectory.path) else { return }
        guard let items = try? fileManager.contentsOfDirectory(at: logDirectory, includingPropertiesForKeys: nil) else {
            return
        }
        for item in items where item.pathExtension.lowercased() == "log" {
            try? fileManager.removeItem(at: item)
        }
    }

    private static func cleanupObsoleteLogDirectoriesIfNeeded() {
        let fileManager = FileManager.default

        for obsoleteDirectory in AppIdentity.obsoletePersistentLogDirectories {
            guard fileManager.fileExists(atPath: obsoleteDirectory.path) else {
                continue
            }

            do {
                try fileManager.removeItem(at: obsoleteDirectory)
                pruneEmptyObsoleteLogParentDirectories(startingAt: obsoleteDirectory.deletingLastPathComponent(), fileManager: fileManager)
            } catch {
                // Ignore cleanup failures; the logger will continue using the current path.
            }
        }
    }

    private static func pruneEmptyObsoleteLogParentDirectories(startingAt directory: URL, fileManager: FileManager) {
        let homeDirectory = fileManager.homeDirectoryForCurrentUser.standardizedFileURL
        let stopDirectory = homeDirectory.appendingPathComponent("Code", isDirectory: true).standardizedFileURL
        var currentDirectory = directory.standardizedFileURL

        while currentDirectory.path.hasPrefix(stopDirectory.path) {
            let isStopDirectory = currentDirectory == stopDirectory

            do {
                let remainingItems = try fileManager.contentsOfDirectory(atPath: currentDirectory.path)
                guard remainingItems.isEmpty else { return }
                try fileManager.removeItem(at: currentDirectory)
            } catch {
                return
            }

            if isStopDirectory {
                return
            }

            currentDirectory.deleteLastPathComponent()
        }
    }
}
