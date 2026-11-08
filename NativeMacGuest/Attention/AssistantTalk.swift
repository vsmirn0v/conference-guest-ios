import AppKit
import AVFoundation
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
    @Published private var sendWithoutAsking: Set<UUID> = []

    private weak var attention: AttentionCoordinator?
    private var captureTask: Task<Void, Never>?
    private var captureEngine: AVAudioEngine?
    private var captureMeeting: NativeDesktopMeetingModel?
    private var captureSamples: AssistantCaptureBuffer?
    private var captureRecognizerAcquired = false
    private var captureGeneration = UUID()
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    var joinMeeting: (AssistantMeetingReference) -> Bool = { _ in false }
    var leaveMeeting: (NativeDesktopMeetingModel) async -> Bool = { _ in false }
    var interpretOverride: ((AssistantCommandRequest) async throws -> AssistantCommand)?
    var headphoneRoute: () -> Bool = { AssistantHeadphoneRoute.isConnected }

    init(attention: AttentionCoordinator) { self.attention = attention }

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
            try prepare(command, context: context)
        } catch is CancellationError { return }
        catch { append(.assistant, error.localizedDescription) }
    }

    /// Button equivalents use the same validation and confirmation path without an LLM call.
    func perform(_ command: AssistantCommand) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let context = makeContext()
            do { try prepare(command, context: context) }
            catch { append(.assistant, error.localizedDescription) }
        }
    }

    private func prepare(_ command: AssistantCommand, context: AssistantCommandContext) throws {
        var command = command
        // Resolve an implicit target before a confirmation can outlive the current selection.
        if command.meetingID == nil, [.leave, .mute, .readChat, .catchUp].contains(command.action) {
            guard let target = try meeting(nil, context: context) else { throw AssistantCommandError.missingField }
            command.meetingID = target.id
        }
        if command.meetingID != nil { targetMeetingID = command.meetingID }
        if command.needsConfirmation {
            let bypass = command.sendBypassAllowed && command.meetingID.map { sendWithoutAsking.contains($0) } == true
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

    private func execute(_ command: AssistantCommand, context: AssistantCommandContext,
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
            sendWithoutAsking.remove(target.id)
            return L("Left “%@”.", target.title)
        case .mute:
            guard let target, let model = activeModel(target.id) else { throw AssistantCommandError.unknownMeeting }
            if model.snapshot.microphoneOn || model.voiceReplyActive { model.toggleMicrophone() }
            return model.snapshot.microphoneOn ? L("Muting “%@”.", target.title) : L("Your microphone is already muted in “%@”.", target.title)
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

    private func makeContext() -> AssistantCommandContext {
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
        if targetMeetingID == nil { targetMeetingID = active.first?.id }
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
    func allowsDirectSend(_ id: UUID) -> Bool { sendWithoutAsking.contains(id) }
    func setDirectSend(_ enabled: Bool, for id: UUID) {
        if enabled { sendWithoutAsking.insert(id) } else { sendWithoutAsking.remove(id) }
    }

    private func append(_ role: Entry.Role, _ text: String) {
        entries.append(.init(role: role, text: String(text.prefix(5000)))); trimEntries()
    }
    private func trimEntries() { if entries.count > 40 { entries.removeFirst(entries.count - 40) } }

    private func confirmationTitle(_ command: AssistantCommand, context: AssistantCommandContext) -> String {
        let title = try? meeting(command.meetingID, context: context)?.title
        switch command.action {
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

    func installHotKey() {
        removeHotKey()
        func handle(_ event: NSEvent) {
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch event.type {
                case .keyDown where event.keyCode == 49 && event.modifierFlags.contains(.option) && !event.isARepeat:
                    startPushToTalk()
                case .keyUp where event.keyCode == 49: stopPushToTalk()
                case .flagsChanged where listening && !event.modifierFlags.contains(.option): stopPushToTalk()
                default: break
                }
            }
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged], handler: { event in
            handle(event); return event
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged], handler: handle) { monitors.append(monitor) }
        for name in [NSApplication.didResignActiveNotification, NSWindow.didResignKeyNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.stopPushToTalk() }
            })
        }
    }

    func removeHotKey() {
        stopPushToTalk()
        for monitor in monitors { NSEvent.removeMonitor(monitor) }; monitors = []
        for observer in observers { NotificationCenter.default.removeObserver(observer) }; observers = []
    }

    func startPushToTalk() {
        guard let attention, attention.store.pushToTalk, !listening, captureTask == nil, !working else { return }
        guard let model = ListenModelStore.shared.recognizerModel() else {
            append(.assistant, L("Install a local transcription model in Settings → Assistant → Models first.")); return
        }
        let generation = UUID(); captureGeneration = generation; audioError = nil
        captureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                    _ = await AVCaptureDevice.requestAccess(for: .audio)
                }
                guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw VoiceSynthesisError.microphoneDenied }
                guard generation == captureGeneration else { return }
                // Gate the meeting that owns physical input before opening a separate local tap.
                guard let meeting = attention.meetings().first(where: { $0.ownsMicrophone && !$0.isClosed }) else {
                    throw AssistantCaptureError.noMeeting
                }
                guard await meeting.holdMicrophoneForAssistant() else { throw AssistantCaptureError.gate }
                guard generation == captureGeneration else { await meeting.releaseMicrophoneForAssistant(); return }
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
                probeLog("assistant-capture-start", ["meeting": meeting.sessionID.uuidString])
            } catch {
                failCapture(error)
            }
        }
    }

    func stopPushToTalk() {
        captureGeneration = UUID()
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
            probeLog("assistant-capture-stop", ["samples": samples.count])
            guard let self, samples.count >= 3200, let model = ListenModelStore.shared.recognizerModel() else { return }
            let text: String? = await withCheckedContinuation { continuation in
                LocalSpeechRecognizer.shared.transcribe(samples, model: model) { text, _ in continuation.resume(returning: text) }
            }
            guard let clean = text?.trimmed, !clean.isEmpty else {
                append(.assistant, L("No speech was recognized. Nothing was sent.")); return
            }
            await run(clean)
        }
    }

    private func failCapture(_ error: Error) {
        audioError = error.localizedDescription
        stopPushToTalk()
    }
}

