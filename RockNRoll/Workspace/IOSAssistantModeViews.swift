import ConferenceCore
import SwiftUI

struct IOSAssistantModePill: View {
    let mode: IOSMeetingAssistantMode
    let isPaused: Bool
    let alertCount: Int
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: mode.symbol)
                    .font(.caption.weight(.semibold))
                Text(isPaused ? L("Paused") : mode.shortTitle)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                if alertCount > 0 {
                    Text("\(alertCount)")
                        .font(.caption2.bold())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.orange, in: Capsule())
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(pillBackground, in: Capsule())
            .foregroundStyle(pillForeground)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L("Assistant mode: %@", mode.title))
    }

    private var pillBackground: Color {
        if isPaused { return .orange.opacity(0.16) }
        switch mode {
        case .off: return Color.secondary.opacity(0.12)
        case .mentions: return Color.blue.opacity(0.14)
        case .follow: return Color.indigo.opacity(0.14)
        case .participating: return Color.green.opacity(0.16)
        }
    }

    private var pillForeground: Color {
        if isPaused { return .orange }
        switch mode {
        case .off: return .secondary
        case .mentions: return .blue
        case .follow: return .indigo
        case .participating: return .green
        }
    }
}

struct IOSAssistantAlertCardView: View {
    let card: IOSAssistantAlertCard
    @ObservedObject var assistant: IOSAssistantCoordinator
    var showMeetingTitle: Bool = true
    var canSendChat: Bool = true
    var onFocusMeeting: (() -> Void)? = nil

    @State private var draftReply: String
    @State private var isWorking = false
    @State private var actionError: String?

    init(
        card: IOSAssistantAlertCard,
        assistant: IOSAssistantCoordinator,
        showMeetingTitle: Bool = true,
        canSendChat: Bool = true,
        onFocusMeeting: (() -> Void)? = nil
    ) {
        self.card = card
        self.assistant = assistant
        self.showMeetingTitle = showMeetingTitle
        self.canSendChat = canSendChat
        self.onFocusMeeting = onFocusMeeting
        _draftReply = State(initialValue: card.suggestedReply)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: card.urgency == .now ? "bell.badge.fill" : card.mode.symbol)
                    .foregroundStyle(card.urgency == .now ? .orange : .accentColor)
                if showMeetingTitle {
                    Text(card.meetingTitle)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                } else {
                    Text(card.urgency == .now ? L("Needs you now") : L("Heads up"))
                        .font(.subheadline.weight(.semibold))
                }
                Spacer()
                Text(card.createdAt, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(card.reason)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)

