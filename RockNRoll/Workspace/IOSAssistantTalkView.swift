import ConferenceCore
import SwiftUI

struct IOSAssistantTalkView: View {
    @ObservedObject var talk: IOSAssistantTalkController
    @ObservedObject var speech: IOSAssistantSpeechCoordinator
    @ObservedObject private var voiceStore = IOSVoiceStore.shared

    private let suggestions = [
        L("Join current meeting"),
        L("How many meetings this month?"),
        L("My open tasks"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if talk.messages.isEmpty {
                            emptyState
                        } else {
                            ForEach(talk.messages) { msg in
                                messageBubble(msg)
                                    .id(msg.id)
                            }
                        }

                        if let pending = talk.pendingApproval {
                            pendingCard(pending)
                                .id(pending.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: talk.messages.count) { _, _ in
                    if let last = talk.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            if talk.working {
                ProgressView(L("Thinking…"))
                    .controlSize(.small)
                    .padding(.vertical, 6)
            }

            if let err = talk.audioError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            if talk.listening || speech.wakeArmed {
                Label(
                    speech.livePartialText.isEmpty ? L("Listening…") : speech.livePartialText,
                    systemImage: "waveform"
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(.teal)
                .padding(.vertical, 4)
            }

            Divider()

            HStack(spacing: 8) {
                TextField(L("Ask Rock or give a command…"), text: $talk.draft)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.send)
                    .onSubmit { talk.submitDraft() }
                    .disabled(talk.working || talk.pendingApproval != nil)
                    .accessibilityIdentifier("ios.assistant.input")

                Button {
                    talk.togglePushToTalk()
                } label: {
                    Image(systemName: talk.listening ? "stop.circle.fill" : "mic.fill")
                        .font(.title3)
                        .foregroundStyle(talk.listening ? Color.red : Color.accentColor)
                }
                .accessibilityLabel(talk.listening ? L("Stop listening") : L("Speak command"))
                .accessibilityIdentifier("ios.assistant.mic")

                Button {
                    talk.submitDraft()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title3)
                }
                .disabled(talk.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || talk.working || talk.pendingApproval != nil)
                .accessibilityIdentifier("ios.assistant.send")
            }
            .padding()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(L("New")) { talk.newConversation() }
                    .disabled(talk.messages.isEmpty || talk.working)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.circle")
                .font(.system(size: 44))
                .foregroundStyle(.teal)
            Text(L("Ask Rock"))
                .font(.title3.weight(.semibold))
            Text(L("Say “Rock, …” or tap the mic to join a meeting, check monthly stats, review tasks, or switch modes."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            VStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { prompt in
                    Button {
                        talk.submitSuggestion(prompt)
                    } label: {
                        Text(prompt)
                            .font(.subheadline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    @ViewBuilder
    private func messageBubble(_ message: IOSAssistantTalkController.Message) -> some View {
        let isUser = message.role == .user
        let playing = talk.auditioningMessageID == message.id
        VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
            Text(message.text)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    isUser
                        ? Color.accentColor.opacity(0.14)
                        : (message.role == .system ? Color.orange.opacity(0.14) : Color(uiColor: .secondarySystemGroupedBackground)),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
            if message.role == .assistant {
                Button {
                    talk.toggleAudition(messageID: message.id, text: message.text)
                } label: {
                    Label(playing ? L("Stop") : L("Speak"), systemImage: playing ? "stop.circle.fill" : "speaker.wave.2")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(playing ? Color.accentColor : .secondary)
                .accessibilityIdentifier("ios.assistant.audition")
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    private func pendingCard(_ pending: IOSAssistantTalkController.PendingApproval) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(pending.title)
                .font(.headline)
            if !pending.detail.isEmpty {
                Text(pending.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button(L("Confirm")) { talk.confirmPendingApproval() }
                    .buttonStyle(.borderedProminent)
                Button(L("Cancel"), role: .cancel) { talk.cancelPendingApproval() }
                    .buttonStyle(.bordered)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Compact floating HUD banner displayed on Home when wake listening is armed/triggered or
/// an assistant voice reply needs confirmation or audio control.
struct IOSAssistantVoiceHUDBanner: View {
    @ObservedObject var talk: IOSAssistantTalkController
    @ObservedObject var speech: IOSAssistantSpeechCoordinator
    var openAsk: () -> Void

    private var visible: Bool {
        speech.wakeArmed
            || talk.listening
            || talk.working
            || talk.auditioningMessageID != nil
            || talk.pendingApproval != nil
    }

    var body: some View {
        if visible {
            HStack(spacing: 10) {
                Image(systemName: talk.auditioningMessageID != nil ? "speaker.wave.2.fill" : "waveform.circle.fill")
                    .font(.title3)
                    .foregroundStyle(talk.pendingApproval != nil ? Color.orange : .teal)

                VStack(alignment: .leading, spacing: 2) {
                    Text(headline)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 4)

                if talk.pendingApproval != nil {
                    Button(L("Confirm")) { talk.confirmPendingApproval() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button(L("Cancel")) { talk.cancelPendingApproval() }
                        .controlSize(.small)
                } else if talk.auditioningMessageID != nil {
                    Button(L("Stop")) { talk.stopAudition() }
                        .controlSize(.small)
                }

                Button(L("Ask"), action: openAsk)
                    .font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.quaternary))
            .padding(.horizontal, 16)
        }
    }

    private var headline: String {
        if let pending = talk.pendingApproval { return pending.title }
        if talk.auditioningMessageID != nil { return L("Assistant speaking") }
        if talk.working { return L("Thinking…") }
        if talk.listening { return L("Listening…") }
        if speech.wakeArmed { return L("Rock is listening…") }
        return L("Assistant")
    }

    private var detail: String? {
        if let pending = talk.pendingApproval, !pending.detail.isEmpty { return pending.detail }
        if !speech.livePartialText.isEmpty { return speech.livePartialText }
        if talk.auditioningMessageID != nil { return talk.lastVoiceAnswer }
        return nil
    }
}
