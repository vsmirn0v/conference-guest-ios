#if DEBUG
import AVFAudio
import ConferenceCore
import UIKit
import UserNotifications

/// Deliberately excluded from Release until physical-device acceptance.
struct BackgroundJoinAccess {
    let protectedData: Bool
    let microphone: Bool
    let systemControls: Bool
    @MainActor static var current: Self {
        .init(protectedData: UIApplication.shared.isProtectedDataAvailable,
              microphone: AVAudioSession.sharedInstance().recordPermission == .granted,
              systemControls: UserDefaults.standard.bool(forKey: SystemCallCoordinator.controlsPreferenceKey))
    }
}

enum BackgroundJoinStart { case started(UInt64), alreadyConnected, openApp }
enum BackgroundJoinProgress: Equatable { case waiting, ready, ended }
enum BackgroundJoinResult: Equatable { case connected, alreadyConnected, openApp, cancelled, foregrounded }

@MainActor protocol BackgroundAudioJoinSession: AnyObject {
    func resolveBackgroundJoin(reference: String) async -> ReminderOccurrence?
    func beginBackgroundJoin(_ occurrence: ReminderOccurrence, access: BackgroundJoinAccess) -> BackgroundJoinStart
    func backgroundJoinProgress(token: UInt64) -> BackgroundJoinProgress
    func cancelBackgroundJoin(token: UInt64)
}

@MainActor protocol BackgroundJoinExecution: AnyObject {
    func begin(expired: @escaping @MainActor () -> Void) -> Bool
    func end()
}

@MainActor final class SystemBackgroundJoinExecution: BackgroundJoinExecution {
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    func begin(expired: @escaping @MainActor () -> Void) -> Bool {
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Join meeting audio") {
            Task { @MainActor in expired() }
        }
        return identifier != .invalid
    }
    func end() {
        guard identifier != .invalid else { return }
        let previous = identifier; identifier = .invalid
        UIApplication.shared.endBackgroundTask(previous)
    }
}

/// One bounded transaction. Cancellation never waits for a provider's teardown.
@MainActor final class BackgroundAudioJoinAttempt {
    private final class Pending {
        let id = UUID(), reference: String
        let session: any BackgroundAudioJoinSession
        var token: UInt64?
        var waiters: [CheckedContinuation<BackgroundJoinResult, Never>] = []
        init(_ reference: String, _ session: any BackgroundAudioJoinSession) {
            self.reference = reference; self.session = session
        }
    }
    private let execution: any BackgroundJoinExecution
    private let timeout: Duration
    private let access: @MainActor () -> BackgroundJoinAccess
    private let clock: () -> Date
    private var pending: Pending?
    private var work: Task<Void, Never>?, deadline: Task<Void, Never>?
    var onFinished: (String, BackgroundJoinResult) -> Void = { _, _ in }
    var isPending: Bool { pending != nil }

    init(execution: any BackgroundJoinExecution, timeout: Duration = .seconds(20),
         access: @escaping @MainActor () -> BackgroundJoinAccess = { .current }, clock: @escaping () -> Date = Date.init) {
        self.execution = execution; self.timeout = timeout; self.access = access; self.clock = clock
    }
    func join(reference: String, session: any BackgroundAudioJoinSession) async -> BackgroundJoinResult {
        await withCheckedContinuation { completion in
            if let pending {
                if pending.reference == reference { pending.waiters.append(completion) }
                else { completion.resume(returning: .openApp); onFinished(reference, .openApp) }
                return
            }
            let request = Pending(reference, session); request.waiters.append(completion); pending = request
            guard execution.begin(expired: { [weak self] in self?.finish(request.id, result: .openApp) }) else {
                finish(request.id, result: .openApp); return
            }
            deadline = Task { [weak self, timeout] in
                do { try await Task.sleep(for: timeout) } catch { return }
                self?.finish(request.id, result: .openApp)
            }
            work = Task { [weak self] in
                guard let self else { return }
                guard let occurrence = await session.resolveBackgroundJoin(reference: reference),
                      self.pending?.id == request.id, !Task.isCancelled else {
                    self.finish(request.id, result: .openApp); return
                }
                guard occurrence.end > self.clock() else { self.finish(request.id, result: .openApp); return }
                switch session.beginBackgroundJoin(occurrence, access: self.access()) {
                case .alreadyConnected: self.finish(request.id, result: .alreadyConnected)
                case .openApp: self.finish(request.id, result: .openApp)
                case .started(let token):
                    request.token = token
                    while self.pending?.id == request.id, !Task.isCancelled {
                        switch session.backgroundJoinProgress(token: token) {
                        case .ready: self.finish(request.id, result: .connected); return
                        case .ended: self.finish(request.id, result: .openApp); return
                        case .waiting: break
                        }
                        do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    }
                }
            }
        }
    }
    func cancel() { if let pending { finish(pending.id, result: .cancelled) } }
    /// Returns an unresolved reference for the normal foreground resolver.
    func foregrounded() -> String? {
        guard let pending else { return nil }
        let reference = pending.token == nil ? pending.reference : nil
        finish(pending.id, result: .foregrounded)
        return reference
    }
    private func finish(_ id: UUID, result: BackgroundJoinResult) {
        guard let request = pending, request.id == id else { return }
        pending = nil // Revoke authority before provider callbacks or late calendar results.
        work?.cancel(); work = nil; deadline?.cancel(); deadline = nil
        if result != .connected && result != .foregrounded, let token = request.token { request.session.cancelBackgroundJoin(token: token) }
        onFinished(request.reference, result)
        execution.end()
        for waiter in request.waiters { waiter.resume(returning: result) }
    }
}

