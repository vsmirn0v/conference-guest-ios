import AVFoundation
import ConferenceCore
import LiveKit
import UIKit

/// The app-owned jam service. Its media engine runs only while this route is selected.
@MainActor
final class RockRoomEngine: NSObject, RoomDelegate, CallEngine, @unchecked Sendable {
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
    private var isHeld = false { didSet { updatePiPMicrophoneStatus() } }
    private var audioAvailable = false { didSet { updatePiPMicrophoneStatus() } }
    private var audioGate = CallAudioRecoveryGate()
    private var leaveRequested = false { didSet { updatePiPMicrophoneStatus() } }
    private var hasConnected = false { didSet { updatePiPMicrophoneStatus() } }
    private var displayMode: ConferenceDisplayMode = .all
    private var refreshScheduled = false
    private let videoSubscriptions = VideoSubscriptionCoordinator<ObjectIdentifier>()
    private var videoPublisher = RoomVideoPublisher()
    private var studio = StudioModel(audioControl: .fullProcessing, preferences: .standard)
    private var microphoneProbe: RoomMicrophoneProbe?
    private var studioAudio = StudioAudioUpdates()
    #if DEBUG
    private var testHoldScheduled = false
    private var directMediaForTesting = false
    private let outgoingMonitor = OutgoingRoomMonitor()
    #endif
    private(set) var hasJoinStarted = false
    private var receptionPaused = false
    var isSharingScreen: Bool { room?.localParticipant.isScreenShareEnabled() == true }
    var continuationHostView: UIView? { callView?.viewIfLoaded }
    func setTransferHeld(_ held: Bool, restoreSending: Bool) async throws {
        if !held && !restoreSending { microphoneIntentOn = false; cameraIntentOn = false }
        try await systemCall.setTransferHeld(held)
        await Task.yield()
    }
    func enableReception() throws {
        try AudioManager.shared.setEngineAvailability(.default)
        receptionPaused = false
        callView?.setHeld(false)
    }

    init(catchUp: CatchUpStore, chat: ChatStore, systemCall: SystemCallCoordinator) {
        self.catchUp = catchUp
        self.chat = chat
        self.systemCall = systemCall
        super.init()
        videoSubscriptions.onError = { [weak self] error in
            self?.onMediaStatus?(L("Video preference could not update: %@", error.localizedDescription))
        }
        audio.onStatus = { [weak self] in self?.onMediaStatus?($0) }
        audio.onRouteChanged = { [weak self] in
            guard let self else { return }
            self.callView?.setAudioRouteName(self.audio.outputName)
        }
        audio.onInterruptionChanged = { [weak self] interrupted in
            guard let self, self.hasConnected else { return }
            if interrupted {
                self.audioAvailable = false
                self.audioGate.markInterrupted()
                self.catchUp.begin(.audioInterruption)
                self.updatePiPMicrophoneStatus()
            } else {
                self.recoverAudioIfReady()
            }
        }
    }

