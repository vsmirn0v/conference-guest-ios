import ConferenceCore
import SwiftUI

struct ArchivedHistoryTranscript: View {
    let events: [SyncedTranscriptEvent]
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L("Saved on this Mac"), systemImage: "internaldrive").foregroundStyle(.secondary)
            TextField(L("Search within this conversation"), text: $query).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(events.filter(matches)) { event in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(workspaceDate(event.occurredAt) + " · " + (event.speaker ?? L("Unknown speaker")))
                                .font(.caption).foregroundStyle(.secondary)
                            Text(event.text.isEmpty ? L("Speech capture gap") : event.text).textSelection(.enabled)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(16)
    }

    private func matches(_ event: SyncedTranscriptEvent) -> Bool {
        query.isEmpty || event.text.localizedStandardContains(query) ||
            event.speaker?.localizedStandardContains(query) == true
    }
}

struct MeetingHistoryContext: View {
    let card: MeetingLibraryCard
    let workspace: NativeDesktopWorkspace
    @ObservedObject private var sync: MacWorkspaceSyncCoordinator
    @ObservedObject private var preferences: RoomSyncCoordinator
    @ObservedObject private var calendar: CalendarMeetingStore
    @Environment(\.dismiss) private var dismiss
    @State private var record: MeetingSessionRecord?
    @State private var confirmJoin = false
    @State private var combineTarget: UUID?

    init(card: MeetingLibraryCard, workspace: NativeDesktopWorkspace) {
        self.card = card
        self.workspace = workspace
        _sync = ObservedObject(wrappedValue: workspace.workspaceSync)
        _preferences = ObservedObject(wrappedValue: workspace.library.sync)
        _calendar = ObservedObject(wrappedValue: workspace.library.calendar)
    }

    private var association: MeetingCalendarAssociation? { sync.association(for: card.sessionID) }

    private var candidates: [CalendarMeeting] {
        guard let date = card.effectiveDate?.date, let url = record?.invitation,
              let room = MeetingRoomIdentity(url) else { return [] }
        let connection = ActiveRoomConnection(room: room)
        let nearby = calendar.matchingHistoryOccurrences(connection, at: date)
        guard let end = card.endedAt, end > date else { return nearby }
        let ids = Set(nearby.map(\.id))
        return nearby + calendar.meetings.filter {
            !ids.contains($0.id) && !$0.allDay && !$0.tentative && $0.start < end && $0.end > date &&
                $0.isConnected(in: [connection])
        }
    }

    private var linkedCards: [MeetingLibraryCard] {
        workspace.attention.store.meetingLibrary.cards.filter {
            $0.sessionID != card.sessionID && sync.canonicalSessionID($0.sessionID) == $0.sessionID &&
                sync.historySessionID($0.sessionID) == card.sessionID
        }
    }

    private var attendance: [(leg: DeviceParticipationLeg, interval: MeetingParticipationInterval)] {
        let ids = [card.sessionID] + linkedCards.map(\.sessionID)
        return ids.flatMap { sync.attendance(for: $0) }.flatMap { leg -> [(leg: DeviceParticipationLeg, interval: MeetingParticipationInterval)] in
            let intervals = leg.intervals.map { Array($0.values) } ??
                [.init(joinedAt: leg.joinedAt, leftAt: leg.leftAt)]
            return intervals.map { (leg: leg, interval: $0) }
        }.sorted { $0.interval.joinedAt < $1.interval.joinedAt }
    }

