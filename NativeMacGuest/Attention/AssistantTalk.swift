import AppKit
import AVFoundation
import Carbon.HIToolbox
import Combine
import CoreAudio
import SwiftUI

@MainActor final class AssistantTalkController: ObservableObject {
    struct Entry: Identifiable, Equatable {
        enum Role { case user, assistant }
        var id = UUID()
        var role: Role
        var text: String
        var at = Date()
    }
    struct Pending: Identifiable {
        var id = UUID()
        var command: AssistantCommand
        var context: AssistantCommandContext
        var title: String
        var detail: String
    }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var pending: Pending?
    @Published private(set) var working = false
    @Published private(set) var listening = false
    @Published var targetMeetingID: UUID?
    @Published private(set) var audioError: String?
    /// Session-scoped per-meeting send overrides on top of the persisted global default.
    @Published private(set) var sendPolicyOverrides: [UUID: AssistantMeetingSendPolicy] = [:]
    /// MCP requests are external callers: the native confirmation gate cannot be bypassed.
    private var externalMCPRequest = false
    // MARK: Agent runtime (typed tools, bounded loop; off unless the store flag is on)
    let agentRuntime = AssistantRuntime()
    @Published var agentPending: AssistantAgentApproval?
    @Published var ruleProposalReview: AssistantAutomationRuleProposal?
    var agentEnvironment: AssistantAgentEnvironment?

    weak var attention: AttentionCoordinator?
    private var captureTask: Task<Void, Never>?
    private var captureEngine: AVAudioEngine?
    private var captureMeeting: NativeDesktopMeetingModel?
    private var captureSamples: AssistantCaptureBuffer?
    private var captureRecognizerAcquired = false
    private var captureGeneration = UUID()
    /// Wall-clock limit for one hold. Cancelled on release, disable, and unregister.
    private var holdLimit: Task<Void, Never>?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    var joinMeeting: (AssistantMeetingReference) -> Bool = { _ in false }
    var leaveMeeting: (NativeDesktopMeetingModel) async -> Bool = { _ in false }
    var interpretOverride: ((AssistantCommandRequest) async throws -> AssistantCommand)?
    var headphoneRoute: () -> Bool = { false }
    var hotKeyMonitorCount: Int { monitors.count }
    var globalHotKeyInstalled: Bool { carbonHotKey != nil }
    @Published var hotKeyWarning: String?
    /// Set when Carbon registration fails. Keystrokes must not retry until install or the app becomes active.
    private var lastHotKeyFailure: OSStatus?
    /// Registration attempts are rate-limited: a busy event stream (repeated activations
    /// or focus churn) must not hammer RegisterEventHotKey and flood the diagnostics.
    private var lastHotKeyAttempt: Date?
    private var pushToTalkTicket: AnyCancellable?
    nonisolated(unsafe) private var carbonHotKey: EventHotKeyRef?
    nonisolated(unsafe) private var carbonHandler: EventHandlerRef?
    /// Read by the local event callback without hopping to the main actor.
    nonisolated(unsafe) private var textFocusedCache = false
    private var textFieldFocused: Bool {
        guard NSApp.isActive, let responder = NSApp.keyWindow?.firstResponder else { return false }
        return responder is NSTextView || responder is NSTextField
    }

    init(attention: AttentionCoordinator) {
        self.attention = attention
        headphoneRoute = { [weak attention] in
            AssistantHeadphoneRoute.isConnected(approved: attention?.store.headphoneUIDs ?? [])
        }
    }

    deinit {
        holdLimit?.cancel()
        if let carbonHotKey { UnregisterEventHotKey(carbonHotKey) }
        if let carbonHandler { RemoveEventHandler(carbonHandler) }
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func submit(_ text: String) {
        let clean = text.trimmed
        guard !clean.isEmpty else { return }
        Task { @MainActor [weak self] in await self?.run(clean) }
    }

    /// Typed text and recognized speech both arrive here. No command executes before
    /// the structured response has been parsed and checked against this context.
    func run(_ input: String) async {
        guard let attention, !working else { return }
        let clean = String(input.trimmed.prefix(2000))
        guard !clean.isEmpty else { return }
        guard pending == nil else { append(.assistant, L("Confirm or cancel the pending action first.")); return }
        if attention.store.agentAssistantEnabled {
            // The bounded agent runtime owns the conversation state; its items render instead of `entries`.
            guard agentPending == nil, ruleProposalReview == nil else {
                append(.assistant, L("Confirm or cancel the pending action first.")); return
            }
            working = true; defer { working = false }
            await runAgent(clean, external: externalMCPRequest)
            return
        }
        entries.append(.init(role: .user, text: clean)); trimEntries()
        working = true; defer { working = false }
        let context = makeContext()
        do {
            let provider = attention.store.provider
            let command = if let interpretOverride {
                try await interpretOverride(.init(input: clean, context: context))
            } else {
                try await provider.commandInterpreter(key: attention.store.apiKey(for: provider)).interpret(.init(input: clean, context: context))
            }
            try prepare(command, context: context, external: externalMCPRequest)
        } catch is CancellationError { return }
        catch { append(.assistant, error.localizedDescription) }
    }

    /// MCP callers use the same interpreter and confirmation state machine, but can never
    /// inherit a meeting's "send without asking" privilege. A command that would need a
    /// native confirmation is reported and cancelled instead of being executed.
    func runExternal(_ input: String) async -> (answer: String?, needsNativeConfirmation: Bool) {
        let previousCount = entries.count
        externalMCPRequest = true
        await run(input)
        externalMCPRequest = false
        if pending != nil {
            cancelPending()
            return (nil, true)
        }
        // The agent runtime pauses on its own approval or rule review; external callers
        // can never confirm those natively bound decisions.
        if agentPending != nil {
            cancelAgentPending()
            return (nil, true)
        }
        if ruleProposalReview != nil {
            discardReviewedRule()
            return (nil, true)
        }
        // Execution is scheduled concurrently; wait for its assistant answer entry.
        for _ in 0..<200 where !(entries.count > previousCount && entries.last?.role == .assistant) {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        if entries.count > previousCount, let last = entries.last, last.role == .assistant { return (last.text, false) }
        // Agent-runtime answers live in its own conversation, not in `entries`.
        if let last = agentRuntime.items.last, last.kind == .assistant { return (last.text, false) }
        return (nil, false)
    }

    /// Button equivalents use the same validation and confirmation path without an LLM call.
    func perform(_ command: AssistantCommand) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let context = makeContext()
            do { try prepare(command, context: context, external: false) }
            catch { append(.assistant, error.localizedDescription) }
        }
    }

