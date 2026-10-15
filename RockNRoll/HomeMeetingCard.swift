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
    @Environment(\.dynamicTypeSize) private var textSize
    @ScaledMetric(relativeTo: .body) private var titleHeight = 23.0
    @ScaledMetric(relativeTo: .caption) private var detailHeight = 17.0
    private var lines: Int { textSize.isAccessibilitySize ? 2 : 1 }

    private var meeting: CalendarMeeting? {
        guard calendar.enabled, calendar.access == .allowed,
              let meeting = item.currentCalendar(in: calendar.upcoming),
              calendar.selected.contains(meeting.calendarID), meeting.end > Date() else { return nil }
        return meeting
    }
    private var source: ActiveJam? {
        item.currentHandoff(in: continuation.candidates, at: Date())
    }
    private var title: String {
        item.calendar?.title ?? history.matching(item.invitation, engine: item.id.engine)?.alias ?? item.handoff?.title ?? ""
    }
    private var roomAlias: String? {
        history.matching(item.invitation, engine: item.id.engine)?.alias.flatMap { $0 == title ? nil : $0 }
    }
    private var action: String {
        if item.handoff != nil { return source == nil ? L("Join here") : L("Move here") }
        return L("Join")
    }
    var body: some View {
        Group {
            if item.handoff != nil {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 8) {
                        description.frame(maxWidth: .infinity, alignment: .leading)
                        starButton
                    }
                    if textSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 8) { handoffButtons }
                    } else {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 12) { handoffButtons }.fixedSize(horizontal: true, vertical: false)
                            VStack(alignment: .leading, spacing: 8) { handoffButtons }
                        }
                    }
                }
            } else if textSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    description
                    HStack { joinButton; Spacer(); starButton }
                }
            } else {
                HStack(spacing: 8) {
                    description.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(spacing: 0) { joinButton; starButton }.frame(width: 92)
                }
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
    @ViewBuilder private var handoffButtons: some View {
        joinButton
        if let source { joinHereButton(source) }
    }
    private var description: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.body.weight(.semibold)).lineLimit(lines)
                .frame(height: titleHeight * Double(lines), alignment: .leading)
            Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                .frame(height: detailHeight * 2, alignment: .leading)
                .accessibilityIdentifier("home.schedule." + (item.calendar?.id ?? ""))
            Label(item.id.displayDetails, systemImage: "link")
                .font(.caption).foregroundStyle(.secondary).lineLimit(lines)
                .frame(height: detailHeight * Double(lines), alignment: .leading)
                .accessibilityElement(children: .ignore).accessibilityLabel(item.id.displayDetails)
                .accessibilityIdentifier("home.room." + (item.calendar?.id ?? item.handoff?.deviceID ?? ""))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel([
            status,
            title, item.id.displayDetails,
            item.calendar.map { CalendarMeetingPresentation.subtitle($0, at: now, roomTitle: title) } ?? "",
            roomAlias ?? ""
        ].filter { !$0.isEmpty }.joined(separator: ". "))
        .accessibilityIdentifier("home.title." + (item.calendar?.id ?? item.handoff?.deviceID ?? ""))
    }
    private var status: String {
        if let handoff = item.handoff { return source != nil ? L("Jam on %@", handoff.deviceLabel) : L("Recently active") }
        if let meeting = item.calendar {
            if meeting.end <= now { return L("Ended") }
            if self.meeting == nil { return L("Calendar event is no longer available.") }
            return HomeMeetingCard.timing(meeting, at: now) + " · " + CalendarMeetingPresentation.compactTimeRange(meeting)
        }
        return L("Calendar event is no longer available.")
    }
    private var joinButton: some View {
        Button {
            if let source { continuation.begin(source) }
            else if let handoff = item.handoff { onStale(handoff) }
            else if let meeting { onJoin(meeting) }
        } label: {
            Text(action).lineLimit(textSize.isAccessibilitySize ? 2 : 1)
                .fixedSize(horizontal: !textSize.isAccessibilitySize, vertical: true).frame(minHeight: 36)
        }
        .buttonStyle(.borderedProminent)
        .tint(Color(red: 1, green: 0.60, blue: 0.33)).foregroundStyle(.black)
        .disabled(busy || continuation.moving || (item.handoff == nil && meeting == nil))
        .accessibilityLabel(source.map { $0.isSharingScreen ? L("Move here and stop sharing") : L("Continue on this device") } ?? action)
        .accessibilityIdentifier(item.calendar.map { "calendar.join." + $0.id } ?? "handoff.join." + (item.handoff?.deviceID ?? ""))
    }
    private func joinHereButton(_ source: ActiveJam) -> some View {
        Button { continuation.joinHere(source) } label: {
            Text(L("Join here")).lineLimit(textSize.isAccessibilitySize ? 2 : 1)
                .fixedSize(horizontal: !textSize.isAccessibilitySize, vertical: true).frame(minHeight: 36)
        }
        .buttonStyle(.bordered)
        .disabled(busy || continuation.moving)
        .accessibilityHint(L("Keep %@ connected. Microphone and camera start off.", source.deviceLabel))
        .accessibilityIdentifier("handoff.join-alongside." + source.deviceID)
    }
    private var starButton: some View {
        let favorite = history.matching(item.invitation, engine: item.id.engine)
        return Button {
            if let favorite, favorite.isStarred { history.toggleStar(favorite.invitationURL) }
            else { history.saveFavorite(url: source?.invitation ?? meeting?.invitation ?? item.invitation,
                                        title: title, engine: item.id.engine) }
        } label: {
            Image(systemName: favorite?.isStarred == true ? "star.fill" : "star")
                .font(.system(size: 20)).frame(width: 44, height: 44)
        }.buttonStyle(.borderless)
        .accessibilityLabel(favorite?.isStarred == true ? L("Unstar %@", title) : L("Star %@", title))
        .accessibilityIdentifier(item.calendar.map { "calendar.star." + $0.id } ?? "handoff.star." + (item.handoff?.deviceID ?? ""))
    }
    static func timing(_ meeting: CalendarMeeting, at now: Date) -> String {
        if meeting.end <= now { return L("Ended") }
        return meeting.isScheduledNow(now) ? L("Scheduled now") :
            L("Starts in %ld min", max(1, Int(ceil(meeting.start.timeIntervalSince(now) / 60))))
    }
}

