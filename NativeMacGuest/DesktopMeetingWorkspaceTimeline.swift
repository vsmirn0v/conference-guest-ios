import SwiftUI

extension MeetingWorkspaceSession {
    var visibleEvents: [MeetingWorkspaceEvent] {
        let linkedChat = Set(events.compactMap(\.linkedChatID))
        return events.filter { $0.kind != .chat || !linkedChat.contains($0.id) }
    }
}

extension MeetingWorkspaceEvent {
    var displayAuthor: String {
        if kind == .assistantReply { return isPrivate ? L("Assistant") : L("You · via assistant") }
        if kind == .privateGuidance { return L("Your private guidance") }
        return author ?? (kind == .transcript ? L("Unknown speaker") : L("Conversation"))
    }

    var displayText: String {
        if kind == .captureGap {
            return switch source {
            case "connection": L("Speech capture paused while the meeting connection was unavailable.")
            case "transcriptionFailed": L("Speech capture failed during this period.")
            case "transcriptionPaused": L("Speech transcription was paused.")
            case "decode": L("Some speech could not be transcribed on this Mac.")
            case "finalization": L("Some final speech could not be saved before the meeting closed.")
            default: L("Speech transcription was unavailable.")
            }
        }
        if kind == .action {
            switch source {
            case "pause": return L("Assistant paused")
            case "resume": return L("Assistant resumed")
            case "takeover": return L("You took over")
            case "soundOn": return L("Meeting sound on")
            case "soundOff": return L("Meeting sound off")
            default: break
            }
        }
        return text ?? L("Text unavailable")
    }

    var displayStatus: String {
        switch status {
        case .queued: return L("Draft · waiting")
        case .sending:
            switch source {
            case "voice", "approvedVoice", "ruleVoice": return L("Playback in progress")
            case "approvedReaction": return L("Sending reaction")
            default: return L("Sending to meeting chat")
            }
        case .sent: return L("Observed in meeting chat")
        case .spoken: return L("Played into meeting audio")
        case .failed: return L("Delivery failed")
        case .held: return L("Draft · held")
        case .cancelled: return L("Cancelled")
        case .interrupted: return L("Interrupted")
        case .unknown: return L("Delivery unknown")
        case .accepted: return L("Accepted by the service")
        case .submitted: return L("Submitted · delivery unconfirmed")
        case .privateOnly: return L("Private text · not sent")
        case nil: break
        }
        return switch kind {
        case .assistantReply: isPrivate ? L("Private text · not sent") : L("Delivery unknown")
        case .privateGuidance: L("Private")
        case .chat: L("Meeting chat")
        case .transcript: source == "local" ? L("On-device transcript") : L("Service transcript")
        case .captureGap: L("Speech capture gap")
        case .action: L("Workspace activity")
        }
    }

    var timelineSymbol: String {
        switch kind {
        case .assistantReply: isPrivate ? "lock" : "sparkle"
        case .privateGuidance: "lock"
        case .chat: "bubble.left"
        case .transcript: "waveform"
        case .captureGap: "waveform.slash"
        case .action: "clock"
        }
    }

    func matches(_ query: String) -> Bool {
        query.isEmpty || displayText.localizedStandardContains(query) || displayAuthor.localizedStandardContains(query)
            || displayStatus.localizedStandardContains(query)
            || revisions.contains { $0.text.localizedStandardContains(query) || $0.author?.localizedStandardContains(query) == true }
            || sourceSnapshots.contains { $0.title.localizedStandardContains(query) || $0.text?.localizedStandardContains(query) == true }
    }
}

struct WorkspaceTimeline: View {
    let events: [MeetingWorkspaceEvent]
    let empty: String
    let live: Bool
    let followsLatest: Bool
    let selectedID: String?
    let onSelect: (String) -> Void
    let onBookmark: (String) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if events.isEmpty {
                        Text(empty).font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center).padding(14)
                    }
                    ForEach(events) { event in
                        WorkspaceTimelineRow(event: event, live: live, selected: event.id == selectedID,
                            select: { onSelect(event.id) }, bookmark: { onBookmark(event.id) })
                            .id(event.id)
                    }
                }
                .padding(.trailing, 5)
            }
            .onAppear { scrollIfFollowing(proxy) }
            .onChange(of: followsLatest) { _ in scrollIfFollowing(proxy) }
            .onChange(of: events.last?.id) { _ in scrollIfFollowing(proxy) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("meetingWorkspace.timeline")
    }

    private func scrollIfFollowing(_ proxy: ScrollViewProxy) {
        guard live, followsLatest, let id = events.last?.id else { return }
        proxy.scrollTo(id, anchor: .bottom)
    }
}

