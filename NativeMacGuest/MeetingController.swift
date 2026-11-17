import AppKit
import AVFoundation
import ConferenceCore
import Foundation
import LiveKitWebRTC

@MainActor final class CompanionMeetingController: NSObject, NSWindowDelegate {
    private let invitationURL: URL
    private let displayName: String
    private let roomTitle: String?
    private let metadata: NativeGuestMetadata?
    private let files: CompanionFiles?
    private let onFinish: ((NativeGuestMeetingCompletion) -> Void)?
    private let window: NSWindow
    private let titleLabel = NSTextField(labelWithString: "")
    private let stateLabel = NSTextField(labelWithString: "Connecting with microphone and camera off…")
    private let emptyLabel = NSTextField(labelWithString: "Waiting for video")
    private let videos = NSStackView()
    private let microphone = NSButton(title: "Unmute", target: nil, action: nil)
    private let camera = NSButton(title: "Camera On", target: nil, action: nil)
    private let sound = NSButton(title: "Sound On", target: nil, action: nil)
    private let leave = NSButton(title: "Leave", target: nil, action: nil)
    private var tiles: [String: CompanionVideoTile] = [:]
    private var videoOrder: [String] = []
    private var localTile: CompanionVideoTile?
    private var injectedSession: GuestSession?
    private var meetingSession: MeetingSession?
    private var watcher: Task<Void, Never>?
    private var diagnosticsTask: Task<Void, Never>?
    private var connecting: Task<Void, Never>?
    private var applying: Task<Void, Never>?
    private let shutdown = CompanionShutdown()
    private let controlRevision = CompanionControlRevision()
    private var desiredMedia: CompanionMediaIntent
    private var desiredRevision: UInt64 { controlRevision.current }
    private var appliedRevision: UInt64 = 0
    private var observedAudioMuted: Bool?
    private var observedVideoMuted: Bool?
    private var gate: NativeGuestCommandGate?
    private var acknowledged: UInt64 = 0
    private var showSequence: UInt64 = 0
    private var lastStatus = Date.distantPast
    private let statusPublication = CompanionStatusPublication()
    private var lastOwnerSeen = Date()
    private var outputOn: Bool
    private var terminalError: NativeGuestErrorCode?
    private(set) var finished = false
    private(set) var cleanupSucceeded = true
    var microphoneTrackProbe: GuestMicrophoneTrackProbe? {
        guard !finishing, !finished else { return nil }
        if let meetingSession {
            return meetingSession.microphoneTrackProbe?.checking { [weak self, weak meetingSession] in
                guard let self, let meetingSession else { return false }
                return !finishing && !finished && self.meetingSession === meetingSession
            }
        }
        guard let session = injectedSession else { return nil }
        return session.microphoneTrackProbe?.checking { [weak self, weak session] in
            guard let self, let session else { return false }
            return !finishing && !finished && self.injectedSession === session
        }
    }
    /// Camera values describe session intent, not a hardware or remote-media witness.
    var ownershipDiagnostics: [String: Any] {
        let executor = meetingSession != nil ? "universal-meeting-engine" : "guest-session"
        let sessionDiagnostics = meetingSession?.ownershipDiagnostics
            ?? injectedSession?.ownershipDiagnostics
            ?? ["state": "not-created"]
        return ["executor": executor, "session": sessionDiagnostics,
                "cameraDesired": desiredMedia.cameraOn,
                "cameraAppliedUnmuted": currentAppliedIntent.cameraOn,
                "connectionTaskPresent": connecting != nil, "finishing": finishing,
                "finished": finished, "cleanupSucceeded": cleanupSucceeded]
    }
    #if DEBUG
    private var captureDiagnosticsRequested = false
    private var reconnectSequence: UInt64 = 0
    private var diagnosticReconnect: Task<Void, Never>?
    #endif
    private var finishing = false