    private var totalMinutes: Int {
        var seconds: TimeInterval = 0
        var previousEnd: Date?
        for (_, interval) in attendance {
            guard let end = interval.leftAt, end > interval.joinedAt else { continue }
            let start = max(interval.joinedAt, previousEnd ?? interval.joinedAt)
            seconds += max(0, end.timeIntervalSince(start))
            previousEnd = max(previousEnd ?? end, end)
        }
        return Int(seconds / 60)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L("Participation and calendar")).font(.title2.bold())
                Spacer()
                Button(L("Done")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    calendarDetails
                    if !linkedCards.isEmpty {
                        Divider()
                        ForEach(linkedCards) { linked in
                            LabeledContent(linked.title, value: workspaceDate(linked.startedAt))
                            Button(L("Separate records")) { sync.setHistoryGroup(sessionID: linked.sessionID, parent: nil) }
                        }
                    }
                    Divider()
                    Text(L("Participation")).font(.headline)
                    if attendance.isEmpty {
                        Text(L("No attendance details are available.")).foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(attendance.enumerated()), id: \.offset) { _, item in
                            HStack {
                                Label(item.leg.deviceKind == .ios ? L("iPhone or iPad") : L("Mac"),
                                      systemImage: item.leg.deviceKind == .ios ? "iphone" : "laptopcomputer")
                                Spacer()
                                Text(workspaceDate(item.interval.joinedAt, style: .abbreviated) + " – " +
                                     (item.interval.leftAt.map { workspaceDate($0, style: .abbreviated) } ?? L("End time unknown")))
                            }
                        }
                        Text(L("Recorded attendance · %ld min", totalMinutes)).foregroundStyle(.secondary)
                    }
                    Divider()
                    syncDetails
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 400)
            if let record, let url = record.invitation {
                Button(workspace.canResumeHistory(card.sessionID, invitation: url) ? L("Return to meeting") : L("Join room as a new meeting")) {
                    confirmJoin = true
                }.buttonStyle(.borderedProminent)
            }
        }.padding(20).frame(width: 510).tint(.orange)
        .task(id: card.sessionID) { record = try? await workspace.attention.store.meetingLibrary.store.session(card.sessionID) }
        .confirmationDialog(L("Combine meeting records?"), isPresented: Binding(get: { combineTarget != nil },
            set: { if !$0 { combineTarget = nil } }), titleVisibility: .visible, presenting: combineTarget) { target in
            Button(L("Combine records")) {
                sync.setHistoryGroup(sessionID: card.sessionID, parent: target)
                dismiss()
                workspace.openMeetingHistory(target)
            }
        } message: { target in
            if let other = workspace.attention.store.meetingLibrary.cards.first(where: { $0.sessionID == target }) {
                Text(card.title + " · " + workspaceDate(card.startedAt) + "\n" + other.title + " · " + workspaceDate(other.startedAt))
            }
        }
        .confirmationDialog(L("Join with microphone and camera off?"), isPresented: $confirmJoin, titleVisibility: .visible) {
            if let record, let url = record.invitation {
                Button(L("Join")) {
                    dismiss()
                    workspace.joinFromHistory(record.id, invitation: url, title: record.title)
                }
            }
        }
    }

    @ViewBuilder private var calendarDetails: some View {
        Text(L("Calendar")).font(.headline)
        if let association {
            Text(association.title).fontWeight(.medium)
            Text(workspaceDate(association.start, style: .abbreviated) + " – " + workspaceDate(association.end))
                .foregroundStyle(.secondary)
            Button(L("Remove calendar link")) { sync.recordCalendarAssociation(nil, sessionID: card.sessionID) }
        } else {
            Text(L("No calendar event linked")).foregroundStyle(.secondary)
            if let url = record?.invitation, let room = MeetingRoomIdentity(url), !candidates.isEmpty {
                ForEach(candidates) { event in
                    let link = MeetingCalendarAssociation(event, room: room)
                    HStack {
                        VStack(alignment: .leading) {
                            Text(event.title)
                            Text(workspaceDate(event.start, style: .abbreviated) + " – " + workspaceDate(event.end))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let existing = sync.historySession(matching: link), existing != card.sessionID {
                            Button(L("Combine records")) { combineTarget = existing }
                            Button(L("Open saved meeting")) { dismiss(); workspace.openMeetingHistory(existing) }
                        } else {
                            Button(L("Link calendar event")) { sync.recordCalendarAssociation(link, sessionID: card.sessionID) }
                        }
                    }
                }
                Button(L("Keep separate")) { sync.recordCalendarAssociation(nil, sessionID: card.sessionID); dismiss() }
            }
        }
    }

    @ViewBuilder private var syncDetails: some View {
        Text(L("iCloud")).font(.headline)
        if !preferences.enabled || !preferences.syncWorkspace {
            Text(L("Meeting history sync is off")).foregroundStyle(.secondary)
        } else {
            if let last = sync.lastLibrarySyncAt {
                LabeledContent(L("Last meeting history sync"), value: workspaceDate(last, style: .abbreviated))
            }
            if let failure = sync.syncError {
                Text(failure).foregroundStyle(.orange)
                if let retry = sync.nextRetryAt, retry > Date() {
                    Text(L("Next sync attempt at %@", workspaceDate(retry))).font(.caption).foregroundStyle(.secondary)
                }
            }
            let receipt = sync.transcriptReceipt(for: card.sessionID)
            if receipt.received { Label(L("Transcript received from another device"), systemImage: "icloud.and.arrow.down") }
            if preferences.transcriptRetention == .off {
                Text(L("Transcript sync is off")).foregroundStyle(.secondary)
            } else if let retention = preferences.transcriptRetention.timeInterval,
                      let opened = card.effectiveDate?.date, Date().timeIntervalSince(opened) > retention {
                Text(L("The iCloud transcript retention window has expired.")).foregroundStyle(.secondary)
            } else if receipt.pending {
                Text(L("Waiting for transcript from another device")).foregroundStyle(.secondary)
            }
            Button(L("Sync now")) { sync.scheduleSync(delayMilliseconds: 0) }.disabled(sync.isSyncing)
        }
    }
}

