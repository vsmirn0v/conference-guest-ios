import AppKit
import SwiftUI

func workspaceDate(_ date: Date, style: Date.FormatStyle.DateStyle = .omitted) -> String {
    let locale = Localization.formattingLocale(language: Bundle.main.preferredLocalizations.first ?? "en")
    return date.formatted(Date.FormatStyle(date: style, time: .shortened).locale(locale))
}

@MainActor
final class MeetingWorkspaceViewState: ObservableObject {
    enum Destination: Hashable { case live, review }
    enum Pause: Equatable {
        case participation(UUID)
        case following(UUID)
        case both(participation: UUID, following: UUID)
    }

    @Published var destination: Destination = .live
    @Published var parallel = false
    @Published var focusedID: UUID?
    @Published var reviewID: UUID?
    @Published var restorePauses: [UUID: Pause] = [:]
    @Published var guidanceDrafts: [UUID: String] = [:]
    @Published var manualDrafts: [UUID: String] = [:]
    @Published var liveReplyIDs: [UUID: String] = [:]

    func prune(liveIDs: Set<UUID>) {
        if let focusedID, !liveIDs.contains(focusedID) { self.focusedID = nil }
        let activePauses = restorePauses.filter { liveIDs.contains($0.key) }
        if activePauses != restorePauses { restorePauses = activePauses }
        guidanceDrafts = guidanceDrafts.filter { liveIDs.contains($0.key) }
        manualDrafts = manualDrafts.filter { liveIDs.contains($0.key) }
        liveReplyIDs = liveReplyIDs.filter { liveIDs.contains($0.key) }
    }

    func pause(_ model: NativeDesktopMeetingModel, attention: AttentionCoordinator) -> Pause? {
        guard model.connected, !model.isClosed else { return nil }
        let participation = model.participation
        if participation.status == .observing {
            participation.pause()
            guard let token = participation.workspacePauseID else { return nil }
            if let following = attention.pauseWorkspaceFollowing(model) {
                return .both(participation: token, following: following)
            }
            return .participation(token)
        }
        guard attention.store.enabled, attention.resolvedMode(model).mode != .off,
              let token = attention.pauseWorkspaceFollowing(model) else { return nil }
        return .following(token)
    }

    func resume(_ model: NativeDesktopMeetingModel, pause: Pause, attention: AttentionCoordinator) {
        let participation = model.participation
        switch pause {
        case .participation(let token):
            if participation.workspacePauseID == token { participation.resume() }
        case .following(let token):
            attention.resumeWorkspaceFollowing(model, pause: token)
        case .both(let token, let following):
            if participation.workspacePauseID == token { participation.resume() }
            attention.resumeWorkspaceFollowing(model, pause: following)
        }
    }

    func toggleAll(_ models: [NativeDesktopMeetingModel], attention: AttentionCoordinator) {
        if restorePauses.isEmpty {
            var paused: [UUID: Pause] = [:]
            for model in models {
                guard let token = pause(model, attention: attention) else { continue }
                paused[model.sessionID] = token
                model.workspaceJournal?.recordAction(sessionID: model.sessionID, text: L("Assistant paused"), source: "pause")
            }
            restorePauses = paused
        } else {
            for model in models {
                guard let previous = restorePauses[model.sessionID] else { continue }
                resume(model, pause: previous, attention: attention)
            }
            restorePauses = [:]
        }
    }
}

struct NativeDesktopMeetingWorkspaceView: View {
    @ObservedObject var workspace: NativeDesktopWorkspace
    @ObservedObject private var state: MeetingWorkspaceViewState
    @ObservedObject private var attention: AttentionCoordinator
    @ObservedObject private var store: AttentionStore

