import ConferenceCore
import SwiftUI

extension AttentionMoment.State {
    var title: String {
        switch self { case .live: L("Live"); case .missed: L("Missed"); case .answered: L("Answered")
        case .dismissed: L("Dismissed"); case .notForMe: L("Not for me") }
    }
}

/// Durable Assistant inbox. History is already in memory; this view only sorts
/// when its query changes and renders rows lazily.
struct AttentionMomentsView: View {
    @ObservedObject var attention: AttentionCoordinator
    @ObservedObject var store: AttentionStore
    @State private var filter: AttentionMoment.State?
    @State private var selectedID: UUID?

    private var moments: [AttentionMoment] { store.momentHistory.moments(filter: filter) }
    private var selected: AttentionMoment? { selectedID.flatMap(store.momentHistory.moment(_:)) }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                Picker(L("Filter"), selection: $filter) {
                    Text(L("All")).tag(AttentionMoment.State?.none)
                    ForEach([AttentionMoment.State.live, .missed, .answered], id: \.self) { Text($0.title).tag(Optional($0)) }
                }.pickerStyle(.segmented).labelsHidden().padding(12)
                ScrollView {
                    LazyVStack(spacing: 2) {
                        if filter == nil {
                            ForEach(store.momentHistory.quietChecks.sorted { $0.latestAt > $1.latestAt }) { quiet in
                                Label(L("%ld quiet checks · latest %@", quiet.count, quiet.latestAt.formatted(date: .abbreviated, time: .shortened)),
                                      systemImage: "moon")
                                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(10).help(quiet.meetingTitle)
                            }
                        }
                        ForEach(moments) { moment in row(moment) }
                    }.padding(.horizontal, 8)
                }
                if !store.momentsLoaded { ProgressView().controlSize(.small).padding(8) }
                if moments.isEmpty && store.momentsLoaded {
                    Text(L("No Moments in this view.")).font(.callout).foregroundStyle(.secondary).padding()
                }
            }.frame(width: 330).background(Color(nsColor: .controlBackgroundColor))
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.navigationTitle(L("Assistant"))
        .onAppear { seen() }
        .onChange(of: filter) { _ in selectedID = nil; attention.selectedCard = nil; seen() }
        .onChange(of: store.momentsLoaded) { _ in
            seen()
            if let id = attention.requestedMomentID, let moment = store.momentHistory.moment(id) {
                filter = nil; selectedID = id; attention.selectMoment(moment)
            }
        }
        .onChange(of: attention.requestedMomentID) { id in
            guard let id, let moment = store.momentHistory.moment(id) else { return }
            filter = nil; selectedID = id; attention.selectMoment(moment)
        }
    }

    private func row(_ moment: AttentionMoment) -> some View {
        Button { selectedID = moment.id; attention.selectMoment(moment) } label: {
            HStack(alignment: .top, spacing: 8) {
                Circle().fill(Color.accentColor).frame(width: 7, height: 7).padding(.top, 6)
                    .opacity(!moment.seen && [.live, .missed].contains(moment.state) ? 1 : 0)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(moment.meetingTitle).fontWeight(.semibold).lineLimit(1)
                        Spacer(); Text(moment.updatedAt, style: .time).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(moment.verdict.reason).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    Text(moment.state.title).font(.caption2.weight(.semibold)).foregroundStyle(moment.state == .missed ? Color.orange : Color.secondary)
                }
            }.padding(9).frame(maxWidth: .infinity, alignment: .leading)
            .background(selectedID == moment.id ? Color.accentColor.opacity(0.13) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).accessibilityIdentifier("attention.moment")
    }

    @ViewBuilder private var detail: some View {
        if let moment = selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(moment.meetingTitle).font(.title2.weight(.semibold))
                            Text(L("%@ · %@", moment.state.title, moment.createdAt.formatted(date: .abbreviated, time: .shortened)))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if moment.state == .missed {
                            Button(moment.reminderAt == nil ? L("Remind me") : L("Reminder set")) { attention.remind(moment) }
                                .disabled(moment.reminderAt != nil).help(L("Remind me in 10 minutes"))
                            Button(attention.summarizing == moment.id ? L("Summarizing…") : L("Since then")) {
                                Task { await attention.summarize(moment) }
                            }.disabled(attention.summarizing != nil)
                        }
                    }
                    if let summary = attention.summaryByMoment[moment.id] {
                        GroupBox(L("Since then")) { Text(summary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    }
                    if let error = attention.summaryError { Text(error).font(.caption).foregroundStyle(.red) }
                    if let card = attention.selectedCard, card.id == moment.id {
                        if card.readOnly {
                            Text(L("This meeting is not open. The Moment is read-only; join it again to answer."))
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        AttentionCardView(attention: attention, card: card).shadow(radius: 0)
                    } else {
                        Text(L("This meeting is not open. The Moment is read-only; join it again to answer."))
                            .font(.callout).foregroundStyle(.secondary)
                        Text(moment.verdict.reason).textSelection(.enabled)
                        ForEach(moment.evidence, id: \.id) { line in
                            Text("\(line.speaker): \(line.text)").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    Button(L("Why")) {
                        if let card = attention.selectedCard { attention.inspecting = card }
                    }.disabled(attention.selectedCard?.id != moment.id)
                }.padding(24).frame(maxWidth: 700, alignment: .leading)
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "tray").font(.largeTitle).foregroundStyle(.secondary)
                Text(L("Choose a Moment")).font(.title3)
                Text(L("Live, missed and answered decisions stay here for 30 days.")).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func seen() { attention.markVisibleMomentsSeen(moments) }
}