    private func prepare(_ command: AssistantCommand, context: AssistantCommandContext, external: Bool) throws {
        var command = command
        // Resolve an implicit target before a confirmation can outlive the current selection.
        if command.meetingID == nil, [.setAttention, .leave, .mute, .sendChat, .say, .react, .readChat, .catchUp].contains(command.action) {
            guard let target = try meeting(nil, context: context) else { throw AssistantCommandError.missingField }
            command.meetingID = target.id
        }
        if command.meetingID != nil { targetMeetingID = command.meetingID }
        if command.needsConfirmation {
            let bypass = AssistantMeetingSendGate.bypass(
                external: external, sendBypassAllowed: command.sendBypassAllowed,
                meetingID: command.meetingID,
                policy: command.meetingID.flatMap { sendPolicyOverrides[$0] },
                globalDefault: attention?.store.agentMeetingSendDefault ?? .sendImmediately)
            if !bypass {
                pending = .init(command: command, context: context, title: confirmationTitle(command, context: context),
                    detail: confirmationDetail(command))
                return
            }
        }
        Task { @MainActor [weak self] in await self?.execute(command, context: context) }
    }

    func confirmPending() {
        guard let pending else { return }
        self.pending = nil
        Task { @MainActor [weak self] in await self?.execute(pending.command, context: pending.context) }
    }
    func cancelPending() { pending = nil; append(.assistant, L("Cancelled. Nothing was sent.")) }

    private func execute(_ command: AssistantCommand, context: AssistantCommandContext) async {
        guard let attention else { return }
        do {
            let answer = try await execute(command, context: context, attention: attention)
            append(.assistant, answer)
            await speakAnswer(answer)
        } catch { append(.assistant, error.localizedDescription) }
    }

    func execute(_ command: AssistantCommand, context: AssistantCommandContext,
                 attention: AttentionCoordinator) async throws -> String {
        let target = try meeting(command.meetingID, context: context)
        switch command.action {
        case .setAttention:
            guard let target, let model = activeModel(target.id), let mode = command.mode else { throw AssistantCommandError.missingField }
            attention.setMode(mode, for: model, scope: command.scope.modeScope)
            return L("Attention for “%@” is now %@.", target.title, mode.title)
        case .join:
            guard let target else { throw AssistantCommandError.missingField }
            if activeModel(target.id) != nil { attention.openMeeting(target.id); return L("Opened “%@”.", target.title) }
            guard joinMeeting(target) else { throw AssistantCommandError.unsupported }
            return L("Joining “%@”.", target.title)
        case .leave:
            guard let target, let model = activeModel(target.id) else { throw AssistantCommandError.unknownMeeting }
            guard await leaveMeeting(model) else { throw AssistantCommandError.unsupported }
            sendPolicyOverrides.removeValue(forKey: target.id)
            return L("Left “%@”.", target.title)
        case .mute:
            guard let target, let model = activeModel(target.id) else { throw AssistantCommandError.unknownMeeting }
            let muted = model.muteMicrophone()
            return muted ? L("Muting “%@”.", target.title) : L("Your microphone is already muted in “%@”.", target.title)
        case .sendChat:
            guard let target, let model = activeModel(target.id), model.chat.canSend,
                  attention.deliverChat(model, command.text) else { throw AssistantCommandError.unsupported }
            return L("Sent to “%@”: %@", target.title, command.text)
        case .say:
            guard let target, let model = activeModel(target.id), model.supportsVoiceReply else { throw AssistantCommandError.unsupported }
            let buffer = try await attention.synthesize(command.text)
            try await attention.deliverVoice(model, buffer)
            return L("Spoken into “%@”.", target.title)
        case .react:
            guard let target, let model = activeModel(target.id), let reaction = command.reaction,
                  model.canReact else { throw AssistantCommandError.unsupported }
            attention.deliverReaction(model, reaction)
            return L("Sent %@ to “%@”.", reaction.emoji, target.title)
        case .readChat:
            guard let target, let model = activeModel(target.id) else { throw AssistantCommandError.unknownMeeting }
            let rows = model.chat.items.suffix(command.count)
            guard !rows.isEmpty else { return L("No chat messages in “%@”.", target.title) }
            return rows.map { "\($0.sender): \($0.text)" }.joined(separator: "\n")
        case .catchUp:
            guard let target, let model = activeModel(target.id) else { throw AssistantCommandError.unknownMeeting }
            let cutoff = attention.now().addingTimeInterval(-Double(command.minutes) * 60)
            let speech = model.transcript.compactMap { line -> (Date, String)? in
                guard let at = line.sentAt, at >= cutoff else { return nil }
                return (at, "\(line.participantName): \(line.text)")
            }
            let chat = model.chat.items.filter { $0.sentAt >= cutoff }.map { ($0.sentAt, L("%@ (chat): %@", $0.sender, $0.text)) }
            let rows = (speech + chat).sorted { $0.0 < $1.0 }.suffix(60).map(\.1)
            return rows.isEmpty ? L("Nothing was said in the last %ld minutes.", command.minutes) : rows.joined(separator: "\n")
        case .remind:
            guard let id = command.momentID, let moment = attention.store.momentHistory.moment(id), let at = command.at else {
                throw AssistantCommandError.missingField
            }
            try await attention.remind(moment, at: at)
            return L("Reminder set for %@.", at.formatted(date: .abbreviated, time: .shortened))
        case .remember:
            attention.store.assistant.remember(command.text, kind: .you)
            return L("Remembered. You can review or delete it in Settings → Assistant → Memory.")
        }
    }

