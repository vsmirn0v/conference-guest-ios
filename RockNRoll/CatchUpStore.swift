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

    var roomHost: String? { roomKey.flatMap { URL(string: $0)?.host } }

    init() {
        guard let data = try? Data(contentsOf: Self.storageURL),
              let saved = try? JSONDecoder().decode(SavedTimeline.self, from: data) else { return }
        guard saved.savedAt > Date().addingTimeInterval(-86_400) else {
            try? FileManager.default.removeItem(at: Self.storageURL)
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
        timeline = CatchUpTimeline()
        canViewTranscript = nil
        transcriptionEnabled = false
        persistenceWarning = nil
        writeNow()
    }

    func finishMeeting() {
        roomKey = nil
        timeline = CatchUpTimeline()
        canViewTranscript = nil
        transcriptionEnabled = false
        persistenceWarning = nil
        pendingWrite?.cancel()
        pendingWrite = nil
        try? FileManager.default.removeItem(at: Self.storageURL)
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
        canViewTranscript = canView
        transcriptionEnabled = enabled
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

    private func scheduleWrite() {
        pendingWrite?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.writeNow() }
        pendingWrite = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: item)
    }

    private func writeNow() {
        pendingWrite?.cancel()
        pendingWrite = nil
        guard let roomKey else { return }
        do {
            let saved = SavedTimeline(roomKey: roomKey, savedAt: Date(), timeline: timeline,
                                      canViewTranscript: canViewTranscript,
                                      transcriptionEnabled: transcriptionEnabled)
            let data = try JSONEncoder().encode(saved)
            let directory = Self.storageURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: Self.storageURL,
                           options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var url = Self.storageURL
            try url.setResourceValues(values)
            persistenceWarning = nil
        } catch {
            persistenceWarning = "Catch-up history is available only until this app closes."
            #if DEBUG
            print("Could not save local catch-up history: \(error.localizedDescription)")
            #endif
        }
    }

    private static var storageURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("catch-up.json")
    }
}

private struct SavedTimeline: Codable {
    let roomKey: String
    let savedAt: Date
    let timeline: CatchUpTimeline
    let canViewTranscript: Bool?
    let transcriptionEnabled: Bool?
}