enum CalendarMeetingPresentation {
    static func compactTimeRange(_ meeting: CalendarMeeting) -> String {
        guard !meeting.allDay, Calendar.current.isDate(meeting.start, inSameDayAs: meeting.end) else { return timeRange(meeting) }
        return meeting.start.formatted(date: .omitted, time: .shortened) + " – " + meeting.end.formatted(date: .omitted, time: .shortened)
    }
    static func timeRange(_ meeting: CalendarMeeting) -> String {
        let start = meeting.start.formatted(date: .abbreviated, time: meeting.allDay ? .omitted : .shortened)
        if meeting.allDay { return start + " · " + L("All day") }
        let end = meeting.end.formatted(date: Calendar.current.isDate(meeting.start, inSameDayAs: meeting.end) ? .omitted : .abbreviated,
                                        time: .shortened)
        return start + " – " + end
    }
    static func subtitle(_ meeting: CalendarMeeting, at now: Date, roomTitle: String) -> String {
        let timing = meeting.end <= now ? L("Ended") : meeting.isScheduledNow(now) ? L("Scheduled now") : L("Upcoming")
        return ([timing + " · " + timeRange(meeting)] +
                (meeting.title == roomTitle ? [] : [meeting.title]) +
                (meeting.calendarTitle.isEmpty ? [] : [meeting.calendarTitle])).joined(separator: "\n")
    }
}
