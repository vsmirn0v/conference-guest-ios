import AVFAudio
import ConferenceCore
import UIKit
import UserNotifications

/// Explicit background admission; all permissions must already be granted.
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
    // Keep the original storage key to preserve existing per-device choices.
    static let enabledKey = "experiments.backgroundAudioJoin"
    static let defaultEnabled = true
    static func preferenceEnabled(in preferences: UserDefaults = .standard) -> Bool {
        preferences.object(forKey: enabledKey) as? Bool ?? defaultEnabled
    }
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
    private let removeFallback: @MainActor () -> Void
    var enabled: Bool { isEnabled() }
    var hasPendingIntent: Bool { attempt.isPending }

    init(attempt: BackgroundAudioJoinAttempt? = nil,
         enabled: @escaping @MainActor () -> Bool = {
             #if DEBUG
             if ColdJoinDeviceFixture.active { return true }
             #endif
             return !ProcessInfo.processInfo.isiOSAppOnMac && BackgroundAudioJoinPrototype.preferenceEnabled()
         },
         makePrepared: @escaping @MainActor () -> Prepared = {
             #if DEBUG
             if let model = ColdJoinDeviceFixture.makeModel() { return .init(model: model, container: MeetingContainerViewController()) }
             #endif
             return .init(model: ConferenceModel(), container: MeetingContainerViewController())
         },
         notify: @escaping @MainActor (String) -> Void = { reference in
             UNUserNotificationCenter.current().add(BackgroundAudioJoinPrototype.fallback(reference: reference), withCompletionHandler: nil)
         }, clearFallback: @escaping @MainActor () -> Void = {
             UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [BackgroundAudioJoinPrototype.fallbackID])
             UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [BackgroundAudioJoinPrototype.fallbackID])
         }) {
        self.isEnabled = enabled; self.makePrepared = makePrepared
        self.removeFallback = clearFallback
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
        clearFallback()
        #if DEBUG
        CameraBackgroundTrace.event("background-join-production-action", ["pid": ProcessInfo.processInfo.processIdentifier])
        #endif
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
        let result = await attempt.join(reference: reference, session: model)
        #if DEBUG
        CameraBackgroundTrace.event("background-join-production-result", ["result": String(describing: result), "pid": ProcessInfo.processInfo.processIdentifier])
        #endif
    }
    func cancel() {
        attempt.cancel()
        clearFallback()
    }
    func preferencesChanged() {
        if !enabled { cancel() }
        CalendarReminderBroker.shared.install()
    }
    private func clearFallback() {
        removeFallback()
    }
    func supersedeForForeground() {
        _ = attempt.foregrounded()
        clearFallback()
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

#if DEBUG
/// Real background admission with isolated local history/name, no Calendar writes.
/// This exercises the notification handler's transaction after a real background
/// transition; notification presentation and reference lookup have separate tests.
@MainActor final class BackgroundJoinDeviceFixture: BackgroundAudioJoinSession {
    private static weak var active: BackgroundJoinDeviceFixture?
    private static let reference = "background-join-device-fixture"
    static func respond(reference: String, action: String) async -> Bool {
        guard reference == Self.reference, action == BackgroundAudioJoinPrototype.action, let active else { return false }
        await active.join(); return true
    }
    private weak var window: UIWindow?
    private var detachedRoot: UIViewController?
    func foregrounded() {
        if let detachedRoot { window?.rootViewController = detachedRoot; self.detachedRoot = nil }
        _ = attempt.foregrounded()
    }

    actor Reader: CalendarReading {
        func access() -> CalendarAccess { .denied }
        func requestAccess() -> Bool { false }
        func read(selected: Set<String>, now: Date, knownOrigins: Set<String>, aliases: [String: URL]) -> CalendarSnapshot {
            .init(calendars: [], meetings: [])
        }
    }
    final class Notifications: ReminderNotifying {
        func authorization() -> ReminderAuthorization { .denied }
        func request(sensitive: Bool) -> Bool { false }
        func pending() -> [String: String] { [:] }
        func add(_ reminder: ReminderNotification) {}
        func removePending(_ ids: [String]) {}
        func removeDelivered(occurrenceIDs: Set<String>) {}
        func removeAllDelivered() {}
    }
    private let model: ConferenceModel
    private let occurrence: ReminderOccurrence
    private let attempt = BackgroundAudioJoinAttempt(execution: SystemBackgroundJoinExecution())
    private var observer: NSObjectProtocol?
    private var started = false
    private var nextTrace = Date.distantPast
    private var work: Task<Void, Never>?
    static func make(model: ConferenceModel, window: UIWindow) -> BackgroundJoinDeviceFixture? {
        guard let raw = ProcessInfo.processInfo.environment["CONFERENCE_TEST_BACKGROUND_JOIN_INVITE"],
              let url = URL(string: raw), url.scheme == "https" else { return nil }
        var meeting = CalendarMeeting(id: "background-device-qa", seriesID: "background-device-qa",
            calendarID: "synthetic", calendarTitle: "Synthetic test", title: "Background join QA",
            start: Date().addingTimeInterval(-60), end: Date().addingTimeInterval(600))
        meeting.invitation = url; meeting.engine = .guest
        guard let occurrence = ReminderOccurrence(meeting: meeting) else { return nil }
        let fixture = BackgroundJoinDeviceFixture(model: model, occurrence: occurrence)
        fixture.window = window
        return fixture
    }
    private init(model: ConferenceModel, occurrence: ReminderOccurrence) {
        self.model = model; self.occurrence = occurrence
        observer = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.begin() }
            }
        Self.active = self
        CameraBackgroundTrace.event("background-join-fixture-ready")
    }
    private func begin() {
        guard !started else { return }
        started = true
        if ProcessInfo.processInfo.environment["CONFERENCE_TEST_BACKGROUND_JOIN_HEADLESS"] == "1" {
            detachedRoot = window?.rootViewController
            window?.rootViewController = UIViewController()
        }
        work = Task { [weak self] in
            guard let self else { return }
            if ProcessInfo.processInfo.environment["CONFERENCE_TEST_BACKGROUND_JOIN_NOTIFICATION"] == "1" {
                let content = UNMutableNotificationContent()
                content.title = "Background join QA"
                content.categoryIdentifier = CalendarReminderBroker.category
                content.userInfo = ["reference": Self.reference]
                do {
                    try await UNUserNotificationCenter.current().add(.init(identifier: Self.reference,
                        content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)))
                } catch { CameraBackgroundTrace.event("background-join-fixture-notification-failed") }
            } else { await join() }
        }
    }
    private func join() async {
        CameraBackgroundTrace.event("background-join-fixture-begin")
        let result = await attempt.join(reference: Self.reference, session: self)
        CameraBackgroundTrace.event("background-join-fixture-result", ["result": String(describing: result)])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.reference])
    }
    func resolveBackgroundJoin(reference: String) async -> ReminderOccurrence? { occurrence }
    func beginBackgroundJoin(_ occurrence: ReminderOccurrence, access: BackgroundJoinAccess) -> BackgroundJoinStart {
        model.beginBackgroundJoin(occurrence, access: access)
    }
    func backgroundJoinProgress(token: UInt64) -> BackgroundJoinProgress {
        if Date() >= nextTrace {
            nextTrace = Date().addingTimeInterval(2)
            CameraBackgroundTrace.event("background-join-fixture-progress", model.backgroundJoinEvidenceForTesting)
        }
        return model.backgroundJoinProgress(token: token)
    }
    func cancelBackgroundJoin(token: UInt64) { model.cancelBackgroundJoin(token: token) }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) }; work?.cancel() }
}
#endif