            if !card.excerpt.isEmpty {
                Text("“\(card.excerpt)”")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            if let deliveryNote = card.deliveryNote, !deliveryNote.isEmpty {
                Label(deliveryNote, systemImage: card.deliveryFailed ? "exclamationmark.triangle" : "checkmark")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(card.deliveryFailed ? Color.orange : .green)
            }

            if card.mode == .participating || !draftReply.isEmpty {
                TextField(L("Draft reply…"), text: $draftReply, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.subheadline)
                    .lineLimit(1...4)
                    .onChange(of: draftReply) { _, newValue in
                        assistant.updateCardDraft(card.id, text: newValue)
                    }
            }

            if let actionError {
                Text(actionError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 8) {
                let cleanReply = draftReply.trimmingCharacters(in: .whitespacesAndNewlines)
                if canSendChat && !cleanReply.isEmpty {
                    Button {
                        perform {
                            assistant.updateCardDraft(card.id, text: cleanReply)
                            try await assistant.sendCardToChat(card.id)
                        }
                    } label: {
                        Label(L("Send chat"), systemImage: "paperplane.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isWorking)
                }

                if !cleanReply.isEmpty {
                    Button {
                        perform {
                            assistant.updateCardDraft(card.id, text: cleanReply)
                            try await assistant.speakCardReply(card.id)
                        }
                    } label: {
                        Label(L("Speak"), systemImage: "waveform")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isWorking)
                }

                if let onFocusMeeting {
                    Button(L("Open"), action: onFocusMeeting)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }

                Spacer()

                Button {
                    assistant.dismissCard(card.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel(L("Dismiss alert"))
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func perform(_ work: @escaping () async throws -> Void) {
        isWorking = true
        actionError = nil
        Task {
            do {
                try await work()
            } catch {
                actionError = error.localizedDescription
            }
            isWorking = false
        }
    }
}

struct IOSAssistantModeSheet: View {
    let controllerID: UUID
    let meetingTitle: String
    let canSendChat: Bool
    @ObservedObject var assistant: IOSAssistantCoordinator
    var speech: IOSAssistantSpeechCoordinator? = nil
    var onFocusMeeting: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var rememberForRoom = false
    @State private var output: IOSParticipationOutput
    @State private var askBeforeSending: Bool
    @State private var goalDraft: String
    @State private var dictatingGoal = false
    @State private var updatingGoalFromSpeech = false

    init(
        controllerID: UUID,
        meetingTitle: String,
        canSendChat: Bool,
        assistant: IOSAssistantCoordinator,
        speech: IOSAssistantSpeechCoordinator? = nil,
        onFocusMeeting: (() -> Void)? = nil
    ) {
        self.controllerID = controllerID
        self.meetingTitle = meetingTitle
        self.canSendChat = canSendChat
        self.assistant = assistant
        self.speech = speech
        self.onFocusMeeting = onFocusMeeting
        _output = State(initialValue: assistant.effectiveParticipationOutput(for: controllerID))
        _askBeforeSending = State(initialValue: assistant.effectiveAskBeforeSending(for: controllerID))
        _goalDraft = State(initialValue: assistant.effectiveParticipationGoal(for: controllerID))
    }

    private var activeMode: IOSMeetingAssistantMode {
        assistant.resolvedMode(for: controllerID)
    }

    private var sessionCards: [IOSAssistantAlertCard] {
        assistant.alertCards.filter { $0.controllerID == controllerID && !$0.dismissed }
    }

    private var sessionActivity: [IOSAssistantActivityItem] {
        assistant.activityLog.filter { $0.controllerID == controllerID }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(IOSMeetingAssistantMode.allCases) { mode in
                        Button {
                            assistant.setMode(mode, for: controllerID, rememberForRoom: rememberForRoom)
                            if mode == .participating {
                                maybeAutoStartGoalDictation()
                            } else {
                                stopGoalDictation(commit: false)
                            }
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: mode.symbol)
                                    .font(.title3)
                                    .foregroundStyle(activeMode == mode ? Color.accentColor : .secondary)
                                    .frame(width: 28, alignment: .center)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(mode.title)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                    Text(mode.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 8)
                                if activeMode == mode {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    Toggle(L("Remember mode for this room"), isOn: $rememberForRoom)
                        .onChange(of: rememberForRoom) { _, newValue in
                            if newValue {
                                assistant.setMode(activeMode, for: controllerID, rememberForRoom: true)
                            }
                        }
                } header: {
                    Text(meetingTitle)
                } footer: {
                    if activeMode != .off, let error = assistant.evaluationErrors[controllerID] {
                        Text(error).foregroundStyle(.red)
                    }
                    if let status = assistant.lastStatusNoteBySession[controllerID] {
                        Text(status)
                    }
                    if activeMode != .off && !assistant.hasModelConfigured() {
                        Text(L("Local mention detection is active. Configure Apple Intelligence or an AI API key in Settings -> Meeting Assistant for deeper context follow-up."))
                    }
                }

                if activeMode == .participating {
                    Section(L("Participation Settings")) {
                        Picker(L("Reply channel"), selection: $output) {
                            ForEach(IOSParticipationOutput.allCases) { ch in
                                Label(ch.title, systemImage: ch.symbol).tag(ch)
                            }
                        }
                        .onChange(of: output) { _, _ in syncParticipationOptions() }

                        Toggle(L("Ask before replying"), isOn: $askBeforeSending)
                            .onChange(of: askBeforeSending) { _, _ in syncParticipationOptions() }

                        HStack(alignment: .top, spacing: 8) {
                            TextField(L("Goal for assistant (optional)"), text: goalTextBinding, axis: .vertical)
                                .lineLimit(2...4)
                                .accessibilityIdentifier("assistant.mode.goal")
                            if speech != nil {
                                Button {
                                    dictatingGoal ? stopGoalDictation(commit: true) : startGoalDictation()
                                } label: {
                                    Image(systemName: dictatingGoal ? "stop.circle.fill" : "mic.fill")
                                        .font(.title3)
                                        .foregroundStyle(dictatingGoal ? Color.red : Color.accentColor)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("assistant.mode.dictate")
                                .accessibilityLabel(dictatingGoal ? L("Stop dictation") : L("Speak context"))
                            }
                        }
                        if dictatingGoal {
                            Label(L("Listening — speak your meeting context…"), systemImage: "waveform")
                                .font(.caption)
                                .foregroundStyle(.teal)
                        }

                        if !canSendChat && (output == .chat || output == .voiceAndChat) {
                            Text(L("Meeting chat is currently unavailable; voice replies will be used or drafted."))
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }

                        Button {
                            Task { await assistant.evaluateNow(controllerID: controllerID) }
                        } label: {
                            HStack {
                                Label(L("Check conversation now"), systemImage: "sparkles")
                                if assistant.evaluatingSessions.contains(controllerID) {
                                    Spacer()
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(assistant.evaluatingSessions.contains(controllerID))
                    }
                }

                if !sessionCards.isEmpty {
                    Section(L("Alerts & Suggested Replies")) {
                        ForEach(sessionCards) { card in
                            IOSAssistantAlertCardView(
                                card: card,
                                assistant: assistant,
                                showMeetingTitle: false,
                                canSendChat: canSendChat,
                                onFocusMeeting: onFocusMeeting.map { fn in
                                    {
                                        dismiss()
                                        fn()
                                    }
                                }
                            )
                            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                            .listRowBackground(Color.clear)
                        }
                    }
                }

                if !sessionActivity.isEmpty {
                    Section(L("Recent Activity")) {
                        ForEach(sessionActivity.prefix(8)) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(item.mode.title)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    if let channel = item.deliveredChannel {
                                        Text("· \(channel)")
                                            .font(.caption.weight(.medium))
                                            .foregroundStyle(.green)
                                    }
                                    Spacer()
                                    Text(item.at, style: .time)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Text(item.summary)
                                    .font(.subheadline)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .navigationTitle(L("Assistant Mode"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Done")) {
                        stopGoalDictation(commit: false)
                        syncParticipationOptions()
                        dismiss()
                    }
                }
            }
            .onAppear { maybeAutoStartGoalDictation() }
            .onDisappear { stopGoalDictation(commit: false) }
        }
    }

    private var goalTextBinding: Binding<String> {
        Binding(
            get: { goalDraft },
            set: { newValue in
                if dictatingGoal && !updatingGoalFromSpeech {
                    stopGoalDictation(commit: false)
                }
                goalDraft = newValue
                syncParticipationOptions()
            }
        )
    }

    private func maybeAutoStartGoalDictation() {
        guard activeMode == .participating,
              goalDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !dictatingGoal else { return }
        startGoalDictation()
    }

    private func startGoalDictation() {
        guard let speech else { return }
        dictatingGoal = true
        speech.startDictation(
            onPartial: { partial in
                updatingGoalFromSpeech = true
                goalDraft = partial
                updatingGoalFromSpeech = false
                syncParticipationOptions()
            },
            onFinal: { finalText in
                updatingGoalFromSpeech = true
                let clean = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty {
                    goalDraft = clean
                    syncParticipationOptions()
                }
                updatingGoalFromSpeech = false
                dictatingGoal = false
            }
        )
    }

    private func stopGoalDictation(commit: Bool) {
        guard dictatingGoal else { return }
        dictatingGoal = false
        speech?.stopDictation(commit: commit)
    }

    private func syncParticipationOptions() {
        assistant.setParticipationOptions(
            for: controllerID,
            askBeforeSending: askBeforeSending,
            output: output,
            goal: goalDraft
        )
    }
}

struct IOSActiveMeetingAssistantPill: View {
    let controllerID: UUID
    @ObservedObject var assistant: IOSAssistantCoordinator
    var action: () -> Void

    var body: some View {
        let mode = assistant.resolvedMode(for: controllerID)
        let isPaused = assistant.isPausedForMicrophone(controllerID: controllerID)
        let alerts = assistant.alertCards.filter { $0.controllerID == controllerID && !$0.dismissed }.count
        IOSAssistantModePill(mode: mode, isPaused: isPaused, alertCount: alerts, action: action)
    }
}

struct IOSAssistantAlertsHomeSection: View {
    @ObservedObject var assistant: IOSAssistantCoordinator
    var canSendChat: (UUID) -> Bool
    var onFocusMeeting: (UUID) -> Void

    var body: some View {
        let cards = assistant.alertCards.filter { !$0.dismissed }
        if !cards.isEmpty {
            Section(L("Assistant Alerts")) {
                ForEach(cards) { card in
                    IOSAssistantAlertCardView(
                        card: card,
                        assistant: assistant,
                        showMeetingTitle: true,
                        canSendChat: canSendChat(card.controllerID),
                        onFocusMeeting: { onFocusMeeting(card.controllerID) }
                    )
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    .listRowBackground(Color.clear)
                }
            }
            .accessibilityIdentifier("home.assistant-alerts")
        }
    }
}