    /// Repair only an absent or closed target. A valid explicit choice survives
    /// microphone handovers because Assistant context never controls media ownership.
    @discardableResult
    func reconcileMeetingTarget() -> UUID? {
        let live = attention?.meetings().filter { !$0.isClosed } ?? []
        if let targetMeetingID, live.contains(where: { $0.sessionID == targetMeetingID }) { return targetMeetingID }
        targetMeetingID = (live.first(where: { $0.ownsMicrophone }) ?? live.first)?.sessionID
        return targetMeetingID
    }

    func makeContext() -> AssistantCommandContext {
        guard let attention else { return .init(meetings: [], moments: [], now: Date()) }
        let active = attention.meetings().filter { !$0.isClosed }.map {
            AssistantMeetingReference(id: $0.sessionID, title: $0.title, invitation: $0.invitation, active: true)
        }
        var known = Set(active.map(\.id)), refs = active
        let historical = attention.store.assistant.outcomes.map {
            AssistantMeetingReference(id: $0.meetingID ?? $0.id, title: $0.meetingTitle, invitation: $0.invitation, active: false)
        } + attention.store.momentHistory.moments.compactMap { moment in
            moment.meetingID.map { AssistantMeetingReference(id: $0, title: moment.meetingTitle, invitation: moment.invitation, active: false) }
        }
        for ref in historical where refs.count < 20 && !known.contains(ref.id) { known.insert(ref.id); refs.append(ref) }
        reconcileMeetingTarget()
        let moments = attention.store.momentHistory.moments.sorted { $0.updatedAt > $1.updatedAt }.prefix(20).map {
            AssistantMomentReference(id: $0.id, meetingTitle: $0.meetingTitle, reason: $0.verdict.reason)
        }
        return .init(meetings: refs, moments: Array(moments), now: attention.now())
    }

    private func meeting(_ id: UUID?, context: AssistantCommandContext) throws -> AssistantMeetingReference? {
        if let id {
            guard let ref = context.meetings.first(where: { $0.id == id }) else { throw AssistantCommandError.unknownMeeting }
            return ref
        }
        if let targetMeetingID, let selected = context.meetings.first(where: { $0.id == targetMeetingID && $0.active }) { return selected }
        let active = context.meetings.filter(\.active)
        if active.count == 1 { return active[0] }
        return nil
    }

    private func activeModel(_ id: UUID) -> NativeDesktopMeetingModel? {
        attention?.meetings().first { $0.sessionID == id && !$0.isClosed }
    }
    func allowsDirectSend(_ id: UUID) -> Bool { (sendPolicyOverrides[id] ?? .inherit) == .sendImmediately }
    func setDirectSend(_ enabled: Bool, for id: UUID) {
        setSendPolicy(enabled ? .sendImmediately : .inherit, for: id)
    }
    func sendPolicy(for id: UUID) -> AssistantMeetingSendPolicy { sendPolicyOverrides[id] ?? .inherit }
    func setSendPolicy(_ policy: AssistantMeetingSendPolicy, for id: UUID) {
        if policy == .inherit { sendPolicyOverrides.removeValue(forKey: id) }
        else { sendPolicyOverrides[id] = policy }
    }
    /// One resolver for the legacy path, the agent policy, and tests.
    func sendsWithoutAsking(_ id: UUID, globalDefault: AssistantMeetingSendDefault? = nil) -> Bool {
        let resolved = globalDefault ?? attention?.store.agentMeetingSendDefault ?? .sendImmediately
        return AssistantMeetingSendGate.bypass(external: false, sendBypassAllowed: true,
                                               meetingID: id, policy: sendPolicyOverrides[id],
                                               globalDefault: resolved)
    }

    private func append(_ role: Entry.Role, _ text: String) {
        entries.append(.init(role: role, text: String(text.prefix(5000)))); trimEntries()
    }
    private func trimEntries() { if entries.count > 40 { entries.removeFirst(entries.count - 40) } }

