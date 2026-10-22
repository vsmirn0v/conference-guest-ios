import Combine
import ConferenceCore
import EventKit
import Foundation

enum CalendarAutomaticJoinMode: String, CaseIterable {
    case off, whenOpening, scheduled
    var title: String {
        switch self {
        case .off: return L("Off")
        case .whenOpening: return L("When I open the app")
        case .scheduled: return L("At scheduled time on this Mac")
        }
    }
}

@MainActor
final class CalendarMeetingStore: ObservableObject {
    @Published private(set) var enabled: Bool
    @Published private(set) var automaticJoin: Bool
    @Published private(set) var automaticJoinMode: CalendarAutomaticJoinMode
    @Published private(set) var keepInMenuBar: Bool
    @Published private(set) var automaticJoinPausedUntil: Date?
    @Published private(set) var selected: Set<String>
    @Published private(set) var calendars: [MeetingCalendar] = []
    @Published private(set) var meetings: [CalendarMeeting] = []
    @Published private(set) var access: CalendarAccess = .notDetermined
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var now = Date()
    @Published private(set) var countdown: Int?
    @Published private(set) var joiningMeeting: CalendarMeeting?
    @Published var choosingMeeting: CalendarMeeting? {
        didSet { if choosingMeeting != nil { cancelAutomaticJoin(suppress: true) } }
    }
    var knownOrigins: () -> Set<String> = { [] }
    var aliases: () -> [String: URL] = { [:] }
    var invitationNormalizer: (URL) -> URL? = { (try? JoinTarget.parse($0.absoluteString))?.invitationURL }
    var knownEngine: (URL) -> MeetingEngineKind? = { _ in nil }
    var canAutomaticallyJoin: (CalendarMeeting) -> Bool = { _ in false }
    var onAutomaticJoin: (CalendarMeeting) -> Void = { _ in }
    var onScheduledJoin: (CalendarMeeting) -> Void = { _ in }
    var onScheduledActivity: (Date?) -> Void = { _ in }
    var onScheduledInvalidation: () -> Void = {}
    var schedulingIsAvailable: () -> Bool = { true }
    @Published var showingMacSettings = false {
        didSet { if showingMacSettings { cancelAutomaticJoin(suppress: true) } }
    }
    var supportsScheduledJoining: Bool { isMac }
    let reminders: CalendarReminderCoordinator
    private let preferences: UserDefaults
    private let storage: any RoomHistoryStorage
    private let reader: any CalendarReading
    private let detector: MeetingEngineDetector
    private var task: Task<Void, Never>?
    private var boundaryTask: Task<Void, Never>?
    private var countdownTask: Task<Void, Never>?
    private var notificationTask: Task<Void, Never>?
    private var revision = UUID()
    private var completedRevision: UUID?
    private var foreground = false
    private var automaticEntry = false
    private let isMac: Bool
    private var schedulingAvailable = false
    private var armedAfter = Date()
    private var admissionRevision = UUID()
    private var scheduledTransportPreparing = false
    private var scheduledUIBlocked = false
    private let clock: () -> Date
    private let countdownInterval: Duration
    private var observer: NSObjectProtocol?
    private struct LocalState: Codable {
        var bindings: [String: URL] = [:]
        var suppressed: [String: Date] = [:]
        var visits: [String: Visit] = [:]
    }
    private struct Visit: Codable { let title: String; let start: Date; let end: Date }
    private var state: LocalState