struct HistoryOutcomeReview: View {
    let card: MeetingLibraryCard
    let draft: AttentionCoordinator.HistoryOutcomeDraft
    let attention: AttentionCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var replaceSummary = false
    @State private var replaceDecisions = false
    @State private var replaceQuestions = false
    @State private var applying = false
    @State private var error: String?

    var body: some View {
        let current = attention.store.assistant.outcomes.first { $0.id == card.outcomeID }
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Review summary draft")).font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    comparison(L("Summary"), draft.content.summary, existing: current?.summary, replace: $replaceSummary)
                    comparison(L("Decisions"), draft.content.decisions.joined(separator: "\n"),
                               existing: current?.decisions.joined(separator: "\n"), replace: $replaceDecisions)
                    comparison(L("Open questions"), draft.content.openQuestions.joined(separator: "\n"),
                               existing: current?.openQuestions.joined(separator: "\n"), replace: $replaceQuestions)
                    if !draft.content.tasks.isEmpty {
                        Label(L("New tasks will appear as suggestions for review."), systemImage: "checklist")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(L("Cancel"), role: .cancel) { dismiss() }.disabled(applying)
                Button(L("Apply")) {
                    applying = true
                    Task { @MainActor in
                        defer { applying = false }
                        do {
                            try await attention.applyHistoryOutcome(draft, card: card, replaceSummary: replaceSummary,
                                replaceDecisions: replaceDecisions, replaceQuestions: replaceQuestions)
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                }.buttonStyle(.borderedProminent).disabled(applying)
            }
        }.padding(20).frame(width: 620, height: 520).tint(.orange)
    }

    private func comparison(_ title: String, _ draft: String, existing: String?, replace: Binding<Bool>) -> some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 8) {
                if let existing, !existing.isEmpty {
                    Text(L("Current version")).font(.caption).foregroundStyle(.secondary)
                    Text(existing).textSelection(.enabled)
                    Divider()
                }
                Text(L("Generated draft")).font(.caption).foregroundStyle(.secondary)
                Text(draft.isEmpty ? "—" : draft).textSelection(.enabled)
                if existing != nil {
                    Toggle(L("Use generated text"), isOn: replace)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
