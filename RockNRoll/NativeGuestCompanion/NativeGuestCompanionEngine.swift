import Combine
import ConferenceCore
import Foundation
import UIKit

/// Performs blocking filesystem operations away from UIKit's main actor.
private actor NativeGuestHostFileIO {
    private let store: NativeGuestSessionStore
    init(store: NativeGuestSessionStore) { self.store = store }
    func prepare(_ ticket: NativeGuestTicket, command: NativeGuestCommand) throws {
        try store.cleanupExpiredSessions()
        try store.create(ticket)
        try store.writeCommand(command)
        try heartbeat(ticket.metadata)
    }
    func heartbeat(_ metadata: NativeGuestMetadata) throws {
        try store.writeHeartbeat(NativeGuestHeartbeat(metadata: metadata))
    }
    func status(_ id: UUID) throws -> NativeGuestStatus? { try store.readStatus(id) }
    func command(_ command: NativeGuestCommand) throws { try store.writeCommand(command) }
    func remove(_ id: UUID) { try? store.removeSession(id) }
}

enum NativeGuestCompanionEngineError: LocalizedError {
    case unavailable, alreadyRunning, handoffUnavailable
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Install the signed native meeting app to use native meetings on Mac."
        case .alreadyRunning: return "Wait for the native meeting to close before joining another meeting."
        case .handoffUnavailable: return "Device transfer is unavailable for native Mac meetings."
        }
    }
}

/// A control-only adapter. The separate AppKit application owns all meeting media.
@MainActor
final class NativeGuestCompanionEngine: CallEngine {
    var onEvent: ((CallEvent) -> Void)?
    var onMediaStatus: ((String?) -> Void)?
    var onRoomTitle: ((String) -> Void)?
    static var isSupported: Bool { ProcessInfo.processInfo.isiOSAppOnMac && NativeGuestCompanionBridge.isSupported() }
    /// Recheck on Settings entry without signature validation blocking UIKit.
    static func companionAvailable() async -> Bool {
        guard isSupported else { return false }
        return await Task.detached(priority: .utility) {
            (try? NativeGuestCompanionBridge.validatedApplicationURL()) != nil
        }.value
    }

    @Published private var workspace: CallWorkspaceControls?
    @Published private var microphoneStatus: PiPMicrophoneStatus = .unavailable
    var callWorkspacePublisher: AnyPublisher<CallWorkspaceControls?, Never> { $workspace.eraseToAnyPublisher() }
    var activityMicrophonePublisher: AnyPublisher<PiPMicrophoneStatus, Never> { $microphoneStatus.eraseToAnyPublisher() }
    private(set) var hasJoinStarted = false
    var isSharingScreen: Bool { latestStatus?.screenSharing ?? false }
    var continuationHostView: UIView? { nil }
    #if DEBUG
    var companionStatusForTesting: NativeGuestStatus? { latestStatus }
    var companionSessionIDForTesting: UUID? { ticket?.metadata.sessionID }
    var companionProcessTerminatedForTesting: Bool { bridge.launchedApplicationTerminated }
    func enableCaptureDiagnosticsForTesting() { change { $0.captureDiagnosticsRequested = true } }
    func reconnectCompanionForTesting() {
        change { $0.reconnectForTestingSequence = ($0.reconnectForTestingSequence ?? 0) + 1 }
    }
    func stopOwnerHeartbeatForTesting() { pollTask?.cancel(); controlTask?.cancel() }
    func observeTerminatedCompanionForTesting() async {
        guard bridge.launchedApplicationTerminated else { return }
        await poll()
    }
    #endif

    private let bridge = NativeGuestCompanionBridge()
    private var io: NativeGuestHostFileIO?
    private var ticket: NativeGuestTicket?
    private var desired: NativeGuestCommand?
    private var latestStatus: NativeGuestStatus?
    private var pollTask: Task<Void, Never>?
    private var controlTask: Task<Void, Never>?
    private var panel: NativeGuestCompanionPanel?
    private var lastState: NativeGuestState?
    private var lastHeartbeat = Date.distantPast
    private var leaveRequestedAt: Date?
    private var retiringAt: Date?
    private var terminalEvent: CallEvent = .failed
    private var launched = false
    private var launchRequested = false
    private var unknownLaunchDeadline: Date?
    private var finished = false

    deinit { pollTask?.cancel(); controlTask?.cancel() }