    private func confirmationTitle(_ command: AssistantCommand, context: AssistantCommandContext) -> String {
        let title = try? meeting(command.meetingID, context: context)?.title
        switch command.action {
        case .join: return L("Join “%@”?", title ?? L("this meeting"))
        case .sendChat: return L("Send chat to “%@”?", title ?? L("this meeting"))
        case .say: return L("Speak into “%@”?", title ?? L("this meeting"))
        case .react: return L("Send this reaction to “%@”?", title ?? L("this meeting"))
        case .leave: return L("Leave “%@”?", title ?? L("this meeting"))
        default: return L("Confirm this action?")
        }
    }
    private func confirmationDetail(_ command: AssistantCommand) -> String {
        switch command.action {
        case .sendChat, .say: return command.text
        case .react: return command.reaction?.emoji ?? ""
        case .leave: return L("The meeting outcome will be captured before leaving.")
        default: return ""
        }
    }

    private func speakAnswer(_ text: String) async {
        guard let attention, attention.store.talkBack else { return }
        audioError = nil
        // Check immediately before playback. Never fall back to speakers or meeting audio.
        guard headphoneRoute() else { audioError = L("Talk-back needs headphones selected as the Mac's output."); return }
        do {
            let buffer = try await attention.synthesize(text)
            guard headphoneRoute() else { audioError = L("Talk-back stopped because headphones are no longer the output."); return }
            try VoicePreviewPlayer.shared.play(buffer)
        } catch { audioError = error.localizedDescription }
    }

    // MARK: Push to talk

    /// `$pushToTalk` emits in willSet, so the value in the sink is the new setting and the property is still the old one.
    func observePushToTalk() {
        pushToTalkTicket = attention?.store.$pushToTalk.dropFirst().sink { [weak self] enabled in
            self?.installHotKey(enabled: enabled)
        }
    }

