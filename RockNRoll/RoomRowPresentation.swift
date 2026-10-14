import ConferenceCore
import SwiftUI

/// Each slot keeps its height when calendar enrichment arrives. Full details
/// remain available to VoiceOver and in the calendar agenda.
struct RoomRowPresentation {
    let title: String
    let timing: String
    let location: String
    let details: String
    init(title: String, timing: String, location: String, details: String) {
        self.title = title; self.timing = timing; self.location = location; self.details = details
    }

    @MainActor init(room: RecentRoom, calendar: CalendarMeetingStore) {
        title = room.displayTitle
        timing = calendar.timing(for: room) ?? room.lastVisit?.formatted(.relative(presentation: .named)) ?? L("Saved · Not joined yet")
        location = [room.joinURL.host() ?? L("Meeting"), room.identifier].joined(separator: " · ")
        details = [calendar.subtitle(for: room) ?? timing, location].joined(separator: ". ")
    }
}

struct RoomRowText: View {
    let presentation: RoomRowPresentation
    @Environment(\.dynamicTypeSize) private var textSize
    @ScaledMetric(relativeTo: .body) private var titleHeight = 23.0
    @ScaledMetric(relativeTo: .caption) private var detailHeight = 17.0
    private var lines: Int { textSize.isAccessibilitySize ? 2 : 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(presentation.title).font(.body.weight(.semibold))
                .lineLimit(lines).frame(height: titleHeight * Double(lines), alignment: .leading)
            Text(presentation.timing).font(.caption).foregroundStyle(.secondary)
                .lineLimit(lines).frame(height: detailHeight * Double(lines), alignment: .leading)
            Text(presentation.location).font(.caption).foregroundStyle(.secondary)
                .lineLimit(lines).frame(height: detailHeight * Double(lines), alignment: .leading)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
