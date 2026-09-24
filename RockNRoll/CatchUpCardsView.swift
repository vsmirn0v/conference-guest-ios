import ConferenceCore
import SwiftUI

struct CatchUpCardsView: View {
    @ObservedObject var store: CatchUpStore

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if let warning = store.persistenceWarning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                Text(availability)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if store.timeline.intervals.isEmpty {
                    ContentUnavailableView("No interruptions recorded",
                                           systemImage: "checkmark.circle",
                                           description: Text("This phone has not detected a missed section in this jam."))
                } else {
                    ForEach(Array(store.timeline.intervals.reversed())) { interval in
                        intervalCard(interval)
                    }
                }
                let unaligned = store.timeline.segments.filter { $0.spokenAt == nil }
                if !unaligned.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Text with unknown timing").font(.headline)
                        Text("These lines cannot be assigned to an interruption.")
                            .font(.footnote).foregroundStyle(.secondary)
                        ForEach(unaligned) { line in
                            Text("\(line.speaker ?? "Participant"): \(line.text)")
                                .font(.body).textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Color(uiColor: .secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 16))
                }
                if store.timeline.isTruncated {
                    Text("Older local history was removed to save space.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .accessibilityIdentifier("Catch up sections")
    }

    private var availability: String {
        switch (store.canViewTranscript, store.transcriptionEnabled) {
        case (nil, _): return "Checking transcript availability…"
        case (false, _): return "Transcripts are unavailable in this room. Missed times can still be shown."
        case (true, false): return "Transcription is off. The host may be able to enable it."
        case (true, true): return "Only text received by this phone is shown. Other speech may be missing."
        }
    }

    private func intervalCard(_ interval: MissedInterval) -> some View {
        let lines = store.timeline.transcript(during: interval)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(reasonTitle(interval.reasons))
                        .font(.headline)
                    Text(timeRange(interval))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if store.timeline.isReviewed(interval) {
                    Label("Reviewed", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Label(lines.isEmpty ? "No transcript received" : "Transcript received",
                  systemImage: lines.isEmpty ? "text.badge.xmark" : "text.bubble")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(lines.isEmpty ? .secondary : .primary)
            ForEach(lines) { line in
                VStack(alignment: .leading, spacing: 2) {
                    Text(line.speaker ?? "Participant").font(.subheadline.weight(.semibold))
                    Text(line.text).font(.body).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            }
            if !lines.isEmpty {
                Text("Other speech may still be missing.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !store.timeline.isReviewed(interval) && !interval.isOngoing {
                Button("Mark section reviewed") { store.markReviewed(interval.id) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("Review section \(interval.id)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func reasonTitle(_ reasons: Set<MissedReason>) -> String {
        var names = [String]()
        if reasons.contains(.anotherCall) { names.append("Another call") }
        if reasons.contains(.connection) { names.append("Connection gap") }
        if reasons.contains(.audioInterruption) { names.append("Audio interruption") }
        return names.joined(separator: " · ")
    }

    private func timeRange(_ interval: MissedInterval) -> String {
        let start = interval.start.formatted(date: .omitted, time: .shortened)
        guard let end = interval.end else { return "\(start) – ongoing" }
        let duration = Int(end.timeIntervalSince(interval.start))
        let length = duration < 60 ? "\(duration) sec" : "\(duration / 60) min \(duration % 60) sec"
        return "\(start)–\(end.formatted(date: .omitted, time: .shortened)) · \(length)"
    }
}