    func installHotKey(enabled: Bool? = nil) {
        let on = enabled ?? (attention?.store.pushToTalk == true)
        lastHotKeyFailure = nil
        removeHotKey()
        guard on else { return }
        refreshTextFocus(retryRegistration: true)
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged], handler: { [weak self] event in
            guard let self else { return event }
            self.scheduleFocusRefresh()
            let hot = event.type == .keyDown && event.keyCode == AssistantPushToTalkHotKey.space &&
                event.modifierFlags.contains(.option) && !event.isARepeat
            if hot && self.textFocusedCache { return event }
            if hot && self.carbonHotKey == nil {
                Task { @MainActor [weak self] in self?.carbonPressed(true) }
                return nil
            }
            if event.type == .keyUp && event.keyCode == AssistantPushToTalkHotKey.space && self.carbonHotKey == nil {
                Task { @MainActor [weak self] in self?.carbonPressed(false) }
            }
            return event
        }) { monitors.append(monitor) }
        for name in [NSText.didBeginEditingNotification, NSText.didEndEditingNotification,
                     NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let retry = note.name == NSApplication.didBecomeActiveNotification
                Task { @MainActor in self?.refreshTextFocus(retryRegistration: retry) }
            })
        }
    }

    private func scheduleFocusRefresh() {
        Task { @MainActor [weak self] in self?.refreshTextFocus() }
    }

    private func refreshTextFocus(retryRegistration: Bool = false) {
        textFocusedCache = textFieldFocused
        if retryRegistration { lastHotKeyFailure = nil }
        syncCarbonHotKey(enabled: attention?.store.pushToTalk == true)
    }

    /// Carbon consumes Option-Space, including from other apps, and reports both press and release.
    /// `enabled` is passed in from the publisher because that fires before the property changes.
    private func syncCarbonHotKey(enabled: Bool) {
        let want = enabled && !textFocusedCache
        // A failed registration stays failed until install or the app becomes active.
        if want, carbonHotKey == nil, lastHotKeyFailure == nil, hotKeyAttemptDue { registerCarbonHotKey() }
        if !want { unregisterCarbonHotKey() }
    }

    /// Re-arming on every activation is legitimate, but a burst of activations must collapse
    /// into at most one registration attempt every couple of seconds.
    private var hotKeyAttemptDue: Bool {
        guard let lastHotKeyAttempt else { return true }
        return Date().timeIntervalSince(lastHotKeyAttempt) >= 2
    }

    private static let carbonCallback: EventHandlerUPP = { _, event, user in
        guard let event, let user else { return OSStatus(eventNotHandledErr) }
        let talk = Unmanaged<AssistantTalkController>.fromOpaque(user).takeUnretainedValue()
        let kind = GetEventKind(event)
        let down = kind == UInt32(kEventHotKeyPressed)
        let up = kind == UInt32(kEventHotKeyReleased)
        guard down || up else { return OSStatus(eventNotHandledErr) }
        Task { @MainActor in talk.carbonPressed(down) }
        return noErr
    }

    private func registerCarbonHotKey() {
        lastHotKeyAttempt = Date()
        let specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        var handler: EventHandlerRef?
        let user = Unmanaged.passUnretained(self).toOpaque()
        let installed = specs.withUnsafeBufferPointer { buffer in
            InstallEventHandler(GetApplicationEventTarget(), Self.carbonCallback, buffer.count, buffer.baseAddress, user, &handler)
        }
        guard installed == noErr, let handler else {
            noteHotKeyFailure(installed)
            return
        }
        carbonHandler = handler
        let hotKeyID = EventHotKeyID(signature: 0x50545431, id: 1) // 'PTT1'
        var hotKey: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), hotKeyID, GetApplicationEventTarget(), 0, &hotKey)
        guard status == noErr, let hotKey else {
            RemoveEventHandler(handler)
            carbonHandler = nil
            noteHotKeyFailure(status)
            return
        }
        carbonHotKey = hotKey
        lastHotKeyFailure = nil
        if hotKeyWarning != nil { hotKeyWarning = nil }
    }

    private func noteHotKeyFailure(_ status: OSStatus) {
        let previous = lastHotKeyFailure
        lastHotKeyFailure = status
        guard previous != status else { return }
        probeLog("assistant-hotkey-failed", ["status": Int(status)])
        let warning = status == eventHotKeyExistsErr
            ? L("⌥Space is used by another app, so it works only in this app.")
            : L("Background ⌥Space could not be installed (%ld). It works only in this app.", Int(status))
        if hotKeyWarning != warning { hotKeyWarning = warning }
    }

    private func unregisterCarbonHotKey() {
        if let carbonHotKey { UnregisterEventHotKey(carbonHotKey) }
        carbonHotKey = nil
        if let carbonHandler { RemoveEventHandler(carbonHandler) }
        carbonHandler = nil
        // A release will not arrive after the hotkey is gone, so end any hold now.
        stopPushToTalk()
    }

    private func carbonPressed(_ down: Bool) {
        guard attention?.store.pushToTalk == true else { stopPushToTalk(); return }
        if down {
            guard !textFieldFocused else { return }
            startPushToTalk()
        } else {
            stopPushToTalk()
        }
    }

    func removeHotKey() {
        hotKeyWarning = nil
        stopPushToTalk()
        unregisterCarbonHotKey()
        for monitor in monitors { NSEvent.removeMonitor(monitor) }; monitors = []
        for observer in observers { NotificationCenter.default.removeObserver(observer) }; observers = []
    }

    func startPushToTalk() {
        guard let attention, attention.store.pushToTalk, !listening, captureTask == nil, !working else { return }
        guard let model = ListenModelStore.shared.recognizerModel() else {
            append(.assistant, L("Install a local transcription model in Settings → Assistant → Models first.")); return
        }
        armHoldLimit()
        let generation = UUID(); captureGeneration = generation; audioError = nil
        captureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                    _ = await AVCaptureDevice.requestAccess(for: .audio)
                }
                guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw VoiceSynthesisError.microphoneDenied }
                guard generation == captureGeneration else { return }
                // The microphone owner is the natural host; when nothing owns it
                // (a stale talk role, a concurrent join that never claimed) fall back
                // to the explicit target, then any live meeting — holdMicrophoneForAssistant
                // claims the microphone role when the chosen meeting does not hold it.
                // With no live meeting the hold is skipped: there is no send gate to close.
                let live = attention.meetings().filter { !$0.isClosed }
                let meeting = live.first(where: { $0.ownsMicrophone })
                    ?? targetMeetingID.flatMap { id in live.first(where: { $0.sessionID == id }) }
                    ?? live.first
                if let meeting, !meeting.ownsMicrophone {
                    probeLog("assistant-capture-claim", ["meeting": meeting.sessionID.uuidString])
                }
                if let meeting {
                    guard await meeting.holdMicrophoneForAssistant() else { throw AssistantCaptureError.gate }
                    guard generation == captureGeneration else { await meeting.releaseMicrophoneForAssistant(); return }
                }
                captureMeeting = meeting // from here every failure goes through stopPushToTalk's release
                let engine = AVAudioEngine(), input = engine.inputNode
                let inputFormat = input.outputFormat(forBus: 0)
                guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
                      let converter = AVAudioConverter(from: inputFormat, to: format) else { throw AssistantCaptureError.audio }
                let samples = AssistantCaptureBuffer()
                input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
                    let capacity = AVAudioFrameCount(max(1, Int((Double(buffer.frameLength) * 16_000 / inputFormat.sampleRate).rounded(.up)) + 32))
                    guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
                    var error: NSError?
                    var supplied = false
                    let status = converter.convert(to: output, error: &error) { _, status in
                        if supplied { status.pointee = .noDataNow; return nil }
                        supplied = true; status.pointee = .haveData; return buffer
                    }
                    if error != nil || status == .error { Task { @MainActor in self?.failCapture(AssistantCaptureError.audio) }; return }
                    guard let channel = output.floatChannelData?[0], output.frameLength > 0 else { return }
                    let full = samples.append(channel, count: Int(output.frameLength))
                    if full { Task { @MainActor in self?.stopPushToTalk() } }
                }
                captureEngine = engine; captureSamples = samples
                engine.prepare(); try engine.start()
                listening = true
                LocalSpeechRecognizer.shared.acquire(model); captureRecognizerAcquired = true
                probeLog("assistant-capture-start", ["meeting": meeting?.sessionID.uuidString ?? "local"])
            } catch {
                failCapture(error)
            }
        }
    }

    func stopPushToTalk() {
        cancelHoldLimit()
        captureGeneration = UUID()
        // A buffer limit and the wall-clock limit can both ask to stop. The first one
        // clears this state, so the second returns without starting another transcription.
        guard captureEngine != nil || captureMeeting != nil || captureTask != nil else { return }
        captureTask?.cancel(); captureTask = nil
        captureEngine?.inputNode.removeTap(onBus: 0); captureEngine?.stop(); captureEngine = nil
        listening = false
        let meeting = captureMeeting, samples = captureSamples?.values ?? []
        let acquired = captureRecognizerAcquired
        captureMeeting = nil; captureSamples = nil; captureRecognizerAcquired = false
        Task { @MainActor [weak self] in
            defer { if acquired { LocalSpeechRecognizer.shared.release() } }
            if let meeting { await meeting.releaseMicrophoneForAssistant() }
            let rms = AssistantCaptureBuffer.rms(samples)
            probeLog("assistant-capture-stop", ["samples": samples.count, "rms": String(format: "%.5f", rms)])
            guard let self, samples.count >= 3200, let model = ListenModelStore.shared.recognizerModel() else { return }
            let text: String? = await withCheckedContinuation { continuation in
                LocalSpeechRecognizer.shared.transcribe(samples, model: model) { text, _ in continuation.resume(returning: text) }
            }
            guard let clean = text?.trimmed, !clean.isEmpty else {
                // Empty text with a silent buffer means the tap captured nothing — another
                // app (or app instance) is holding the microphone, not a recognition miss.
                let message = rms < 0.001
                    ? L("No microphone audio was captured — the microphone may be in use by another app.")
                    : L("No speech was recognized. Nothing was sent.")
                append(.assistant, message); return
            }
            await run(clean)
        }
    }

    private func failCapture(_ error: Error) {
        audioError = error.localizedDescription
        stopPushToTalk()
    }

    /// One timer per hold. A repeated key-down does not extend it.
    private func armHoldLimit() {
        guard holdLimit == nil else { return }
        let seconds = AssistantCaptureLimit.holdSeconds
        holdLimit = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled else { return }
            self.stopPushToTalk()
        }
    }

    private func cancelHoldLimit() {
        holdLimit?.cancel()
        holdLimit = nil
    }
}

