import AVFoundation
import Combine
import LiveKit
import ConferenceCore
import LiveKitWebRTC
import Network
import UIKit

@MainActor
final class TelemostCallEngine: CallEngine {
    var onEvent: ((CallEvent) -> Void)?
    var onMediaStatus: ((String?) -> Void)?
    private let systemCall: SystemCallCoordinator
    private let catchUp: CatchUpStore
    private let chat: ChatStore
    private let audio = AudioCoordinator()
    private let studio = StudioModel(audioControl: .fullProcessing, preferences: .standard)
    private var microphoneProbe: NativeMicrophoneProbe?
    private var view: RockCallViewController?
    private var target: TelemostTarget?
    private var name = ""
    private var bootstrap: TelemostBootstrap?
    private var factory: LKRTCPeerConnectionFactory?
    private var transport: TelemostTransport?
    private lazy var meetingChat = TelemostChat(store: chat)
    private var screenSender: NativeScreenSender?
    private var sharingTask: Task<Void, Never>?
    private var sharingGeneration = UUID()
    private var sharingActive = false
    private var broadcastObservation: AnyCancellable?
    private var subscriber: NativeRTCPeer?
    private var publisher: NativeRTCPeer?
    private var tracks: [String: LKRTCVideoTrack] = [:]
    private var descriptions: [String: [String: Any]] = [:]
    private var slots: [[String: Any]] = []
    private var speaking: Set<String> = []
    private var epoch = UUID()
    private var connectionTask: Task<Void, Never>?
    private var mediaTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var connectionDeadline: Task<Void, Never>?
    private var answerTimeout: Task<Void, Never>?
    private var answerCompletion: CheckedContinuation<Void, Error>?
    private var mediaDirty = false
    private var microphoneIntent = false
    private var audioProfile: StudioAudioProfile = .conversation
    private var cameraIntent = false
    private var cameraPosition: AVCaptureDevice.Position = .front
    private var quiet = false
    private var held = false
    private var helloAccepted = false
    private var serverReady = false
    private var connected = false
    private var leaving = false
    private var retries = 0
    private var slotKey = 0
    private var displayMode: ConferenceDisplayMode = .all
    private var observers: [NSObjectProtocol] = []
    private var pathMonitor: NWPathMonitor?
    private var pathSignature: String?
    private var previousManualAudio = false
    private var previousAudioEnabled = true
    private var rtcAudioActive = false
    private var cameraRequest = UUID()
    private var microphoneRequest = UUID()
    private(set) var hasJoinStarted = false
    var isSharingScreen: Bool { sharingActive }
    var continuationHostView: UIView? { view?.viewIfLoaded }

