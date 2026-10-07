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
        history.matching(item.invitation, engine: item.id.engine)?.alias ?? meeting?.title ?? item.handoff?.title ?? item.calendar?.title ?? ""
    }
    private var action: String {
        if let source { return source.isSharingScreen ? L("Move here and stop sharing") : L("Continue") }
        return item.handoff != nil ? L("Join here") : L("Join")
    }
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { description.frame(minWidth: 100, maxWidth: .infinity, alignment: .leading); actions }
            VStack(alignment: .leading, spacing: 4) {
                description
                HStack { joinButton; Spacer(minLength: 0); starButton }
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
            Text(title).font(.body.weight(.semibold)).lineLimit(2)
                .accessibilityIdentifier("home.title." + (item.calendar?.id ?? item.handoff?.deviceID ?? ""))
            if meeting?.tentative == true { Text(L("Tentative")).font(.caption).foregroundStyle(.secondary) }
        }
        .accessibilityElement(children: .combine)
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

struct HomeTopPreference: PreferenceKey {
    static var defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        if let next = nextValue() { value = next }
    }
}