@MainActor final class BackgroundAudioJoinPrototype {
    static let shared = BackgroundAudioJoinPrototype()
    static let enabledKey = "experiments.backgroundAudioJoin"
    static let action = "REMINDER_JOIN_AUDIO_PROTOTYPE"
    static let fallbackCategory = "MEETING_JOIN_OPEN_APP"
    static let fallbackID = "meeting.background-join.result"
    static var notificationAction: UNNotificationAction {
        .init(identifier: action, title: L("Join audio"), options: [.authenticationRequired])
    }
    static var notificationCategory: UNNotificationCategory {
        .init(identifier: fallbackCategory,
              actions: [.init(identifier: CalendarReminderBroker.join, title: L("Open to continue"), options: [.foreground, .authenticationRequired])],
              intentIdentifiers: [], options: [])
    }
    struct Prepared {
        let model: ConferenceModel
        let container: MeetingContainerViewController
    }
    private weak var attached: ConferenceModel?
    private weak var attachedContainer: MeetingContainerViewController?
    private var prepared: Prepared?
    private var needsAdoption = false
    private let attempt: BackgroundAudioJoinAttempt
    private let isEnabled: @MainActor () -> Bool
    private let makePrepared: @MainActor () -> Prepared
    var enabled: Bool { isEnabled() }
    var hasPendingIntent: Bool { attempt.isPending }

    init(attempt: BackgroundAudioJoinAttempt? = nil,
         enabled: @escaping @MainActor () -> Bool = { UserDefaults.standard.bool(forKey: BackgroundAudioJoinPrototype.enabledKey) },
         makePrepared: @escaping @MainActor () -> Prepared = { .init(model: ConferenceModel(), container: MeetingContainerViewController()) },
         notify: @escaping @MainActor (String) -> Void = { reference in
             UNUserNotificationCenter.current().add(BackgroundAudioJoinPrototype.fallback(reference: reference), withCompletionHandler: nil)
         }) {
        self.isEnabled = enabled; self.makePrepared = makePrepared
        self.attempt = attempt ?? BackgroundAudioJoinAttempt(execution: SystemBackgroundJoinExecution())
        self.attempt.onFinished = { reference, result in
            guard result == .openApp else { return }
            notify(reference)
        }
    }
    func attach(_ model: ConferenceModel, container: MeetingContainerViewController) {
        attached = model; attachedContainer = container
    }
    func takePreparedForScene() -> Prepared? {
        guard needsAdoption else { return nil }
        needsAdoption = false
        return prepared
    }
    func sceneDisconnected(_ model: ConferenceModel) -> Bool {
        guard prepared?.model === model else { return false }
        if model.desktopMeetingActive || attempt.isPending { needsAdoption = true; return true }
        prepared = nil; return false
    }
    func join(reference: String) async {
        guard enabled else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.fallbackID])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.fallbackID])
        let model: ConferenceModel
        if let attached, let attachedContainer {
            model = attached; prepared = Prepared(model: attached, container: attachedContainer)
        }
        else if let prepared { model = prepared.model }
        else {
            let new = makePrepared()
            prepared = new; needsAdoption = true; model = new.model
            model.configure(container: new.container)
        }
        _ = await attempt.join(reference: reference, session: model)
    }
    func cancel() { attempt.cancel() }
    func supersedeForForeground() {
        _ = attempt.foregrounded()
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.fallbackID])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.fallbackID])
    }
    func foregrounded() {
        if let reference = attempt.foregrounded() {
            CalendarReminderBroker.shared.sharedCoordinator.open(reference: reference, join: true)
        }
    }
    static func fallback(reference: String) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = L("Open to finish joining")
        content.body = L("Open Rock’n’Roll to connect to the meeting.")
        content.categoryIdentifier = fallbackCategory
        content.userInfo = ["reference": reference]
        return .init(identifier: fallbackID, content: content, trigger: nil)
    }
}
#endif
