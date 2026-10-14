import SwiftUI

/// Reception diagnostics belong to an opt-in information sheet, never the activity feed.
struct ReactionHistoryInfoView: View {
    @ObservedObject var history: ReactionHistoryStore
    let onDone: () -> Void
    @State private var interruptionsExpanded = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(L("Only reactions received on this device are saved for this jam. Interruptions may leave gaps; this does not mean any reactions were sent or lost."))
                        .accessibilityIdentifier("reaction.history-explanation")
                    if history.hasTruncatedHistory { Text(L("Showing recent reactions")) }
                }
                if !history.gaps.isEmpty {
                    Section {
                        Button {
                            withAnimation { interruptionsExpanded.toggle() }
                        } label: {
                            HStack {
                                Text(L("Possible interruptions"))
                                Spacer()
                                Image(systemName: interruptionsExpanded ? "chevron.down" : "chevron.right")
                                    .accessibilityHidden(true)
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("reaction.history-interruptions")
                        .accessibilityValue(interruptionsExpanded ? L("Expanded") : L("Collapsed"))
                        if interruptionsExpanded {
                            ForEach(history.interruptionIntervals) { gap in
                                Text(gap.summary())
                                    .accessibilityIdentifier("reaction.interruption." + gap.id)
                            }
                            if history.hasTruncatedGapDetails { Text(L("Showing recent interruptions")) }
                        }
                    }
                }
            }
            .navigationTitle(L("Reaction history"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Done"), action: onDone)
                        .accessibilityIdentifier("reaction.history-done")
                }
            }
        }
    }
}

extension ReactionHistoryGap {
    func summary(locale: Locale = Localization.formattingLocale(language: Bundle.main.preferredLocalizations.first ?? "en"),
                 calendar: Calendar = .current) -> String {
        let style = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale,
                                     calendar: calendar, timeZone: calendar.timeZone)
        let startTime = start.formatted(style)
        guard let end else { return startTime + " · " + L("Reception not confirmed") }
        let endTime = end.formatted(style)
        if !calendar.isDate(start, inSameDayAs: end) {
            let interval = DateIntervalFormatter()
            interval.locale = locale; interval.calendar = calendar; interval.timeZone = calendar.timeZone
            interval.dateStyle = .short; interval.timeStyle = .short
            return interval.string(from: start, to: end)
        }
        if startTime != endTime { return startTime + "–" + endTime }
        // A same-minute interruption needs a duration, not a misleading 10:03–10:03.
        let duration = DateComponentsFormatter()
        var formattingCalendar = calendar; formattingCalendar.locale = locale
        duration.calendar = formattingCalendar
        duration.allowedUnits = [.minute, .second]; duration.unitsStyle = .abbreviated
        duration.maximumUnitCount = 2; duration.zeroFormattingBehavior = .dropAll
        let seconds = max(0, end.timeIntervalSince(start))
        let detail = seconds < 1 ? L("Less than a second") : duration.string(from: ceil(seconds)) ?? ""
        return start.formatted(style.second()) + " · " + detail
    }
}
