import Combine
import Foundation

/// Local navigation progress only. Feature settings remain owned by their coordinators.
@MainActor final class MeetingSetupCoordinator: ObservableObject {
    enum Step: Int, Codable, CaseIterable { case calendar, reminders, devices }
    private struct Progress: Codable {
        var version = 1
        var step = Step.calendar
        var completed = false
        var deferred = false
    }
    static let progressKey = "meetingSetup.progress.v1"
    @Published private(set) var step: Step
    @Published private(set) var isPresented = false
    @Published private(set) var launchReady = false
    @Published private(set) var completed: Bool
    private(set) var intentGeneration = 0
    private let preferences: UserDefaults
    private var progress: Progress
    private var writable = true
    private var suppressedForLaunch = false
    private var dismissing = false
    private var mounted = false
    private var afterDismissal: (generation: Int, action: () -> Void)?
    var onBegin: () -> Void = {}
    var onEnd: () -> Void = {}
    var onCloudStep: () -> Void = {}
    var onDefer: () -> Void = {}

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        if let stored = preferences.object(forKey: Self.progressKey) {
            if let data = stored as? Data, let value = try? JSONDecoder().decode(Progress.self, from: data), value.version == 1 {
                progress = value
            } else {
                // Unknown progress must not cause an upgrade popup or overwrite a newer schema.
                progress = Progress(deferred: true); writable = false
            }
        } else { progress = Progress() }
        step = progress.step; completed = progress.completed
    }
    var blocksAutomaticJoin: Bool {
        isPresented || dismissing || (!suppressedForLaunch && !progress.completed && !progress.deferred)
    }
    func finishLaunch(hasMeetingIntent: Bool) {
        if hasMeetingIntent { suspendForMeeting() }
        launchReady = true
    }
    func offerIfAppropriate(_ idleHome: Bool) {
        guard launchReady, idleHome, !suppressedForLaunch, !progress.completed, !progress.deferred, !isPresented else { return }
        begin()
    }
    func begin() {
        guard !isPresented, !dismissing else { return }
        if completed {
            step = .calendar; progress.step = .calendar
            progress.completed = false; completed = false; progress.deferred = true; save()
        } else { step = progress.step }
        onBegin(); isPresented = true
        if step == .devices { onCloudStep() }
    }
    func back() {
        guard isPresented, let previous = Step(rawValue: step.rawValue - 1) else { return }
        move(to: previous)
    }
    func next() {
        guard isPresented else { return }
        if let next = Step(rawValue: step.rawValue + 1) { move(to: next) }
        else {
            progress.completed = true; completed = true; progress.deferred = false
            save(); end()
        }
    }
    func showCalendars() { guard isPresented else { return }; move(to: .calendar) }
    func finishLater() {
        guard isPresented else { return }
        progress.deferred = true; save(); onDefer(); end()
    }
    func suspendForMeeting() {
        intentGeneration += 1
        afterDismissal = nil
        suppressedForLaunch = true
        if isPresented { save(); end() }
    }
    var needsDismissal: Bool { isPresented || dismissing }
    func presentationDidMount() { mounted = true }
    /// Newest meeting intent wins; UIKit presentation must wait for the full sheet chain.
    func performMeetingIntent(_ action: @escaping () -> Void) {
        suspendForMeeting()
        if dismissing { afterDismissal = (intentGeneration, action) } else { action() }
    }
    func presentationDidDismiss() {
        mounted = false; dismissing = false
        let pending = afterDismissal; afterDismissal = nil
        if let pending, pending.generation == intentGeneration { pending.action() }
    }
    private func move(to value: Step) {
        step = value; progress.step = value; save()
        if value == .devices { onCloudStep() }
    }
    private func end() {
        dismissing = mounted; onEnd(); isPresented = false; suppressedForLaunch = true
    }
    private func save() {
        guard writable, let data = try? JSONEncoder().encode(progress) else { return }
        preferences.set(data, forKey: Self.progressKey)
    }
}
