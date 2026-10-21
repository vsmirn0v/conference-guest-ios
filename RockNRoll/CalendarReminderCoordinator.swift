import Combine
import ConferenceCore
import Foundation
import UIKit

@MainActor
final class CalendarReminderCoordinator: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var profile = ReminderProfile()
    @Published private(set) var authorization: ReminderAuthorization = .notDetermined
    @Published private(set) var error: String?
    @Published var editing: ReminderOccurrence? { didSet { if editing != nil { onEditing() }; refreshPresentation() } }
    var onOpen: (ReminderOccurrence?, Bool) -> Void = { _, _ in }
    var onPresentation: ([ReminderForegroundEvent]) -> Set<String> = { _ in [] }
    var scene: () -> ReminderScene = { .init() }
    var onBackground: () -> Void = {}
    private var deadline: Task<Void, Never>?
    private var permissionRefresh: Task<Void, Never>?
    private var permissionFresh = false
    private var permissionEpoch = 0
    private var foregroundOffers: [String: ReminderForegroundEvent] = [:]
    private var lastSceneRoom: MeetingRoomIdentity?
    private let clock: () -> Date
    var beforeOpen: () async -> Bool = { true }
    var onNeedsSnapshot: () -> Void = {}
    var onEditing: () -> Void = {}
    var activeRoom: () -> MeetingRoomIdentity? = { nil }
    var isEventVisible: (String) -> Bool = { _ in false }
    var canPresent: () -> Bool = { false }
    private(set) var repository = CalendarReminderRepository()
    private let storage: any ReminderStorage
    private let notifications: any ReminderNotifying
    private let preferences: UserDefaults
    private var loaded = false
    private var available = false
    private var revision = 0
    private var worker: Task<Void, Never>?
    private var cloudTask: Task<Void, Never>?
    private var opening: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var removedOccurrences: Set<String> = []
    private var cloud: ReminderProfileCloud?
    private var syncAccount: String?
    private(set) var hasOpenIntent = false
    var presenting = false { didSet { refreshPresentation() } }
    private var enableRevision = 0

    init(preferences: UserDefaults = .standard, storage: any ReminderStorage = ReminderFileStorage(),
         notifications: (any ReminderNotifying)? = nil, clock: @escaping () -> Date = Date.init) {
        self.preferences = preferences; self.storage = storage; self.clock = clock
        self.notifications = notifications ?? SystemReminderNotifications()
        load()
        available = preferences.bool(forKey: "calendarMeetings.enabled") &&
            !(preferences.stringArray(forKey: "calendarMeetings.selected") ?? []).isEmpty
        for name in [UIApplication.significantTimeChangeNotification, NSNotification.Name.NSSystemTimeZoneDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.onNeedsSnapshot(); self?.changed() }
            })
        }
        for name in [UIApplication.willResignActiveNotification, UIApplication.didBecomeActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                Task { @MainActor in
                    if note.name == UIApplication.willResignActiveNotification { self?.backgrounded() }
                    else { self?.foregrounded() }
                }
            })
        }
    }
    deinit {
        worker?.cancel(); cloudTask?.cancel(); opening?.cancel(); deadline?.cancel(); permissionRefresh?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
    private func load() {
        if let enabled = preferences.object(forKey: "calendarReminders.enabled") as? Bool { self.enabled = enabled }
        do {
            if let data = try storage.read() {
                let saved = try JSONDecoder().decode(CalendarReminderRepository.self, from: data)
                guard (1...2).contains(saved.schema), (1...2).contains(saved.profile.schema) else { throw CocoaError(.coderReadCorrupt) }
                repository = saved
                repository.schema = 2; repository.profile.schema = 2
            }
            enabled = preferences.object(forKey: "calendarReminders.enabled") as? Bool ?? repository.enabled
            repository.enabled = enabled
            profile = repository.profile.value; loaded = true; error = nil
        } catch { self.error = L("Reminders could not be saved. Try again."); loaded = false }
    }
    @discardableResult private func save() -> Bool {
        guard loaded else { return false }
        do { try storage.write(JSONEncoder().encode(repository)); error = nil; return true }
        catch { self.error = L("Reminders could not be saved. Try again."); return false }
    }
    func foregrounded() {
        if !loaded { load() }
        if let reference = repository.pendingOpen {
            let recent = repository.pendingOpenDate.map { clock().timeIntervalSince($0) < 86400 } ?? false
            repository.pendingOpen = nil; repository.pendingOpenDate = nil; _ = save()
            if recent, !hasOpenIntent { open(reference: reference, join: false) }
        }
        guard permissionRefresh == nil else { return }
        permissionFresh = false
        let epoch = permissionEpoch
        permissionRefresh = Task { [weak self] in
            guard let self else { return }
            let value = await notifications.authorization()
            guard !Task.isCancelled, epoch == permissionEpoch else { return }
            authorization = value; permissionFresh = true; permissionRefresh = nil; changed()
        }
    }
    func setEnabled(_ value: Bool) async {
        enableRevision += 1
        let expected = enableRevision
        if !loaded { load() }
        if !value {
            enabled = false; repository.enabled = false
            preferences.set(false, forKey: "calendarReminders.enabled")
            changed(); return
        }
        guard loaded else { return }
        if value {
            do {
                let current = await notifications.authorization()
                if current == .notDetermined { _ = try await notifications.request(sensitive: profile.timeSensitive) }
                authorization = await notifications.authorization(); permissionFresh = true
            } catch { self.error = L("Notifications could not be enabled. Try again."); return }
        }
        guard expected == enableRevision else { return }
        enabled = value; repository.enabled = value
        preferences.set(value, forKey: "calendarReminders.enabled")
        changed()
        if value { onNeedsSnapshot() }
    }
    func setProfile(_ value: ReminderProfile) {
        guard loaded else { return }
        var value = value; value.timing = value.timing.validated
        let needsSensitive = value.timeSensitive && !profile.timeSensitive
        if profile.details && !value.details { removedOccurrences.formUnion(repository.occurrences.map(\.id)) }
        profile = value; repository.profile.value = value
        repository.profile.counter = min(Int64.max - 1, repository.profile.counter) + 1
        repository.profile.device = repository.device
        changed()
        syncProfile(account: syncAccount)
        if needsSensitive, enabled {
            Task { _ = try? await notifications.request(sensitive: true) }
        }
    }
    func update(meetings: [CalendarMeeting], available: Bool) {
        guard loaded else { return }
        self.available = available
        // Avoid deriving another persistent calendar cache before reminder opt-in.
        guard enabled || !repository.occurrences.isEmpty else { return }
        let previous = Set(repository.occurrences.map(\.id))
        repository.update(available ? meetings : [], at: clock())
        removedOccurrences.formUnion(previous.subtracting(repository.occurrences.map(\.id)))
        if let active = activeRoom() { repository.joined(room: active, at: clock()) }
        changed()
    }
    func occurrence(for meeting: CalendarMeeting) -> ReminderOccurrence? {
        guard loaded else { return nil }
        if let found = existingOccurrence(for: meeting) { return found }
        // Per-occurrence settings can be edited before opting in, without granting permission.
        guard let occurrence = ReminderOccurrence(meeting: meeting) else { return nil }
        repository.occurrences.append(occurrence); _ = save(); return occurrence
    }
    func existingOccurrence(for meeting: CalendarMeeting) -> ReminderOccurrence? {
        repository.occurrences.first { $0.eventID == meeting.id ||
            $0.room == meeting.roomIdentity && $0.start == meeting.start && $0.end == meeting.end }
    }
    func override(for occurrence: ReminderOccurrence) -> ReminderOverride {
        repository.states[occurrence.id]?.override ?? .init(custom: profile.timing)
    }
    func setOverride(_ value: ReminderOverride, for occurrence: ReminderOccurrence) {
        repository.setOverride(value, id: occurrence.id); changed()
    }
    func joined(room: MeetingRoomIdentity, eventID: String? = nil) {
        guard !repository.occurrences.isEmpty else { return }
        repository.joined(room: room, eventID: eventID, at: clock()); changed()
    }
    func observe(_ jams: [ActiveJam], account: String?) {
        let previous = repository.states
        repository.observe(jams, account: account, now: clock())
        if repository.states != previous { changed() }
    }
    func open(reference: String, join: Bool) {
        if join, repository.pendingOpen != nil {
            repository.pendingOpen = nil; repository.pendingOpenDate = nil; _ = save()
        }
        hasOpenIntent = true
        opening?.cancel()
        opening = Task { [weak self] in
            guard let self else { return }
            let occurrence = await resolve(reference: reference)
            guard !Task.isCancelled else { return }
            onOpen(occurrence, join)
            hasOpenIntent = false
        }
    }
    func resolve(reference: String) async -> ReminderOccurrence? {
        hasOpenIntent = true
        defer { hasOpenIntent = false }
        let refreshed = await beforeOpen()
        guard refreshed, available, !Task.isCancelled else { return nil }
        return repository.occurrences.first { $0.reference == reference && $0.eligible &&
            (!$0.tentative || repository.states[$0.id]?.override?.mode == .custom) }
    }
    func foregroundReminder(reference: String, requestID: String, fingerprint: String) {
        guard let occurrence = repository.occurrences.first(where: { $0.reference == reference }),
              enabled, available, occurrence.eligible, occurrence.end > clock(),
              !occurrence.tentative || override(for: occurrence).mode == .custom,
              let planned = repository.scheduled.first(where: { $0.reference == reference && $0.id == requestID }),
              repository.states[occurrence.id]?.attended != true,
              repository.states[occurrence.id]?.remoteAccount == nil,
              repository.states[occurrence.id]?.skipped != true,
              repository.states[occurrence.id]?.override?.mode != .off else { return }
        let timing = override(for: occurrence).timing(profile: profile)
        guard let timing, (planned.phase == .snooze || planned.phase == .before && timing.before != nil ||
            planned.phase == .start && timing.atStart || planned.phase == .after && timing.followUp.mode == .always),
            ReminderNotification(plan: planned, occurrence: occurrence, profile: profile).fingerprint == fingerprint else { return }
        let event = ReminderForegroundEvent(plan: planned, scope: .system)
        guard repository.states[occurrence.id]?.presentation != event else { return }
        foregroundOffers[occurrence.id] = event
        refreshPresentation()

    }
    func action(reference: String, snooze: Bool, scope: ReminderDeliveryScope = .system) async {
        guard loaded else { return }
        var expectedSnooze: PlannedReminder?
        if snooze {
            guard enabled, await resolve(reference: reference) != nil else { deferCard(reference: reference); return }
            let pending = await notifications.pending()
            guard enabled, available, let occurrence = repository.occurrences.first(where: { $0.reference == reference && $0.eligible }),
                  override(for: occurrence).timing(profile: profile) != nil else { deferCard(reference: reference); return }
            let previousState = repository.states[occurrence.id]
            guard repository.snooze(reference: reference, now: clock(), scope: scope) else { deferCard(reference: reference); return }
            let foreign = pending.keys.filter { !$0.hasPrefix(PlannedReminder.namespace) }.count
            let plan = CalendarReminderPlanner.plan(occurrences: repository.occurrences, states: repository.states,
                profile: profile, now: clock(), budget: max(0, min(56, 64 - foreign)))
            guard repository.occurrences.contains(where: { $0.reference == reference }),
                  scope == .anotherMeeting || plan.contains(where: { $0.reference == reference && $0.phase == .snooze }) else {
                if let occurrence = repository.occurrences.first(where: { $0.reference == reference }) { repository.states[occurrence.id] = previousState }
                deferCard(reference: reference); error = L("Some reminders could not be scheduled. Try again."); return
            }
            if scope == .system { expectedSnooze = plan.first { $0.reference == reference && $0.phase == .snooze } }
        } else { repository.skip(reference: reference) }
        foregroundOffers = foregroundOffers.filter { $0.value.plan.reference != reference }
        changed() // Persist intent before any asynchronous notification operation.
        if let occurrence = repository.occurrences.first(where: { $0.reference == reference }) {
            await notifications.removeDelivered(occurrenceIDs: [occurrence.id])
        }
        await worker?.value
        if let expectedSnooze, expectedSnooze.date > clock() {
            let expectedRevision = revision
            let pending = await notifications.pending()
            guard expectedRevision == revision, expectedSnooze.date > clock(), enabled, available, let occurrence = repository.occurrences.first(where: { $0.reference == reference && $0.eligible }),
                  override(for: occurrence).timing(profile: profile) != nil,
                  !occurrence.tentative || override(for: occurrence).mode == .custom,
                  repository.states[occurrence.id]?.remoteAccount == nil,
                  repository.states[occurrence.id]?.snoozeScope != .anotherMeeting,
                  repository.states[occurrence.id]?.snooze == expectedSnooze.date,
                  repository.states[occurrence.id]?.attended != true, repository.states[occurrence.id]?.skipped != true else { return }
            let fingerprint = ReminderNotification(plan: expectedSnooze, occurrence: occurrence, profile: profile).fingerprint
            if pending[expectedSnooze.id] != fingerprint {
                repository.states[occurrence.id]?.snooze = nil; changed()
                deferCard(reference: reference)
            }
        }
    }
    private func deferCard(reference: String) {
        if canPresent() { open(reference: reference, join: false) }
        else {
            // A background Snooze action cannot dynamically activate a scene. Preserve its card for next open.
            repository.pendingOpen = reference; repository.pendingOpenDate = clock(); _ = save()
        }
    }
    /// One worker owns notification writes. Async completions are fenced by revisions and followed by a fresh pass.
    private func changed(refresh: Bool = true) {
        objectWillChange.send()
        revision += 1
        _ = save()
        if refresh { refreshPresentation() }
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let expected = revision
                await reconcile(expected: expected)
                if expected == revision { break }
            }
            worker = nil
        }
    }
    private func reconcile(expected: Int) async {
        guard loaded else {
            // Disabling must not depend on decoding protected occurrence data.
            guard !enabled else { return }
            let pending = await notifications.pending()
            guard expected == revision else { return }
            notifications.removePending(pending.keys.filter { $0.hasPrefix(PlannedReminder.namespace) })
            await notifications.removeAllDelivered()
            return
        }
        let permission = await notifications.authorization()
        guard expected == revision else { return }
        authorization = permission
        refreshPresentation()
        let pending = await notifications.pending()
        guard expected == revision else { return }
        let foreign = pending.keys.filter { !$0.hasPrefix(PlannedReminder.namespace) }.count
        let budget = max(0, min(56, 64 - foreign))
        let plans = enabled && available && permission == .allowed ? CalendarReminderPlanner.plan(
            occurrences: repository.occurrences, states: repository.states, profile: profile,
            now: clock(), budget: budget) : []
        let desired = plans.compactMap { plan -> ReminderNotification? in
            repository.occurrences.first { $0.id == plan.occurrenceID }.map {
                .init(plan: plan, occurrence: $0, profile: profile)
            }
        }
        let ids = Set(desired.map { $0.plan.id })
        let fingerprints = Dictionary(uniqueKeysWithValues: desired.map { ($0.plan.id, $0.fingerprint) })
        notifications.removePending(pending.keys.filter { $0.hasPrefix(PlannedReminder.namespace) && (!ids.contains($0) || fingerprints[$0] != pending[$0]) })
        let quiet = Set(repository.occurrences.filter {
            !enabled || !available || !$0.eligible || $0.end <= clock() || repository.states[$0.id]?.attended == true ||
                repository.states[$0.id]?.remoteAccount != nil || repository.states[$0.id]?.skipped == true ||
                repository.states[$0.id]?.override?.mode == .off
        }.map(\.id)).union(removedOccurrences)
        if enabled { await notifications.removeDelivered(occurrenceIDs: quiet) }
        else { await notifications.removeAllDelivered() }
        guard expected == revision else { return }
        // Retain accepted due phases until event expiry; OS callbacks can arrive after a boundary refresh.
        let due = repository.scheduled.filter { old in
            old.date <= clock() && !ids.contains(old.id) && repository.occurrences.contains {
                $0.id == old.occurrenceID && $0.reference == old.reference && $0.end.addingTimeInterval(86400) > clock()
            }
        }
        repository.scheduled = due + plans
        guard save() else { return } // Cancellation above is still safe when protected storage is unavailable.
        for reminder in desired where pending[reminder.plan.id] != reminder.fingerprint {
            do { try await notifications.add(reminder) }
            catch { self.error = L("Some reminders could not be scheduled. Try again."); return }
            if expected != revision {
                notifications.removePending([reminder.plan.id]); return
            }
        }
        let readback = await notifications.pending()
        guard expected == revision else { return }
        guard desired.allSatisfy({ $0.plan.date <= clock() || readback[$0.plan.id] == $0.fingerprint }) else {
            error = L("Some reminders could not be scheduled. Try again."); return
        }
        removedOccurrences = []; _ = save()
    }
    /// Called by the visible call host on layout/interaction/lifecycle changes, never a heartbeat.
    func refreshPresentation() {
        deadline?.cancel(); deadline = nil
        let snapshot = scene()
        let previous = repository.states
        for room in Set([lastSceneRoom, snapshot.room].compactMap { $0 }) { repository.joined(room: room, at: clock()) }
        lastSceneRoom = snapshot.room
        if repository.states != previous { changed(refresh: false) }
        if !snapshot.visible { onBackground() }
        var states = repository.states
        for (id, event) in foregroundOffers { states[id, default: .init()].presentation = event }
        let decision = ReminderForegroundPlanner.decide(occurrences: repository.occurrences, states: states,
            profile: profile, enabled: loaded && enabled && available && authorization == .allowed && permissionFresh,
            scene: snapshot, now: clock())
        for id in decision.invalidatedIDs { foregroundOffers[id] = nil; repository.states[id]?.presentation = nil }
        let mounted = onPresentation(decision.events)
        var didChange = false
        for event in decision.events where mounted.contains(event.id) {
            let id = event.plan.occurrenceID
            if repository.states[id]?.presentation != event {
                repository.states[id, default: .init()].presentation = event
                repository.states[id]?.consumed.insert(event.plan.phase)
                if event.plan.phase == .snooze { repository.states[id]?.snooze = nil }
                foregroundOffers[id] = nil; didChange = true
            }
        }
        if didChange { changed(refresh: false) }
        if let next = decision.nextDeadline, snapshot.visible {
            let delay = max(0.01, next.timeIntervalSince(clock()))
            deadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard !Task.isCancelled else { return }
                self?.refreshPresentation()
            }
        }
    }
    func backgrounded() {
        permissionEpoch += 1; permissionFresh = false; permissionRefresh?.cancel(); permissionRefresh = nil
        deadline?.cancel(); deadline = nil; onBackground(); _ = onPresentation([])
    }
    func wasPresented(_ event: ReminderForegroundEvent) -> Bool {
        repository.states[event.plan.occurrenceID]?.presentation == event
    }
    func occurrence(for event: ReminderForegroundEvent) -> ReminderOccurrence? {
        repository.occurrences.first { $0.reference == event.plan.reference && $0.id == event.plan.occurrenceID }
    }

    func waitForReconciliation() async { await permissionRefresh?.value; await worker?.value }

    func syncProfile(account: String?) {
        syncAccount = account
        cloudTask?.cancel()
        guard let account else { cloud = nil; observe([], account: nil); return }
        guard loaded else { return }
        cloud = cloud ?? ReminderProfileCloud()
        cloudTask = Task { [weak self] in
            guard let self, let cloud else { return }
            do {
                let session = try await cloud.session(account: account)
                guard !Task.isCancelled else { return }
                if repository.account != account || repository.cloudGeneration != session.generation {
                    repository.cloudAcknowledged = nil; repository.cloudGeneration = session.generation
                    if repository.profileAccount != nil && repository.profileAccount != account {
                        repository.profile.counter = 0; repository.profile.device = repository.device
                    }
                }
                repository.profileAccount = account
                let value = try await cloud.exchange(repository.profile, acknowledged: repository.cloudAcknowledged, session: session)
                guard !Task.isCancelled else { return }
                if repository.profile.precedes(value) || repository.cloudAcknowledged == nil && repository.profile.counter == 0 {
                    if profile.details && !value.value.details { removedOccurrences.formUnion(repository.occurrences.map(\.id)) }
                    repository.profile = value; profile = value.value
                }
                repository.cloudAcknowledged = value; changed()
            } catch { /* Preferences remain usable locally; the next existing sync pass retries. */ }
        }
    }
    func deleteCloudProfile() async throws {
        cloudTask?.cancel(); try await (cloud ?? ReminderProfileCloud()).delete()
        repository.cloudAcknowledged = nil; repository.cloudGeneration = nil; _ = save()
    }
}