private struct WorkspaceTimelineRow: View {
    let event: MeetingWorkspaceEvent
    let live: Bool
    let selected: Bool
    let select: () -> Void
    let bookmark: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if event.kind == .captureGap || event.kind == .action {
                Label(event.displayText, systemImage: event.timelineSymbol)
                    .font(.caption).foregroundStyle(event.kind == .captureGap ? .orange : .secondary)
                HStack(spacing: 3) {
                    Text(event.occurredAt, style: .time)
                    if let end = event.endedAt { Text("–"); Text(end, style: .time) }
                }.font(.caption2).foregroundStyle(.secondary)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(event.displayAuthor).font(.caption.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(event.timeIsObserved
                         ? L("Observed at %@", workspaceDate(event.occurredAt))
                         : workspaceDate(event.occurredAt))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    Button(action: bookmark) {
                        Image(systemName: event.isBookmarked ? "bookmark.fill" : "bookmark").font(.caption)
                    }
                    .buttonStyle(.borderless).foregroundStyle(event.isBookmarked ? .teal : .secondary)
                    .accessibilityLabel(event.isBookmarked ? L("Remove bookmark") : L("Bookmark entry"))
                }
                Text(event.displayText).font(.callout).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Label(event.displayStatus, systemImage: event.timelineSymbol)
                        .font(.caption2).foregroundStyle(.secondary)
                    if event.kind == .assistantReply {
                        Button(live ? L("Why this reply") : L("Review this reply"), action: select)
                            .buttonStyle(.borderless).font(.caption2.weight(.semibold))
                    } else if event.revisions.count > 1 {
                        Text(L("Corrected")).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if !live, event.kind == .transcript || event.kind == .chat {
                    if event.revisions.count > 1 {
                        DisclosureGroup(L("Earlier text")) {
                            ForEach(Array(event.revisions.dropLast().enumerated()), id: \.offset) { _, revision in
                                Text(revision.text).font(.caption).textSelection(.enabled)
                            }
                        }.font(.caption)
                    }
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint, in: RoundedRectangle(cornerRadius: 7))
    }

    private var tint: Color {
        if selected { return .teal.opacity(0.18) }
        if event.kind == .assistantReply && !event.isPrivate { return .teal.opacity(0.08) }
        if event.kind == .captureGap { return .orange.opacity(0.07) }
        if event.isPrivate { return .secondary.opacity(0.075) }
        return .clear
    }
}

struct WorkspaceReplyEvidence: View {
    let event: MeetingWorkspaceEvent
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.headline)
            Text(event.displayText).font(.callout).textSelection(.enabled)
            Label(event.displayStatus, systemImage: event.timelineSymbol)
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if event.status == .spoken {
                Text(L("Playback into meeting audio was recorded. Participant audibility is unverified."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if event.sourceSnapshots.isEmpty {
                Text(L("No reply context was saved.")).font(.caption).foregroundStyle(.secondary)
            } else {
                Divider()
                Text(L("Context at the time")).font(.subheadline.weight(.semibold))
                ForEach(event.sourceSnapshots) { source in
                    DisclosureGroup(sourceTitle(source)) {
                        if source.id.hasPrefix("trigger:") {
                            Text(source.title).font(.caption.weight(.semibold))
                        }
                        if let text = source.text {
                            Text(text).font(.callout).textSelection(.enabled).padding(.top, 4)
                        } else {
                            Text(L("Excerpt unavailable")).font(.caption).foregroundStyle(.secondary)
                        }
                    }.font(.caption)
                }
            }
            if event.revisions.count > 1 {
                Divider()
                DisclosureGroup(L("Draft revisions")) {
                    ForEach(Array(event.revisions.enumerated()), id: \.offset) { _, revision in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(revision.observedAt, style: .time).font(.caption2).foregroundStyle(.secondary)
                            Text(revision.text).font(.caption).textSelection(.enabled)
                        }.padding(.top, 4)
                    }
                }.font(.caption)
            }
            if event.statusHistory.count > 1 {
                DisclosureGroup(L("Delivery history")) {
                    ForEach(Array(event.statusHistory.enumerated()), id: \.offset) { _, change in
                        HStack {
                            Text(event.statusLabel(change.status))
                            Spacer(minLength: 4)
                            Text(change.at, style: .time).foregroundStyle(.secondary)
                        }.font(.caption)
                    }
                }.font(.caption)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sourceTitle(_ source: MeetingWorkspaceEvent.SourceSnapshot) -> String {
        if source.id.hasPrefix("trigger:") { return L("What it responded to") }
        switch source.id {
        case "meeting-metadata": return L("Meeting information")
        case "meeting-note": return L("Meeting notes")
        case "guidance:liveGuidance": return L("Private guidance")
        case "guidance:reviewGuidance": return L("Review guidance")
        default: return source.title
        }
    }
}

private extension MeetingWorkspaceEvent {
    func statusLabel(_ status: Status) -> String {
        var observed = self
        observed.statusHistory = [.init(status: status, at: occurredAt)]
        return observed.displayStatus
    }
}