/// How long one push-to-talk hold may last. The sample cap and the wall-clock timer use the same duration,
/// so a stall that never fills the buffer still ends the hold.
enum AssistantCaptureLimit {
    static let holdSeconds = 30
    static let sampleRate = 16_000
    static var sampleLimit: Int { holdSeconds * sampleRate }
}

private final class AssistantCaptureBuffer: @unchecked Sendable {
    private let lock = NSLock(); private var storage: [Float] = []
    private var reportedFull = false
    private let limit = AssistantCaptureLimit.sampleLimit
    func append(_ samples: UnsafePointer<Float>, count: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        storage.append(contentsOf: UnsafeBufferPointer(start: samples, count: min(count, max(0, limit - storage.count))))
        guard storage.count >= limit, !reportedFull else { return false }
        reportedFull = true
        return true
    }
    var values: [Float] { lock.lock(); defer { lock.unlock() }; return storage }
    /// Root-mean-square level of a captured buffer. ~0.001 (-60 dBFS) is effectively silence.
    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        return Float((sum / Double(samples.count)).squareRoot())
    }
}

enum AssistantCaptureError: LocalizedError {
    case gate, audio
    var errorDescription: String? {
        switch self {
        case .gate: L("The meeting microphone could not be held back. Nothing was recorded.")
        case .audio: L("Local microphone capture failed. Nothing was sent to the meeting.")
        }
    }
}

/// Fail-closed headphone check for local talk-back. Speakers stay closed. A headphone
/// jack is enough; Bluetooth and USB count only after the person marks that device.
enum AssistantHeadphoneRoute {
    static let headphonesDataSource: UInt32 = 0x6864706e // 'hdpn'
    static let internalSpeaker: UInt32 = 0x6973706b // 'ispk'
    static let externalSpeaker: UInt32 = 0x6573706b // 'espk'
    static let bluetoothTransport: UInt32 = 0x626c7565 // 'blue'
    static let bluetoothLETransport: UInt32 = 0x626c6561 // 'blea'
    static let usbTransport: UInt32 = 0x75736220 // 'usb '
    static func isHeadphoneSource(_ source: UInt32) -> Bool { source == headphonesDataSource }
    static func isSpeakerSource(_ source: UInt32) -> Bool { source == internalSpeaker || source == externalSpeaker }
    static func isPeripheralTransport(_ transport: UInt32) -> Bool {
        transport == bluetoothTransport || transport == bluetoothLETransport || transport == usbTransport
    }
    /// `approved` holds device UIDs the person marked with "This is a headphone". Names are never read.
    static func accepts(source: UInt32, transport: UInt32, deviceUID: String, approved: Set<String>) -> Bool {
        if isHeadphoneSource(source) { return true }
        if isSpeakerSource(source) { return false }
        return isPeripheralTransport(transport) && !deviceUID.isEmpty && approved.contains(deviceUID)
    }
    struct Snapshot: Equatable {
        var deviceID: AudioDeviceID
        var uid: String
        var source: UInt32
        var transport: UInt32
    }
    static func outputDevice() -> Snapshot? {
        var device = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        var source = UInt32(0); size = UInt32(MemoryLayout<UInt32>.size)
        address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDataSource,
            mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        _ = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &source)
        var transport = UInt32(0); size = UInt32(MemoryLayout<UInt32>.size)
        address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        _ = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport)
        var unmanaged: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &unmanaged) == noErr, let unmanaged else { return nil }
        return Snapshot(deviceID: device, uid: unmanaged.takeRetainedValue() as String, source: source, transport: transport)
    }
    static func isConnected(approved: Set<String>) -> Bool {
        guard let device = outputDevice() else { return false }
        return accepts(source: device.source, transport: device.transport, deviceUID: device.uid, approved: approved)
    }
}

/// Refreshes the settings row when the default output device changes, and when that device's jack changes.
@MainActor final class HeadphoneOutputMonitor: ObservableObject {
    @Published private(set) var output: AssistantHeadphoneRoute.Snapshot?
    private var listener: AudioObjectPropertyListenerBlock?
    private var defaultAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    private var sourceAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDataSource,
        mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    private var watchedDevice: AudioDeviceID = 0