private final class AssistantCaptureBuffer: @unchecked Sendable {
    private let lock = NSLock(); private var storage: [Float] = []
    private let limit = 30 * 16_000
    func append(_ samples: UnsafePointer<Float>, count: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        storage.append(contentsOf: UnsafeBufferPointer(start: samples, count: min(count, max(0, limit - storage.count))))
        return storage.count >= limit
    }
    var values: [Float] { lock.lock(); defer { lock.unlock() }; return storage }
}

enum AssistantCaptureError: LocalizedError {
    case noMeeting, gate, audio
    var errorDescription: String? {
        switch self {
        case .noMeeting: L("Join a meeting before using push-to-talk.")
        case .gate: L("The meeting microphone could not be held back. Nothing was recorded.")
        case .audio: L("Local microphone capture failed. Nothing was sent to the meeting.")
        }
    }
}

/// Fail-closed headphone check for local talk-back. In particular, the default
/// output being built-in speakers, a display, or an unknown Bluetooth route is not enough.
enum AssistantHeadphoneRoute {
    static let headphonesDataSource: UInt32 = 0x6864706e // 'hdpn'
    static let bluetoothTransport: UInt32 = 0x626c7565 // 'blue'
    static func isHeadphoneSource(_ source: UInt32) -> Bool { source == headphonesDataSource }
    static func isBluetoothHeadphone(name: String, transport: UInt32) -> Bool {
        guard transport == bluetoothTransport else { return false }
        let name = name.lowercased()
        // Bluetooth speakers have no headphone data source either. Accept only
        // explicit headphone product names; unknown Bluetooth routes stay closed.
        return ["airpods", "headphone", "headset", "earbud", "earphone"].contains { name.contains($0) }
    }
    static var isConnected: Bool {
        var device = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return false }
        var source = UInt32(0); size = UInt32(MemoryLayout<UInt32>.size)
        address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDataSource,
            mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &source) == noErr,
           isHeadphoneSource(source) { return true }
        var transport = UInt32(0); size = UInt32(MemoryLayout<UInt32>.size)
        address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else { return false }
        var name: CFString = "" as CFString; size = UInt32(MemoryLayout<CFString>.size)
        address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr else { return false }
        return isBluetoothHeadphone(name: name as String, transport: transport)
    }
}