    init(reader: any CalendarReading = AppleCalendarReader(), detector: MeetingEngineDetector,
         preferences: UserDefaults = .standard,
         storage: any RoomHistoryStorage = KeychainRoomHistoryStorage(service: "dev.vsmirn0v.conferenceguest.calendar"),
         reminders: CalendarReminderCoordinator? = nil,
         isMac: Bool = ProcessInfo.processInfo.isiOSAppOnMac,
         clock: @escaping () -> Date = Date.init, countdownInterval: Duration = .seconds(1)) {
        self.reader = reader; self.detector = detector; self.preferences = preferences; self.storage = storage
        self.isMac = isMac; self.clock = clock; self.countdownInterval = countdownInterval
        self.reminders = reminders ?? (preferences === UserDefaults.standard ? CalendarReminderBroker.shared.sharedCoordinator : CalendarReminderCoordinator(preferences: preferences))
        enabled = preferences.bool(forKey: "calendarMeetings.enabled")
        let savedMode = preferences.string(forKey: "calendarMeetings.automaticJoinMode").flatMap(CalendarAutomaticJoinMode.init(rawValue:))
        let mode = savedMode ?? (preferences.bool(forKey: "calendarMeetings.automaticJoin") ? .whenOpening : .off)
        let availableMode = mode == .scheduled && !isMac ? CalendarAutomaticJoinMode.off : mode
        automaticJoinMode = availableMode
        automaticJoin = availableMode != .off
        keepInMenuBar = isMac && (preferences.bool(forKey: "calendarMeetings.keepInMenuBar") || availableMode == .scheduled)
        automaticJoinPausedUntil = preferences.object(forKey: "calendarMeetings.pausedUntil") as? Date
        armedAfter = clock()
        selected = Set(preferences.stringArray(forKey: "calendarMeetings.selected") ?? [])
        state = storage.read().flatMap { try? JSONDecoder().decode(LocalState.self, from: $0) } ?? .init()
        self.reminders.onNeedsSnapshot = { [weak self] in self?.refresh() }
        self.reminders.onEditing = { [weak self] in self?.cancelAutomaticJoin(suppress: true) }
        self.reminders.beforeOpen = { [weak self] in await self?.refreshForReminder() ?? false }
        self.reminders.onSkip = { [weak self] eventID in
            guard let self, let meeting = self.meetings.first(where: { $0.id == eventID }) else { return }
            self.suppressAutomaticJoin(for: meeting)
        }
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.calendarDidChange() }
        }
    }
    deinit {
        task?.cancel(); boundaryTask?.cancel(); countdownTask?.cancel(); notificationTask?.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func setEnabled(_ value: Bool) {
        invalidateScheduledAdmission()
        enabled = value; preferences.set(value, forKey: "calendarMeetings.enabled")
        if !value {
            revision = UUID(); task?.cancel(); task = nil; loading = false
            boundaryTask?.cancel(); cancelAutomaticJoin(); meetings = []; calendars = []
            state.visits = [:]; persist()
            updateReminders()
        } else { armedAfter = clock(); refresh(requestPermission: true) }
    }
    func setAutomaticJoin(_ value: Bool) {
        setAutomaticJoinMode(value ? .whenOpening : .off)
    }
    func setAutomaticJoinMode(_ value: CalendarAutomaticJoinMode) {
        guard value != .scheduled || isMac else { return }
        automaticJoinMode = value; automaticJoin = value != .off
        preferences.set(value.rawValue, forKey: "calendarMeetings.automaticJoinMode")
        preferences.set(value == .whenOpening, forKey: "calendarMeetings.automaticJoin")
        if value == .scheduled { setKeepInMenuBar(true) }
        invalidateScheduledAdmission(); cancelAutomaticJoin(); automaticEntry = false; armedAfter = clock()
        scheduleBoundary()
    }
    func setKeepInMenuBar(_ value: Bool) {
        keepInMenuBar = value || automaticJoinMode == .scheduled
        preferences.set(keepInMenuBar, forKey: "calendarMeetings.keepInMenuBar")
    }
    func pauseScheduledJoiningToday() {
        invalidateScheduledAdmission()
        automaticJoinPausedUntil = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: clock()))
        preferences.set(automaticJoinPausedUntil, forKey: "calendarMeetings.pausedUntil")
        cancelAutomaticJoin(); scheduleBoundary()
    }
    func resumeScheduledJoining() {
        automaticJoinPausedUntil = nil; preferences.removeObject(forKey: "calendarMeetings.pausedUntil")
        armedAfter = clock(); scheduleBoundary()
    }
    /// Focus and window visibility never determine whether this Mac may run a schedule.
    func setSchedulingAvailable(_ available: Bool, resetEligibility: Bool = false) {
        guard isMac else { return }
        if schedulingAvailable != available || resetEligibility {
            invalidateScheduledAdmission(); schedulingAvailable = available; armedAfter = clock(); cancelAutomaticJoin()
            if available { refresh() } else { boundaryTask?.cancel(); onScheduledActivity(nil) }
        }
    }
    var scheduledJoiningEnabled: Bool {
        isMac && enabled && automaticJoinMode == .scheduled &&
            (automaticJoinPausedUntil.map { $0 <= clock() } ?? true)
    }
    func setScheduledUIBlocked(_ blocked: Bool) {
        guard isMac, scheduledUIBlocked != blocked else { return }
        scheduledUIBlocked = blocked
        if blocked { invalidateScheduledAdmission(); cancelAutomaticJoin(suppress: true) }
    }
    var nextScheduledMeeting: CalendarMeeting? {
        upcoming.filter { !$0.allDay && !$0.tentative && $0.start >= clock() }
            .min { $0.start < $1.start }
    }
    func automaticJoinSuppressed(_ meeting: CalendarMeeting) -> Bool {
        state.suppressed[meeting.id] != nil || reminders.skipped(meeting)
    }
    func pauseAutomaticJoin() {
        automaticEntry = false; cancelAutomaticJoin()
    }
    func select(_ id: String, included: Bool) {
        invalidateScheduledAdmission()
        if included { selected.insert(id) } else { selected.remove(id) }
        meetings.removeAll { !selected.contains($0.calendarID) }
        preferences.set(selected.sorted(), forKey: "calendarMeetings.selected")
        state.visits = [:]; persist(); cancelAutomaticJoin(); armedAfter = clock(); refresh()
        updateReminders()
    }
    func foregrounded(allowAutomaticJoin: Bool) {
        foreground = true; automaticEntry = allowAutomaticJoin
        reminders.foregrounded()
        if automaticJoinMode == .scheduled, joiningMeeting != nil { return }
        refresh()
    }
    func backgrounded() {
        foreground = false; automaticEntry = false
        if automaticJoinMode == .scheduled && schedulingAvailable {
            if joiningMeeting == nil { scheduleBoundary() }
            return
        }
        task?.cancel(); revision = UUID(); loading = false
        boundaryTask?.cancel(); notificationTask?.cancel(); cancelAutomaticJoin()
    }
    func calendarDidChange() {
        guard enabled, foreground || reminders.enabled || scheduledJoiningEnabled && schedulingAvailable else { return }
        invalidateScheduledAdmission()
        cancelAutomaticJoin()
        notificationTask?.cancel()
        notificationTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            self?.notificationTask = nil; self?.refresh()
        }
    }
    func refresh(requestPermission: Bool = false) {
        guard enabled else { return }
        task?.cancel(); cancelAutomaticJoin(preservingActivity: scheduledTransportPreparing || preparingScheduledMeeting != nil)
        if let meeting = preparingScheduledMeeting { onScheduledActivity(meeting.start.addingTimeInterval(15)) }
        let token = UUID(); revision = token; loading = true; error = nil
        task = Task { [weak self] in
            guard let self else { return }
            do {
                var authorization = await reader.access()
                if requestPermission, authorization == .notDetermined {
                    _ = try await reader.requestAccess(); authorization = await reader.access()
                }
                guard !Task.isCancelled, revision == token else { return }
                access = authorization
                guard authorization == .allowed else {
                    meetings = []; calendars = []; loading = false; state.visits = [:]; persist(); updateReminders(); return
                }
                let snapshot = await reader.read(selected: selected, now: Date(), knownOrigins: knownOrigins(), aliases: aliases())
                guard !Task.isCancelled, revision == token else { return }
                calendars = snapshot.calendars
                // Removed calendars and new accounts never silently widen selection.
                let available = Set(calendars.map(\.id))
                selected.formIntersection(available)
                if meetings.contains(where: { !selected.contains($0.calendarID) }) {
                    meetings.removeAll { !selected.contains($0.calendarID) }
                }
                preferences.set(selected.sorted(), forKey: "calendarMeetings.selected")
                var incoming = snapshot.meetings.filter { selected.contains($0.calendarID) }
                let candidateGroups = incoming.map { meeting -> [[URL]] in
                    if let bound = state.bindings[meeting.id] ?? state.bindings[meeting.seriesID] { return [[bound]] }
                    var seen: Set<MeetingRoomIdentity> = []
                    return meeting.linkGroups.map { group in
                        group.links.compactMap(invitationNormalizer).filter {
                            guard let key = MeetingRoomIdentity($0) else { return false }
                            return seen.insert(key).inserted
                        }
                    }
                }
                // Keep the resolved snapshot until the whole refresh is ready.
                let proofs = await probe(candidateGroups.flatMap { $0.flatMap { $0 } })
                guard !Task.isCancelled, revision == token else { return }
                for index in incoming.indices {
                    for group in candidateGroups[index] {
                        var unresolvedConflict = false
                        let supported = group.compactMap { url -> (URL, MeetingEngineKind)? in
                            let kind: MeetingEngineKind?
                            switch proofs[self.probeKey(url)] ?? .unknown {
                            case .verified(.guest): kind = .guest
                            case .verified(.community): kind = .community
                            case .verified(.telemost): kind = .telemost
                            case .verified(.trueconf): kind = .trueconf
                            case .ambiguous:
                                kind = self.knownEngine(url)
                                unresolvedConflict = unresolvedConflict || kind == nil
                            case .unknown: kind = self.knownEngine(url)
                            }
                            return kind.map { (url, $0) }
                        }
                        if unresolvedConflict || supported.count > 1 { incoming[index].requiresChoice = true; break }
                        if let (url, kind) = supported.first {
                            incoming[index].invitation = url; incoming[index].engine = kind; break
                        }
                    }
                }
                // Deduplicate identical copies without collapsing different events in one room.
                var seen: Set<CalendarCopy> = []
                meetings = incoming.filter { seen.insert(CalendarCopy($0)).inserted }
                now = clock(); loading = false; task = nil
                let retained = state.suppressed.filter { $0.value > now }
                if retained != state.suppressed { state.suppressed = retained; persist() }
                completedRevision = token
                updateReminders(); scheduleBoundary(); considerAutomaticJoin()
            } catch {
                guard !Task.isCancelled, revision == token else { return }
                self.error = L("Calendar access could not be completed. Try again."); loading = false
            }
        }
    }
    private func updateReminders() {
        reminders.update(meetings: meetings, available: enabled && access == .allowed && !selected.isEmpty)
    }
    private func refreshForReminder() async -> Bool {
        automaticEntry = false; cancelAutomaticJoin(); refresh()
        for _ in 0..<2 {
            let token = revision
            await task?.value
            if revision != token { continue }
            return completedRevision == token && enabled && access == .allowed && !loading && error == nil
        }
        return false
    }
    private struct CalendarCopy: Hashable {
        let title: String; let start: Date; let end: Date; let links: [URL]
        init(_ meeting: CalendarMeeting) {
            title = meeting.title; start = meeting.start; end = meeting.end
            links = (meeting.invitation.map { [$0] } ?? meeting.links).sorted { $0.absoluteString < $1.absoluteString }
        }
    }
    private func probeKey(_ url: URL) -> URL {
        if (try? TrueConfTarget.parse(url.absoluteString)) != nil { return url }
        if (try? JamTarget.parseCompatibleInvitation(url.absoluteString)) != nil { return url }
        return (try? JoinTarget.parse(url.absoluteString))?.originURL ?? url
    }
    private func probe(_ invitations: [URL]) async -> [URL: MeetingEngineDetection] {
        var unique: [URL: URL] = [:]
        for url in invitations { unique[probeKey(url)] = url }
        let requests = Array(unique.sorted { $0.key.absoluteString < $1.key.absoluteString }.prefix(32))
        let detector = self.detector
        return await withTaskGroup(of: (URL, MeetingEngineDetection).self) { group in
            var iterator = requests.makeIterator()
            func add(_ entry: (key: URL, value: URL)) {
                group.addTask { (entry.key, (try? await detector.detect(entry.value)) ?? .unknown) }
            }
            for _ in 0..<4 { if let entry = iterator.next() { add(entry) } }
            var result: [URL: MeetingEngineDetection] = [:]
            while let entry = await group.next() {
                result[entry.0] = entry.1
                if !Task.isCancelled, let next = iterator.next() { add(next) }
            }
            return result
        }
    }

    var upcoming: [CalendarMeeting] { meetings.filter { $0.end > now && $0.hasResolvedInvitation } }
    var next: CalendarMeeting? {
        let timely = upcoming.filter { $0.isTimely(now) }
        return timely.count == 1 ? timely[0] : nil
    }
    func bind(_ meeting: CalendarMeeting, to url: URL, series: Bool) {
        guard let url = invitationNormalizer(url) else { return }
        state.bindings[series ? meeting.seriesID : meeting.id] = url
        if series { state.bindings.removeValue(forKey: meeting.id) }
        persist(); choosingMeeting = nil; refresh()
    }
    func forgetBindings() { state.bindings = [:]; persist(); refresh() }
    private func meeting(matching invitation: URL, engine: MeetingEngineKind?, in candidates: [CalendarMeeting]) -> CalendarMeeting? {
        candidates.first { candidate in
            candidate.hasResolvedInvitation &&
                MeetingRoomIdentity(invitation, engine: engine ?? candidate.engine) == candidate.roomIdentity
        }
    }
    func subtitle(for room: RecentRoom) -> String? {
        guard enabled, access == .allowed else { return nil }
        if let meeting = meeting(matching: room.joinURL, engine: room.engine, in: upcoming) {
            return CalendarMeetingPresentation.subtitle(meeting, at: now, roomTitle: room.displayTitle)
        }
        if let visit = state.visits[room.id] {
            return L("Scheduled: %@ · %@", visit.start.formatted(date: .abbreviated, time: .shortened), visit.title)
        }
        return nil
    }
    func timing(for room: RecentRoom) -> String? {
        guard enabled, access == .allowed else { return nil }
        if let meeting = meeting(matching: room.joinURL, engine: room.engine, in: upcoming) {
            return CalendarMeetingPresentation.timeRange(meeting)
        }
        return state.visits[room.id].map { $0.start.formatted(date: .abbreviated, time: .shortened) }
    }
    func noteJoined(_ room: RecentRoom, invitation: URL) {
        guard let meeting = meeting(matching: invitation, engine: room.engine,
                                    in: meetings.filter { $0.isScheduledNow(Date()) }) else { return }
        state.visits[room.id] = Visit(title: meeting.title, start: meeting.start, end: meeting.end)
        state.suppressed[meeting.id] = meeting.end
        persist()
    }
    func preferredInvitation(for room: RecentRoom) -> URL {
        meeting(matching: room.joinURL, engine: room.engine, in: upcoming)?.invitation ?? room.joinURL
    }
    func preferredEngine(for room: RecentRoom) -> MeetingEngineKind? {
        meeting(matching: room.joinURL, engine: room.engine, in: upcoming)?.engine ?? room.engine
    }
    func cancelAutomaticJoin(suppress: Bool = false, preservingActivity: Bool = false) {
        if suppress { invalidateScheduledAdmission() }
        if suppress, let meeting = joiningMeeting { state.suppressed[meeting.id] = meeting.end; persist() }
        countdownTask?.cancel(); countdownTask = nil; countdown = nil; joiningMeeting = nil
        if !preservingActivity { finishScheduledTransportPreparation() }
    }
    func suppressAutomaticJoin(for meeting: CalendarMeeting) {
        invalidateScheduledAdmission()
        state.suppressed[meeting.id] = meeting.end; persist()
        cancelAutomaticJoin()
        scheduleBoundary()
    }
    private func considerAutomaticJoin() {
        defer { automaticEntry = false }
        let scheduled = automaticJoinMode == .scheduled
        guard scheduled ? automaticJoinAllowed(scheduled: true) : foreground && automaticEntry && automaticJoin,
              let meeting = automaticCandidate(at: now, scheduled: scheduled),
              canAutomaticallyJoin(meeting) else { return }
        joiningMeeting = meeting; countdown = 5
        if scheduled { onScheduledActivity(meeting.start.addingTimeInterval(15)) }
        countdownTask = Task { [weak self] in
            for remaining in stride(from: 5, through: 1, by: -1) {
                guard let self, self.automaticJoinAllowed(scheduled: scheduled), self.canAutomaticallyJoin(meeting) else { self?.cancelAutomaticJoin(); return }
                self.countdown = remaining
                do { try await Task.sleep(for: self.countdownInterval) } catch { return }
            }
            guard let self else { return }
            guard self.automaticJoinAllowed(scheduled: scheduled), self.canAutomaticallyJoin(meeting),
                  self.automaticCandidate(at: self.clock(), scheduled: scheduled)?.id == meeting.id else { self.cancelAutomaticJoin(); return }
            self.state.suppressed[meeting.id] = meeting.end; self.persist()
            self.scheduledTransportPreparing = scheduled
            self.cancelAutomaticJoin(preservingActivity: scheduled); self.automaticEntry = false
            if scheduled { self.onScheduledJoin(meeting) } else { self.onAutomaticJoin(meeting) }
            self.scheduleBoundary()
        }
    }
    private func automaticJoinAllowed(scheduled: Bool) -> Bool {
        scheduled ? scheduledJoiningEnabled && schedulingAvailable && schedulingIsAvailable() && !scheduledUIBlocked && !showingMacSettings && reminders.editing == nil : foreground && automaticJoinMode == .whenOpening
    }
    func scheduledTransportAdmission(for meeting: CalendarMeeting) -> () -> Bool {
        let revision = admissionRevision
        return { [weak self] in
            guard let self else { return false }
            return self.admissionRevision == revision && self.automaticJoinAllowed(scheduled: true) &&
                self.meetings.first(where: { $0.id == meeting.id }) == meeting && meeting.start >= self.armedAfter &&
                (0...15).contains(self.clock().timeIntervalSince(meeting.start)) && !self.reminders.skipped(meeting) &&
                self.meetings.filter { !$0.allDay && !$0.tentative && $0.start <= self.clock() && $0.end > self.clock() }.count == 1
        }
    }
    func finishScheduledTransportPreparation() {
        scheduledTransportPreparing = false; onScheduledActivity(nil)
    }
    private func invalidateScheduledAdmission() {
        admissionRevision = UUID(); onScheduledInvalidation()
    }
    private var preparingScheduledMeeting: CalendarMeeting? {
        guard automaticJoinAllowed(scheduled: true) else { return nil }
        return meetings.first { $0.hasResolvedInvitation && !$0.allDay && !$0.tentative &&
            $0.start >= armedAfter && (-10...30).contains($0.start.timeIntervalSince(clock())) &&
            !state.suppressed.keys.contains($0.id) && !reminders.skipped($0) }
    }
    private func automaticCandidate(at date: Date, scheduled: Bool) -> CalendarMeeting? {
        if !scheduled { return CalendarAutoJoinPolicy.candidate(in: meetings, at: date, suppressed: Set(state.suppressed.keys)) }
        let overlapping = meetings.filter { !$0.allDay && !$0.tentative && $0.start <= date && $0.end > date }
        guard overlapping.count == 1, let meeting = overlapping.first,
              meeting.hasResolvedInvitation, meeting.start >= armedAfter,
              date.timeIntervalSince(meeting.start) <= 10, !state.suppressed.keys.contains(meeting.id),
              !reminders.skipped(meeting) else { return nil }
        return meeting
    }
    private func scheduleBoundary() {
        boundaryTask?.cancel()
        let scheduled = isMac && enabled && automaticJoinMode == .scheduled && schedulingAvailable
        guard foreground || scheduled else { finishScheduledTransportPreparation(); return }
        let current = clock()
        var dates = meetings.flatMap { [$0.start.addingTimeInterval(-900),
            $0.start.addingTimeInterval(-HomeMeetingPolicy.soonInterval), $0.start, $0.end] }.filter { $0 > now }
        if scheduled {
            dates = meetings.flatMap { [$0.start.addingTimeInterval(-30), $0.start, $0.end] }.filter { $0 > current }
            if let midnight = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: current)) { dates.append(midnight) }
        }
        let delay = max(0.05, scheduled ? dates.min()?.timeIntervalSince(current) ?? 300 : min(300, dates.min()?.timeIntervalSince(current) ?? 300))
        if joiningMeeting == nil && !scheduledTransportPreparing {
            onScheduledActivity(scheduled ? preparingScheduledMeeting?.start.addingTimeInterval(15) : nil)
        }
        boundaryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self else { return }
            let previous = self.now; self.now = self.clock()
            if scheduled { self.refresh(); return }
            if Calendar.current.isDate(previous, inSameDayAs: self.now) { self.updateReminders(); self.scheduleBoundary() }
            else { self.refresh() }
        }
    }
    private func persist() {
        do { try storage.write(JSONEncoder().encode(state)) }
        catch { self.error = L("Calendar choices are not saved yet. Try again.") }
    }
}