    init(workspace: NativeDesktopWorkspace) {
        self.workspace = workspace
        _state = ObservedObject(wrappedValue: workspace.workspaceViewState)
        _attention = ObservedObject(wrappedValue: workspace.attention)
        _store = ObservedObject(wrappedValue: workspace.attention.store)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 22).padding(.vertical, 14)
            Divider()
            MeetingWorkspaceContent(workspace: workspace, state: state,
                journal: store.meetingLibrary.workspaceJournal)
        }
        .navigationTitle(L("Meeting workspace"))
        .tint(.teal)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { state.prune(liveIDs: Set(workspace.meetings.map(\.sessionID))) }
        .onChange(of: workspace.meetings.map(\.sessionID)) { state.prune(liveIDs: Set($0)) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("meetingWorkspace")
    }

    private var header: some View {
        HStack {
            Picker(L("Meeting workspace"), selection: $state.destination) {
                Label(L("Live"), systemImage: "dot.radiowaves.left.and.right").tag(MeetingWorkspaceViewState.Destination.live)
                Label(L("Review"), systemImage: "clock.arrow.circlepath").tag(MeetingWorkspaceViewState.Destination.review)
            }
            .labelsHidden().pickerStyle(.segmented)
            .frame(maxWidth: 215)
            .accessibilityIdentifier("meetingWorkspace.destination")
            Spacer()
            if state.destination == .live, !workspace.meetings.isEmpty {
                Button { state.parallel.toggle() } label: {
                    Label(state.parallel ? L("Focused conversation") : L("Parallel transcripts"),
                          systemImage: state.parallel ? "rectangle.split.2x1" : "rectangle.split.3x1")
                }
                .accessibilityIdentifier("meetingWorkspace.parallel")
                Button { state.toggleAll(workspace.meetings, attention: attention) } label: {
                    Label(state.restorePauses.isEmpty ? L("Pause all assistants") : L("Restore previous modes"),
                          systemImage: state.restorePauses.isEmpty ? "pause.fill" : "play.fill")
                }
                .disabled(state.restorePauses.isEmpty && !store.enabled)
                .accessibilityIdentifier("meetingWorkspace.pauseAll")
            }
        }
    }

}

private struct MeetingWorkspaceContent: View {
    @ObservedObject var workspace: NativeDesktopWorkspace
    @ObservedObject var state: MeetingWorkspaceViewState
    @ObservedObject var journal: MeetingWorkspaceJournal

    private var focused: NativeDesktopMeetingModel? {
        workspace.meetings.first { $0.sessionID == state.focusedID } ?? workspace.talkMeeting ?? workspace.meetings.first
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = journal.persistenceError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    .background(.orange.opacity(0.07))
            }
            switch state.destination {
            case .live: live
            case .review: MeetingWorkspaceReview(workspace: workspace, state: state, journal: journal)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var live: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(L("Live workspace")).font(.system(size: 26, weight: .semibold))
                Spacer()
                if let talk = workspace.talkMeeting {
                    WorkspaceMicrophoneRoute(model: talk)
                } else {
                    Label(L("Microphone unassigned"), systemImage: "mic.slash")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if workspace.meetings.isEmpty {
                WorkspaceEmptyView(title: L("No live meetings"), detail: L("Join a meeting to follow its conversation here."),
                                   symbol: "dot.radiowaves.left.and.right")
                HStack {
                    Spacer()
                    Button(L("Go to Home")) { workspace.selection = .home }
                    Button(L("Review saved meetings")) { state.destination = .review }
                    Spacer()
                }
                Spacer(minLength: 0)
            } else {
                GeometryReader { geometry in
                    let models = workspace.meetings
                    let width = max(state.parallel ? 290 : 205,
                                    (geometry.size.width - CGFloat(models.count - 1) * 10) / CGFloat(models.count))
                    VStack(alignment: .leading, spacing: 14) {
                        ScrollView(.horizontal) {
                            HStack(alignment: .top, spacing: 10) {
                                ForEach(models, id: \.sessionID) { model in
                                    WorkspaceLiveMeeting(workspace: workspace, state: state, model: model,
                                        session: journal.session(id: model.workspaceSessionID),
                                        selected: focused === model, style: state.parallel ? .parallel : .card)
                                        .frame(width: width)
                                }
                            }
                        }
                        .frame(height: state.parallel ? max(0, geometry.size.height) : 158)
                        if !state.parallel, let focused {
                            WorkspaceLiveMeeting(workspace: workspace, state: state, model: focused,
                                session: journal.session(id: focused.workspaceSessionID),
                                selected: true, style: .focused)
                                .id(focused.sessionID)
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct WorkspaceMicrophoneRoute: View {
    @ObservedObject var model: NativeDesktopMeetingModel

    var body: some View {
        let on = model.assistantMicrophoneOn
        Label(on ? L("Microphone on in %@", model.title) : L("Microphone assigned to %@ · muted", model.title),
              systemImage: on ? "mic.fill" : "mic.slash")
            .font(.caption).foregroundStyle(on ? .primary : .secondary)
            .lineLimit(1).help(model.title)
    }
}

struct WorkspaceEmptyView: View {
    let title: String
    let detail: String
    let symbol: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct WorkspacePanel: ViewModifier {
    var selected = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12)
        content
            .background(Color(nsColor: .controlBackgroundColor), in: shape)
            .overlay(shape.strokeBorder(selected ? .teal : Color(nsColor: .separatorColor),
                                        lineWidth: selected ? 1.5 : 0.5).allowsHitTesting(false))
    }
}