/// Typed commands and push-to-talk share AssistantTalkController's structured pipeline.
struct AssistantTalkView: View {
    @ObservedObject var attention: AttentionCoordinator
    @ObservedObject private var talk: AssistantTalkController
    @State private var input = ""

    init(attention: AttentionCoordinator) {
        self.attention = attention
        _talk = ObservedObject(wrappedValue: attention.talk)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker(L("Meeting"), selection: $talk.targetMeetingID) {
                    Text(L("Choose a meeting")).tag(UUID?.none)
                    ForEach(attention.meetings().filter { !$0.isClosed }, id: \.sessionID) { model in
                        Text(model.title).tag(UUID?.some(model.sessionID))
                    }
                }.labelsHidden().frame(maxWidth: 260)
                if let id = talk.targetMeetingID {
                    Toggle(L("Send without asking in this meeting"), isOn: Binding(get: { talk.allowsDirectSend(id) },
                        set: { talk.setDirectSend($0, for: id) }))
                        .toggleStyle(.checkbox).help(L("Only chat, spoken replies, and reactions in this active meeting. Leave always asks."))
                }
                Spacer()
                Menu {
                    if let id = talk.targetMeetingID {
                        Button(L("Read latest chat")) { talk.perform(.init(action: .readChat, meetingID: id)) }
                        Button(L("Catch up for 10 minutes")) { talk.perform(.init(action: .catchUp, meetingID: id)) }
                        Button(L("Mute microphone")) { talk.perform(.init(action: .mute, meetingID: id)) }
                    }
                } label: { Label(L("Quick actions"), systemImage: "bolt") }
            }.padding(12)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if talk.entries.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "waveform").font(.largeTitle).foregroundStyle(.secondary)
                            Text(L("Talk to Assistant")).font(.title3)
                            Text(L("Type a request, or hold ⌥Space. Your speech is recognized on this Mac."))
                                .foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }.frame(maxWidth: .infinity).padding(.vertical, 50)
                    }
                    ForEach(talk.entries) { entry in
                        Text(entry.text).textSelection(.enabled).padding(10)
                            .background(entry.role == .user ? Color.accentColor.opacity(0.1) : Color(nsColor: .controlBackgroundColor),
                                in: RoundedRectangle(cornerRadius: 8))
                            .frame(maxWidth: .infinity, alignment: entry.role == .user ? .trailing : .leading)
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
            if talk.working { ProgressView(L("Interpreting…")).controlSize(.small).padding(6) }
            if talk.listening { Label(L("Listening on this Mac… release ⌥Space to interpret"), systemImage: "mic.fill").foregroundStyle(.teal).padding(6) }
            if let error = talk.audioError { Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 12) }
            HStack(spacing: 8) {
                TextField(L("Ask Assistant to read, remember, join, mute, or draft an action…"), text: $input)
                    .textFieldStyle(.roundedBorder).onSubmit { send() }.disabled(talk.working || talk.pending != nil)
                Button(L("Ask")) { send() }.buttonStyle(.borderedProminent).disabled(input.trimmed.isEmpty || talk.working || talk.pending != nil)
                Button(talk.listening ? L("Stop") : L("Listen")) {
                    talk.listening ? talk.stopPushToTalk() : talk.startPushToTalk()
                }.disabled(!attention.store.pushToTalk && !talk.listening)
            }.padding(12)
        }
    }

    private func send() { let text = input; input = ""; talk.submit(text) }
}