    func join(target: JoinTarget, displayName: String, in container: UIViewController,
              roomTitle: String? = nil, quiet: Bool = false) throws {
        guard Self.isSupported else { throw NativeGuestCompanionEngineError.unavailable }
        guard !hasJoinStarted else { throw NativeGuestCompanionEngineError.alreadyRunning }
        let store: NativeGuestSessionStore
        do { store = try NativeGuestSessionStore.appGroupStore() }
        catch { Self.logFailure(error, stage: "app-group"); throw error }
        let ticket = NativeGuestTicket(invitationURL: target.invitationURL, displayName: displayName,
                                       roomTitle: roomTitle, quiet: quiet)
        try ticket.validateForLaunch()
        let command = NativeGuestCommand(metadata: ticket.metadata, outputOn: !quiet)
        self.ticket = ticket; desired = command
        let io = NativeGuestHostFileIO(store: store); self.io = io
        hasJoinStarted = true; finished = false
        let controls = CallWorkspaceControls()
        controls.microphoneAvailable = false
        controls.invitationURL = target.invitationURL; controls.roomIdentifier = target.roomID
        controls.routeName = "Native Mac meeting"
        controls.toggleMicrophone = { [weak self] in self?.change(fields: [.microphone]) { $0.microphoneOn.toggle() } }
        controls.toggleCamera = { [weak self] in self?.change(fields: [.camera]) { $0.cameraOn.toggle() } }
        controls.toggleSpeaker = { [weak self] in self?.change(fields: [.output]) { $0.outputOn.toggle() } }
        controls.leave = { [weak self] in self?.leave() }
        workspace = controls
        let panel = NativeGuestCompanionPanel()
        panel.onShow = { [weak self] in self?.showMeeting() }
        panel.onLeave = { [weak self] in self?.leave() }
        panel.install(in: container)
        self.panel = panel
        onMediaStatus?("Opening the native Mac meeting window…")
        pollTask = Task { [weak self] in
            do {
                try await io.prepare(ticket, command: command)
                guard let bridge = self?.bridge else { return }
                self?.launchRequested = true
                try await Self.launch(ticket.metadata.sessionID, bridge: bridge)
                self?.launched = true
                if let self {
                    let pid = bridge.processIdentifier
                    self.change { $0.expectedHelperPID = pid }
                    await self.controlTask?.value
                }
            } catch is CancellationError { return }
            catch {
                guard let self else { return }
                Self.logFailure(error, stage: self.launchRequested ? "launch" : "prepare")
                let nativeError = error as NSError
                let failedBeforeLaunch = nativeError.domain == "NativeGuestCompanion" && (1...3).contains(nativeError.code)
                if self.launched || !self.bridge.launchedApplicationTerminated || (self.launchRequested && !failedBeforeLaunch) {
                    if self.bridge.processIdentifier == 0 {
                        self.unknownLaunchDeadline = Date().addingTimeInterval(NativeGuestProtocol.ownerDeathTimeout + 5)
                    }
                    await self.beginRetirement(message: "The native meeting app did not confirm startup. Waiting for it to close.")
                }
                else {
                    self.onMediaStatus?("The native meeting app could not start. Check that the signed companion is installed.")
                    await self.finish(.failed)
                }
            }
            while !Task.isCancelled && self != nil && self?.finished == false {
                await self?.poll()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private static func logFailure(_ error: Error, stage: String) {
        #if DEBUG
        if let storeError = error as? NativeGuestStoreError {
            print("Native guest failure: phase=\(stage) store=\(storeError)")
        } else {
            let native = error as NSError
            let knownDomain = ["NativeGuestCompanion", NSCocoaErrorDomain, NSPOSIXErrorDomain, NSOSStatusErrorDomain].contains(native.domain)
            let domain = knownDomain ? native.domain : "other"
            let bridgeStage = native.domain == "NativeGuestCompanion" ? native.userInfo["NativeGuestStage"] as? String ?? "none" : "none"
            let status = native.domain == "NativeGuestCompanion" ? native.userInfo["NativeGuestOSStatus"] as? NSNumber : nil
            print("Native guest failure: phase=\(stage) domain=\(domain) code=\(native.code) bridge=\(bridgeStage) osstatus=\(status?.int32Value ?? 0)")
        }
        #endif
    }

    private static func launch(_ id: UUID, bridge: NativeGuestCompanionBridge) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            bridge.launchSession(id) { pid, error in
                if let error { continuation.resume(throwing: error) }
                else if pid > 0 { continuation.resume() }
                else { continuation.resume(throwing: NativeGuestCompanionEngineError.unavailable) }
            }
        }
    }

    private func poll() async {
        guard let ticket, let io, !finished else { return }
        let now = Date()
        do {
            if retiringAt == nil && now.timeIntervalSince(lastHeartbeat) >= 2 {
                try await io.heartbeat(ticket.metadata); lastHeartbeat = now
            }
            if let status = try await io.status(ticket.metadata.sessionID) { try accept(status, now: now) }
        } catch {
            await beginRetirement(message: "The native meeting control channel could not be verified.")
        }
        guard !finished else { return }
        if bridge.launchedApplicationTerminated {
            if let deadline = unknownLaunchDeadline, now < deadline { return }
            if leaveRequestedAt != nil || retiringAt != nil { await finish(terminalEvent) }
            else {
                onMediaStatus?("The native meeting app closed.")
                await finish(.failed)
            }
            return
        }
        if let retiringAt {
            // Stop the owner's heartbeat first. The companion independently fails closed.
            if now.timeIntervalSince(retiringAt) >= NativeGuestProtocol.ownerDeathTimeout + 5 {
                panel?.showStatus("Close the native meeting window before joining another meeting.")
                onMediaStatus?("Waiting for the native meeting app to confirm it has closed.")
            }
            return
        }
        if let status = latestStatus {
            if !status.isFresh(now: now) { await beginRetirement(message: "The native meeting stopped responding.") }
        } else if now.timeIntervalSince(ticket.metadata.createdAt) > NativeGuestProtocol.launchWindow {
            await beginRetirement(message: "The native meeting did not start in time.")
        }
        if let leaveRequestedAt, now.timeIntervalSince(leaveRequestedAt) > 20 {
            await beginRetirement(message: "Waiting for the native meeting app to finish leaving.")
        }
    }

    private func accept(_ status: NativeGuestStatus, now: Date) throws {
        guard let ticket, let desired, status.metadata == ticket.metadata,
              status.helperPID == bridge.processIdentifier,
              status.acknowledgedSequence <= desired.sequence,
              status.acknowledgedSequence >= (latestStatus?.acknowledgedSequence ?? 0),
              status.updatedAt >= (latestStatus?.updatedAt ?? .distantPast) else {
            throw NativeGuestStoreError.incompatibleRecord
        }
        guard status.isFresh(now: now) else { return }
        latestStatus = status
        let controls = workspace
        controls?.microphoneAvailable = status.state == .active && status.canShareMicrophone && retiringAt == nil && leaveRequestedAt == nil
        controls?.microphoneOn = status.microphoneOn
        controls?.cameraOn = status.cameraOn
        controls?.speakerOn = status.outputOn
        controls?.onHold = desired.held
        microphoneStatus = status.microphoneOn ? (status.microphoneCapturing ? .on : .unavailable) : .muted
        if let title = status.roomTitle, !title.isEmpty { onRoomTitle?(title) }
        if status.state.isTerminal {
            // A leave is acknowledged only after the companion has released its media.
            if status.state == .left && (leaveRequestedAt == nil || status.acknowledgedSequence >= desired.sequence) {
                Task { [weak self] in await self?.finish(.left) }
            } else if status.state == .failed {
                let message = "The native meeting ended with an error (\(status.errorCode?.rawValue ?? "internalFailure"))."
                // A failure does not prove that native media teardown succeeded.
                Task { [weak self] in await self?.beginRetirement(message: message) }
            }
            return
        }
        guard retiringAt == nil, leaveRequestedAt == nil else { return }
        guard lastState != status.state else { return }
        lastState = status.state
        switch status.state {
        case .launching, .connecting:
            panel?.showStatus("Connecting in the native Mac meeting window…"); onEvent?(.connecting)
        case .lobby:
            panel?.showStatus("Waiting for admission in the native Mac meeting window…"); onEvent?(.lobby)
        case .active:
            panel?.showStatus("Your meeting is open in its native Mac window.")
            onMediaStatus?(nil); onEvent?(.active)
        case .leaving: panel?.showStatus("Leaving the native Mac meeting…")
        case .left, .failed: break
        }
    }

    /// Serializes user actions across the asynchronous filesystem boundary.
    private func change(fields: Set<NativeGuestControlField> = [], allowLeave: Bool = false,
                        _ mutate: @escaping (inout NativeGuestCommand) -> Void) {
        guard hasJoinStarted, !finished, retiringAt == nil, allowLeave || leaveRequestedAt == nil else { return }
        let previous = controlTask
        controlTask = Task { [weak self] in
            await previous?.value
            guard let self, let io = self.io, let ticket = self.ticket, !self.finished,
                  self.retiringAt == nil else { return }
            do {
                if let status = try await io.status(ticket.metadata.sessionID) { try self.accept(status, now: Date()) }
                guard var command = self.desired, !command.leave, command.sequence < UInt64.max else { return }
                try command.advance(changing: fields, acknowledged: self.latestStatus)
                mutate(&command)
                self.desired = command
                try await io.command(command)
            } catch { await self.beginRetirement(message: "The native meeting control request failed.") }
        }
    }

    func showMeeting() {
        guard leaveRequestedAt == nil, retiringAt == nil else { bridge.show(); return }
        bridge.show()
        change { command in
            if command.showWindowSequence < UInt64.max { command.showWindowSequence += 1 }
        }
    }
    func leave() {
        guard hasJoinStarted, !finished, leaveRequestedAt == nil else { return }
        leaveRequestedAt = Date(); terminalEvent = .left
        workspace?.microphoneAvailable = false
        panel?.showStatus("Leaving the native Mac meeting…")
        change(allowLeave: true) { $0.leave = true }
    }

    private func beginRetirement(message: String) async {
        guard !finished, retiringAt == nil else { return }
        retiringAt = Date()
        if leaveRequestedAt == nil { terminalEvent = .failed }
        workspace?.microphoneAvailable = false; microphoneStatus = .unavailable
        panel?.showStatus(message); onMediaStatus?(message)
        if var command = desired, let io, command.sequence < UInt64.max {
            if !command.leave { try? command.advance(changing: [], acknowledged: latestStatus) }
            command.leave = true
            desired = command; try? await io.command(command)
        }
        // NSRunningApplication refers to the exact newly launched instance.
        _ = bridge.terminateLaunchedApplication()
    }

    private func finish(_ event: CallEvent) async {
        guard !finished else { return }
        finished = true; hasJoinStarted = false
        controlTask?.cancel(); pollTask?.cancel()
        workspace = nil; microphoneStatus = .unavailable
        panel?.uninstall(); panel = nil
        if let ticket, let io { await io.remove(ticket.metadata.sessionID) }
        onEvent?(event)
    }

    func resumeSystemCallIfPossible() { showMeeting() }
    func prepareToFloat() {}
    func restoreFromFloatingVideo() { showMeeting() }
    func showMediaStatus(_ message: String?) { panel?.showStatus(message ?? "Your meeting is open in its native Mac window.") }
    func setTransferHeld(_ held: Bool, restoreSending: Bool) async throws {
        throw NativeGuestCompanionEngineError.handoffUnavailable
    }
}

@MainActor
private final class NativeGuestCompanionPanel: UIViewController {
    var onShow: (() -> Void)?
    var onLeave: (() -> Void)?
    private let status = UILabel()
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let heading = UILabel(); heading.text = "Native Mac meeting"; heading.font = .preferredFont(forTextStyle: .title2)
        heading.textAlignment = .center
        status.text = "Opening the native Mac meeting window…"
        status.numberOfLines = 0; status.textAlignment = .center; status.font = .preferredFont(forTextStyle: .body)
        let show = UIButton(type: .system); show.setTitle("Show meeting window", for: .normal)
        show.addAction(UIAction { [weak self] _ in self?.onShow?() }, for: .touchUpInside)
        let leave = UIButton(type: .system); leave.setTitle("Leave meeting", for: .normal); leave.tintColor = .systemRed
        leave.addAction(UIAction { [weak self] _ in self?.onLeave?() }, for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [heading, status, show, leave])
        stack.axis = .vertical; stack.spacing = 20; stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor), stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 440)
        ])
    }
    func install(in parent: UIViewController) {
        parent.addChild(self); view.translatesAutoresizingMaskIntoConstraints = false; parent.view.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: parent.view.leadingAnchor), view.trailingAnchor.constraint(equalTo: parent.view.trailingAnchor),
            view.topAnchor.constraint(equalTo: parent.view.topAnchor), view.bottomAnchor.constraint(equalTo: parent.view.bottomAnchor)
        ])
        didMove(toParent: parent)
    }
    func showStatus(_ message: String) { status.text = message }
    func uninstall() { willMove(toParent: nil); view.removeFromSuperview(); removeFromParent() }
}