    func join(target: JamTarget, credentials: JamCredentials, container: UIViewController, quiet: Bool = false) throws {
        guard !hasJoinStarted else { return }
        self.container = container
        self.credentials = credentials
        videoSubscriptions.reset()
        videoPublisher = RoomVideoPublisher()
        #if DEBUG
        if let experiment = OutgoingRoomExperiment.configured {
            self.room = Room(delegate: self, roomOptions: experiment.options)
            self.videoPublisher = RoomVideoPublisher(options: experiment.options.defaultVideoPublishOptions)
        } else { self.room = Room(delegate: self, roomOptions: RoomMediaPolicy.options) }
        #else
        self.room = Room(delegate: self, roomOptions: RoomMediaPolicy.options)
        #endif
        self.leaveRequested = false
        self.hasConnected = false
        #if DEBUG
        self.testHoldScheduled = false
        self.directMediaForTesting = false
        #endif
        self.audioAvailable = false
        self.receptionPaused = quiet
        self.isHeld = false
        self.audioGate = CallAudioRecoveryGate()
        self.microphoneIntentOn = false
        self.cameraIntentOn = false
        self.displayMode = .all
        if let microphoneProbe { AudioManager.shared.remove(localAudioRenderer: microphoneProbe); self.microphoneProbe = nil }
        studio.end()
        studioAudio.end()
        studioAudio = StudioAudioUpdates()
        studio = StudioModel(audioControl: .fullProcessing, preferences: .standard)
        studioAudio.profile = studio.profile
        studio.applyProfile = { [weak self, weak room = self.room] profile in
            guard let self, let room, self.room === room, !self.leaveRequested else { throw CancellationError() }
            let previous = self.studioAudio.profile
            self.studioAudio.profile = profile
            do { try await self.applyAudioProfile(to: room) }
            catch {
                if self.room === room && self.studioAudio.profile == profile { self.studioAudio.profile = previous }
                throw error
            }
        }
        #if DEBUG
        studio.applyTestProfileIfRequested()
        #endif
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
        view.studio = studio
        let microphoneProbe = RoomMicrophoneProbe(activity: studio.microphoneActivity)
        self.microphoneProbe = microphoneProbe
        AudioManager.shared.add(localAudioRenderer: microphoneProbe)
        studio.soundCheck.verifyMuted = { [weak self, weak room = self.room] in
            guard let self, let room, self.room === room, !self.leaveRequested, !self.isHeld,
                  self.audioAvailable else { throw CancellationError() }
            self.setMicrophone(false)
            for _ in 0..<60 {
                try Task.checkCancellation()
                guard self.room === room, !self.leaveRequested, !self.isHeld, self.audioAvailable else { throw CancellationError() }
                if !room.localParticipant.isMicrophoneEnabled() { return }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            throw SoundCheckError.mute
        }
        studio.liveCaptureDevice = { [weak room = self.room] in
            ((room?.localParticipant.firstCameraVideoTrack as? LocalVideoTrack)?.capturer as? CameraCapturer)?.device
        }
        studio.makeLivePreview = { [weak self, weak room = self.room] in
            guard let self, let room, self.room === room, !self.leaveRequested,
                  let track = room.localParticipant.firstCameraVideoTrack else { return nil }
            let preview = VideoView()
            preview.layoutMode = .fit
            preview.track = track
            return StudioLivePreview(view: preview, stop: { preview.track = nil })
        }
        view.onLeave = { [weak self] in self?.leave() }
        view.onMicrophone = { [weak self] in self?.setMicrophone($0) }
        view.onCamera = { [weak self] in self?.setCamera($0) }
        view.onShare = { [weak self] in self?.setScreenShare($0) }
        view.onFlipCamera = { [weak self] in self?.flipCamera() }
        view.onSpeaker = { preferred in AudioManager.shared.isSpeakerOutputPreferred = preferred }
        view.onDisplayMode = { [weak self] mode in self?.setDisplayMode(mode) }
        self.callView = view
        view.setHeld(quiet)
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
        callView?.endFloatingVideo()
        joinTask?.cancel()
        BroadcastManager.shared.requestStop()
        #if DEBUG
        if directMediaForTesting { finish(failed: false); return }
        #endif
        systemCall.end()
    }

    func resumeSystemCallIfPossible() {
        systemCall.resumeIfPossible()
    }

    func prepareToFloat() { callView?.prepareToFloat() }
    func restoreFromFloatingVideo() { callView?.restoreFromFloatingVideo() }

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
                self.audioAvailable = false
                self.audioGate.deactivate()
                if self.hasConnected { self.catchUp.begin(.audioInterruption) }
                self.onMediaStatus?(L("Jam audio paused by iOS"))
                try? AudioManager.shared.setEngineAvailability(.none)
                self.updatePiPMicrophoneStatus()
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
                self.updatePiPMicrophoneStatus()
            }
        }
    }

    private func recoverAudioIfReady() {
        guard hasJoinStarted, !leaveRequested, audioGate.takeRecovery() else { return }
        do {
            // The outgoing cellular call can release hold before CallKit gives
            // this call its audio session back. Restart the engine only after both.
            try AudioManager.shared.setEngineAvailability(.none)
            if !receptionPaused { try AudioManager.shared.setEngineAvailability(.default) }
            audio.ensureMixing()
            audioAvailable = true
            applyMediaIntent()
            catchUp.end(.audioInterruption)
        } catch {
            audioAvailable = false
            audioGate.markInterrupted()
            onMediaStatus?(L("Audio could not resume: %@", error.localizedDescription))
        }
        updatePiPMicrophoneStatus()
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
                if OutgoingRoomExperiment.configured != nil { self.outgoingMonitor.start(room: room) }
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
                self.onMediaStatus?(L("Could not connect to jam: %@", error.localizedDescription))
                self.finish(failed: true)
            }
        }
    }

    private func updatePiPMicrophoneStatus() {
        guard hasConnected, !leaveRequested, !isHeld, audioAvailable,
              let room, room.connectionState == .connected else {
            studio.microphoneActivity.setStatus(.unavailable)
            studio.releasePrivateMicrophone()
            callView?.setSpeakerReceptionAvailable(false)
            callView?.setFloatingMicrophoneStatus(.unavailable)
            return
        }
        let wasSpeakerAvailable = callView?.activeSpeaker.available == true
        callView?.setSpeakerReceptionAvailable(true)
        if !wasSpeakerAvailable { callView?.refreshSpeaking(room: room) }
        let microphone = room.localParticipant.audioTracks.first { $0.source == .microphone }
        let status: PiPMicrophoneStatus
        if let microphone {
            status = microphone.isMuted ? .muted : .on
        } else {
            status = microphoneIntentOn ? .unavailable : .muted
        }
        studio.microphoneActivity.setStatus(status)
        callView?.setFloatingMicrophoneStatus(status)
    }

    private func setMicrophone(_ enabled: Bool) {
        guard hasJoinStarted else { return }
        guard !receptionPaused else { systemCall.setMuted(true); return }
        if enabled { studio.releasePrivateMicrophone() }
        microphoneIntentOn = enabled
        callView?.setMicrophone(enabled)
        systemCall.setMuted(!enabled)
        guard !isHeld, let room else { return }
        Task { @MainActor [weak self] in
            guard let self, self.room === room, !self.leaveRequested, !self.isHeld,
                  self.microphoneIntentOn == enabled else { return }
            do {
                _ = try await room.localParticipant.setMicrophone(enabled: enabled,
                    captureOptions: StudioAudioPolicy.captureOptions(for: self.studioAudio.profile))
                guard self.room === room, !self.leaveRequested else { return }
                do { try await self.applyAudioProfile(to: room) }
                catch is CancellationError { return }
                catch { self.studio.reportUpdateFailure() }
                self.updatePiPMicrophoneStatus()
                self.callView?.render(room: room)
            } catch is CancellationError { return }
            catch {
                guard self.room === room, !self.leaveRequested else { return }
                if self.microphoneIntentOn == enabled {
                    self.microphoneIntentOn = false
                    self.callView?.setMicrophone(false)
                    self.systemCall.setMuted(true)
                }
                self.updatePiPMicrophoneStatus()
                self.onMediaStatus?(L("Microphone unavailable: %@", error.localizedDescription))
            }
        }
    }

    private func setCamera(_ enabled: Bool) {
        guard hasJoinStarted else { return }
        guard !receptionPaused else { return }
        cameraIntentOn = enabled
        callView?.setCamera(enabled)
        guard !isHeld, let room else { return }
        let publisher = videoPublisher
        Task { @MainActor [weak self] in
            do {
                await self?.studio.releasePrivateCamera()
                _ = try await publisher.perform { options in
                    guard self?.room === room, self?.leaveRequested == false,
                          self?.cameraIntentOn == enabled, self?.isHeld == false else { throw CancellationError() }
                    return try await room.localParticipant.setCamera(enabled: enabled, publishOptions: options)
                }
                guard self?.room === room, self?.leaveRequested == false else { return }
                self?.callView?.render(room: room)
            } catch is CancellationError {
                return
            } catch {
                guard self?.room === room, self?.leaveRequested == false else { return }
                if self?.cameraIntentOn == enabled {
                    self?.cameraIntentOn = false
                    self?.callView?.setCamera(false)
                }
                self?.onMediaStatus?(L("Camera unavailable: %@", error.localizedDescription))
            }
        }
    }

    private func setScreenShare(_ enabled: Bool) {
        guard hasJoinStarted, !leaveRequested, let room else { return }
        let publisher = videoPublisher
        Task { @MainActor [weak self] in
            do {
                _ = try await publisher.perform { options in
                    guard self?.room === room, self?.leaveRequested == false else { throw CancellationError() }
                    return try await room.localParticipant.set(source: .screenShareVideo, enabled: enabled, publishOptions: options)
                }
                if !enabled { BroadcastManager.shared.requestStop() }
                guard let self, self.room === room else { return }
                self.callView?.render(room: room)
            } catch let error as LiveKitError where error.type == .cancelled {
                self?.callView?.render(room: room)
            } catch is CancellationError {
                return
            } catch {
                guard self?.room === room, self?.leaveRequested == false else { return }
                self?.onMediaStatus?(L("Screen sharing unavailable: %@", error.localizedDescription))
            }
        }
    }

    private func applyMediaIntent() {
        guard let room else { return }
        let publisher = videoPublisher
        Task { @MainActor [weak self] in
            guard let self, self.room === room, !self.leaveRequested else { return }
            _ = try? await room.localParticipant.setMicrophone(enabled: self.microphoneIntentOn && !self.receptionPaused,
                captureOptions: StudioAudioPolicy.captureOptions(for: self.studioAudio.profile))
            try? await self.applyAudioProfile(to: room)
            _ = try? await publisher.perform { options in
                guard self.room === room, !self.leaveRequested else { throw CancellationError() }
                return try await room.localParticipant.setCamera(enabled: self.cameraIntentOn && !self.receptionPaused,
                                                         publishOptions: options)
            }
            guard self.room === room, !self.leaveRequested else { return }
            self.updatePiPMicrophoneStatus()
            self.callView?.render(room: room)
        }
    }

    private func applyAudioProfile(to room: Room) async throws {
        guard self.room === room, !leaveRequested else { throw CancellationError() }
        guard studio.hasSelection || studioAudio.profile != .conversation else { return }
        guard let track = room.localParticipant.audioTracks.first(where: { $0.source == .microphone })?.track as? LocalAudioTrack else { return }
        // This SDK call blocks until its signaling thread finishes; keep it off the UI thread.
        try await studioAudio.apply { [weak self] profile in
            guard self?.room === room, self?.leaveRequested == false else { throw CancellationError() }
            let options = StudioAudioPolicy.processingOptions(for: profile)
            _ = try await Task.detached { try track.setAudioProcessingOptions(options) }.value
        }
        guard self.room === room, !leaveRequested else { throw CancellationError() }
    }

    private func flipCamera() {
        guard cameraIntentOn,
              let track = room?.localParticipant.firstCameraVideoTrack as? LocalVideoTrack,
              let capturer = track.capturer as? CameraCapturer else { return }
        Task { @MainActor [weak self] in
            do { _ = try await capturer.switchCameraPosition() }
            catch { self?.onMediaStatus?(L("Camera could not switch: %@", error.localizedDescription)) }
        }
    }

    private func finish(failed: Bool) {
        guard hasJoinStarted else { return }
        if let microphoneProbe { AudioManager.shared.remove(localAudioRenderer: microphoneProbe); self.microphoneProbe = nil }
        studio.end()
        studioAudio.end()
        callView?.endFloatingVideo()
        #if DEBUG
        print("Jam engine: finishing; failed=\(failed), connected=\(hasConnected), leaving=\(leaveRequested)")
        outgoingMonitor.stop()
        #endif
        let wasLeaving = leaveRequested
        let wasConnected = hasConnected
        hasJoinStarted = false
        audioGate = CallAudioRecoveryGate()
        leaveRequested = true
        hasConnected = false
        refreshScheduled = false
        videoSubscriptions.reset()
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
        let departingRoom = room
        room = nil
        credentials = nil
        let cleanup: Task<Void, Never>?
        if failed && wasConnected {
            catchUp.begin(.connection)
            catchUp.continueAsConnectionGap()
            cleanup = nil
        } else { cleanup = catchUp.finishMeeting() }
        callView?.dismiss(animated: false)
        callView = nil
        let destination = onEvent
        Task {
            await departingRoom?.disconnect()
            await cleanup?.value
            destination?(failed ? .failed : .left)
        }
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
            self.callView?.refreshSpeaking(room: room, speakers: participants)
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
            self.callView?.setConnectionRecovering(true)
            self.updatePiPMicrophoneStatus()
            self.catchUp.begin(.connection)
            self.onEvent?(.connecting)
        }
    }

    nonisolated func room(_ room: Room, didCompleteReconnectWithMode reconnectMode: ReconnectMode) {
        Task { @MainActor [weak self] in
            guard let self, self.room === room, self.hasConnected else { return }
            self.callView?.setConnectionRecovering(false)
            self.catchUp.end(.connection)
            self.applyMediaIntent()
            self.videoSubscriptions.reset()
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
        guard topic == RoomChatPacket.topic,
              let packet = try? RoomChatPacket.decode(data) else { return }
        Task { @MainActor [weak self] in
            guard let self, self.room === room else { return }
            self.chat.append(ChatEntry(id: packet.id,
                                       sender: participant?.name ?? L("Musician"),
                                       text: packet.text, sentAt: Date(), isOwn: false))
        }
    }

    private func sendChat(_ text: String) {
        guard hasConnected else { return }
        let packet = RoomChatPacket(id: UUID().uuidString, text: text)
        guard (try? packet.encoded()) != nil else { return }
        chat.append(ChatEntry(id: packet.id, sender: L("You"), text: text,
                              sentAt: Date(), isOwn: true, delivery: .pending))
        publishChat(id: packet.id, text: text)
    }

    private func publishChat(id: String, text: String) {
        guard hasConnected, let room else { return }
        let packet = RoomChatPacket(id: id, text: text)
        Task { @MainActor [weak self] in
            do {
                try await room.localParticipant.publish(
                    data: packet.encoded(),
                    options: DataPublishOptions(topic: RoomChatPacket.topic, reliable: true))
                guard let self, self.room === room, !self.leaveRequested else { return }
                self.chat.setDelivery(.sent, for: packet.id)
            } catch {
                guard let self, self.room === room, !self.leaveRequested else { return }
                self.chat.setDelivery(.failed, for: packet.id)
                self.onMediaStatus?(L("Chat could not send: %@", error.localizedDescription))
            }
        }
    }

    private func refresh(_ room: Room) {
        guard self.room === room, hasJoinStarted else { return }
        updatePiPMicrophoneStatus()
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            guard self.room === room, self.hasJoinStarted else { return }
            self.updateVideoSubscriptions(in: room)
            self.callView?.render(room: room)
        }
    }

    private func setDisplayMode(_ mode: ConferenceDisplayMode) {
        displayMode = mode
        if let room { updateVideoSubscriptions(in: room) }
    }

    private func updateVideoSubscriptions(in room: Room) {
        let requests = room.remoteParticipants.values.flatMap { participant in
            participant.videoTracks.compactMap { item -> VideoSubscriptionCoordinator<ObjectIdentifier>.Request? in
                guard let publication = item as? RemoteTrackPublication else { return nil }
                let wanted = displayMode == .all ||
                    (displayMode == .screenShares && publication.source == .screenShareVideo)
                return .init(key: ObjectIdentifier(publication), subscribed: wanted) {
                    try await publication.set(subscribed: $0)
                }
            }
        }
        videoSubscriptions.update(requests)
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
