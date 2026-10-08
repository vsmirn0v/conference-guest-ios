import Combine
import UIKit

struct InCallNotice {
    struct Key: Hashable { let title: String; let actionTitle: String? }
    let title: String
    let actionTitle: String?
    let action: (() -> Void)?
    var key: Key { Key(title: title, actionTitle: actionTitle) }
}

/// One inline notice, with privacy state kept independently of transient text.
/// Provider text is preserved verbatim, never interpreted to determine its kind.
@MainActor
final class MeetingHeaderStatus: ObservableObject {
    struct Snapshot: Equatable {
        var transcribing = false
        var recording = false
        var noticeTitle: String?
        var actionTitle: String?
        var announcingPrivacy = false
        var privacySymbol: String? {
            recording ? "record.circle" : transcribing ? "text.bubble" : nil
        }
        var privacySummary: String? {
            let parts = [recording ? L("Recording") : nil, transcribing ? L("Transcription on") : nil].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
        var privacyDetails: [String] {
            [recording ? L("Meeting is being recorded") : nil,
             transcribing ? L("The organizer is transcribing this meeting.") : nil].compactMap { $0 }
        }
    }
    @Published private(set) var snapshot = Snapshot()
    private(set) var recentMessages: [String] = []
    private var currentNotices: [InCallNotice] = []
    private var seen: [InCallNotice.Key] = []
    private var transientTitle: String?
    private var transientDeadline: Date?
    private var privacyDeadline: Date?
    private var transcribing = false
    private var recording = false
    private var privacyText = false
    private var timer: Timer?
    private let duration: TimeInterval
    private let automaticallyExpires: Bool

    init(duration: TimeInterval = 4, automaticallyExpires: Bool = true) {
        self.duration = duration; self.automaticallyExpires = automaticallyExpires
    }
    var activeActions: [InCallNotice] { currentNotices.filter { $0.action != nil && $0.actionTitle != nil } }

    func updatePrivacy(transcribing: Bool, recording: Bool, at now: Date = Date()) {
        guard self.transcribing != transcribing || self.recording != recording else { return }
        let started = (transcribing && !self.transcribing) || (recording && !self.recording)
        self.transcribing = transcribing; self.recording = recording
        let value = Snapshot(transcribing: transcribing, recording: recording)
        if started {
            transientTitle = value.privacyDetails.joined(separator: " · ")
            transientDeadline = now.addingTimeInterval(duration)
            privacyDeadline = transientDeadline
            privacyText = true
            remember(transientTitle!)
            UIAccessibility.post(notification: .announcement, argument: transientTitle)
        } else {
            if !transcribing && !recording { privacyDeadline = nil }
            if privacyText { transientTitle = nil; transientDeadline = nil; privacyText = false }
        }
        refresh(at: now)
    }
    func updateNotices(_ notices: [InCallNotice], at now: Date = Date()) {
        var keys: Set<InCallNotice.Key> = []
        currentNotices = notices.filter { !$0.title.isEmpty && keys.insert($0.key).inserted }
        let new = currentNotices.filter { !seen.contains($0.key) }
        for item in new {
            seen.append(item.key); remember(item.title)
        }
        if seen.count > 128 { seen.removeFirst(seen.count - 128) }
        if let item = new.last {
            transientTitle = item.title; transientDeadline = now.addingTimeInterval(duration)
            privacyText = false
        }
        refresh(at: now)
    }
    func expire(at now: Date = Date()) { refresh(at: now) }
    func reset() {
        timer?.invalidate(); timer = nil
        currentNotices = []; seen = []; recentMessages = []
        transientTitle = nil; transientDeadline = nil; privacyDeadline = nil
        transcribing = false; recording = false; privacyText = false
        snapshot = Snapshot()
    }
    private func remember(_ title: String) {
        recentMessages.removeAll { $0 == title }
        recentMessages.append(title)
        if recentMessages.count > 4 { recentMessages.removeFirst() }
    }
    private func refresh(at now: Date) {
        timer?.invalidate(); timer = nil
        if let deadline = transientDeadline, deadline <= now { transientTitle = nil; transientDeadline = nil }
        if let deadline = privacyDeadline, deadline <= now { privacyDeadline = nil }
        let action = activeActions.last
        var value = Snapshot(transcribing: transcribing, recording: recording)
        value.noticeTitle = action?.title ?? transientTitle
        value.actionTitle = action?.actionTitle
        value.announcingPrivacy = privacyDeadline != nil
        if value != snapshot { snapshot = value }
        guard automaticallyExpires, let next = [transientDeadline, privacyDeadline].compactMap({ $0 }).min() else { return }
        timer = Timer.scheduledTimer(withTimeInterval: max(0.01, next.timeIntervalSince(now)), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.expire() }
        }
    }
    deinit { timer?.invalidate() }
}
