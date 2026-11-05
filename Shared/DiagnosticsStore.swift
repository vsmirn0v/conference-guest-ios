import Foundation
import MetricKit

// MARK: - Saved diagnostics (all builds)

/// Diagnostic events kept across launches: rotating timestamped JSON-lines files,
/// bounded by size, count and age. All file work runs on one serial queue.
final class NativeDiagnosticsLog: @unchecked Sendable {
    static let shared = NativeDiagnosticsLog(directory: rootDirectory)
    static var rootDirectory: URL {
        (FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("Logs/Diagnostics", isDirectory: true)
    }
    let directory: URL
    let maxFileBytes: Int, maxFiles: Int, maxAge: TimeInterval
    private let queue = DispatchQueue(label: "rocknroll.diagnostics-log")
    private var handle: FileHandle?
    private var current: URL?
    private var written = 0, sequence = 0
    private let lineStamp: ISO8601DateFormatter = {
        let value = ISO8601DateFormatter(); value.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return value
    }()
    private let nameStamp: DateFormatter = {
        let value = DateFormatter(); value.locale = Locale(identifier: "en_US_POSIX")
        value.timeZone = TimeZone(identifier: "UTC"); value.dateFormat = "yyyyMMdd-HHmmss-SSS"; return value
    }()

    init(directory: URL, maxFileBytes: Int = 2_000_000, maxFiles: Int = 5, maxAge: TimeInterval = 7 * 86_400) {
        self.directory = directory; self.maxFileBytes = maxFileBytes; self.maxFiles = maxFiles; self.maxAge = maxAge
    }
    /// Starts this launch's file and removes files beyond the count or age limit.
    func start(now: Date = Date()) { queue.sync { open(now: now); prune(now: now) } }
    func append(_ line: String, at date: Date = Date()) {
        queue.async { [self] in
            guard handle != nil else { return }
            let data = Data((lineStamp.string(from: date) + " " + line + "\n").utf8)
            if written > 0, written + data.count > maxFileBytes { open(now: date); prune(now: date) }
            do { try handle?.write(contentsOf: data); written += data.count } catch { close() }
        }
    }
    func flush() { queue.sync { try? handle?.synchronize() } }
    func stop() { queue.sync { close() } }
    /// Oldest first.
    var files: [URL] { queue.sync { logFiles() } }

    private func logFiles() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasPrefix("events-") && $0.hasSuffix(".log") }.sorted()
            .map { directory.appendingPathComponent($0) }
    }
    private func close() { try? handle?.close(); handle = nil; current = nil; written = 0 }
    private func open(now: Date) {
        close()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        sequence += 1
        let url = directory.appendingPathComponent("events-\(nameStamp.string(from: now))-\(getpid())-\(String(format: "%04d", sequence)).log")
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let value = try? FileHandle(forWritingTo: url) else { return }
        handle = value; current = url
    }
    private func prune(now: Date) {
        let files = logFiles()
        for (index, url) in files.enumerated() where url != current {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
            if index < files.count - maxFiles || now.timeIntervalSince(modified) > maxAge {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}

/// Crash and hang reports that MetricKit delivers on a later launch, saved beside the logs.
final class NativeDiagnosticReports: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = NativeDiagnosticReports(directory: NativeDiagnosticsLog.rootDirectory.appendingPathComponent("Reports", isDirectory: true))
    let directory: URL
    let maxFiles = 10, maxAge: TimeInterval = 30 * 86_400
    /// Called with the number of reports saved, to record it in the event log.
    var onSaved: ((Int) -> Void)?
    init(directory: URL) { self.directory = directory }
    func start() { MXMetricManager.shared.add(self) }
    /// Oldest first.
    var files: [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.sorted().map { directory.appendingPathComponent($0) }
    }
    func didReceive(_ payloads: [MXDiagnosticPayload]) { save(payloads.map { $0.jsonRepresentation() }) }
    func save(_ reports: [Data], now: Date = Date()) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = Int(now.timeIntervalSince1970)
        for (index, data) in reports.enumerated() {
            try? data.write(to: directory.appendingPathComponent("report-\(stamp)-\(index).json"), options: .atomic)
        }
        let saved = files
        for (index, url) in saved.enumerated() {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
            if index < saved.count - maxFiles || now.timeIntervalSince(modified) > maxAge { try? FileManager.default.removeItem(at: url) }
        }
        onSaved?(reports.count)
    }
}

/// A zip the person saves and sends: the Copy Diagnostics report, saved event logs
/// and crash/hang reports. The system builds the archive; nothing is uploaded.
enum NativeDiagnosticsArchive {
    static func make(report: String, logs: [URL], reports: [URL], destination: URL) throws {
        let manager = FileManager.default
        let staging = manager.temporaryDirectory.appendingPathComponent("diagnostics-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: staging) }
        let folder = staging.appendingPathComponent("RockNRoll Diagnostics", isDirectory: true)
        for (name, sources) in [("Logs", logs), ("Reports", reports)] {
            let target = folder.appendingPathComponent(name, isDirectory: true)
            try manager.createDirectory(at: target, withIntermediateDirectories: true)
            for url in sources { try manager.copyItem(at: url, to: target.appendingPathComponent(url.lastPathComponent)) }
        }
        try Data(report.utf8).write(to: folder.appendingPathComponent("report.txt"))
        var coordination: NSError?, failure: Error?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordination) { zip in
            do {
                if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
                try manager.copyItem(at: zip, to: destination)
            } catch { failure = error }
        }
        if let error = coordination ?? failure { throw error }
    }
}
