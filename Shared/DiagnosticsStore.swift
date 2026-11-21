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
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        sequence += 1
        let url = directory.appendingPathComponent("events-\(nameStamp.string(from: now))-\(getpid())-\(String(format: "%04d", sequence)).log")
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]),
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
    private let lock = NSLock()
    /// Called with the number of reports saved, to record it in the event log.
    private var _onSaved: ((Int) -> Void)?
    var onSaved: ((Int) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onSaved }
        set { lock.lock(); defer { lock.unlock() }; _onSaved = newValue }
    }
    init(directory: URL) { self.directory = directory }
    func start() { MXMetricManager.shared.add(self) }
    /// Oldest first.
    var files: [URL] {
        lock.lock(); defer { lock.unlock() }
        return unlockedFiles()
    }
    private func unlockedFiles() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.sorted().map { directory.appendingPathComponent($0) }
    }
    func didReceive(_ payloads: [MXDiagnosticPayload]) { save(payloads.map { $0.jsonRepresentation() }) }
    func save(_ reports: [Data], now: Date = Date()) {
        let handler: ((Int) -> Void)?
        lock.lock()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stamp = Int(now.timeIntervalSince1970)
        for (index, data) in reports.enumerated() {
            let fileURL = directory.appendingPathComponent("report-\(stamp)-\(index).json")
            try? data.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
        let saved = unlockedFiles()
        for (index, url) in saved.enumerated() {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
            if index < saved.count - maxFiles || now.timeIntervalSince(modified) > maxAge { try? FileManager.default.removeItem(at: url) }
        }
        handler = _onSaved
        lock.unlock()
        handler?(reports.count)
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
        // Read the copies staged for this archive so the timeline and raw logs agree.
        let logCopies = logs.sorted { $0.lastPathComponent < $1.lastPathComponent }.map {
            folder.appendingPathComponent("Logs").appendingPathComponent($0.lastPathComponent)
        }
        let windows = logCopies.flatMap { url -> [Substring] in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").filter { $0.contains("\"event\":\"guest-audio-reception\"") }
        }
        if !windows.isEmpty {
            let guide = """
            Guest meeting audio reception (UTC). Each line ends one sample window. The attempt ID changes on reconnect.
            packetsLostIncrease counts new RTP loss. concealedSamples counts audio samples supplied by the decoder to cover missing audio.
            speakingStreamsWithoutPackets counts streams marked speaking at both observations that delivered zero packets. Quiet senders can pause RTP.
            streamDetails lists up to eight affected receivers. Compare the stream numbers within one attempt to spot repeated gaps on the same receiver.
            decodedNonSilentCallbacks measures incoming audio with nonzero energy. outputNonSilentCallbacks measures the shared device output mix.
            callback-stale means the output tap is overdue. callback-gap records a pause that ended between observations.
            Compare timestamps with audio-device-route, audio-engine-lifecycle and session-recovery in Logs/. Missing counters were unavailable.

            """
            try (guide + windows.joined(separator: "\n") + "\n").write(
                to: folder.appendingPathComponent("audio-reception.log"), atomically: true, encoding: .utf8)
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
