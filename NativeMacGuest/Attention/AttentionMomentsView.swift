import ConferenceCore
import SwiftUI

extension AttentionMoment.State {
    var title: String {
        switch self { case .live: L("Current moment"); case .missed: L("Missed"); case .answered: L("Answered")
        case .dismissed: L("Dismissed"); case .notForMe: L("Not for me") }
    }
}

/// Durable Assistant inbox. History is already in memory; this view only sorts
/// when its query changes and renders rows lazily.
struct AttentionMomentsView: View {
    private enum Section: Hashable { case moments, outcomes, tasks, talk }
    @ObservedObject var attention: AttentionCoordinator
    @ObservedObject var store: AttentionStore
    @State private var filter: AttentionMoment.State?
    @State private var selectedID: UUID?
    @State private var area = Section.moments

    private var moments: [AttentionMoment] { store.momentHistory.moments(filter: filter) }
    private var selected: AttentionMoment? { selectedID.flatMap(store.momentHistory.moment(_:)) }

    var body: some View {
        VStack(spacing: 0) {
            Picker(L("Assistant section"), selection: $area) {
                Text(L("Moments")).tag(Section.moments)
                Text(L("Outcomes")).tag(Section.outcomes)
                Text(L("My Tasks")).tag(Section.tasks)
                Text(L("Talk")).tag(Section.talk)
            }.pickerStyle(.segmented).labelsHidden().padding(12)
            Divider()
            switch area {
            case .outcomes: AssistantOutcomesView(attention: attention)
            case .tasks:
                PersonalTasksView(attention: attention) { sessionID in
                    attention.requestedOutcomeSessionID = sessionID
                    area = .outcomes
                }
            case .talk: AssistantTalkView(attention: attention)
            case .moments: momentsView
            }
        }.navigationTitle(L("Assistant"))
        .onAppear {
            if attention.requestedOutcomeSessionID != nil { area = .outcomes }
        }
        .onChange(of: attention.requestedOutcomeSessionID) { id in
            if id != nil { area = .outcomes }
        }
        .onChange(of: filter) { _ in selectedID = nil; attention.selectedCard = nil }
        .onChange(of: store.momentsLoaded) { _ in
            if let id = attention.requestedMomentID, let moment = store.momentHistory.moment(id) {
                filter = nil; selectedID = id; attention.selectMoment(moment)
            }
        }
        .onChange(of: attention.requestedMomentID) { id in
            guard let id, let moment = store.momentHistory.moment(id) else { return }
            area = .moments; filter = nil; selectedID = id; attention.selectMoment(moment)
        }
    }

    private var momentsView: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                Picker(L("Filter"), selection: $filter) {
                    Text(L("All")).tag(AttentionMoment.State?.none)
                    ForEach([AttentionMoment.State.live, .missed, .answered], id: \.self) { Text($0.title).tag(Optional($0)) }
                }.pickerStyle(.segmented).labelsHidden().controlSize(.small).padding(12)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(moments) { moment in row(moment) }
                        }.padding(.horizontal, 8)
                    }
                    .onAppear { scrollToRequested(proxy) }
                    .onChange(of: attention.requestedMomentID) { _ in scrollToRequested(proxy) }
                    .onChange(of: store.momentsLoaded) { _ in scrollToRequested(proxy) }
                }
                if !store.momentsLoaded { ProgressView().controlSize(.small).padding(8) }
                if moments.isEmpty && store.momentsLoaded {
                    Text(L("No Moments in this view.")).font(.callout).foregroundStyle(.secondary).padding()
                }
            }.frame(width: 330).background(Color(nsColor: .controlBackgroundColor))
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func scrollToRequested(_ proxy: ScrollViewProxy) {
        guard let id = attention.requestedMomentID, moments.contains(where: { $0.id == id }) else { return }
        proxy.scrollTo(id, anchor: .center)
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
        .id(moment.id).onAppear { attention.markVisibleMomentsSeen([moment]) }
    }

    @ViewBuilder private var detail: some View {
        if let moment = selected {
            let terminal = [.answered, .dismissed, .notForMe].contains(moment.state)
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
                    if let error = attention.summaryErrorByMoment[moment.id] { Text(error).font(.caption).foregroundStyle(.red) }
                    if let error = attention.reminderErrorByMoment[moment.id] { Text(error).font(.caption).foregroundStyle(.red) }
                    if let sent = moment.sent, !sent.isEmpty {
                        GroupBox(L("Your answer")) { Text(sent).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    }
                    if let reaction = moment.reaction {
                        Label(L("You reacted with %@", reaction.emoji), systemImage: "face.smiling")
                    }
                    if let card = attention.selectedCard, card.id == moment.id {
                        if !terminal, card.readOnly {
                            Text(L("This meeting is not open. The Moment is read-only; join it again to answer."))
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        AttentionCardView(attention: attention, card: card).shadow(radius: 0)
                    } else {
                        if !terminal {
                            Text(L("This meeting is not open. The Moment is read-only; join it again to answer."))
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Text(moment.verdict.reason).textSelection(.enabled)
                        ForEach(moment.evidence, id: \.id) { line in
                            Text("\(line.speaker): \(line.text)").font(.callout).foregroundStyle(.secondary)
                        }
                    }
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
}
