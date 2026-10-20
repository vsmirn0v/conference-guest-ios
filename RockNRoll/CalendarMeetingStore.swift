import Combine
import ConferenceCore
import EventKit
import Foundation

@MainActor
final class CalendarMeetingStore: ObservableObject {
    @Published private(set) var enabled: Bool
    @Published private(set) var automaticJoin: Bool
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
         reminders: CalendarReminderCoordinator? = nil) {
        self.reader = reader; self.detector = detector; self.preferences = preferences; self.storage = storage
        self.reminders = reminders ?? (preferences === UserDefaults.standard ? CalendarReminderBroker.shared.sharedCoordinator : CalendarReminderCoordinator(preferences: preferences))
        enabled = preferences.bool(forKey: "calendarMeetings.enabled")
        automaticJoin = preferences.bool(forKey: "calendarMeetings.automaticJoin")
        selected = Set(preferences.stringArray(forKey: "calendarMeetings.selected") ?? [])
        state = storage.read().flatMap { try? JSONDecoder().decode(LocalState.self, from: $0) } ?? .init()
        self.reminders.onNeedsSnapshot = { [weak self] in self?.refresh() }
        self.reminders.onEditing = { [weak self] in self?.cancelAutomaticJoin(suppress: true) }
        self.reminders.beforeOpen = { [weak self] in await self?.refreshForReminder() ?? false }
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.calendarDidChange() }
        }
    }
    deinit {
        task?.cancel(); boundaryTask?.cancel(); countdownTask?.cancel(); notificationTask?.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func setEnabled(_ value: Bool) {
        enabled = value; preferences.set(value, forKey: "calendarMeetings.enabled")
        if !value {
            revision = UUID(); task?.cancel(); task = nil; loading = false
            boundaryTask?.cancel(); cancelAutomaticJoin(); meetings = []; calendars = []
            state.visits = [:]; persist()
            updateReminders()
        } else { refresh(requestPermission: true) }
    }
    func setAutomaticJoin(_ value: Bool) {
        automaticJoin = value; preferences.set(value, forKey: "calendarMeetings.automaticJoin")
        cancelAutomaticJoin(); automaticEntry = false
    }
    func select(_ id: String, included: Bool) {
        if included { selected.insert(id) } else { selected.remove(id) }
        meetings.removeAll { !selected.contains($0.calendarID) }
        preferences.set(selected.sorted(), forKey: "calendarMeetings.selected")
        state.visits = [:]; persist(); cancelAutomaticJoin(); refresh()
        updateReminders()
    }
    func foregrounded(allowAutomaticJoin: Bool) {
        foreground = true; automaticEntry = allowAutomaticJoin
        reminders.foregrounded()
        refresh()
    }
    func backgrounded() {
        foreground = false; automaticEntry = false
        task?.cancel(); revision = UUID(); loading = false
        boundaryTask?.cancel(); notificationTask?.cancel(); cancelAutomaticJoin()
    }
    func calendarDidChange() {
        guard enabled, foreground || reminders.enabled else { return }
        cancelAutomaticJoin()
        notificationTask?.cancel()
        notificationTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            self?.notificationTask = nil; self?.refresh()
        }
    }
    func refresh(requestPermission: Bool = false) {
        guard enabled else { return }
        task?.cancel(); cancelAutomaticJoin()
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
                now = Date(); loading = false; task = nil
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
    func cancelAutomaticJoin(suppress: Bool = false) {
        if suppress, let meeting = joiningMeeting { state.suppressed[meeting.id] = meeting.end; persist() }
        countdownTask?.cancel(); countdownTask = nil; countdown = nil; joiningMeeting = nil
    }
    func suppressAutomaticJoin(for meeting: CalendarMeeting) {
        state.suppressed[meeting.id] = meeting.end; persist()
        cancelAutomaticJoin()
    }
    private func considerAutomaticJoin() {
        defer { automaticEntry = false }
        guard foreground, automaticEntry, automaticJoin,
              let meeting = CalendarAutoJoinPolicy.candidate(in: meetings, at: now, suppressed: Set(state.suppressed.keys)),
              canAutomaticallyJoin(meeting) else { return }
        joiningMeeting = meeting; countdown = 5
        countdownTask = Task { [weak self] in
            for remaining in stride(from: 5, through: 1, by: -1) {
                guard let self, self.foreground, self.canAutomaticallyJoin(meeting) else { self?.cancelAutomaticJoin(); return }
                self.countdown = remaining
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
            guard let self, self.foreground, self.canAutomaticallyJoin(meeting),
                  CalendarAutoJoinPolicy.candidate(in: self.meetings, at: Date(), suppressed: Set(self.state.suppressed.keys))?.id == meeting.id else { return }
            self.state.suppressed[meeting.id] = meeting.end; self.persist()
            self.cancelAutomaticJoin(); self.automaticEntry = false
            self.onAutomaticJoin(meeting)
        }
    }
    private func scheduleBoundary() {
        boundaryTask?.cancel()
        guard foreground else { return }
        let dates = meetings.flatMap { [$0.start.addingTimeInterval(-900),
            $0.start.addingTimeInterval(-HomeMeetingPolicy.soonInterval), $0.start, $0.end] }.filter { $0 > now }
        let delay = min(300, max(1, dates.min()?.timeIntervalSince(now) ?? 300))
        boundaryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self else { return }
            let previous = self.now; self.now = Date()
            if Calendar.current.isDate(previous, inSameDayAs: self.now) { self.updateReminders(); self.scheduleBoundary() }
            else { self.refresh() }
        }
    }
    private func persist() {
        do { try storage.write(JSONEncoder().encode(state)) }
        catch { self.error = L("Calendar choices are not saved yet. Try again.") }
    }
}
