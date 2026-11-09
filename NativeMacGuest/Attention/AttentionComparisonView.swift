import ConferenceCore
import SwiftUI

/// Settings → Intelligence → Compare models: your saved decisions and drafts
/// run through another model, scored against what you did with the cards.
struct AttentionComparisonView: View {
    @ObservedObject var store: AttentionStore
    @StateObject private var comparison = ModelComparison()
    @Environment(\.dismiss) private var dismiss
    @State private var model = ""
    @State private var modelContext: Int?
    @State private var limit = 30
    @State private var draftLimit = 10
    @State private var choosingModel = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("Compare models")).font(.title3.weight(.semibold))
                Text(L("Sends the meeting text of your saved decisions (last 30 days) to %@ again, with another model, and compares its answers with what you did: Open, a reply or a reaction count as needed; Decline as not needed. Nothing is sent into any meeting.", store.provider.host))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            setup
            if comparison.running || comparison.total > 0 { progress }
            if !comparison.rows.isEmpty || !comparison.draftRows.isEmpty { results }
            Spacer(minLength: 0)
            HStack {
                if !comparison.running, comparison.candidateScore.judged > 0, comparison.candidateModel != store.provider.model {
                    Button(L("Use %@ for the judge", comparison.candidateModel)) {
                        store.provider.adopt(model: comparison.candidateModel, contextLength: comparison.candidateContext)
                    }
                }
                Spacer()
                Button(L("Close")) { comparison.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20).frame(width: 720, height: 680)
        .onAppear { comparison.load(from: store) }
        .sheet(isPresented: $choosingModel) { AttentionModelPicker(store: store, chosen: model, onSelect: { picked in
            model = picked.id
            modelContext = picked.contextLength
        }) }
    }

    private var setup: some View {
        let labelled = comparison.cases.filter { $0.needed != nil }.count
        return GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("%ld saved decisions, %ld of them with your choice; %ld drafted replies.",
                       comparison.cases.count, labelled, comparison.drafts.count)).font(.callout)
                HStack {
                    TextField(L("Model to compare"), text: Binding(get: { model }, set: { newValue in
                        if newValue != model { modelContext = nil }
                        model = newValue
                    }), prompt: Text(store.provider.model))
                    Button(L("Choose…")) { choosingModel = true }
                }
                HStack(spacing: 16) {
                    Stepper(L("Decisions: %ld", limit), value: $limit, in: 5...200, step: 5).fixedSize()
                    Stepper(L("Drafts: %ld", draftLimit), value: $draftLimit, in: 0...50, step: 5).fixedSize()
                    Spacer()
                    if comparison.running {
                        Button(L("Stop")) { comparison.cancel() }
                    } else {
                        Button(L("Compare")) {
                            comparison.run(model: model, provider: store.provider, key: store.apiKey(), limit: limit, draftLimit: draftLimit, contextLength: modelContext)
                        }.buttonStyle(.borderedProminent)
                            .disabled(model.trimmed.isEmpty || comparison.cases.isEmpty && comparison.drafts.isEmpty)
                    }
                }
                if comparison.cases.isEmpty && comparison.drafts.isEmpty {
                    Text(L("Nothing to compare yet. Decisions are saved while the judge watches your meetings.")).font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var progress: some View {
        HStack {
            ProgressView(value: Double(comparison.done), total: Double(max(comparison.total, 1)))
            Text(L("%ld of %ld", comparison.done, comparison.total)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private var results: some View {
        let original = comparison.originalScore, candidate = comparison.candidateScore
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    GridRow {
                        Text(L("Model")).fontWeight(.semibold); Text(L("Agrees with you")).fontWeight(.semibold)
                        Text(L("Precision")).fontWeight(.semibold); Text(L("Recall")).fontWeight(.semibold)
                        Text(L("Cards")).fontWeight(.semibold); Text(L("Median time")).fontWeight(.semibold); Text(L("Failed")).fontWeight(.semibold)
                    }
                    scoreRow(L("As judged (%@)", originalModels), original)
                    scoreRow(comparison.candidateModel, candidate)
                }.font(.callout)
                Text(L("Precision: how many cards were wanted. Recall: how many wanted cards appeared. Only decisions you chose on are scored."))
                    .font(.caption).foregroundStyle(.secondary)
                let changed = comparison.rows.filter { $0.changed || $0.error != nil }
                if !changed.isEmpty {
                    Text(L("Where the models differ")).font(.headline)
                    ForEach(changed) { row in decisionRow(row) }
                }
                if !comparison.draftRows.isEmpty {
                    Text(L("Drafted replies")).font(.headline)
                    ForEach(comparison.draftRows) { row in draftRow(row) }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var originalModels: String {
        Array(Set(comparison.rows.map(\.item.originalModel))).sorted().joined(separator: ", ")
    }

    private func percent(_ value: Double?) -> String { value.map { String(format: "%.0f%%", $0 * 100) } ?? "—" }

    @ViewBuilder private func scoreRow(_ title: String, _ score: ComparisonScore) -> some View {
        GridRow {
            Text(title).lineLimit(1)
            Text(score.labelled == 0 ? "—" : "\(score.agreed)/\(score.labelled) (\(percent(score.agreement)))")
            Text(percent(score.precision)); Text(percent(score.recall))
            Text("\(score.shown)/\(score.judged)")
            Text(score.medianLatency.map { String(format: "%.1f s", $0) } ?? "—")
            Text("\(score.failed)")
        }
    }

    private func decisionRow(_ row: ModelComparison.Row) -> some View {
        let item = row.item
        let you = item.needed.map { $0 ? L("needed") : L("not needed") } ?? L("no choice")
        let before = item.wouldShow(item.original) ? L("card") : L("no card")
        let after: String = row.candidate.map { verdict in
            (item.wouldShow(verdict) ? L("card") : L("no card")) + String(format: " · %@ %.2f", verdict.level.title, verdict.probability)
        } ?? (row.error ?? "—")
        return VStack(alignment: .leading, spacing: 2) {
            Text(item.meetingTitle + " · " + item.at.formatted(date: .abbreviated, time: .shortened)).fontWeight(.semibold)
            Text(L("You: %@ · as judged: %@ · %@: %@", you, before, comparison.candidateModel, after)).foregroundStyle(.secondary)
            if let reason = row.candidate?.reason { Text(reason).font(.caption) }
        }.font(.callout).padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private func draftRow(_ row: ModelComparison.DraftRow) -> some View {
        let item = row.item
        return VStack(alignment: .leading, spacing: 4) {
            Text(item.meetingTitle + " · " + item.at.formatted(date: .abbreviated, time: .shortened)).fontWeight(.semibold)
            labeled(L("Drafted by %@", item.originalModel), describe(item.original))
            labeled(comparison.candidateModel, row.candidate.map(describe) ?? row.error ?? "…")
            if let sent = item.sent { labeled(L("You sent"), sent) }
            else if let reaction = item.reaction { labeled(L("You sent"), reaction.emoji) }
        }.font(.callout).padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private func labeled(_ title: String, _ text: String) -> some View {
        (Text(title + ": ").foregroundColor(.secondary) + Text(text)).textSelection(.enabled)
    }

    private func describe(_ draft: ReplyDraft) -> String {
        [draft.chat.isEmpty ? nil : draft.chat, draft.reaction?.emoji].compactMap { $0 }.joined(separator: "  ")
    }
}