    convenience init(ticket: NativeGuestTicket, files: CompanionFiles) {
        self.init(invitationURL: ticket.invitationURL, displayName: ticket.displayName,
                  roomTitle: ticket.roomTitle, quiet: ticket.quiet, metadata: ticket.metadata,
                  files: files, onFinish: nil, makeSession: nil)
    }
    convenience init(request: NativeGuestJoinRequest, makeSession: (() -> GuestSession)? = nil,
                     onFinish: @escaping (NativeGuestMeetingCompletion) -> Void) {
        self.init(invitationURL: request.invitation.invitationURL, displayName: request.displayName,
                  roomTitle: nil, quiet: false, metadata: nil, files: nil, onFinish: onFinish, makeSession: makeSession)
    }
    private init(invitationURL: URL, displayName: String, roomTitle: String?, quiet: Bool,
                 metadata: NativeGuestMetadata?, files: CompanionFiles?,
                 onFinish: ((NativeGuestMeetingCompletion) -> Void)?, makeSession: (() -> GuestSession)?) {
        self.invitationURL = invitationURL; self.displayName = displayName; self.roomTitle = roomTitle
        self.metadata = metadata; self.files = files; self.onFinish = onFinish
        outputOn = !quiet
        desiredMedia = CompanionMediaIntent(outputOn: !quiet)
        gate = metadata.map(NativeGuestCommandGate.init)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = roomTitle ?? "Rock'N'Roll for Mac"
        // Two gallery rows still need room for their 160-point tiles and controls.
        window.minSize = NSSize(width: 800, height: 540); window.center(); window.delegate = self
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading
        stack.spacing = 12; stack.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.stringValue = roomTitle ?? "Guest meeting"
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        let badge = NSTextField(labelWithString: "Native guest · Beta")
        badge.textColor = .secondaryLabelColor
        stateLabel.textColor = .secondaryLabelColor; stateLabel.lineBreakMode = .byTruncatingTail
        videos.orientation = .vertical; videos.distribution = .fillEqually; videos.spacing = 8
        videos.addArrangedSubview(emptyLabel)
        let controls = NSStackView(views: [microphone, camera, sound, leave]); controls.spacing = 12
        for button in [microphone, camera, sound, leave] { button.bezelStyle = .rounded; button.target = self }
        microphone.action = #selector(toggleMicrophone); camera.action = #selector(toggleCamera)
        sound.action = #selector(toggleSound); leave.action = #selector(leaveMeeting)
        microphone.identifier = NSUserInterfaceItemIdentifier("nativeGuest.mic")
        camera.identifier = NSUserInterfaceItemIdentifier("nativeGuest.camera")
        sound.identifier = NSUserInterfaceItemIdentifier("nativeGuest.sound")
        leave.identifier = NSUserInterfaceItemIdentifier("nativeGuest.leave")
        for view in [titleLabel, badge, stateLabel, videos, controls] { stack.addArrangedSubview(view) }
        let content = window.contentView!; content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            videos.widthAnchor.constraint(equalTo: stack.widthAnchor),
            videos.heightAnchor.constraint(greaterThanOrEqualToConstant: 220)
        ])
        stateLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if let makeSession {
            let session = makeSession()
            injectedSession = session
            session.onEngineChange = { [weak self] engine in self?.bind(engine) }
            session.onStateChange = { [weak self] _ in self?.handleSessionStateChange() }
        } else if let destination = try? JoinDestination.verified(invitationURL, engine: .guest) {
            let session = UniversalMeetingEngine.shared.makeSession(destination: destination, exclusiveTalk: true)
            meetingSession = session
            session.onVideo = { [weak self] streams in self?.updateExternalVideo(streams) }
            session.onLocalCamera = { [weak self] track in self?.updateLocalVideo(track) }
            session.onSessionSnapshot = { [weak self] _ in self?.handleSessionStateChange() }
        }
        updateControls()
    }
    private func handleSessionStateChange() {
        guard !finishing else { return }
        // A server-forced mute must also replace the window's desired state;
        // a later, unrelated camera/sound action may never restore it.
        let desired = currentDesiredAudioVideo
        var revised = desiredMedia
        if observedAudioMuted == false, desired.audioMuted == true { revised.microphoneOn = false }
        if observedVideoMuted == false, desired.videoMuted == true { revised.cameraOn = false }
        observedAudioMuted = desired.audioMuted; observedVideoMuted = desired.videoMuted
        if revised != desiredMedia { requestMedia(revised) }
        updateControls()
        applyPending()
        Task { @MainActor [weak self] in
            guard let self, !finishing else { return }
            if isSessionFailed { await finish(error: .connectionFailed) }
            else { await publishStatus() }
        }
    }
    private var isSessionConnected: Bool {
        meetingSession?.snapshot.phase == .connected || injectedSession?.state == .connected
    }
    private var isSessionRecovering: Bool {
        meetingSession?.snapshot.phase == .reconnecting || injectedSession?.state == .recovering
    }
    private var isSessionConnecting: Bool {
        meetingSession?.snapshot.phase == .connecting || injectedSession?.state == .connecting
    }
    private var isSessionFailed: Bool {
        meetingSession?.snapshot.phase == .failed || injectedSession?.state == .failed
    }
    private var isSessionTerminal: Bool {
        if let meetingSession {
            return meetingSession.snapshot.phase == .failed || meetingSession.snapshot.phase == .left
        }
        if let injectedSession {
            return injectedSession.state == .failed || injectedSession.state == .left
        }
        return true
    }
    private var hasDesiredIntent: Bool {
        meetingSession?.hasDesiredMediaIntent ?? (injectedSession?.desiredIntent != nil)
    }
    private var currentDesiredAudioVideo: (audioMuted: Bool?, videoMuted: Bool?) {
        if let meetingSession {
            guard let desired = meetingSession.desiredMediaIntent else { return (nil, nil) }
            return (!desired.microphoneOn, !desired.cameraOn)
        }
        if let injectedSession {
            return (injectedSession.snapshot.desiredIntent?.audioMuted, injectedSession.snapshot.desiredIntent?.videoMuted)
        }
        return (nil, nil)
    }
    private var currentAppliedIntent: (microphoneOn: Bool, cameraOn: Bool, playoutOn: Bool?) {
        if let meetingSession { return meetingSession.appliedMediaIntent }
        if let injectedSession {
            let applied = injectedSession.snapshot.appliedIntent
            return (applied?.audioMuted == false, applied?.videoMuted == false, injectedSession.snapshot.appliedPlayoutEnabled)
        }
        return (false, false, nil)
    }
    private var currentPermissions: (canShareMicrophone: Bool, canShareCamera: Bool) {
        if let meetingSession { return meetingSession.mediaPermissions }
        if let injectedSession {
            let permissions = injectedSession.snapshot.permissions
            return (permissions.canShareMicrophone, permissions.canShareCamera)
        }
        return (false, false)
    }
    func show() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if onFinish != nil { Task { await finish() } }
        else { sender.orderOut(nil) }
        return false
    }

    func start() async {
        if ProcessInfo.processInfo.environment["ROCK_NATIVE_MEDIA_DIAGNOSTICS"] == "1" {
            diagnosticsTask = Task { @MainActor [weak self] in
                guard let self else { return }
                var from = ProcessInfo.processInfo.systemUptime
                while !Task.isCancelled && !finishing {
                    do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { break }
                    let to = ProcessInfo.processInfo.systemUptime
                    let remote = tiles.values.map { $0.sink.presentationWindow(from: from, to: to) }
                    let local = localTile?.sink.presentationWindow(from: from, to: to)
                    let audioSamples: Int
                    if let meetingSession {
                        audioSamples = await meetingSession.companionDiagnosticsSnapshot(includeStatistics: false).receivedAudioSamples
                    } else {
                        audioSamples = injectedSession?.engine?.receivedAudioSamples ?? 0
                    }
                    probeLog("native-render-window", ["remoteCount": remote.count,
                        "remoteMinFPS": remote.map(\.fps).min() ?? 0,
                        "remoteMaxGap": remote.map(\.maximumGap).max() ?? 0,
                        "remoteSmoothCount": remote.filter(\.smooth).count,
                        "localFPS": local?.fps ?? 0,
                        "localMaxGap": local?.maximumGap ?? 0,
                        "receivedAudioSamples": audioSamples,
                        "seconds": to - from])
                    from = to
                }
            }
        }
        if files != nil { watcher = Task { @MainActor [weak self] in
            while let self, !finished, !finishing, !Task.isCancelled {
                do { try await tick() }
                catch { await finish(error: .internalFailure); break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        } }
        connecting = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if let meetingSession {
                    try await meetingSession.connect(invitation: invitationURL, name: displayName, quiet: !outputOn)
                } else if let injectedSession {
                    let invitation = try GuestInvitation.parse(invitationURL)
                    try await injectedSession.connect(invitation, publish: true, codec: "h264", camera: true,
                                                      initialAudioMuted: true, initialVideoMuted: true)
                } else {
                    throw NativeGuestEntryError.invalidInvitation
                }
                guard !finishing else { return }
                updateControls(); await publishStatus()
            } catch {
                guard !finishing else { return }
                await finish(error: .connectionFailed)
            }
        }
    }
    private func bind(_ engine: NativeGuestEngine?) {
        detachVideo()
        engine?.onIncomingVideoChange = { [weak self] streams in self?.updateVideo(streams) }
        engine?.onLocalCameraTrackChange = { [weak self] track in self?.updateLocalVideo(track) }
        if let engine { updateVideo(engine.incomingVideo); updateLocalVideo(engine.localCameraTrack) }
    }
    private func updateExternalVideo(_ available: [NativeDesktopExternalVideo]) {
        let names = Dictionary(uniqueKeysWithValues: (meetingSession?.sessionSnapshot.participants ?? []).map { ($0.id, $0.name) })
        let items = available.map { (id: $0.id, isScreenShare: $0.source == .screen, track: $0.track,
                                     title: names[$0.participantID] ?? "Participant") }
        applyVideoTiles(items)
    }
    private func updateVideo(_ available: [GuestRemoteVideo]) {
        let items = available.map { (id: $0.id, isScreenShare: CompanionMediaPolicy.isScreenShare($0.source),
                                     track: $0.track, title: $0.participantName ?? "Participant") }
        applyVideoTiles(items)
    }
    private func applyVideoTiles(_ available: [(id: String, isScreenShare: Bool, track: LKRTCVideoTrack, title: String)]) {
        let streams = Array(available.sorted {
            $0.isScreenShare == $1.isScreenShare ? $0.id < $1.id : $0.isScreenShare
        }.prefix(6))
        videoOrder = streams.map(\.id)
        let ids = Set(streams.map(\.id))
        for key in tiles.keys.filter({ !ids.contains($0) }) { tiles.removeValue(forKey: key)?.detach() }
        for stream in streams {
            if let old = tiles[stream.id], !old.track.isEqual(stream.track) { old.detach(); tiles.removeValue(forKey: stream.id) }
            if tiles[stream.id] == nil {
                tiles[stream.id] = CompanionVideoTile(track: stream.track, title: stream.title)
            }
        }
        rebuildVideo()
    }
    private func updateLocalVideo(_ track: LKRTCVideoTrack?) {
        if let track, localTile?.track.isEqual(track) == true { return }
        localTile?.detach(); localTile = nil
        if let track { localTile = CompanionVideoTile(track: track, title: "You", mirrored: true) }
        if let meetingSession {
            updateExternalVideo(meetingSession.incomingVideo)
        } else {
            updateVideo(injectedSession?.engine?.incomingVideo ?? [])
        }
    }
    private func rebuildVideo() {
        for view in videos.arrangedSubviews { videos.removeArrangedSubview(view); view.removeFromSuperview() }
        let all = videoOrder.compactMap { tiles[$0] } + [localTile].compactMap { $0 }
        guard !all.isEmpty else { videos.addArrangedSubview(emptyLabel); return }
        let columns = all.count <= 2 ? all.count : (all.count <= 4 ? 2 : (all.count <= 6 ? 3 : 4))
        for start in stride(from: 0, to: all.count, by: columns) {
            let row = NSStackView(views: Array(all[start..<min(start + columns, all.count)]))
            row.orientation = .horizontal; row.distribution = .fillEqually; row.spacing = 8
            videos.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: videos.widthAnchor).isActive = true
        }
    }
    private func detachVideo() {
        for tile in tiles.values { tile.detach() }; tiles.removeAll(); videoOrder.removeAll()
        localTile?.detach(); localTile = nil; rebuildVideo()
    }
    private func tick() async throws {
        guard let files, let metadata else { return }
        let now = Date()
        if let owner = try await files.heartbeat(metadata.sessionID), owner.metadata == metadata,
           now.timeIntervalSince(owner.updatedAt) <= NativeGuestProtocol.ownerDeathTimeout {
            lastOwnerSeen = owner.updatedAt
        }
        guard now.timeIntervalSince(lastOwnerSeen) <= NativeGuestProtocol.ownerDeathTimeout else {
            await finish(error: .parentUnavailable); return
        }
        if let command = try await files.command(metadata.sessionID), gate?.accept(command) == true {
            guard command.expectedHelperPID == getpid() else { await finish(error: .invalidTicket); return }
            if command.leave {
                acknowledged = command.sequence; await finish(); return
            }
            if command.showWindowSequence > showSequence { showSequence = command.showWindowSequence; show() }
            #if DEBUG
            captureDiagnosticsRequested = command.captureDiagnosticsRequested == true
            if captureDiagnosticsRequested, let sequence = command.reconnectForTestingSequence,
               sequence > reconnectSequence {
                reconnectSequence = sequence
                diagnosticReconnect = Task { @MainActor [weak self] in
                    guard let self, !finishing else { return }
                    do {
                        if let meetingSession { try await meetingSession.reconnect() }
                        else if let injectedSession { try await injectedSession.reconnectForTesting() }
                    }
                    catch { if !finishing { await finish(error: .connectionFailed) } }
                }
            }
            #endif
            if command.mediaFields.isEmpty {
                acknowledged = command.sequence
                await publishStatus()
            } else { requestMedia(desiredMedia.merging(command)) }
        }
        if now.timeIntervalSince(lastStatus) >= 2 { await publishStatus() }
    }
    private func applyPending() {
        guard applying == nil, !finishing, desiredRevision > appliedRevision,
              hasDesiredIntent, !isSessionTerminal else { return }
        applying = Task { @MainActor [weak self] in
            guard let self else { return }
            while desiredRevision > appliedRevision, !finishing, !Task.isCancelled {
                let revision = desiredRevision, intent = desiredMedia
                updateControls()
                do {
                    try await setMedia(intent, revision: revision)
                    try checkRevision(revision)
                    terminalError = nil
                } catch {
                    guard !finishing, !Task.isCancelled else { break }
                    if revision != desiredRevision { continue }
                    terminalError = error is CompanionMediaControlError ? .permissionDenied : .commandFailed
                    // Reflect only completed operations after a refused request.
                    let applied = currentAppliedIntent
                    desiredMedia.microphoneOn = applied.microphoneOn
                    desiredMedia.cameraOn = applied.cameraOn
                    desiredMedia.outputOn = applied.playoutOn ?? outputOn
                }
                guard revision == desiredRevision, !finishing else { continue }
                appliedRevision = revision
                acknowledged = gate?.acknowledgedSequence ?? 0
                updateControls(); await publishStatus()
            }
            applying = nil
            updateControls()
        }
    }
    private func requestMedia(_ intent: CompanionMediaIntent) {
        guard !finishing, controlRevision.advance() else { return }
        desiredMedia = intent
        // This also changes the session's recovery intent, before any TCC/network wait.
        if !intent.microphoneOn {
            injectedSession?.setLocalMuteIntent(true)
            meetingSession?.prepareLocalMuteIntent(audioMuted: true, videoMuted: nil)
        }
        if !intent.cameraOn {
            injectedSession?.setLocalMuteIntent(true, video: true)
            meetingSession?.prepareLocalMuteIntent(audioMuted: nil, videoMuted: true)
        }
        updateControls(); applyPending()
    }
    private func checkRevision(_ revision: UInt64) throws {
        try controlRevision.check(revision)
    }
    private func setMedia(_ intent: CompanionMediaIntent, revision: UInt64) async throws {
        try await CompanionMediaPolicy.apply(intent, validate: { try self.checkRevision(revision) },
            permitted: { field in field == .microphone ? self.currentPermissions.canShareMicrophone :
                self.currentPermissions.canShareCamera },
            authorize: { field in await Self.authorize(field == .microphone ? .audio : .video) },
            activateMicrophone: {
                if let meetingSession = self.meetingSession { try await meetingSession.activateCompanionMicrophone() }
                else if let injectedSession = self.injectedSession { try await injectedSession.activateMicrophone() }
            },
            mute: { muted, video in
                if let meetingSession = self.meetingSession { try await meetingSession.setCompanionMute(muted, video: video) }
                else if let injectedSession = self.injectedSession { try await injectedSession.mute(muted, video: video) }
            },
            setOutput: { enabled in
                if let meetingSession = self.meetingSession { try await meetingSession.setPlayout(enabled) }
                else if let injectedSession = self.injectedSession { try await injectedSession.setPlayoutEnabled(enabled) }
            })
        outputOn = intent.outputOn
    }
    private static func authorize(_ type: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: type)
        default: return false
        }
    }
    @objc private func toggleMicrophone() { localChange(mic: !desiredMedia.microphoneOn) }
    @objc private func toggleCamera() { localChange(video: !desiredMedia.cameraOn) }
    @objc private func toggleSound() { localChange(output: !desiredMedia.outputOn) }
    private func localChange(mic: Bool? = nil, video: Bool? = nil, output: Bool? = nil) {
        guard isSessionConnected, !finishing else { return }
        requestMedia(CompanionMediaIntent(microphoneOn: mic ?? desiredMedia.microphoneOn,
                                 cameraOn: video ?? desiredMedia.cameraOn,
                                 outputOn: output ?? desiredMedia.outputOn))
    }
    @objc private func leaveMeeting() { Task { await finish() } }
    private func updateControls() {
        let active = isSessionConnected && !finishing
        let permissions = currentPermissions
        microphone.isEnabled = active && permissions.canShareMicrophone
        camera.isEnabled = active && permissions.canShareCamera
        sound.isEnabled = active
        leave.isEnabled = !finishing
        microphone.title = desiredMedia.microphoneOn ? "Mute" : "Unmute"
        camera.title = desiredMedia.cameraOn ? "Camera Off" : "Camera On"
        sound.title = desiredMedia.outputOn ? "Sound Off" : "Sound On"
        if finishing { stateLabel.stringValue = "Leaving…" }
        else if terminalError == .permissionDenied { stateLabel.stringValue = "Media permission was denied. You can keep listening." }
        else if terminalError == .commandFailed { stateLabel.stringValue = "The media change could not be completed." }
        else if isSessionConnected { stateLabel.stringValue = "Connected · Microphone and camera are under your control" }
        else if isSessionRecovering { stateLabel.stringValue = "Reconnecting…" }
        else if isSessionFailed { stateLabel.stringValue = "Could not connect" }
        else { stateLabel.stringValue = "Connecting with microphone and camera off…" }
    }
    private func publishStatus(state override: NativeGuestState? = nil) async {
        guard let files, let metadata else { return }
        await statusPublication.publish(state: override, prepare: { [self] state in
            await prepareStatus(state: state, metadata: metadata)
        }, write: { record in try? await files.status(record) })
    }
    private func prepareStatus(state override: NativeGuestState?, metadata: NativeGuestMetadata) async -> NativeGuestStatus {
        let state: NativeGuestState = override ?? (finishing ? .leaving : companionPhase)
        lastStatus = Date()
        if let meetingSession {
            #if DEBUG
            let includeStats = captureDiagnosticsRequested
            #else
            let includeStats = false
            #endif
            let diagSnapshot = await meetingSession.companionDiagnosticsSnapshot(includeStatistics: includeStats)
            #if DEBUG
            var diagnostics = includeStats ? Self.captureDiagnostics(snapshot: diagSnapshot) : nil
            if let end = diagnostics?.videoSampleUptime {
                diagnostics?.presentationCadence = tiles.keys.sorted().compactMap { id in
                    guard let sink = tiles[id]?.sink else { return nil }
                    let value = sink.presentationWindow(from: end - 5, to: end)
                    return .init(sourceID: id, complete: value.complete, frames: value.frames, fps: value.fps,
                        maximumGap: value.maximumGap, endFrameAge: value.endFrameAge)
                }
            }
            #endif
            let audioSnapshot = diagSnapshot.systemAudioSnapshot
            var status = NativeGuestStatus(metadata: metadata, acknowledgedSequence: acknowledged, state: state,
                microphoneOn: diagSnapshot.appliedAudioMuted == false && state == .active,
                cameraOn: diagSnapshot.appliedVideoMuted == false && state == .active,
                outputOn: diagSnapshot.appliedPlayoutEnabled ?? outputOn,
                microphoneCapturing: state == .active && CompanionMediaPolicy.microphoneCapturing(
                    audioSnapshot, uptime: ProcessInfo.processInfo.systemUptime),
                errorCode: terminalError, roomTitle: roomTitle, helperPID: getpid(),
                remoteVideoFrames: tiles.values.reduce(0) { $0 + $1.sink.frames },
                receivedAudioSamples: diagSnapshot.receivedAudioSamples,
                canShareMicrophone: diagSnapshot.canShareMicrophone,
                canShareCamera: diagSnapshot.canShareCamera,
                captureDisabledVerified: state == .active && CompanionMediaPolicy.captureDisabled(
                    audioSnapshot, cameraAbsent: !diagSnapshot.cameraPresent,
                    uptime: ProcessInfo.processInfo.systemUptime),
                receiveConnected: diagSnapshot.mediaConnected,
                decodedVideoFrames: diagSnapshot.renderedVideoFrames,
                playoutRunning: audioSnapshot?["playing"] as? Bool,
                receivedAudioRMS: diagSnapshot.receivedAudioRMS)
            #if DEBUG
            status.captureDiagnostics = diagnostics
            #endif
            return status
        }
        if let injectedSession {
            if injectedSession.state == .connected, !finishing {
                _ = await injectedSession.engine?.systemAudio?.refreshSnapshot()
            }
            #if DEBUG
            var diagnostics = captureDiagnosticsRequested ? await Self.captureDiagnostics(engine: injectedSession.engine, connections: injectedSession.connectionCount) : nil
            if let end = diagnostics?.videoSampleUptime {
                diagnostics?.presentationCadence = tiles.keys.sorted().compactMap { id in
                    guard let sink = tiles[id]?.sink else { return nil }
                    let value = sink.presentationWindow(from: end - 5, to: end)
                    return .init(sourceID: id, complete: value.complete, frames: value.frames, fps: value.fps,
                        maximumGap: value.maximumGap, endFrameAge: value.endFrameAge)
                }
            }
            #endif
            let applied = injectedSession.snapshot.appliedIntent
            var status = NativeGuestStatus(metadata: metadata, acknowledgedSequence: acknowledged, state: state,
                microphoneOn: applied?.audioMuted == false && state == .active,
                cameraOn: applied?.videoMuted == false && state == .active,
                outputOn: injectedSession.snapshot.appliedPlayoutEnabled ?? outputOn,
                microphoneCapturing: state == .active && CompanionMediaPolicy.microphoneCapturing(
                    injectedSession.engine?.systemAudio?.snapshot, uptime: ProcessInfo.processInfo.systemUptime),
                errorCode: terminalError, roomTitle: roomTitle, helperPID: getpid(),
                remoteVideoFrames: tiles.values.reduce(0) { $0 + $1.sink.frames }, receivedAudioSamples: injectedSession.engine?.receivedAudioSamples ?? 0,
                canShareMicrophone: injectedSession.snapshot.permissions.canShareMicrophone,
                canShareCamera: injectedSession.snapshot.permissions.canShareCamera,
                captureDisabledVerified: state == .active && CompanionMediaPolicy.captureDisabled(
                    injectedSession.engine?.systemAudio?.snapshot, cameraAbsent: injectedSession.engine?.cameraSnapshot == nil,
                    uptime: ProcessInfo.processInfo.systemUptime),
                receiveConnected: injectedSession.engine?.mediaSnapshot.connected,
                decodedVideoFrames: injectedSession.engine?.mediaSnapshot.render["advancingFrames"] as? Int,
                playoutRunning: injectedSession.engine?.systemAudio?.snapshot["playing"] as? Bool,
                receivedAudioRMS: injectedSession.engine?.mediaSnapshot.audio.rms)
            #if DEBUG
            status.captureDiagnostics = diagnostics
            #endif
            return status
        }
        return NativeGuestStatus(metadata: metadata, acknowledgedSequence: acknowledged, state: state,
            microphoneOn: false, cameraOn: false, outputOn: outputOn,
            microphoneCapturing: false, errorCode: terminalError, roomTitle: roomTitle, helperPID: getpid(),
            remoteVideoFrames: tiles.values.reduce(0) { $0 + $1.sink.frames }, receivedAudioSamples: 0,
            canShareMicrophone: false, canShareCamera: false)
    }
    private var companionPhase: NativeGuestState {
        if let meetingSession {
            switch meetingSession.snapshot.phase {
            case .connected: return .active
            case .connecting, .reconnecting: return .connecting
            case .leaving: return .leaving
            case .failed: return .failed
            case .left: return .left
            case .idle: return .launching
            }
        }
        if let injectedSession {
            switch injectedSession.state {
            case .connected: return .active
            case .recovering, .connecting: return .connecting
            case .failed: return .failed
            case .left: return .left
            case .idle: return .launching
            }
        }
        return .failed
    }
    func finish(error: NativeGuestErrorCode? = nil) async {
        if let task = shutdown.task { await task.value; return }
        finishing = true; terminalError = error
        controlRevision.stop()
        desiredMedia.microphoneOn = false; desiredMedia.cameraOn = false
        injectedSession?.setLocalMuteIntent(true); injectedSession?.setLocalMuteIntent(true, video: true)
        injectedSession?.engine?.suppressOutgoingMedia()
        meetingSession?.prepareLocalMuteIntent(audioMuted: true, videoMuted: true)
        meetingSession?.suppressOutgoingMedia()
        watcher?.cancel(); diagnosticsTask?.cancel(); applying?.cancel(); connecting?.cancel(); updateControls()
        #if DEBUG
        diagnosticReconnect?.cancel()
        #endif
        let task = shutdown.start { [self] in
            await publishStatus(state: .leaving)
            let clean: Bool
            if let meetingSession { clean = await meetingSession.leave() }
            else if let injectedSession { clean = await injectedSession.leave() }
            else { clean = true }
            cleanupSucceeded = clean
            detachVideo()
            if !clean { terminalError = .mediaFailed }
            await publishStatus(state: clean && error == nil ? .left : .failed)
            finished = true
        }
        await task.value
        window.orderOut(nil)
        if let onFinish {
            onFinish(terminalError == .mediaFailed ? .cleanupFailed : (error == nil ? .left : .failed))
        } else { NSApp.terminate(nil) }
    }
}