    init(systemCall: SystemCallCoordinator, catchUp: CatchUpStore, chat: ChatStore) {
        self.systemCall = systemCall; self.catchUp = catchUp; self.chat = chat
        audio.onRouteChanged = { [weak self] in guard let self else { return }; self.view?.setAudioRouteName(self.audio.outputName) }
        audio.onStatus = { [weak self] in self?.onMediaStatus?($0) }
        audio.onInterruptionChanged = { [weak self] interrupted in
            guard let self, self.hasJoinStarted else { return }
            if interrupted { self.pauseAudio(); self.catchUp.begin(.audioInterruption) }
            else { self.restoreAudio() }
        }
        studio.applyProfile = { [weak self] profile in self?.audioProfile = profile; self?.scheduleMedia() }
        studio.enableCamera = { [weak self] in self?.setCamera(true) }
        studio.enableMicrophone = { [weak self] in self?.setMicrophone(true) }
        studio.flipLiveCamera = { [weak self] in self?.flipCamera() }
        studio.liveCaptureDevice = { [weak self] in self?.publisher?.captureDevice }
        studio.makeLivePreview = { [weak self] in
            guard let track = self?.publisher?.videoTrack else { return nil }
            let preview = CallVideoView(); preview.track = .native(track)
            return StudioLivePreview(view: preview, stop: { preview.track = nil })
        }
        microphoneProbe = NativeMicrophoneProbe(activity: studio.microphoneActivity) { [weak self] in
            await self?.publisher?.microphoneLevel()
        }
        studio.soundCheck.verifyMuted = { [weak self] in
            guard let self, self.connected, !self.leaving, !self.held, !self.quiet,
                  self.canUseCallAudio else { throw CancellationError() }
            self.setMicrophone(false)
            guard self.publisher?.microphoneSending != true else { throw SoundCheckError.mute }
        }
        configurePresenter()
    }
    private func configurePresenter() {
        studio.presenter.preparePrivateCamera = { [weak self] in await self?.studio.releasePreviewCamera() }
        studio.presenter.onPreviewVisibilityChanged = { [weak self] in self?.view?.sharePreview.setEditorVisible($0) }
        studio.presenter.makeCameraSource = { [weak self] onFrame in
            guard let track = self?.publisher?.videoTrack else { return nil }
            return TrackPresenterCamera(source: .native(track), onFrame: onFrame)
        }
        if ProcessInfo.processInfo.isiOSAppOnMac, GuestScreenCaptureFactory.isAvailable {
            studio.presenter.prepareScreenSource = { [weak self] in
                guard let self, self.screenSender?.composed != true else { return }
                await self.stopScreenSharing(retirePresenter: false)
            }
            studio.presenter.makeScreenSource = { [weak self] onFrame, onEffect, onSelection, onEnd in
                GuestScreenCaptureFactory.make(preview: self?.view?.sharePreview ?? LocalSharePreview(),
                    onFrame: onFrame, onEffect: onEffect, onSelection: onSelection, onEnd: onEnd, onError: { _ in })
            }
        }
        studio.presenter.shareOtherApps = { [weak self] in
            guard let self else { return }
            self.studio.close()
            let generation = self.epoch
            Task { [weak self] in
                guard let self else { return }
                await self.stopScreenSharing()
                guard self.epoch == generation, !self.leaving else { return }
                self.setScreenSharing(true)
            }
        }
        studio.presenter.startSharing = { [weak self] sample in
            guard let self else { throw CancellationError() }
            let generation = self.epoch
            await self.stopScreenSharing(retirePresenter: false)
            guard self.epoch == generation else { throw CancellationError() }
            let sender = try self.makeScreenSender()
            try sender.startComposed(); sender.send(sample)
        }
        studio.presenter.sendSample = { [weak self] sample in
            guard let self, !self.held, !self.quiet, !self.leaving, self.screenSender?.composed == true else { return }
            self.screenSender?.send(sample)
        }
        studio.presenter.stopSharing = { [weak self] in await self?.stopScreenSharing() }
    }
    func join(target: TelemostTarget, name: String, container: UIViewController, quiet: Bool, title: String? = nil) throws {
        guard !hasJoinStarted else { return }
        self.target = target; self.name = name; self.quiet = quiet
        catchUp.enter(roomKey: target.invitationURL.absoluteString)
        catchUp.observe(messages: [], canView: false, enabled: false)
        chat.clear()
        catchUp.transcriptUnavailableReason = L("This meeting service does not provide live transcripts to anonymous guests.")
        audioProfile = studio.profile
        try audio.prepareForJoin()
        factory = try NativeRTCPeer.makeFactory()
        let rtcAudio = LKRTCAudioSession.sharedInstance()
        previousManualAudio = rtcAudio.useManualAudio; previousAudioEnabled = rtcAudio.isAudioEnabled
        rtcAudio.useManualAudio = true; rtcAudio.isAudioEnabled = false
        let view = RockCallViewController(title: title ?? L("Jam %@", target.roomID), catchUp: catchUp,
            chat: chat, invitationURL: target.invitationURL, roomIdentifier: target.roomID)
        view.supportsChat = true; view.supportsSharing = true; view.studio = studio
        view.usesNativeShareControl = GuestScreenCaptureFactory.isAvailable
        view.sharingAvailable = false
        view.onShare = { [weak self] in self?.setScreenSharing($0) }
        view.onLeave = { [weak self] in self?.leave() }
        view.onMicrophone = { [weak self] in self?.setMicrophone($0) }
        view.onCamera = { [weak self] in self?.setCamera($0) }
        view.onFlipCamera = { [weak self] in self?.flipCamera() }
        view.onSpeaker = { [weak self] enabled in
            do { try self?.audio.selectBuiltInOutput(speaker: enabled) }
            catch { self?.onMediaStatus?(error.localizedDescription) }
        }
        view.onDisplayMode = { [weak self] mode in
            guard let self else { return }; self.displayMode = mode
            Task { try? await self.updateSlots() }
        }
        view.onVideoDemandChanged = { [weak self] in self?.updateVisibleVideo() }
        self.view = view; hasJoinStarted = true
        view.loadViewIfNeeded(); view.setSharing(false); view.setHeld(quiet); view.setAudioRouteName(audio.outputName)
        updateMicrophoneStatus()
        refresh(); container.present(view, animated: false)
        installSystemCall()
        if !GuestScreenCaptureFactory.isAvailable {
            broadcastObservation = BroadcastManager.shared.isBroadcastingPublisher.receive(on: DispatchQueue.main)
                .sink { [weak self] active in
                    guard let self, self.hasJoinStarted, !self.leaving else { return }
                    self.setScreenSharing(active, broadcast: true)
                }
        }
        let center = NotificationCenter.default
        for notification in [UIApplication.didBecomeActiveNotification, UIApplication.didEnterBackgroundNotification] {
            observers.append(center.addObserver(forName: notification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.updateVisibleVideo(); self?.scheduleMedia() }
            })
        }
        let monitor = NWPathMonitor(); pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let signature = "\(path.status == .satisfied)-\(path.usesInterfaceType(.wifi))-\(path.usesInterfaceType(.cellular))-\(path.usesInterfaceType(.wiredEthernet))"
            Task { @MainActor in
                guard let self else { return }
                defer { self.pathSignature = signature }
                if let old = self.pathSignature, old != signature, self.connected { self.recover() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "dev.vsmirn0v.conferenceguest.telemost-path"))
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment["CONFERENCE_TEST_DIRECT_MEDIA"] == "1" {
            try AVAudioSession.sharedInstance().setActive(true)
            activateRTCAudio(); rtcAudio.isAudioEnabled = !quiet
            connect(); return
        }
        #endif
        systemCall.start()
    }
    private func installSystemCall() {
        systemCall.onCallStateChanged = { [weak self] in Task { @MainActor in self?.resumeSystemCallIfPossible() } }
        systemCall.onActivated = { [weak self] in Task { @MainActor in
            guard let self, self.hasJoinStarted else { return }
            self.activateRTCAudio()
            self.audio.callAudioDidActivate(); self.restoreAudio()
            if self.transport == nil && self.connectionTask == nil && self.recoveryTask == nil { self.connect() }
        } }
        systemCall.onDeactivated = { [weak self] in Task { @MainActor in
            guard let self else { return }; self.pauseAudio()
            self.deactivateRTCAudio()
        } }
        systemCall.onHoldChanged = { [weak self] value in Task { @MainActor in
            guard let self else { return }; self.held = value
            self.view?.sharingAvailable = self.connected && !value && !self.quiet
            self.view?.setHeld(value || self.quiet); self.studio.held = value || self.quiet
            if value { self.pauseAudio(); await self.stopScreenSharing(); self.catchUp.begin(.anotherCall) }
            else { self.catchUp.end(.anotherCall); self.restoreAudio() }
            self.scheduleMedia()
        } }
        systemCall.onMuteChanged = { [weak self] muted in Task { @MainActor in self?.setMicrophone(!muted) } }
        systemCall.onEnded = { [weak self] _ in Task { @MainActor in await self?.finish(failed: false) } }
        systemCall.onFailure = { [weak self] error in Task { @MainActor in self?.onMediaStatus?(error.localizedDescription); await self?.finish(failed: true) } }
    }
    private func pauseAudio() {
        guard hasJoinStarted else { return }
        LKRTCAudioSession.sharedInstance().isAudioEnabled = false
        view?.setSpeakerReceptionAvailable(false)
        updateMicrophoneStatus()
    }
    private func activateRTCAudio() {
        guard !rtcAudioActive else { return }
        LKRTCAudioSession.sharedInstance().audioSessionDidActivate(AVAudioSession.sharedInstance())
        rtcAudioActive = true
    }
    private func deactivateRTCAudio() {
        guard rtcAudioActive else { return }
        LKRTCAudioSession.sharedInstance().audioSessionDidDeactivate(AVAudioSession.sharedInstance())
        rtcAudioActive = false
    }
    private func restoreAudio() {
        guard hasJoinStarted, !leaving, !held, !quiet else { return }
        guard canUseCallAudio else { return }
        let wasPaused = !LKRTCAudioSession.sharedInstance().isAudioEnabled
        LKRTCAudioSession.sharedInstance().isAudioEnabled = true
        audio.ensureMixing(); view?.setSpeakerReceptionAvailable(true)
        if connected && wasPaused { recover() } else { scheduleMedia() }
        catchUp.end(.audioInterruption)
        updateMicrophoneStatus()
    }
    private var canUseCallAudio: Bool {
        #if DEBUG && targetEnvironment(simulator)
        return ProcessInfo.processInfo.environment["CONFERENCE_TEST_DIRECT_MEDIA"] == "1" || systemCall.canRestoreAudio
        #else
        return systemCall.canRestoreAudio
        #endif
    }
    private func updateMicrophoneStatus() {
        let available = hasJoinStarted && connected && !held && !quiet && LKRTCAudioSession.sharedInstance().isAudioEnabled
        let status: PiPMicrophoneStatus = available ? (studio.microphoneOn ? .on : .muted) : .unavailable
        studio.microphoneActivity.setStatus(status)
        view?.setFloatingMicrophoneStatus(status)
    }
    private func connect() {
        guard let target, hasJoinStarted, !leaving else { return }
        let generation = epoch
        onEvent?(.connecting)
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        // A finite resource timeout also terminates an established WebSocket.
        // HTTP requests and connection/ACK deadlines are bounded independently.
        config.httpShouldSetCookies = false
        let session = URLSession(configuration: config)
        connectionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let bootstrap = try await TelemostBootstrap.load(target, name: name, session: session)
                try Task.checkCancellation(); guard epoch == generation, !leaving else { session.invalidateAndCancel(); return }
                self.bootstrap = bootstrap
                if bootstrap.chatAllowed { meetingChat.start(invitation: target.invitationURL, roomID: bootstrap.roomID) }
                else { chat.isReadOnly = true; chat.unavailableReason = L("The host has disabled meeting chat.") }
                let factory = try NativeRTCPeer.makeFactory()
                self.factory = factory
                let subscriber = NativeRTCPeer(target: "SUBSCRIBER", factory: factory, ice: bootstrap.iceServers)
                let publisher = NativeRTCPeer(target: "PUBLISHER", factory: factory, ice: bootstrap.iceServers, cameraPosition: cameraPosition)
                self.subscriber = subscriber; self.publisher = publisher
                for peer in [subscriber, publisher] {
                    peer.onCandidate = { [weak self] candidate in Task { @MainActor in
                        guard let self, self.epoch == generation else { return }
                        do { try await self.transport?.request("webrtcIceCandidate", candidate) } catch { if !Task.isCancelled { self.recover(error) } }
                    } }
                    peer.onState = { [weak self] state in Task { @MainActor in
                        guard let self, self.epoch == generation else { return }
                        if state == .failed || state == .disconnected { self.recover() } else { self.markConnectedIfReady() }
                    } }
                }
                subscriber.onTrack = { [weak self] mid, track in Task { @MainActor in
                    guard let self, self.epoch == generation, self.tracks[mid]?.isEqual(track) != true else { return }
                    self.tracks[mid] = track; self.refresh()
                } }
                let transport = TelemostTransport(server: bootstrap.serverURL, session: session); self.transport = transport
                transport.onMessage = { [weak self] kind, body in
                    guard let self, self.epoch == generation else { return }; try await self.receive(kind, body)
                }
                transport.onFailure = { [weak self] error in guard let self, self.epoch == generation else { return }; self.recover(error) }
                transport.start()
                try await transport.request("hello", hello(bootstrap))
                guard epoch == generation else { return }
                helloAccepted = true; connectionTask = nil; markConnectedIfReady()
                connectionDeadline = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(20)) } catch { return }
                    guard let self, self.epoch == generation, !self.connected else { return }; self.recover(TelemostError.timedOut)
                }
            } catch {
                session.invalidateAndCancel()
                guard epoch == generation, !Task.isCancelled else { return }
                connectionTask = nil
                recover(error)
            }
        }
    }
    private func hello(_ value: TelemostBootstrap) -> [String: Any] {
        let meta: [String: Any] = ["name": name, "role": "SPEAKER", "sendAudio": false, "sendVideo": false]
        return ["participantMeta": meta, "participantAttributes": ["name": name, "role": "SPEAKER"],
            "participantId": value.participantID, "roomId": value.roomID, "serviceName": value.serviceName,
            "credentials": value.credentials, "sendAudio": false, "sendVideo": false, "sendSharing": false,
            "disablePublisher": false, "disableSubscriber": false, "disableSubscriberAudio": quiet,
            "sdkInitializationId": UUID().uuidString,
            "sdkInfo": ["implementation": "native", "version": "1", "userAgent": "RockNRoll", "hwConcurrency": ProcessInfo.processInfo.processorCount],
            "capabilitiesOffer": ["offerAnswerMode": ["SEPARATE"], "initialSubscriberOffer": ["ON_HELLO"],
                "slotsMode": ["FROM_CONTROLLER"], "simulcastMode": ["DISABLED"], "selfVadStatus": ["FROM_SERVER"],
                "dataChannelSharing": ["TO_RTP"], "videoEncoderConfig": ["NO_CONFIG"],
                "subscriberDtlsPassiveMode": ["SUBSCRIBER_DTLS_PASSIVE_MODE_DISABLED"]]]
    }
    private func receive(_ kind: String, _ body: [String: Any]) async throws {
        switch kind {
        case "serverHello":
            if let config = body["rtcConfiguration"] as? [String: Any] { try subscriber?.configure(config); try publisher?.configure(config) }
            serverReady = true; scheduleMedia()
        case "subscriberSdpOffer":
            guard let subscriber, let transport else { throw TelemostError.disconnected }
            try await transport.request("subscriberSdpAnswer", try await subscriber.answer(body))
            subscriber.localSDPSent()
            try await updateSlots()
        case "publisherSdpAnswer":
            do { try await publisher?.accept(body); completeAnswer(); markConnectedIfReady() }
            catch { completeAnswer(error); throw error }
        case "webrtcIceCandidate":
            if body["target"] as? String == "SUBSCRIBER" { try await subscriber?.addCandidate(body) }
            else if body["target"] as? String == "PUBLISHER" { try await publisher?.addCandidate(body) }
        case "updateDescription", "upsertDescription":
            if kind == "updateDescription" { descriptions.removeAll() }
            for description in (body["description"] as? [[String: Any]] ?? []).prefix(1000) {
                guard let id = description["id"] as? String, !id.isEmpty else { continue }; descriptions[id] = description
            }
            refresh()
        case "removeDescription":
            for id in body["descriptionId"] as? [String] ?? [] { descriptions.removeValue(forKey: id) }
            refresh()
        case "slotsConfig":
            // The SFU may publish autonomous slot updates with key 0 (including
            // a new share) independently of our latest layout request.
            if let key = body["key"] as? Int, key != 0, key < slotKey { return }
            slots = body["slots"] as? [[String: Any]] ?? []
            speaking = Set(slots.compactMap { slot -> String? in
                guard slot["vad"] as? Bool == true else { return nil }
                let owner = (slot["participantVideoByMid"] ?? slot["participantScreenSharingByMid"] ?? slot["participant"]) as? [String: Any]
                return owner?["participantId"] as? String
            }); refresh()
        case "vadActivity":
            if let id = bootstrap?.participantID {
                if body["active"] as? Bool == true { speaking.insert(id) } else { speaking.remove(id) }
                refresh(speakingOnly: true)
            }
        default: break
        }
    }
    private func updateSlots() async throws {
        guard serverReady, let transport else { return }
        slotKey += 1
        try await transport.request("setSlots", ["key": slotKey, "audioSlotsCount": 0,
            "slots": Array(repeating: ["width": 1280, "height": 720], count: 8),
            "gridConfig": [:], "withSelfView": false, "shutdownAllVideo": displayMode == .audioOnly])
    }
    private func markConnectedIfReady() {
        guard !connected, helloAccepted, let subscriber, let publisher,
            [.connected, .completed].contains(subscriber.connection.iceConnectionState),
            [.connected, .completed].contains(publisher.connection.iceConnectionState) else { return }
        connected = true; retries = 0; connectionDeadline?.cancel()
        view?.sharingAvailable = !held && !quiet
        systemCall.markConnected(); view?.setConnectionRecovering(false); onMediaStatus?(nil)
        catchUp.end(.connection); onEvent?(.active); refresh()
        updateMicrophoneStatus()
    }
    private func scheduleMedia() {
        mediaDirty = true
        guard serverReady, mediaTask == nil, hasJoinStarted, !leaving else { return }
        let generation = epoch
        mediaTask = Task { [weak self] in
            guard let self else { return }
            defer { if epoch == generation { mediaTask = nil } }
            while mediaDirty && epoch == generation && !Task.isCancelled {
                mediaDirty = false
                guard let publisher, let transport else { return }
                do {
                    let microphone = microphoneIntent && !held && !quiet
                    var camera = cameraIntent && !held && !quiet && UIApplication.shared.applicationState == .active
                    var cameraFailed = false
                    if camera { await studio.releasePrivateCamera() }
                    publisher.setMicrophone(microphone, profile: audioProfile)
                    do { try await publisher.setCamera(camera) }
                    catch {
                        guard !Task.isCancelled, epoch == generation else { return }
                        camera = false
                        if error is CancellationError { mediaDirty = true }
                        else {
                            cameraFailed = true; cameraIntent = false; view?.setCamera(false)
                            onMediaStatus?(TelemostError.cameraUnavailable.localizedDescription)
                        }
                    }
                    guard epoch == generation, !leaving else { return }
                    if camera && (!cameraIntent || held || quiet || UIApplication.shared.applicationState != .active) {
                        try await publisher.setCamera(false); camera = false; mediaDirty = true
                    }
                    let offer = try await publisher.offer()
                    try await withCheckedThrowingContinuation { (completion: CheckedContinuation<Void, Error>) in
                        answerCompletion = completion
                        answerTimeout = Task { [weak self] in
                            do { try await Task.sleep(for: .seconds(10)) } catch { return }; self?.completeAnswer(TelemostError.timedOut)
                        }
                        Task { [weak self] in
                            do { try await transport.request("publisherSdpOffer", offer); publisher.localSDPSent() }
                            catch { guard let self, self.epoch == generation else { return }; self.completeAnswer(error) }
                        }
                    }
                    guard epoch == generation, !leaving else { return }
                    let sendingAudio = microphone && microphoneIntent && !held && !quiet
                    let sendingVideo = camera && cameraIntent && !held && !quiet && UIApplication.shared.applicationState == .active
                    try await transport.request("updateMe", ["participantMeta": ["name": name, "role": "SPEAKER", "sendAudio": sendingAudio, "sendVideo": sendingVideo],
                        "participantAttributes": ["name": name, "role": "SPEAKER"], "sendAudio": sendingAudio, "sendVideo": sendingVideo, "sendSharing": sharingActive])
                    view?.setMicrophone(sendingAudio); view?.setCamera(sendingVideo)
                    if !cameraFailed && !held && !quiet { onMediaStatus?(nil) }
                    updateMicrophoneStatus()
                    refresh(); markConnectedIfReady()
                } catch {
                    guard !Task.isCancelled, epoch == generation else { return }
                    onMediaStatus?(error.localizedDescription); recover(error); return
                }
            }
        }
    }
    private func completeAnswer(_ error: Error? = nil) {
        answerTimeout?.cancel(); answerTimeout = nil
        let completion = answerCompletion; answerCompletion = nil
        if let error { completion?.resume(throwing: error) } else { completion?.resume() }
    }
    private func setMicrophone(_ enabled: Bool) {
        guard hasJoinStarted, !quiet, !leaving else { return }
        microphoneRequest = UUID(); let request = microphoneRequest
        if !enabled {
            microphoneIntent = false; publisher?.setMicrophone(false, profile: audioProfile)
            view?.setMicrophone(false); systemCall.setMuted(true); updateMicrophoneStatus(); scheduleMedia(); return
        }
        Task { [weak self] in
            let allowed = await withCheckedContinuation { completion in AVAudioSession.sharedInstance().requestRecordPermission { completion.resume(returning: $0) } }
            guard let self, self.hasJoinStarted, self.microphoneRequest == request else { return }
            self.microphoneIntent = allowed; if allowed { self.studio.releasePrivateMicrophone() }
            self.systemCall.setMuted(!allowed); self.scheduleMedia()
            if !allowed { self.onMediaStatus?(L("Microphone access is disabled. Enable it in Settings.")) }
        }
    }
    private func setCamera(_ enabled: Bool) {
        guard hasJoinStarted, !quiet, !leaving else { return }
        cameraRequest = UUID(); let request = cameraRequest
        if !enabled {
            cameraIntent = false; view?.setCamera(false)
            let publisher = publisher
            Task { try? await publisher?.setCamera(false) }
            scheduleMedia(); return
        }
        Task { [weak self] in
            let allowed = await AVCaptureDevice.requestAccess(for: .video)
            guard let self, self.hasJoinStarted, self.cameraRequest == request else { return }
            self.cameraIntent = allowed; self.scheduleMedia()
            if !allowed { self.onMediaStatus?(L("Camera access is disabled. Enable it in Settings.")) }
        }
    }
    private func flipCamera() {
        let generation = epoch
        Task { [weak self] in
            guard let self, let publisher else { return }
            do {
                try await publisher.flipCamera()
                guard epoch == generation else { return }
                if let position = publisher.captureDevice?.position { cameraPosition = position }
                studio.liveCameraChanged()
                refresh()
            }
            catch { if epoch == generation { onMediaStatus?(error.localizedDescription) } }
        }
    }
    private func setScreenSharing(_ enabled: Bool, broadcast: Bool = false) {
        guard hasJoinStarted, !leaving else { return }
        if !enabled {
            sharingGeneration = UUID(); sharingTask?.cancel()
            sharingTask = Task { [weak self] in await self?.stopScreenSharing() }
            return
        }
        guard !held, !quiet, connected, screenSender == nil else {
            if broadcast { BroadcastManager.shared.requestStop() }
            return
        }
        let sender: NativeScreenSender
        do { sender = try makeScreenSender() } catch { return }
        let attempt = sharingGeneration
        sharingTask = Task { [weak self] in
            do { try await sender.start(broadcast: broadcast) }
            catch {
                guard let self, self.sharingGeneration == attempt else { await sender.stop(); return }
                await self.stopScreenSharing()
                if !(error is CancellationError) { self.onMediaStatus?(L("Screen sharing unavailable: %@", error.localizedDescription)) }
            }
        }
    }
    private func makeScreenSender() throws -> NativeScreenSender {
        guard hasJoinStarted, !leaving, !held, !quiet, connected, screenSender == nil, let factory, let view else { throw CancellationError() }
        let attempt = UUID(); sharingGeneration = attempt
        let sender = NativeScreenSender(factory: factory, preview: view.sharePreview,
            onFirstFrame: { [weak self] in
                guard let self, self.sharingGeneration == attempt, self.hasJoinStarted, !self.leaving else { return }
                self.sharingActive = true; self.publisher?.setSharing(self.screenSender?.track)
                self.view?.setSharing(true); self.scheduleMedia(); self.refresh()
            }, onEnd: { [weak self] message in
                guard let self, self.sharingGeneration == attempt else { return }
                if let message { self.onMediaStatus?(message) }
                self.setScreenSharing(false)
            })
        screenSender = sender
        return sender
    }
    private func stopScreenSharing(retirePresenter: Bool = true) async {
        if retirePresenter { studio.presenter.sharingEnded() }
        sharingGeneration = UUID(); sharingTask?.cancel(); sharingTask = nil
        let sender = screenSender; screenSender = nil
        sharingActive = false; publisher?.setSharing(nil); view?.setSharing(false)
        BroadcastManager.shared.requestStop()
        await sender?.stop()
        if retirePresenter { await studio.presenter.waitForScreenStop() }
        if hasJoinStarted, !leaving, serverReady { scheduleMedia(); refresh() }
    }
    private func updateVisibleVideo() {
        _ = view?.visibleVideoQualities(foreground: UIApplication.shared.applicationState == .active, wantsVideo: false)
    }
    private func refresh(speakingOnly: Bool = false) {
        guard let localID = bootstrap?.participantID else {
            view?.render(snapshot: .init(participants: [.init(id: "local", name: name, isLocal: true, microphoneOn: false, cameraOn: false, screenShareOn: false, isSpeaking: false, videoTracks: [])])); return
        }
        var items: [CallParticipant] = descriptions.values.filter { $0["hideFromParticipantsList"] as? Bool != true }.compactMap { value in
            guard let id = value["id"] as? String else { return nil }
            let meta = value["meta"] as? [String: Any] ?? [:]
            let microphone = meta["sendAudio"] as? Bool ?? value["sendAudio"] as? Bool ?? false
            let camera = meta["sendVideo"] as? Bool ?? value["sendVideo"] as? Bool ?? false
            var streams: [CallVideoStream] = []
            for slot in slots {
                for (key, kind) in [("participantVideoByMid", CallVideoKind.camera), ("participantScreenSharingByMid", .screenShareVideo)] {
                    guard let owner = slot[key] as? [String: Any], owner["participantId"] as? String == id,
                        let mid = owner["mid"] as? String, let track = tracks[mid], kind != .camera || camera else { continue }
                    let key = id + (kind == .camera ? ".camera" : ".share")
                    if !streams.contains(where: { $0.id == key }) { streams.append(.init(id: key, source: kind, track: .native(track))) }
                }
            }
            return .init(id: id, name: String((meta["name"] as? String ?? L("Musician")).prefix(256)), isLocal: id == localID,
                microphoneOn: microphone, cameraOn: camera, screenShareOn: streams.contains { $0.source == .screenShareVideo },
                isSpeaking: speaking.contains(id), videoTracks: streams)
        }
        items.removeAll { $0.isLocal }
        items.sort { $0.id < $1.id }
        let localVideo = publisher?.videoTrack.map { CallVideoStream(id: localID + ".camera", source: .camera, track: .native($0)) }
        items.insert(.init(id: localID, name: name, isLocal: true, microphoneOn: microphoneIntent && !held && !quiet,
            cameraOn: localVideo != nil, screenShareOn: sharingActive, isSpeaking: speaking.contains(localID), videoTracks: localVideo.map { [$0] } ?? []), at: 0)
        let snapshot = CallMediaSnapshot(participants: items)
        if speakingOnly { view?.refreshSpeaking(snapshot: snapshot) } else { view?.render(snapshot: snapshot) }
    }
    private func recover(_ error: Error? = nil) {
        guard hasJoinStarted, !leaving, recoveryTask == nil else { return }
        if let error = error as? TelemostError, !error.isRetryable {
            onMediaStatus?(error.localizedDescription); Task { await finish(failed: true) }; return
        }
        if retries >= 5 { Task { await finish(failed: true) }; return }
        retries += 1; epoch = UUID(); connected = false; helloAccepted = false; serverReady = false
        updateMicrophoneStatus()
        view?.sharingAvailable = false
        connectionTask?.cancel(); connectionTask = nil; mediaTask?.cancel(); mediaTask = nil; completeAnswer(CancellationError())
        connectionDeadline?.cancel(); catchUp.begin(.connection); onEvent?(.connecting)
        view?.setConnectionRecovering(true); onMediaStatus?(L("Restoring meeting media…"))
        let delay = min(8, 1 << (retries - 1))
        recoveryTask = Task { [weak self] in
            guard let self else { return }
            await closeTransport()
            do { try await Task.sleep(for: .seconds(delay)); try Task.checkCancellation() } catch { return }
            recoveryTask = nil
            if !leaving { connect() }
        }
    }
    private func closeTransport() async {
        meetingChat.stop()
        await stopScreenSharing()
        let oldTransport = transport, oldSubscriber = subscriber, oldPublisher = publisher
        transport = nil; subscriber = nil; publisher = nil; factory = nil; bootstrap = nil
        tracks.removeAll(); slots.removeAll(); descriptions.removeAll(); speaking.removeAll(); slotKey = 0
        await oldSubscriber?.close(); await oldPublisher?.close(); await oldTransport?.close()
    }
    func leave() {
        guard hasJoinStarted, !leaving else { return }
        leaving = true; view?.endFloatingVideo(); systemCall.end()
        Task { await finish(failed: false) }
    }
    private func finish(failed: Bool) async {
        guard hasJoinStarted else { return }
        LKRTCAudioSession.sharedInstance().isAudioEnabled = false
        deactivateRTCAudio()
        hasJoinStarted = false; leaving = true; epoch = UUID()
        connectionTask?.cancel(); recoveryTask?.cancel(); mediaTask?.cancel(); connectionDeadline?.cancel(); completeAnswer(CancellationError())
        pathMonitor?.cancel(); pathMonitor = nil; observers.forEach(NotificationCenter.default.removeObserver); observers = []
        broadcastObservation = nil
        view?.endFloatingVideo(); studio.end(); chat.clear(); pauseAudio()
        microphoneProbe = nil
        await closeTransport()
        LKRTCAudioSession.sharedInstance().isAudioEnabled = previousAudioEnabled
        LKRTCAudioSession.sharedInstance().useManualAudio = previousManualAudio
        if failed { systemCall.markEnded(reason: .failed) }
        await catchUp.finishMeeting().value
        view?.dismiss(animated: false); view = nil
        onEvent?(failed ? .failed : .left)
    }
    func resumeSystemCallIfPossible() {
        systemCall.resumeIfPossible(afterReturningToMeeting: true)
        if systemCall.canRestoreAudio, !LKRTCAudioSession.sharedInstance().isAudioEnabled, hasJoinStarted, !held, !quiet {
            do {
                try audio.reactivateAfterInterruption()
                activateRTCAudio()
                restoreAudio()
            } catch { onMediaStatus?(error.localizedDescription) }
        }
    }
    func prepareToFloat() { view?.prepareToFloat() }
    func restoreFromFloatingVideo() { view?.restoreFromFloatingVideo() }
    func showMediaStatus(_ message: String?) { view?.showMediaStatus(message) }
    func setTransferHeld(_ held: Bool, restoreSending: Bool) async throws {
        if !restoreSending { microphoneIntent = false; cameraIntent = false }
        quiet = held; try await systemCall.setTransferHeld(held)
        view?.setHeld(held); scheduleMedia(); if !held { restoreAudio() }
    }
    #if DEBUG
    var studioForTesting: StudioModel { studio }
    var microphoneSendingForTesting: Bool { publisher?.microphoneSending == true }
    func setSendingForTesting(microphone: Bool, camera: Bool) {
        setMicrophone(microphone); setCamera(camera)
    }
    func flipCameraForTesting() { flipCamera() }
    func selectSpeakerForTesting(_ enabled: Bool) throws { try audio.selectBuiltInOutput(speaker: enabled) }
    var cameraPositionForTesting: AVCaptureDevice.Position? { publisher?.captureDevice?.position }
    struct ReceiveEvidence {
        var videoFrames = 0.0
        var audioDuration = 0.0
        var audioEnergy = 0.0
    }
    func startSharingForTesting() throws {
        guard let factory, let view, connected else { throw TelemostError.disconnected }
        let attempt = UUID(); sharingGeneration = attempt
        let sender = NativeScreenSender(factory: factory, preview: view.sharePreview, onFirstFrame: { [weak self] in
            guard let self, self.sharingGeneration == attempt else { return }
            self.sharingActive = true; self.publisher?.setSharing(self.screenSender?.track)
            self.scheduleMedia(); self.refresh()
        }, onEnd: { _ in })
        screenSender = sender
    }
    func sendScreenForTesting(_ pixels: CVPixelBuffer, timestamp: Int64) { screenSender?.receiveForTesting(pixels, timestamp: timestamp) }
    func stopSharingForTesting() async { await stopScreenSharing() }
    func sentScreenFramesForTesting() async -> Int {
        guard let publisher else { return 0 }
        let report = await withCheckedContinuation { completion in publisher.connection.statistics { completion.resume(returning: $0) } }
        return report.statistics.values.filter { $0.type == "outbound-rtp" && $0.values["kind"] as? String == "video" }
            .reduce(0) { $0 + (($1.values["framesEncoded"] as? NSNumber)?.intValue ?? 0) }
    }
    func codecEvidenceForTesting() async -> [[String: Any]] {
        var evidence: [[String: Any]] = []
        for peer in [publisher, subscriber].compactMap({ $0 }) {
            let report: LKRTCStatisticsReport = await withCheckedContinuation { completion in
                peer.connection.statistics { completion.resume(returning: $0) }
            }
            for entry in report.statistics.values where ["outbound-rtp", "inbound-rtp"].contains(entry.type) {
                var fields: [String: Any] = ["target": peer.target, "type": entry.type]
                for key in ["kind", "mid", "framesEncoded", "framesDecoded", "frameWidth", "frameHeight", "framesPerSecond", "totalEncodeTime", "totalDecodeTime", "encoderImplementation", "decoderImplementation", "powerEfficientEncoder", "powerEfficientDecoder"] {
                    if let value = entry.values[key] { fields[key] = value }
                }
                if let codecID = entry.values["codecId"] as? String, let codec = report.statistics[codecID] {
                    for key in ["mimeType", "sdpFmtpLine"] { if let value = codec.values[key] { fields[key] = value } }
                }
                if let mid = entry.values["mid"] as? String {
                    fields["track"] = peer.connection.transceivers.first { $0.mid == mid }?.sender.track?.trackId
                }
                evidence.append(fields)
            }
        }
        return evidence
    }
    func interruptForTesting() { transport?.interruptForTesting() }
    func receiveEvidenceForTesting() async -> ReceiveEvidence {
        guard let subscriber else { return .init() }
        let report: LKRTCStatisticsReport = await withCheckedContinuation { completion in
            subscriber.connection.statistics { completion.resume(returning: $0) }
        }
        var evidence = ReceiveEvidence()
        for entry in report.statistics.values where entry.type == "inbound-rtp" {
            evidence.videoFrames += (entry.values["framesDecoded"] as? NSNumber)?.doubleValue ?? 0
            evidence.audioDuration += (entry.values["totalSamplesDuration"] as? NSNumber)?.doubleValue ?? 0
            evidence.audioEnergy += (entry.values["totalAudioEnergy"] as? NSNumber)?.doubleValue ?? 0

        }
        return evidence
    }
    #endif
}
