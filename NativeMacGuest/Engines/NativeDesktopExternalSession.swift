import AVFoundation
import ConferenceCore
import Foundation
import LiveKitWebRTC

@MainActor final class NativeDesktopTelemostEngine: NativeDesktopExternalSession {
    init() { super.init(kind: .telemost) }
}
@MainActor final class NativeDesktopTrueConfEngine: NativeDesktopExternalSession {
    init() { super.init(kind: .trueconf) }
}

/// A single owner serializes provider negotiation and native capture. Provider
/// adapters share lifecycle/media policy, but retain their actual wire schemas.
@MainActor
class NativeDesktopExternalSession: NativeDesktopMeetingEngine {
    enum Kind { case telemost, trueconf }
    private static let sslInitialized = LKRTCInitializeSSL()
    let kind: Kind
    var onState: ((NativeDesktopExternalSnapshot) -> Void)?
    var onVideo: (([NativeDesktopExternalVideo]) -> Void)?
    var onLocalCamera: ((LKRTCVideoTrack?) -> Void)?
    var onTitle: ((String) -> Void)?
    var onTelemostChatContext: ((URL, String) -> Void)?
    var snapshot = NativeDesktopExternalSnapshot()
    var incomingVideo: [NativeDesktopExternalVideo] = []
    var factory: LKRTCPeerConnectionFactory? {
        guard [.connecting, .connected, .reconnecting].contains(snapshot.phase) else { return nil }
        return audio?.factory
    }
    var audio: GuestSystemAudio?
    var publisher: NativeDesktopRTCPeer?
    var subscriber: NativeDesktopRTCPeer?
    var telemost: TelemostTransport?
    var trueconf: TrueConfTransport?
    var http: URLSession?
    var invitation: URL?
    var name = ""
    var epoch = UUID()
    var microphoneRevision: UInt64 = 0
    var cameraRevision: UInt64 = 0
    var microphoneIntent = false
    var cameraIntent = false
    var screenTrack: LKRTCVideoTrack?
    var outputIntent = true
    private var accessoryCapturePrepared = false
    private var privateAudioCheck = UUID()
    private var audioProfile = GuestAudioProfile.speech
    var privateAudioLevel: Float? { audio?.privateInputLevel }
    var ready = false
    var helloAccepted = false
    var mediaAccepted = false
    var publisherNegotiated = false
    var mediaDirty = false
    var mediaTask: Task<Void, Never>?
    var recoveryTask: Task<Void, Never>?
    var deadline: Task<Void, Never>?
    var meter: Task<Void, Never>?
    var shutdownTask: Task<Bool, Never>?
    private(set) var connectionRetirementTask: Task<Bool, Never>?
    private var connectionRetirementID: UUID?
    var cleanupSucceeded = true
    var failureDuringShutdown: String?
    #if DEBUG
    var beforeAudioShutdownForTesting: (() -> Void)?
    private(set) var connectionRetirementWaitersForTesting = 0
    #endif
    var retries = 0
    var pendingAnswer: GuestCompletion<Void>?
    var telemostBootstrap: TelemostBootstrap?
    var descriptions: [String: [String: Any]] = [:]
    var slots: [[String: Any]] = []
    var slotKey = 0
    var tracks: [String: LKRTCVideoTrack] = [:]
    var speaking = Set<String>()
    var roster = TrueConfRoster()
    var regions: [String: CGRect] = [:]
    var localID = ""
    var cid = ""
    var streamID = ""
    var roomID = ""
    var visibleParticipantIDs: Set<String>?
    var focusedParticipantID: String?
    var lastSlotConfiguration: Data?
    var slotUpdateTask: Task<Void, Never>?
    var slotUpdateDirty = false
    init(kind: Kind) { self.kind = kind }
    func connect(invitation: URL, name: String, quiet: Bool = false) async throws {
        guard [.idle, .left, .failed].contains(snapshot.phase), cleanupSucceeded,
              shutdownTask == nil, connectionRetirementTask == nil else { throw NativeDesktopRTCError.cleanupFailed }
        guard Self.sslInitialized else { throw NativeDesktopRTCError.invalidResponse }
        if kind == .telemost { _ = try TelemostTarget.parse(invitation.absoluteString) }
        else { _ = try TrueConfTarget.parse(invitation.absoluteString) }
        self.invitation = invitation; self.name = name
        epoch = UUID(); let attempt = epoch
        microphoneIntent = false; cameraIntent = false; screenTrack = nil; outputIntent = !quiet; retries = 0
        accessoryCapturePrepared = false
        audioProfile = .saved
        snapshot = .init(phase: .connecting, playoutOn: !quiet); publish()
        var admittedAudio: GuestSystemAudio?
        do {
            let owner = try await GuestSystemAudio.create(microphoneEnabled: false, playoutEnabled: !quiet, profile: audioProfile)
            guard epoch == attempt, snapshot.phase == .connecting else { _ = await owner.shutdown(); throw CancellationError() }
            audio = owner; admittedAudio = owner
            try await startConnection(attempt)
            try check(attempt)
            startMeterIfNeeded()
        } catch {
            if !Task.isCancelled, let admittedAudio, audio === admittedAudio {
                // A reader failure may start recovery before the initiating
                // hello request finishes. Its obsolete error cannot retire the
                // same audio owner's replacement transport.
                if epoch != attempt, [.reconnecting, .connected].contains(snapshot.phase) { return }
                if epoch == attempt, Self.isRetryableTransportFailure(error) {
                    recover(error); return
                }
            }
            if epoch == attempt { await fail(error) }
            throw error
        }
    }
    private func startMeterIfNeeded() {
        guard meter == nil else { return }
        meter = Task { [weak self] in
            while let self, !Task.isCancelled {
                let level = await publisher?.microphoneLevel()
                if !Task.isCancelled { snapshot.microphoneLevel = level; publish() }
                do { try await Task.sleep(for: .milliseconds(200)) } catch { break }
            }
        }
    }
    func reconnect() async throws {
        guard let invitation else { throw NativeDesktopRTCError.closed }
        let name = name, quiet = !outputIntent
        guard await leave() else { throw NativeDesktopRTCError.cleanupFailed }
        try await connect(invitation: invitation, name: name, quiet: quiet)
    }
    func check(_ attempt: UUID) throws {
        if epoch != attempt || Task.isCancelled || [.leaving, .left, .failed].contains(snapshot.phase) { throw CancellationError() }
    }
    func publish() { onState?(snapshot) }
    func cameraCaptureDevice() async -> AVCaptureDevice? {
        guard snapshot.cameraOn, let peer = publisher else { return nil }
        let device = await peer.cameraCaptureDevice()
        return snapshot.cameraOn && publisher === peer ? device : nil
    }
    func setMicrophone(_ enabled: Bool) async throws {
        guard [.connecting, .connected, .reconnecting].contains(snapshot.phase) else { throw NativeDesktopRTCError.closed }
        microphoneRevision &+= 1; let revision = microphoneRevision, attempt = epoch
        if !enabled {
            microphoneIntent = false; publisher?.setMicrophone(false); audio?.suppressMicrophone()
            snapshot.microphoneOn = false; publish(); scheduleMedia(); return
        }
        let authorized = try await GuestCaptureAuthorization.request(.audio)
        try check(attempt); guard microphoneRevision == revision else { throw CancellationError() }
        guard authorized else { throw NativeDesktopRTCError.permissionDenied }
        guard let audio, await audio.activateMicrophone() else { throw NativeDesktopRTCError.invalidResponse }
        try check(attempt); guard microphoneRevision == revision else { audio.suppressMicrophone(); throw CancellationError() }
        microphoneIntent = true; scheduleMedia(); await mediaTask?.value
    }
    /// Makes already-authorized hardware available for accessory mute gestures.
    /// This changes input availability, never publication intent or permission.
    func prepareMutedCaptureForAccessories() async throws {
        guard snapshot.phase == .connected, !microphoneIntent, !snapshot.microphoneOn,
              !accessoryCapturePrepared, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
              let owner = audio else { return }
        accessoryCapturePrepared = true
        let attempt = epoch, revision = microphoneRevision
        publisher?.setMicrophone(false); owner.suppressMicrophone()
        do {
            guard await owner.activateMicrophone() else { throw NativeDesktopRTCError.invalidResponse }
            try check(attempt)
            // A newer explicit unmute owns the state; an old primer may not
            // overwrite it after an asynchronous device operation completes.
            guard microphoneRevision == revision, !microphoneIntent else { return }
            guard await owner.setMicrophoneMuted(true) else { throw NativeDesktopRTCError.invalidResponse }
            try check(attempt)
        } catch {
            if epoch == attempt { accessoryCapturePrepared = false }
            throw error
        }
    }
    func setCamera(_ enabled: Bool) async throws {
        if enabled { try Task.checkCancellation() }
        guard [.connecting, .connected, .reconnecting].contains(snapshot.phase) else { throw NativeDesktopRTCError.closed }
        cameraRevision &+= 1; cameraIntent = enabled
        let command = cameraRevision, attempt = epoch
        if !enabled {
            snapshot.cameraOn = false; publish()
            try await publisher?.setCamera(false)
        }
        scheduleMedia()
        await withTaskCancellationHandler(operation: { await mediaTask?.value }, onCancel: { [weak self] in
            guard enabled else { return }
            Task { @MainActor in
                guard let self, self.epoch == attempt, self.cameraRevision == command else { return }
                self.cameraIntent = false; self.snapshot.cameraOn = false; self.publish()
                // The independent media task may be waiting inside capture.start.
                // Cancel that capture rather than waiting for its permission reply.
                try? await self.publisher?.setCamera(false)
                self.scheduleMedia()
            }
        })
        if enabled { try Task.checkCancellation() }
    }
    func startPrivateAudioCheck() async throws {
        guard snapshot.phase == .connected, let owner = audio else { throw NativeDesktopRTCError.closed }
        let attempt = epoch, checkID = UUID(); privateAudioCheck = checkID
        do {
            guard try await GuestCaptureAuthorization.request(.audio) else { throw NativeDesktopRTCError.permissionDenied }
            try check(attempt)
            guard privateAudioCheck == checkID else { throw CancellationError() }
            guard await owner.beginPrivateInputCheck() else { throw NativeDesktopRTCError.invalidResponse }
            try check(attempt)
            guard privateAudioCheck == checkID else { throw CancellationError() }
        } catch {
            if privateAudioCheck == checkID, !(await owner.endPrivateInputCheck()) { throw NativeDesktopRTCError.cleanupFailed }
            throw error
        }
    }
    func stopPrivateAudioCheck() async throws {
        privateAudioCheck = UUID()
        if let audio, !(await audio.endPrivateInputCheck()) { throw NativeDesktopRTCError.cleanupFailed }
    }
    func setPlayout(_ enabled: Bool) async throws {
        let attempt = epoch
        guard let audio, await audio.setPlayoutEnabled(enabled) else { throw NativeDesktopRTCError.invalidResponse }
        try check(attempt); outputIntent = enabled; snapshot.playoutOn = enabled; publish()
    }
    func setScreenTrack(_ track: LKRTCVideoTrack?) async throws {
        guard [.connecting, .connected, .reconnecting].contains(snapshot.phase) else { throw NativeDesktopRTCError.closed }
        screenTrack = track
        try publisher?.setScreenTrack(track)
        if track == nil { snapshot.sharing = false; publish() }
        scheduleMedia(); await mediaTask?.value
    }
    func setVisibleParticipantIDs(_ ids: Set<String>?, focusedParticipantID: String?) async throws {
        guard visibleParticipantIDs != ids || self.focusedParticipantID != focusedParticipantID else { return }
        visibleParticipantIDs = ids; self.focusedParticipantID = focusedParticipantID
        refresh()
        scheduleSlots()
        await slotUpdateTask?.value
    }
    func scheduleSlots() {
        slotUpdateDirty = true
        guard kind == .telemost, ready, subscriber?.connection.localDescription != nil, slotUpdateTask == nil else { return }
        let attempt = epoch
        slotUpdateTask = Task { [weak self] in
            guard let self else { return }
            defer { if epoch == attempt { slotUpdateTask = nil } }
            while slotUpdateDirty, epoch == attempt, !Task.isCancelled {
                slotUpdateDirty = false
                do { try await updateSlots() }
                catch { if epoch == attempt, !Task.isCancelled { recover(error) }; return }
            }
        }
    }
    func scheduleMedia() {
        mediaDirty = true
        guard ready, mediaTask == nil, publisher != nil else { return }
        let attempt = epoch
        mediaTask = Task { [weak self] in
            guard let self else { return }
            defer { if epoch == attempt { mediaTask = nil } }
            while mediaDirty, epoch == attempt, !Task.isCancelled {
                mediaDirty = false
                do { try await applyMedia(attempt) }
                catch {
                    guard epoch == attempt, !Task.isCancelled else { return }
                    recover(error); return
                }
            }
        }
    }
    func applyMedia(_ attempt: UUID) async throws {
        guard let publisher, let audio else { throw NativeDesktopRTCError.closed }
        do { try await publisher.setCamera(cameraIntent) }
        catch {
            try check(attempt)
            if error as? NativeDesktopRTCError == .cleanupFailed { throw error }
            if error is CancellationError { mediaDirty = true; return }
            cameraIntent = false; snapshot.cameraOn = false
            snapshot.lastError = "The camera is unavailable. Audio can continue."; publish()
        }
        try check(attempt)
        // A user may revoke either input while camera permission/start suspends.
        if !cameraIntent { try await publisher.setCamera(false) }
        try check(attempt)
        let mic = microphoneIntent
        guard await audio.setMicrophoneMuted(!mic) else { throw NativeDesktopRTCError.invalidResponse }
        try check(attempt)
        publisher.setMicrophone(microphoneIntent && mic)
        try publisher.setScreenTrack(screenTrack)
        let offer = try await publisher.offer(); try check(attempt)
        let completion = GuestCompletion<Void>(); pendingAnswer = completion
        do {
            try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { continuation in
                    completion.install(continuation, timeout: 10)
                    Task { [weak self] in
                        guard let self else { completion.finish(.failure(CancellationError())); return }
                        do {
                            try check(attempt)
                            if let telemost { try await telemost.request("publisherSdpOffer", offer) }
                            else { try await sendTrueConfMedia(["type": "offer", "sdp": offer["sdp"] ?? "", "browser": "RockNRoll Native"]) }
                            try check(attempt); publisher.localSDPSent()
                        } catch { completion.finish(.failure(error)) }
                    }
                }
            }, onCancel: { completion.finish(.failure(CancellationError())) })
        } catch { if pendingAnswer === completion { pendingAnswer = nil }; throw error }
        if pendingAnswer === completion { pendingAnswer = nil }
        try check(attempt)
        publisherNegotiated = true
        publisher.setMicrophone(microphoneIntent)
        let micOn = microphoneIntent && publisher.microphoneSending
        let cameraOn = cameraIntent && publisher.videoTrack != nil
        let sharing = screenTrack != nil
        if let telemost {
            try await telemost.request("updateMe", ["participantMeta": ["name": name, "role": "SPEAKER", "sendAudio": micOn, "sendVideo": cameraOn],
                "participantAttributes": ["name": name, "role": "SPEAKER"], "sendAudio": micOn, "sendVideo": cameraOn, "sendSharing": sharing])
        } else {
            try await trueconf?.send(["method": "VideoSourceType", "Type": sharing ? 2 : 0, "Conference": streamID])
            try await trueconf?.send(["method": "DeviceStatus", "value": (cameraOn || sharing ? 0 : 4 << 16) | (micOn ? 0 : 4)])
        }
        try check(attempt)
        snapshot.microphoneOn = microphoneIntent && micOn
        snapshot.cameraOn = cameraIntent && cameraOn
        snapshot.sharing = screenTrack != nil && sharing
        refresh(); markConnected()
    }
    func makePeer(target: String, ice: [[String: Any]], topology: NativeDesktopRTCPeer.Topology = .split) throws -> NativeDesktopRTCPeer {
        guard let factory else { throw NativeDesktopRTCError.closed }
        let peer = try NativeDesktopRTCPeer(target: target, factory: factory, ice: ice, topology: topology, audioProfile: audioProfile)
        let attempt = epoch
        peer.onCandidate = { [weak self] value in
            Task { @MainActor in
                guard let self, self.epoch == attempt else { return }
                do {
                    if let telemost = self.telemost { try await telemost.request("webrtcIceCandidate", value) }
                    else { try await self.sendTrueConfMedia(["type": "candidate", "candidate": value["candidate"] ?? "",
                        "sdpMLineIndex": value["sdpMlineIndex"] ?? 0, "sdpMid": value["sdpMid"] ?? "0"]) }
                } catch { if self.epoch == attempt { self.recover(error) } }
            }
        }
        peer.onState = { [weak self] state in
            guard let self, epoch == attempt else { return }
            if state == .failed || state == .disconnected { recover(NativeDesktopRTCError.closed) }
            else { markConnected() }
        }
        peer.onTrack = { [weak self] mid, track in
            guard let self, epoch == attempt else { return }; tracks[mid] = track; refresh()
        }
        peer.onLocalCamera = { [weak self] track in
            guard let self, epoch == attempt else { return }; onLocalCamera?(track)
        }
        return peer
    }
    func markConnected() {
        guard ready, publisherNegotiated, helloAccepted, mediaAccepted, let publisher,
              [.connected, .completed].contains(publisher.connection.iceConnectionState),
              subscriber == nil || [.connected, .completed].contains(subscriber!.connection.iceConnectionState) else { return }
        if snapshot.phase == .reconnecting { snapshot.lastError = nil }
        snapshot.phase = .connected; deadline?.cancel(); deadline = nil; publish()
    }
    static func isRetryableTransportFailure(_ error: Error) -> Bool {
        if let error = error as? TelemostError { return error.isRetryable }
        if let error = error as? TrueConfError { return error.isRetryable }
        if error as? NativeDesktopRTCError == .cleanupFailed { return false }
        if error is URLError || error is NativeDesktopRTCError || error is GuestTransportError { return true }
        // URLSessionWebSocketTask may surface a socket reset as a raw POSIX
        // NSError, rather than wrapping it in URLError.networkConnectionLost.
        let system = error as NSError
        guard system.domain == NSPOSIXErrorDomain, let code = Int32(exactly: system.code) else { return false }
        switch POSIXErrorCode(rawValue: code) {
        case .ENOTCONN, .ECONNRESET, .ECONNABORTED, .EPIPE, .ETIMEDOUT,
             .ENETDOWN, .ENETRESET, .ENETUNREACH, .EHOSTUNREACH, .ECONNREFUSED: return true
        default: return false
        }
    }
    func recover(_ error: Error) {
        guard ![.leaving, .left, .failed].contains(snapshot.phase), recoveryTask == nil else { return }
        guard Self.isRetryableTransportFailure(error), retries < 3 else {
            let attempt = epoch
            recoveryTask = Task { [weak self] in
                guard let self, epoch == attempt, !Task.isCancelled else { return }
                await fail(error)
            }; return
        }
        retries += 1; epoch = UUID(); let attempt = epoch
        microphoneRevision &+= 1; cameraRevision &+= 1
        snapshot.phase = .reconnecting; snapshot.microphoneOn = false; snapshot.cameraOn = false; snapshot.sharing = false
        snapshot.lastError = "Connection interrupted. Reconnecting…"; publish()
        publisher?.setMicrophone(false); audio?.suppressMicrophone()
        recoveryTask = Task { [weak self] in
            guard let self else { return }
            let clean = await closeConnections()
            // Leave/reconnect can be waiting on this same retirement. An old
            // recovery must never fail or restart their replacement lifetime.
            guard epoch == attempt, !Task.isCancelled else { return }
            guard clean else { await fail(NativeDesktopRTCError.cleanupFailed); return }
            do {
                try await Task.sleep(for: .milliseconds(500 * retries)); try check(attempt)
                try await startConnection(attempt); try check(attempt)
                startMeterIfNeeded()
                recoveryTask = nil
            } catch {
                guard epoch == attempt, !Task.isCancelled else { return }
                recoveryTask = nil; recover(error)
            }
        }
    }
    func closeConnections() async -> Bool {
        if let connectionRetirementTask {
            #if DEBUG
            connectionRetirementWaitersForTesting += 1
            defer { connectionRetirementWaitersForTesting -= 1 }
            #endif
            return await connectionRetirementTask.value
        }
        ready = false; helloAccepted = false; mediaAccepted = false; publisherNegotiated = false
        deadline?.cancel(); deadline = nil
        slotUpdateTask?.cancel(); let slotUpdate = slotUpdateTask; slotUpdateTask = nil; lastSlotConfiguration = nil
        mediaTask?.cancel(); let media = mediaTask; mediaTask = nil
        pendingAnswer?.finish(.failure(CancellationError())); pendingAnswer = nil
        let tx = publisher, rx = subscriber, tm = telemost, tc = trueconf, session = http
        let retiringRoom = roomID.isEmpty ? nil : roomID
        publisher = nil; subscriber = nil; telemost = nil; trueconf = nil
        http = nil
        tx?.setMicrophone(false)
        // Clear only the retiring generation's state before suspension. The
        // task retains all owners until stop completes, even if its initiating
        // recovery is cancelled. Every concurrent closer joins this barrier.
        descriptions = [:]; slots = []; tracks = [:]; speaking = []; regions = [:]; roster = .init()
        localID = ""; cid = ""; streamID = ""; telemostBootstrap = nil
        incomingVideo = []; onVideo?([]); onLocalCamera?(nil)
        let retirement = UUID(); connectionRetirementID = retirement
        let task = Task { [self] in
            // Audio remains owned until both camera/peer stops and media work
            // finish; cancellation of a waiter cannot drop this retirement.
            let txClean = await tx?.close() ?? true, rxClean = await rx?.close() ?? true
            await tm?.close(); await tc?.close(room: retiringRoom)
            await media?.value; await slotUpdate?.value
            session?.invalidateAndCancel()
            let clean = txClean && rxClean
            cleanupSucceeded = cleanupSucceeded && clean
            if clean, connectionRetirementID == retirement {
                connectionRetirementTask = nil; connectionRetirementID = nil
            }
            // Keep a failed barrier: empty fields cannot turn an unconfirmed
            // stop into a successful later Leave or permit another connection.
            return clean
        }
        connectionRetirementTask = task
        return await task.value
    }
    func fail(_ error: Error) async {
        let message = (error as? LocalizedError)?.errorDescription ?? "The meeting connection failed. Try reconnecting."
        failureDuringShutdown = message
        _ = await leave()
    }
    func leave() async -> Bool {
        if let shutdownTask { return await shutdownTask.value }
        if snapshot.phase == .left { return cleanupSucceeded }
        epoch = UUID(); microphoneRevision &+= 1; cameraRevision &+= 1
        privateAudioCheck = UUID(); audio?.setPrivateInputMeterEnabled(false)
        snapshot.phase = .leaving; microphoneIntent = false; cameraIntent = false; screenTrack = nil
        snapshot.microphoneOn = false; snapshot.cameraOn = false; snapshot.sharing = false; publish()
        publisher?.setMicrophone(false); audio?.suppressMicrophone()
        recoveryTask?.cancel(); recoveryTask = nil; meter?.cancel(); meter = nil
        let task = Task { [self] in
            let peers = await closeConnections()
            #if DEBUG
            beforeAudioShutdownForTesting?()
            #endif
            let stopped = await audio?.shutdown() ?? true; audio = nil
            cleanupSucceeded = cleanupSucceeded && peers && stopped
            snapshot.phase = cleanupSucceeded && failureDuringShutdown == nil ? .left : .failed
            if let failureDuringShutdown { snapshot.lastError = failureDuringShutdown }
            if !cleanupSucceeded { snapshot.lastError = "Media teardown could not be confirmed. Quit before reconnecting." }
            failureDuringShutdown = nil
            snapshot.participants = []; snapshot.microphoneLevel = nil; publish()
            return cleanupSucceeded
        }
        shutdownTask = task
        let result = await task.value; shutdownTask = nil; return result
    }
}