    init() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        listener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultAddress, DispatchQueue.main, block)
        refresh()
    }

    func refresh() {
        let next = AssistantHeadphoneRoute.outputDevice()
        if output != next { output = next }
        watchSource(of: next?.deviceID ?? 0)
    }

    private func watchSource(of device: AudioDeviceID) {
        guard let listener else { return }
        if watchedDevice != 0, watchedDevice != device {
            AudioObjectRemovePropertyListenerBlock(watchedDevice, &sourceAddress, DispatchQueue.main, listener)
            watchedDevice = 0
        }
        guard device != 0, device != watchedDevice else { return }
        AudioObjectAddPropertyListenerBlock(device, &sourceAddress, DispatchQueue.main, listener)
        watchedDevice = device
    }

    deinit {
        guard let listener else { return }
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultAddress, DispatchQueue.main, listener)
        if watchedDevice != 0 {
            AudioObjectRemovePropertyListenerBlock(watchedDevice, &sourceAddress, DispatchQueue.main, listener)
        }
    }
}

/// Option-Space. The decision looks only at the key code and the Option flag, never at typed characters.
enum AssistantPushToTalkHotKey {
    static let space: UInt16 = 49
    enum Action: Equatable { case start, stop, ignore }
    static func action(type: NSEvent.EventType, keyCode: UInt16, option: Bool, isRepeat: Bool,
                       enabled: Bool, appActive: Bool, textFocused: Bool, listening: Bool) -> Action {
        guard enabled else { return .ignore }
        if type == .keyDown, keyCode == space, option, !isRepeat {
            if appActive && textFocused { return .ignore }
            return .start
        }
        if type == .keyUp, keyCode == space { return .stop }
        if type == .flagsChanged, !option, listening { return .stop }
        return .ignore
    }
}

/// Typed commands and push-to-talk share AssistantTalkController's structured pipeline.
struct AssistantTalkView: View {
    @ObservedObject var attention: AttentionCoordinator
    @ObservedObject private var talk: AssistantTalkController
    // Observe the store so a push-to-talk toggle re-enables Listen immediately.
    @ObservedObject private var store: AttentionStore
    @ObservedObject private var agentRuntime: AssistantRuntime
    @ObservedObject private var ruleStore: AssistantRuleStore
    @State private var input = ""

    init(attention: AttentionCoordinator) {
        self.attention = attention
        _talk = ObservedObject(wrappedValue: attention.talk)
        _store = ObservedObject(wrappedValue: attention.store)
        _agentRuntime = ObservedObject(wrappedValue: attention.talk.agentRuntime)
        _ruleStore = ObservedObject(wrappedValue: attention.ruleStore)
    }

