import ConferenceCore
import SwiftUI

struct HomeMeetingCard: View {
    let item: HomeMeeting
    let now: Date
    @ObservedObject var calendar: CalendarMeetingStore
    @ObservedObject var history: RoomHistoryStore
    @ObservedObject var continuation: MeetingContinuationCoordinator
    let busy: Bool
    let onJoin: (CalendarMeeting) -> Void
    let onStale: (ActiveJam) -> Void

    private var meeting: CalendarMeeting? {
        item.calendar.flatMap { value in calendar.upcoming.first { $0.id == value.id } }
    }
    private var source: ActiveJam? {
        item.handoff.flatMap { value in
            continuation.candidates.first { $0.deviceID == value.deviceID && $0.sessionID == value.sessionID && $0.isRecent(at: now) }
        }
    }
    private var title: String {
        meeting?.title ?? history.matching(item.invitation, engine: item.id.engine)?.alias ?? item.handoff?.title ?? item.calendar?.title ?? ""
    }
    private var roomAlias: String? {
        history.matching(item.invitation, engine: item.id.engine)?.alias.flatMap { $0 == title ? nil : $0 }
    }
    private var action: String {
        if let source { return source.isSharingScreen ? L("Move here and stop sharing") : L("Continue") }
        return item.handoff != nil ? L("Join here") : L("Join")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { description.frame(minWidth: 100, maxWidth: .infinity, alignment: .leading); actions }
                VStack(alignment: .leading, spacing: 4) {
                    description
                    HStack { joinButton; Spacer(minLength: 0); starButton }
                }
            }
            if let meeting {
                Text(CalendarMeetingPresentation.timeRange(meeting)).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("home.schedule." + meeting.id)
                Text([roomAlias, meeting.calendarTitle].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("home.calendar." + meeting.id)
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            if let meeting {
                Button(L("Choose another room")) { calendar.choosingMeeting = meeting }
                    .accessibilityIdentifier("calendar.choose-room." + meeting.id)
            }
            Button(L("Copy invitation")) { UIPasteboard.general.url = source?.invitation ?? meeting?.invitation ?? item.invitation }
            if let source, source.supportsCompanion {
                Button(L("Join as a second device")) { continuation.begin(source, companion: true) }.disabled(busy)
            }
        }
        .accessibilityAction(named: L("Choose another room")) {
            if let meeting { calendar.choosingMeeting = meeting }
        }
    }
    private var description: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let handoff = item.handoff {
                Label(source != nil ? L("Jam on %@", handoff.deviceLabel) : L("Recently active"),
                      systemImage: "laptopcomputer.and.iphone").font(.caption).foregroundStyle(.secondary)
            } else if let meeting {
                Label(HomeMeetingCard.timing(meeting, at: now), systemImage: "clock")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(L("Calendar event is no longer available.")).font(.caption).foregroundStyle(.secondary)
            }
            Text(title).font(.body.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            Label(item.id.displayDetails, systemImage: "link")
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                .accessibilityElement(children: .ignore).accessibilityLabel(item.id.displayDetails)
                .accessibilityIdentifier("home.room." + (item.calendar?.id ?? item.handoff?.deviceID ?? ""))
            if meeting?.tentative == true { Text(L("Tentative")).font(.caption).foregroundStyle(.secondary) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel([
            item.handoff.map { source != nil ? L("Jam on %@", $0.deviceLabel) : L("Recently active") } ??
                meeting.map { HomeMeetingCard.timing($0, at: now) } ?? "",
            title, item.id.displayDetails
        ].filter { !$0.isEmpty }.joined(separator: ". "))
        .accessibilityIdentifier("home.title." + (item.calendar?.id ?? item.handoff?.deviceID ?? ""))
    }
    private var actions: some View { HStack(spacing: 0) { joinButton; starButton }.fixedSize(horizontal: true, vertical: false) }
    private var joinButton: some View {
        Button {
            if let source { continuation.begin(source) }
            else if let handoff = item.handoff { onStale(handoff) }
            else if let meeting { onJoin(meeting) }
        } label: { Text(action).fixedSize(horizontal: false, vertical: true).frame(minHeight: 36) }
        .buttonStyle(.borderedProminent)
        .tint(Color(red: 1, green: 0.60, blue: 0.33)).foregroundStyle(.black)
        .disabled(busy || continuation.moving || (item.handoff == nil && meeting == nil))
        .accessibilityLabel(source.map { $0.isSharingScreen ? L("Move here and stop sharing") : L("Continue on this device") } ?? action)
        .accessibilityIdentifier(item.calendar.map { "calendar.join." + $0.id } ?? "handoff.join." + (item.handoff?.deviceID ?? ""))
    }
    private var starButton: some View {
        let favorite = history.matching(item.invitation, engine: item.id.engine)
        return Button {
            if let favorite, favorite.isStarred { history.toggleStar(favorite.invitationURL) }
            else { history.saveFavorite(url: source?.invitation ?? meeting?.invitation ?? item.invitation,
                                        title: title, engine: item.id.engine) }
        } label: {
            Image(systemName: favorite?.isStarred == true ? "star.fill" : "star").frame(width: 44, height: 44)
        }.buttonStyle(.borderless)
        .accessibilityLabel(favorite?.isStarred == true ? L("Unstar %@", title) : L("Star %@", title))
        .accessibilityIdentifier(item.calendar.map { "calendar.star." + $0.id } ?? "handoff.star." + (item.handoff?.deviceID ?? ""))
    }
    static func timing(_ meeting: CalendarMeeting, at now: Date) -> String {
        meeting.isScheduledNow(now) ? L("Scheduled now") :
            L("Starts in %ld min", max(1, Int(ceil(meeting.start.timeIntervalSince(now) / 60))))
    }
}

enum CalendarMeetingPresentation {
    static func timeRange(_ meeting: CalendarMeeting) -> String {
        let start = meeting.start.formatted(date: .abbreviated, time: meeting.allDay ? .omitted : .shortened)
        if meeting.allDay { return start + " · " + L("All day") }
        let end = meeting.end.formatted(date: Calendar.current.isDate(meeting.start, inSameDayAs: meeting.end) ? .omitted : .abbreviated,
                                        time: .shortened)
        return start + " – " + end
    }
    static func subtitle(_ meeting: CalendarMeeting, at now: Date, roomTitle: String) -> String {
        let timing = meeting.isScheduledNow(now) ? L("Scheduled now") : L("Upcoming")
        return ([timing + " · " + timeRange(meeting)] +
                (meeting.title == roomTitle ? [] : [meeting.title]) +
                (meeting.calendarTitle.isEmpty ? [] : [meeting.calendarTitle])).joined(separator: "\n")
    }
}

struct HomeTopPreference: PreferenceKey {
    static var defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        if let next = nextValue() { value = next }
    }
}
