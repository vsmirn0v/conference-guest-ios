import Combine
import ConferenceCore
import Foundation

/// Kept in memory for the current room. A new SDK state can replay its message
/// snapshot after reconnect; unavailable history is never described as recovered.
final class CatchUpStore: ObservableObject {
    @Published private(set) var timeline = CatchUpTimeline()
    @Published private(set) var canViewTranscript: Bool?
    @Published private(set) var transcriptionEnabled = false
    @Published private(set) var persistenceWarning: String?

    private var roomKey: String?
    private var pendingWrite: DispatchWorkItem?
    private static let sharedWriter = DispatchQueue(label: "dev.vsmirn0v.conferenceguest.catch-up-writer")
    private let writer: DispatchQueue
    private let storage: URL
    private var sessionID: String?
    private var markerWarning: String?
    private let revision = WriteRevision()
    private var writeVersion: UInt64 = 0
    private var lastEnqueuedWriteAt: TimeInterval = 0

    var roomHost: String? { roomKey.flatMap { URL(string: $0)?.host } }

    init(storageURL: URL? = nil, writer: DispatchQueue? = nil) {
        self.storage = storageURL ?? Self.storageURL
        self.writer = writer ?? Self.sharedWriter
        guard let data = try? Data(contentsOf: storage),
              let saved = try? JSONDecoder().decode(SavedTimeline.self, from: data),
              readSessionMarker() == saved.sessionID else { return }
        sessionID = saved.sessionID
        guard saved.savedAt > Date().addingTimeInterval(-86_400) else {
            try? FileManager.default.removeItem(at: storage)
            return
        }
        roomKey = saved.roomKey
        canViewTranscript = saved.canViewTranscript
        transcriptionEnabled = saved.transcriptionEnabled ?? false
        var restored = saved.timeline
        restored.resumeAfterRestart(at: saved.savedAt)
        timeline = restored
    }

    func enter(roomKey: String) {
        guard self.roomKey != roomKey else { return }
        self.roomKey = roomKey
        sessionID = UUID().uuidString
        timeline = CatchUpTimeline()
        canViewTranscript = nil
        transcriptionEnabled = false
        persistenceWarning = nil
        writeSessionMarker(sessionID ?? "ended")
        writeNow()
    }

    @discardableResult
    func finishMeeting() -> Task<Void, Never> {
        sessionID = nil
        roomKey = nil
        timeline = CatchUpTimeline()
        canViewTranscript = nil
        transcriptionEnabled = false
        persistenceWarning = nil
        writeSessionMarker("ended")
        pendingWrite?.cancel()
        pendingWrite = nil
        writeVersion &+= 1
        revision.set(writeVersion)
        let url = storage
        let writer = writer
        let completion = AsyncStream<Void> { continuation in
            writer.async {
                try? FileManager.default.removeItem(at: url)
                continuation.yield(())
                continuation.finish()
            }
        }
        return Task { for await _ in completion {} }
    }

    func begin(_ reason: MissedReason) {
        var updated = timeline
        updated.begin(reason)
        timeline = updated
        writeNow()
    }

    func end(_ reason: MissedReason) {
        var updated = timeline
        updated.end(reason)
        timeline = updated
        writeNow()
    }

    func continueAsConnectionGap() {
        var updated = timeline
        updated.resumeAfterRestart()
        timeline = updated
        writeNow()
    }

    func observe(messages: [TranscriptSegment], canView: Bool, enabled: Bool) {
        let accessChanged = canViewTranscript != canView || transcriptionEnabled != enabled
        if canViewTranscript != canView { canViewTranscript = canView }
        if transcriptionEnabled != enabled { transcriptionEnabled = enabled }
        guard !messages.isEmpty else {
            if accessChanged { scheduleWrite() }
            return
        }
        var updated = timeline
        updated.upsert(messages)
        guard updated.segments != timeline.segments || updated.isTruncated != timeline.isTruncated else {
            if accessChanged { scheduleWrite() }
            return
        }
        timeline = updated
        scheduleWrite()
    }

    func markReviewed() {
        var updated = timeline
        updated.markReviewed()
        timeline = updated
        writeNow()
    }

    func markReviewed(_ id: UUID) {
        var updated = timeline
        updated.markReviewed(id)
        guard updated.unreadCount != timeline.unreadCount else { return }
        timeline = updated
        writeNow()
    }

    private func scheduleWrite() {
        if ProcessInfo.processInfo.systemUptime - lastEnqueuedWriteAt >= 5 {
            writeNow()
            return
        }
        pendingWrite?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.writeNow() }
        pendingWrite = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: item)
    }

    private func writeNow() {
        pendingWrite?.cancel()
        pendingWrite = nil
        guard let roomKey else { return }
        lastEnqueuedWriteAt = ProcessInfo.processInfo.systemUptime
        writeVersion &+= 1
        let version = writeVersion
        revision.set(version)
        let revision = revision
        let saved = SavedTimeline(sessionID: sessionID, roomKey: roomKey, savedAt: Date(), timeline: timeline,
                                  canViewTranscript: canViewTranscript,
                                  transcriptionEnabled: transcriptionEnabled)
        let url = storage
        writer.async { [weak self] in
            guard revision.matches(version) else { return }
            let warning: String?
            do {
                let data = try JSONEncoder().encode(saved)
                let directory = url.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: url,
                               options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                var savedURL = url
                try savedURL.setResourceValues(values)
                warning = nil
            } catch {
                warning = L("Catch-up history is available only until this app closes.")
                #if DEBUG
                print("Could not save local catch-up history: \(error.localizedDescription)")
                #endif
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.writeVersion == version else { return }
                let effectiveWarning = warning ?? self.markerWarning
                if self.persistenceWarning != effectiveWarning { self.persistenceWarning = effectiveWarning }
            }
        }
    }

    private var markerURL: URL { storage.appendingPathExtension("session") }
    private func readSessionMarker() -> String? {
        guard let data = try? Data(contentsOf: markerURL), data.count <= 64 else { return nil }
        return String(data: data, encoding: .utf8)
    }
    private func writeSessionMarker(_ marker: String) {
        // A tiny separate atomic marker survives force quit without waiting for
        // the queue encoding/writing transcript history. UserDefaults flushes asynchronously.
        do {
            try FileManager.default.createDirectory(at: storage.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(marker.utf8).write(to: markerURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            markerWarning = nil
        } catch {
            markerWarning = L("Local history could not be updated. Try deleting it again.")
            persistenceWarning = L("Local history could not be updated. Try deleting it again.")
        }
    }

    private static var storageURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("catch-up.json")
    }
}

private struct SavedTimeline: Codable {
    let sessionID: String?
    let roomKey: String
    let savedAt: Date
    let timeline: CatchUpTimeline
    let canViewTranscript: Bool?
    let transcriptionEnabled: Bool?
}

/// The writer reads only this lock-protected revision, never observable UI state.
private final class WriteRevision: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    func set(_ value: UInt64) { lock.lock(); self.value = value; lock.unlock() }
    func matches(_ value: UInt64) -> Bool { lock.lock(); defer { lock.unlock() }; return self.value == value }
}