#if DEBUG
import EventKit

/// TTL-bounded device qualification. Only the owned event/notification and a
/// separate sandbox document are changed; normal reminder reconciliation is inert.
@MainActor enum ColdJoinDeviceFixture {
    struct Manifest: Codable {
        var id: String
        var expires: Date
        var invitation: URL
        var eventID: String?
        var calendarID: String?
        var reference: String?
        var title: String { "Cold notification QA " + id }
    }
    static let notificationID = "cold-join-device-fixture"
    private static let suite = "ColdJoinDeviceFixture"
    private static var manifest: Manifest?
    private static var modelID: ObjectIdentifier?
    static private(set) var cleanupSucceeded = false
    static var active: Bool { manifest.map { $0.expires > Date() } ?? false }
    nonisolated private static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ColdJoinDeviceFixture")
    }
    private static var manifestURL: URL { folder.appendingPathComponent("manifest.json") }
    static func bootstrap() {
        if let data = try? Data(contentsOf: manifestURL) { manifest = try? JSONDecoder().decode(Manifest.self, from: data) }
        if let raw = ProcessInfo.processInfo.environment["CONFERENCE_TEST_COLD_JOIN_SETUP"],
           let url = URL(string: raw), url.scheme == "https", manifest == nil {
            manifest = Manifest(id: UUID().uuidString, expires: Date().addingTimeInterval(1800), invitation: url)
            // Model a person who completed setup before opting into the experiment.
            let setup = MeetingSetupCoordinator(preferences: UserDefaults(suiteName: suite)!)
            setup.begin()
            for _ in MeetingSetupCoordinator.Step.allCases { setup.next() }
        }
        guard active else { return }
        for key in ["CONFERENCE_TEST_CAMERA_TRACE", "CONFERENCE_TEST_MEDIA_TRACE"] { setenv(key, "1", 1) }
        CameraBackgroundTrace.start()
        CameraBackgroundTrace.event("background-join-cold-process", ["pid": ProcessInfo.processInfo.processIdentifier,
            "persisted": manifest?.reference != nil])
    }
    private static func persist() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication, .posixPermissions: 0o700])
        try JSONEncoder().encode(manifest).write(to: manifestURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var url = folder; try url.setResourceValues(values)
    }
    final class Storage: RoomHistoryStorage, ReminderStorage {
        private let url: URL
        init(_ name: String) { url = ColdJoinDeviceFixture.folder.appendingPathComponent(name + ".json") }
        func read() -> Data? { try? Data(contentsOf: url) }
        func write(_ data: Data) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }
    actor OwnedReader: CalendarReading {
        private let title: String
        private let reader = AppleCalendarReader()
        init(title: String) { self.title = title }
        func access() async -> CalendarAccess { await reader.access() }
        func requestAccess() async throws -> Bool { try await reader.requestAccess() }
        func read(selected: Set<String>, now: Date, knownOrigins: Set<String>, aliases: [String: URL]) async -> CalendarSnapshot {
            let snapshot = await reader.read(selected: selected, now: now, knownOrigins: knownOrigins, aliases: aliases)
            return .init(calendars: snapshot.calendars, meetings: snapshot.meetings.filter { $0.title == title })
        }
    }
    static func makeModel() -> ConferenceModel? {
        guard active else { return nil }
        let preferences = UserDefaults(suiteName: suite)!
        preferences.set("Cold listener QA", forKey: "savedDisplayName")
        preferences.set(true, forKey: "iCloudSyncOfferSeen")
        preferences.set(true, forKey: "calendarMeetings.enabled")
        preferences.set(true, forKey: "calendarReminders.enabled")
        if let id = manifest?.calendarID { preferences.set([id], forKey: "calendarMeetings.selected") }
        let detector = VendorEndpointResolver.makeDetector()
        let reminders = CalendarReminderCoordinator(preferences: preferences, storage: Storage("reminders"),
            notifications: BackgroundJoinDeviceFixture.Notifications())
        let calendar = CalendarMeetingStore(reader: OwnedReader(title: manifest!.title), detector: detector,
            preferences: preferences, storage: Storage("calendar"), reminders: reminders)
        let model = ConferenceModel(history: RoomHistoryStore(storage: Storage("history")), preferences: preferences,
            engineDetector: detector, calendar: calendar,
            catchUp: CatchUpStore(storageURL: folder.appendingPathComponent("catchup.json")))
        modelID = ObjectIdentifier(model)
        RoomSyncUIFixture.isolateColdModel(model, preferences: preferences, storage: Storage("sync"))
        CameraBackgroundTrace.event("background-join-cold-model", ["pid": ProcessInfo.processInfo.processIdentifier,
            "persistedReference": manifest?.reference != nil])
        Task { [weak model] in
            for _ in 0..<90 {
                try? await Task.sleep(for: .seconds(2))
                guard let model else { return }
                CameraBackgroundTrace.event("background-join-cold-progress", model.backgroundJoinEvidenceForTesting)
            }
        }
        return model
    }
    static func prepareIfRequested(model: ConferenceModel) {
        guard active, ObjectIdentifier(model) == modelID,
              ProcessInfo.processInfo.environment["CONFERENCE_TEST_COLD_JOIN_SETUP"] != nil else { return }
        Task {
            do {
                guard #available(iOS 17, *), var value = manifest else { return }
                let store = EKEventStore()
                guard try await store.requestFullAccessToEvents(), let calendar = store.defaultCalendarForNewEvents,
                      calendar.allowsContentModifications else { throw CocoaError(.fileWriteNoPermission) }
                if let id = value.eventID {
                    guard let event = store.event(withIdentifier: id), event.title == value.title,
                          event.url == value.invitation, event.calendar.calendarIdentifier == value.calendarID else {
                        throw CocoaError(.fileReadNoSuchFile)
                    }
                } else {
                    // Persist ownership before creating an EventKit object; retry never
                    // overwrites the only identifier of a previously created event.
                    try persist()
                    let event = EKEvent(eventStore: store)
                    event.calendar = calendar; event.title = value.title; event.url = value.invitation
                    event.startDate = Date().addingTimeInterval(-60); event.endDate = value.expires
                    try store.save(event, span: .thisEvent)
                    value.eventID = event.eventIdentifier; value.calendarID = calendar.calendarIdentifier
                    manifest = value; try persist()
                }
                model.calendar.select(value.calendarID!, included: true)
                model.calendar.foregrounded(allowAutomaticJoin: false)
                for _ in 0..<200 {
                    if let occurrence = model.calendar.reminders.repository.occurrences.first(where: { $0.title == value.title && $0.eligible }) {
                        value.reference = occurrence.reference; manifest = value; try persist()
                        let content = UNMutableNotificationContent()
                        content.title = "Cold notification join QA"; content.categoryIdentifier = CalendarReminderBroker.category
                        content.userInfo = ["reference": occurrence.reference]
                        try await UNUserNotificationCenter.current().add(.init(identifier: notificationID, content: content,
                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 12, repeats: false)))
                        CameraBackgroundTrace.event("background-join-cold-armed", ["pid": ProcessInfo.processInfo.processIdentifier])
                        let label = UILabel(); label.text = "Cold notification armed"; label.accessibilityIdentifier = "cold-join-armed"
                        label.frame = CGRect(x: 30, y: 120, width: 300, height: 60)
                        model.continuationHostView?.addSubview(label)
                        return
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
                throw CocoaError(.fileReadUnknown)
            } catch { CameraBackgroundTrace.event("background-join-cold-setup-error", ["error": String(describing: error)]) }
        }
    }
    static func cleanupIfRequested() async {
        guard ProcessInfo.processInfo.environment["CONFERENCE_TEST_COLD_JOIN_CLEANUP"] == "1" else { return }
        do {
            if let value = manifest, let id = value.eventID {
                let status = EKEventStore.authorizationStatus(for: .event)
                if #available(iOS 17, *) {
                    guard status == .fullAccess else { throw CocoaError(.fileReadNoPermission) }
                } else { guard status == .authorized else { throw CocoaError(.fileReadNoPermission) } }
                let store = EKEventStore()
                if let event = store.event(withIdentifier: id) {
                    guard event.title == value.title, event.url == value.invitation else { throw CocoaError(.fileWriteNoPermission) }
                    try store.remove(event, span: .thisEvent)
                }
                guard EKEventStore().event(withIdentifier: id) == nil else { throw CocoaError(.fileWriteUnknown) }
            }
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [notificationID])
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [notificationID])
            let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
            let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
            guard !pending.contains(where: { $0.identifier == notificationID }),
                  !delivered.contains(where: { $0.request.identifier == notificationID }) else { throw CocoaError(.fileWriteUnknown) }
            if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            manifest = nil; modelID = nil; cleanupSucceeded = !FileManager.default.fileExists(atPath: folder.path)
            CalendarReminderBroker.shared.install()
            CameraBackgroundTrace.event("background-join-cold-cleaned", ["verified": cleanupSucceeded,
                "eventAbsent": true, "notificationAbsent": true])
        } catch { CameraBackgroundTrace.event("background-join-cold-cleanup-error", ["error": String(describing: error)]) }
    }
}
#endif
