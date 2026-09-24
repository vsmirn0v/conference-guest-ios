import AVFoundation
import ConferenceCore
import LiveKit
import UIKit

/// The app-owned jam service. Its media engine runs only while this route is selected.
@MainActor
final class RockRoomEngine: NSObject, RoomDelegate, @unchecked Sendable {
    var onEvent: ((CallEvent) -> Void)?
    var onMediaStatus: ((String?) -> Void)?
    private let systemCall: SystemCallCoordinator
    private let audio = AudioCoordinator()
    private let catchUp: CatchUpStore
    private let chat: ChatStore
    private var room: Room?
    private weak var container: UIViewController?
    private var callView: RockCallViewController?
    private var credentials: JamCredentials?
    private var joinTask: Task<Void, Never>?
    private var microphoneIntentOn = false
    private var cameraIntentOn = false
    private var isHeld = false
    private var audioGate = CallAudioRecoveryGate()
    private var leaveRequested = false
    private var hasConnected = false
    private var displayMode: ConferenceDisplayMode = .all
    #if DEBUG
    private var testHoldScheduled = false
    private var directMediaForTesting = false
    #endif
    private(set) var hasJoinStarted = false

    init(catchUp: CatchUpStore, chat: ChatStore, systemCall: SystemCallCoordinator) {
        self.catchUp = catchUp
        self.chat = chat
        self.systemCall = systemCall
        super.init()
        audio.onStatus = { [weak self] in self?.onMediaStatus?($0) }
        audio.onRouteChanged = { [weak self] in
            guard let self else { return }
            self.callView?.setAudioRouteName(self.audio.outputName)
        }
        audio.onInterruptionChanged = { [weak self] interrupted in
            guard let self, self.hasConnected else { return }
            if interrupted {
                self.audioGate.markInterrupted()
                self.catchUp.begin(.audioInterruption)
            } else {
                self.recoverAudioIfReady()
            }
        }
    }

    func join(target: JamTarget, credentials: JamCredentials, container: UIViewController) throws {
        guard !hasJoinStarted else { return }
        self.container = container
        self.credentials = credentials
        self.room = Room(delegate: self)
        self.leaveRequested = false
        self.hasConnected = false
        #if DEBUG
        self.testHoldScheduled = false
        self.directMediaForTesting = false
        #endif
        self.isHeld = false
        self.audioGate = CallAudioRecoveryGate()
        self.microphoneIntentOn = false
        self.cameraIntentOn = false
        self.displayMode = .all
        catchUp.enter(roomKey: target.originURL.absoluteString + "/" + target.jamID)
        chat.clear()
        chat.onSend = { [weak self] in self?.sendChat($0) }
        chat.onRetry = { [weak self] in self?.publishChat(id: $0.id, text: $0.text) }
        catchUp.observe(messages: [], canView: false, enabled: false)
        AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = false
        try AudioManager.shared.setEngineAvailability(.none)
        try audio.prepareForJoin()
        let view = RockCallViewController(title: credentials.jam.title,
                                          catchUp: catchUp, chat: chat,
                                          invitationURL: target.invitationURL,
                                          roomIdentifier: target.jamID)
        view.onLeave = { [weak self] in self?.leave() }
        view.onMicrophone = { [weak self] in self?.setMicrophone($0) }
        view.onCamera = { [weak self] in self?.setCamera($0) }
        view.onFlipCamera = { [weak self] in self?.flipCamera() }
        view.onSpeaker = { preferred in AudioManager.shared.isSpeakerOutputPreferred = preferred }
        view.onDisplayMode = { [weak self] mode in self?.setDisplayMode(mode) }
        self.callView = view
        view.setAudioRouteName(audio.outputName)
        container.present(view, animated: false)
        installCallHandlers()
        hasJoinStarted = true
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment["CONFERENCE_TEST_DIRECT_MEDIA"] == "1" {
            directMediaForTesting = true
            try AVAudioSession.sharedInstance().setActive(true)
            audioGate.activate()
            audio.callAudioDidActivate()
            recoverAudioIfReady()
            connect()
            return
        }
        #endif
        systemCall.start()
    }