    private var liveMeetings: [NativeDesktopMeetingModel] { attention.meetings().filter { !$0.isClosed } }
    private var targetMeeting: NativeDesktopMeetingModel? {
        liveMeetings.first { $0.sessionID == talk.targetMeetingID }
    }
    private var inputPrompt: String {
        targetMeeting.map { L("Ask about %@ or request an action…", $0.title) }
            ?? L("Ask Assistant to read, remember, join, mute, or draft an action…")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Menu {
                    if let id = talk.targetMeetingID {
                        Button(L("Read latest chat")) { talk.perform(.init(action: .readChat, meetingID: id)) }
                        Button(L("Catch up for 10 minutes")) { talk.perform(.init(action: .catchUp, meetingID: id)) }
                        Button(L("Mute microphone")) { talk.perform(.init(action: .mute, meetingID: id)) }
                        Divider()
                        Picker(L("Chat, voice, and reactions"), selection: Binding(get: { talk.sendPolicy(for: id) },
                            set: { talk.setSendPolicy($0, for: id) })) {
                            Text(L("Use default")).tag(AssistantMeetingSendPolicy.inherit)
                            Text(L("Send immediately")).tag(AssistantMeetingSendPolicy.sendImmediately)
                            Text(L("Ask every time")).tag(AssistantMeetingSendPolicy.ask)
                        }
                        .pickerStyle(.inline)
                        .help(L("Only chat, spoken replies, and reactions in this active meeting. Leave always asks. “Use default” follows Settings → Assistant."))
                    }
                } label: { Label(L("Quick actions"), systemImage: "bolt") }
                    .disabled(talk.targetMeetingID == nil)
            }.padding(12)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if store.agentAssistantEnabled {
                        if agentRuntime.items.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "waveform").font(.largeTitle).foregroundStyle(.secondary)
                                Text(L("Talk to Assistant")).font(.title3)
                                Text(L("Ask about your meetings, outcomes, calendar, or request an action."))
                                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                            }.frame(maxWidth: .infinity).padding(.vertical, 50)
                        }
                        ForEach(agentRuntime.turns) { turn in
                            AssistantAgentTurnView(turn: turn)
                        }
                    } else if talk.entries.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "waveform").font(.largeTitle).foregroundStyle(.secondary)
                            Text(L("Talk to Assistant")).font(.title3)
                            if let targetMeeting {
                                Text(L("Ask about %@ or choose another meeting below.", targetMeeting.title))
                                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                            }
                            Text(L("Type a request, or hold ⌥Space. Your speech is recognized on this Mac."))
                                .foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }.frame(maxWidth: .infinity).padding(.vertical, 50)
                    }
                    if !store.agentAssistantEnabled {
                        ForEach(talk.entries) { entry in
                            Text(entry.text).textSelection(.enabled).padding(10)
                                .background(entry.role == .user ? Color.accentColor.opacity(0.1) : Color(nsColor: .controlBackgroundColor),
                                    in: RoundedRectangle(cornerRadius: 8))
                                .frame(maxWidth: .infinity, alignment: entry.role == .user ? .trailing : .leading)
                        }
                    }
                }.padding(16)
            }
            if let pending = talk.pending {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(pending.title).font(.headline)
                        if !pending.detail.isEmpty { Text(pending.detail).textSelection(.enabled) }
                        HStack {
                            Button(L("Confirm")) { talk.confirmPending() }.buttonStyle(.borderedProminent)
                                .accessibilityIdentifier("assistant.command.confirm")
                            Button(L("Cancel"), role: .cancel) { talk.cancelPending() }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.padding(.horizontal, 12)
            }
            if let approval = talk.agentPending {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(approval.title).font(.headline)
                        if !approval.detail.isEmpty { Text(approval.detail).textSelection(.enabled) }
                        Text(L("Expires at %@", approval.expiresAt.formatted(date: .omitted, time: .shortened)))
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button(L("Confirm")) { talk.confirmAgentPending() }.buttonStyle(.borderedProminent)
                                .accessibilityIdentifier("assistant.agent.confirm")
                            Button(L("Cancel"), role: .cancel) { talk.cancelAgentPending() }
                                .accessibilityIdentifier("assistant.agent.cancel")
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.padding(.horizontal, 12)
            }
            if let proposal = talk.ruleProposalReview {
                AssistantRuleReviewCard(proposal: proposal,
                    onEnable: { unattended in talk.enableReviewedRule(unattended: unattended) },
                    onDiscard: { talk.discardReviewedRule() })
                    .padding(.horizontal, 12)
            }
            ForEach(ruleStore.pendingActions) { pending in
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("Automation rule: mention reply")).font(.headline)
                        Text(L("“%@” in “%@”", pending.ruleText, pending.meetingTitle)).textSelection(.enabled)
                        Text(L("Expires at %@", pending.expiresAt.formatted(date: .omitted, time: .shortened)))
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button(L("Say it")) {
                                Task { @MainActor in
                                    let result = await attention.executeRuleAction(pending)
                                    if !result.isEmpty { talk.agentRuntime.appendSystemForUI(result) }
                                }
                            }.buttonStyle(.borderedProminent)
                            Button(L("Skip"), role: .cancel) { ruleStore.actionDenied(pending.id) }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.padding(.horizontal, 12)
            }
            if talk.working { ProgressView(L("Interpreting…")).controlSize(.small).padding(6) }
            if store.agentAssistantEnabled {
                HStack(spacing: 8) {
                    if talk.working {
                        Button(L("Cancel")) { talk.agentRuntime.cancel() }
                            .accessibilityIdentifier("assistant.agent.stop")
                    }
                    Spacer()
                    Button(L("New chat")) { talk.agentNewConversation() }
                        .disabled(talk.working)
                        .accessibilityIdentifier("assistant.agent.new")
                }.padding(.horizontal, 12)
            }
            if talk.listening { Label(L("Listening on this Mac… release ⌥Space to interpret"), systemImage: "mic.fill").foregroundStyle(.teal).padding(6) }
            if let error = talk.audioError { Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 12) }
            if !liveMeetings.isEmpty {
                HStack(spacing: 12) {
                    Menu {
                        ForEach(liveMeetings, id: \.sessionID) { model in
                            Button { talk.targetMeetingID = model.sessionID } label: {
                                if model.sessionID == talk.targetMeetingID { Label(model.title, systemImage: "checkmark") }
                                else { Text(model.title) }
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(L("For Assistant: %@", targetMeeting?.title ?? L("Choose a meeting"))).lineLimit(1).truncationMode(.middle)
                            Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
                        }.padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    }.menuStyle(.borderlessButton).menuIndicator(.hidden)
                        .frame(maxWidth: 250, alignment: .leading)
                        .accessibilityIdentifier("assistant.meeting-target")
                        .accessibilityLabel(L("Assistant meeting context"))
                        .help(L("Changes only the meeting Assistant talks about. It does not open the meeting or move microphone or sound."))
                    Spacer(minLength: 4)
                    if liveMeetings.count > 1 {
                        ViewThatFits(in: .horizontal) {
                            Text(L("%ld meetings connected · switching does not change microphone or sound", liveMeetings.count))
                            Text(L("%ld meetings · Assistant context only", liveMeetings.count))
                        }.font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }.padding(.horizontal, 12).padding(.top, 8)
            }
            HStack(spacing: 8) {
                TextField(inputPrompt, text: $input)
                    .textFieldStyle(.roundedBorder).onSubmit { send() }
                    .disabled(talk.working || talk.pending != nil || talk.agentPending != nil || talk.ruleProposalReview != nil)
                    .accessibilityIdentifier("assistant.input")
                Button(L("Ask")) { send() }.buttonStyle(.borderedProminent)
                    .disabled(input.trimmed.isEmpty || talk.working || talk.pending != nil || talk.agentPending != nil || talk.ruleProposalReview != nil)
                    .accessibilityIdentifier("assistant.ask")
                Button(talk.listening ? L("Stop") : L("Listen")) {
                    talk.listening ? talk.stopPushToTalk() : talk.startPushToTalk()
                }.disabled(!store.pushToTalk && !talk.listening)
                    .accessibilityIdentifier("assistant.listen")
            }.padding(12)
        }
        .onAppear { talk.reconcileMeetingTarget() }
        .onChange(of: liveMeetings.map(\.sessionID)) { _ in talk.reconcileMeetingTarget() }
    }

    private func send() { let text = input; input = ""; talk.submit(text) }
}