    func leave() {
        guard hasJoinStarted, !leaveRequested else { return }
        leaveRequested = true
        joinTask?.cancel()
        #if DEBUG
        if directMediaForTesting { finish(failed: false); return }
        #endif
        systemCall.end()
    }

    func resumeSystemCallIfPossible() {
        systemCall.resumeIfPossible()
    }

    func showMediaStatus(_ message: String?) { callView?.showMediaStatus(message) }

    private func installCallHandlers() {
        systemCall.onActivated = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.hasJoinStarted else { return }
                self.audioGate.activate()
                self.audio.callAudioDidActivate()
                self.callView?.setAudioRouteName(self.audio.outputName)
                self.recoverAudioIfReady()
                self.systemCall.resumeIfPossible()
                if !self.hasConnected && self.joinTask == nil { self.connect() }
            }
        }
        systemCall.onDeactivated = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.hasJoinStarted else { return }
                self.audioGate.deactivate()
                if self.hasConnected { self.catchUp.begin(.audioInterruption) }
                self.onMediaStatus?("Jam audio paused by iOS")
                try? AudioManager.shared.setEngineAvailability(.none)
            }
        }
        systemCall.onEnded = { [weak self] _ in
            Task { @MainActor [weak self] in self?.finish(failed: false) }
        }
        systemCall.onFailure = { [weak self] _ in
            Task { @MainActor [weak self] in self?.finish(failed: true) }
        }
        systemCall.onMuteChanged = { [weak self] muted in
            Task { @MainActor [weak self] in self?.setMicrophone(!muted) }
        }
        systemCall.onHoldChanged = { [weak self] held in
            Task { @MainActor [weak self] in
                guard let self, self.hasJoinStarted else { return }
                self.isHeld = held
                self.audioGate.setHeld(held)
                if self.hasConnected {
                    if held { self.catchUp.begin(.anotherCall) }
                    else { self.catchUp.end(.anotherCall) }
                }
                if held {
                    try? AudioManager.shared.setEngineAvailability(.none)
                    Task {
                        _ = try? await self.room?.localParticipant.setMicrophone(enabled: false)
                        _ = try? await self.room?.localParticipant.setCamera(enabled: false)
                    }
                } else {
                    self.recoverAudioIfReady()
                }
                self.callView?.setHeld(held)
            }
        }
    }

    private func recoverAudioIfReady() {
        guard hasJoinStarted, !leaveRequested, audioGate.takeRecovery() else { return }
        do {
            // The outgoing cellular call can release hold before CallKit gives
            // this call its audio session back. Restart the engine only after both.
            try AudioManager.shared.setEngineAvailability(.none)
            try AudioManager.shared.setEngineAvailability(.default)
            audio.ensureMixing()
            applyMediaIntent()
            catchUp.end(.audioInterruption)
        } catch {
            audioGate.markInterrupted()
            onMediaStatus?("Audio could not resume: \(error.localizedDescription)")
        }
    }

    private func connect() {
        guard let room, let credentials else { return }
        onEvent?(.connecting)
        joinTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await room.connect(url: credentials.serverURL.absoluteString,
                                       token: credentials.participantToken)
                guard self.room === room, !self.leaveRequested else { return }
                self.joinTask = nil
                self.hasConnected = true
                self.chat.canSend = true
                #if DEBUG
                print("Jam engine: connected")
                #endif
                self.systemCall.markConnected()
                self.catchUp.end(.connection)
                if self.isHeld { self.catchUp.begin(.anotherCall) }
                self.callView?.render(room: room)
                self.onEvent?(.active)
                #if DEBUG
                self.scheduleTestHoldIfRequested()
                #endif
            } catch {
                guard !Task.isCancelled else { return }
                #if DEBUG
                print("Jam engine: join failed: \(error.localizedDescription)")
                #endif
                self.joinTask = nil
                self.onMediaStatus?("Could not connect to jam: \(error.localizedDescription)")
                self.finish(failed: true)
            }
        }
    }

    private func setMicrophone(_ enabled: Bool) {
        guard hasJoinStarted else { return }
        microphoneIntentOn = enabled
        callView?.setMicrophone(enabled)
        systemCall.setMuted(!enabled)
        guard !isHeld, let room else { return }
        Task { @MainActor [weak self] in
            do {
                _ = try await room.localParticipant.setMicrophone(enabled: enabled)
                self?.callView?.render(room: room)
            } catch {
                if self?.microphoneIntentOn == enabled {
                    self?.microphoneIntentOn = false
                    self?.callView?.setMicrophone(false)
                    self?.systemCall.setMuted(true)
                }
                self?.onMediaStatus?("Microphone unavailable: \(error.localizedDescription)")
            }
        }
    }

    private func setCamera(_ enabled: Bool) {
        guard hasJoinStarted else { return }
        cameraIntentOn = enabled
        callView?.setCamera(enabled)
        guard !isHeld, let room else { return }
        Task { @MainActor [weak self] in
            do {
                _ = try await room.localParticipant.setCamera(enabled: enabled)
                self?.callView?.render(room: room)
            } catch {
                if self?.cameraIntentOn == enabled {
                    self?.cameraIntentOn = false
                    self?.callView?.setCamera(false)
                }
                self?.onMediaStatus?("Camera unavailable: \(error.localizedDescription)")
            }
        }
    }

    private func applyMediaIntent() {
        guard let room else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = try? await room.localParticipant.setMicrophone(enabled: self.microphoneIntentOn)
            _ = try? await room.localParticipant.setCamera(enabled: self.cameraIntentOn)
            self.callView?.render(room: room)
        }
    }

    private func flipCamera() {
        guard cameraIntentOn,
              let track = room?.localParticipant.firstCameraVideoTrack as? LocalVideoTrack,
              let capturer = track.capturer as? CameraCapturer else { return }
        Task { @MainActor [weak self] in
            do { _ = try await capturer.switchCameraPosition() }
            catch { self?.onMediaStatus?("Camera could not switch: \(error.localizedDescription)") }
        }
    }

    private func finish(failed: Bool) {
        guard hasJoinStarted else { return }
        #if DEBUG
        print("Jam engine: finishing; failed=\(failed), connected=\(hasConnected), leaving=\(leaveRequested)")
        #endif
        let wasLeaving = leaveRequested
        let wasConnected = hasConnected
        hasJoinStarted = false
        audioGate = CallAudioRecoveryGate()
        leaveRequested = true
        hasConnected = false
        chat.clear()
        joinTask?.cancel()
        joinTask = nil
        if !wasLeaving { systemCall.markEnded(reason: .failed) }
        try? AudioManager.shared.setEngineAvailability(.none)
        #if DEBUG
        if directMediaForTesting {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            directMediaForTesting = false
        }
        #endif
        if let room { Task { await room.disconnect() } }
        room = nil
        credentials = nil
        if failed && wasConnected {
            catchUp.begin(.connection)
            catchUp.continueAsConnectionGap()
        } else {
            catchUp.finishMeeting()
        }
        callView?.dismiss(animated: false)
        callView = nil
        onEvent?(failed ? .failed : .left)
    }

    nonisolated func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        Task { @MainActor [weak self] in self?.refresh(room) }
    }

    nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        Task { @MainActor [weak self] in self?.refresh(room) }
    }

    nonisolated func room(_ room: Room, didUpdateSpeakingParticipants participants: [Participant]) {
        Task { @MainActor [weak self] in
            guard let self, self.room === room, self.hasJoinStarted else { return }
            self.callView?.refreshSpeaking(room: room)
        }
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        Task { @MainActor [weak self] in self?.refresh(room) }
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication) {
        Task { @MainActor [weak self] in self?.refresh(room) }
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant, didPublishTrack publication: RemoteTrackPublication) {
        Task { @MainActor [weak self] in self?.refresh(room) }
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant, didUnpublishTrack publication: RemoteTrackPublication) {
        Task { @MainActor [weak self] in self?.refresh(room) }
    }

    nonisolated func room(_ room: Room, participant: Participant, trackPublication: TrackPublication, didUpdateIsMuted isMuted: Bool) {
        Task { @MainActor [weak self] in self?.refresh(room) }
    }

    nonisolated func room(_ room: Room, didStartReconnectWithMode reconnectMode: ReconnectMode) {
        Task { @MainActor [weak self] in
            guard let self, self.room === room, self.hasConnected else { return }
            self.catchUp.begin(.connection)
            self.onEvent?(.connecting)
        }
    }

    nonisolated func room(_ room: Room, didCompleteReconnectWithMode reconnectMode: ReconnectMode) {
        Task { @MainActor [weak self] in
            guard let self, self.room === room, self.hasConnected else { return }
            self.catchUp.end(.connection)
            self.applyMediaIntent()
            self.refresh(room)
            self.onEvent?(.active)
        }
    }

    nonisolated func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        Task { @MainActor [weak self] in
            guard let self, self.room === room, !self.leaveRequested else { return }
            #if DEBUG
            print("Jam engine: room disconnected: \(error?.localizedDescription ?? "none")")
            #endif
            self.catchUp.begin(.connection)
            self.finish(failed: true)
        }
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant?,
                          didReceiveData data: Data, forTopic topic: String,
                          encryptionType: EncryptionType) {
        guard topic == RockChatPacket.topic, data.count <= 4_096,
              let packet = try? JSONDecoder().decode(RockChatPacket.self, from: data),
              !packet.text.isEmpty, packet.text.count <= 2_000 else { return }
        Task { @MainActor [weak self] in
            guard let self, self.room === room else { return }
            self.chat.append(ChatEntry(id: packet.id,
                                       sender: participant?.name ?? "Musician",
                                       text: packet.text, sentAt: Date(), isOwn: false))
        }
    }

    private func sendChat(_ text: String) {
        guard hasConnected else { return }
        let packet = RockChatPacket(id: UUID().uuidString, text: text)
        chat.append(ChatEntry(id: packet.id, sender: "You", text: text,
                              sentAt: Date(), isOwn: true, delivery: .pending))
        publishChat(id: packet.id, text: text)
    }

    private func publishChat(id: String, text: String) {
        guard hasConnected, let room else { return }
        let packet = RockChatPacket(id: id, text: text)
        Task { @MainActor [weak self] in
            do {
                try await room.localParticipant.publish(
                    data: JSONEncoder().encode(packet),
                    options: DataPublishOptions(topic: RockChatPacket.topic, reliable: true))
                self?.chat.setDelivery(.sent, for: packet.id)
            } catch {
                self?.chat.setDelivery(.failed, for: packet.id)
                self?.onMediaStatus?("Chat could not send: \(error.localizedDescription)")
            }
        }
    }

    private func refresh(_ room: Room) {
        guard self.room === room, hasJoinStarted else { return }
        updateVideoSubscriptions(in: room)
        callView?.render(room: room)
    }

    private func setDisplayMode(_ mode: ConferenceDisplayMode) {
        displayMode = mode
        if let room { updateVideoSubscriptions(in: room) }
    }

    private func updateVideoSubscriptions(in room: Room) {
        for participant in room.remoteParticipants.values {
            for item in participant.videoTracks {
                guard let publication = item as? RemoteTrackPublication else { continue }
                let wanted = displayMode == .all ||
                    (displayMode == .screenShares && publication.source == .screenShareVideo)
                Task { [weak self] in
                    do { try await publication.set(subscribed: wanted) }
                    catch { self?.onMediaStatus?("Video preference could not update: \(error.localizedDescription)") }
                }
            }
        }
    }

    #if DEBUG
    private func scheduleTestHoldIfRequested() {
        guard !testHoldScheduled,
              let raw = ProcessInfo.processInfo.environment["CONFERENCE_TEST_HOLD_SECONDS"],
              let seconds = Double(raw), (2...30).contains(seconds) else { return }
        testHoldScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, self.hasJoinStarted, !self.leaveRequested else { return }
            self.systemCall.requestHoldForTesting(true)
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard self.hasJoinStarted, !self.leaveRequested else { return }
            self.systemCall.requestHoldForTesting(false)
        }
    }
    #endif
}

private struct RockChatPacket: Codable {
    static let topic = "rock.chat.v1"
    let id: String
    let text: String
}
