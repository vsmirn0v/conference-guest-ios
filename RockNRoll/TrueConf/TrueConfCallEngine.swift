import AVFoundation
import Combine
import LiveKit
import ConferenceCore
import LiveKitWebRTC
import Network
import UIKit

@MainActor
final class TrueConfCallEngine: CallEngine {
    var onEvent: ((CallEvent) -> Void)?
    var onMediaStatus: ((String?) -> Void)?
    var onRoomTitle: ((String) -> Void)?
    private let systemCall: SystemCallCoordinator
    private let catchUp: CatchUpStore
    private let chat: ChatStore
    private let audio = AudioCoordinator()
    private let studio = StudioModel(audioControl: .fullProcessing, preferences: .standard)
    private var microphoneProbe: NativeMicrophoneProbe?
    private var activityObservation: AnyCancellable?
    private var view: RockCallViewController?
    private var target: TrueConfTarget?
    private var name = ""
    private var bootstrap: TrueConfBootstrap?
    private var factory: LKRTCPeerConnectionFactory?
    private var transport: TrueConfTransport?
    private var screenSender: NativeScreenSender?
    private var sharingTask: Task<Void, Never>?
    private var sharingGeneration = UUID()
    private var sharingActive = false
    private var broadcastObservation: AnyCancellable?
    private var publisher: NativeRTCPeer?
    private var roster = TrueConfRoster()
    private var regions: [String: CGRect] = [:]
    private var streams: [String: CompositeVideoSource] = [:]
    private var cid = "", localID = "", streamID = ""
    private var receiveTrack: LKRTCVideoTrack?
    private var mediaAccepted = false
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
    private var serverReady = false
    private var connected = false
    private var leaving = false
    private var retries = 0
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
        activityObservation = studio.microphoneActivity.$level.removeDuplicates().sink { [weak self] _ in
            self?.refresh(speakingOnly: true)
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
    func join(target: TrueConfTarget, name: String, container: UIViewController, quiet: Bool, title: String? = nil) throws {
        guard !hasJoinStarted else { return }
        NativeVideoDecoderPolicy.shared.beginCall()
        self.target = target; self.name = name; self.quiet = quiet
        catchUp.enter(roomKey: target.invitationURL.absoluteString)
        catchUp.observe(messages: [], canView: false, enabled: false)
        chat.clear()
        chat.isReadOnly = true; chat.unavailableReason = L("This meeting service does not provide live transcripts to anonymous guests.")
        catchUp.transcriptUnavailableReason = L("This meeting service does not provide live transcripts to anonymous guests.")
        audioProfile = studio.profile
        try audio.prepareForJoin()
        factory = try NativeRTCPeer.makeFactory()
        let rtcAudio = LKRTCAudioSession.sharedInstance()
        previousManualAudio = rtcAudio.useManualAudio; previousAudioEnabled = rtcAudio.isAudioEnabled
        rtcAudio.useManualAudio = true; rtcAudio.isAudioEnabled = false
        let view = RockCallViewController(title: title ?? L("Jam %@", target.roomID), catchUp: catchUp,
            chat: chat, invitationURL: target.invitationURL, roomIdentifier: target.roomID)
        view.supportsChat = false; view.supportsSharing = true; view.studio = studio
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
            self.refresh()
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
        monitor.start(queue: DispatchQueue(label: "dev.vsmirn0v.conferenceguest.trueconf-path"))
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
        let status: PiPMicrophoneStatus = available ? (publisher?.microphoneSending == true ? .on : .muted) : .unavailable
        studio.microphoneActivity.setStatus(status)
        view?.setFloatingMicrophoneStatus(status)
    }
    private func connect() {
        guard let target, hasJoinStarted, !leaving else { return }
        let generation = epoch
        onEvent?(.connecting)
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil; config.httpShouldSetCookies = false
        let session = URLSession(configuration: config, delegate: AdditionalRootTrust(), delegateQueue: nil)
        connectionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let bootstrap = try await TrueConfBootstrap.load(target, name: name, session: session)
                try Task.checkCancellation(); guard epoch == generation, !leaving else { session.invalidateAndCancel(); return }
                self.bootstrap = bootstrap
                self.factory = try NativeRTCPeer.makeFactory()
                let transport = TrueConfTransport(server: bootstrap.socketURL, session: session); self.transport = transport
                transport.onMessage = { [weak self] event in
                    guard let self, self.epoch == generation else { return }; try await self.receive(event)
                }
                transport.onFailure = { [weak self] error in guard let self, self.epoch == generation else { return }; self.recover(error) }
                transport.start()
                try await transport.send(["method": "ping"])
                try await transport.send(["method": "loginUser", "AppID": UUID().uuidString.replacingOccurrences(of: "-", with: ""),
                    "login": bootstrap.login, "credentials": bootstrap.credential, "credentialsType": 3, "chatV2Enabled": false,
                    "browser": "RockNRoll Native", "appLang": "en", "appVersion": "5.1.0", "appName": "RockNRoll Native"])
                guard epoch == generation else { return }
                connectionTask = nil
                connectionDeadline = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(25)) } catch { return }
                    guard let self, self.epoch == generation, !self.connected else { return }; self.recover(TrueConfError.timedOut)
                }
            } catch {
                session.invalidateAndCancel()
                guard epoch == generation, !Task.isCancelled else { return }
                connectionTask = nil; recover(error)
            }
        }
    }
    private func receive(_ event: [String: Any]) async throws {
        guard let method = event["method"] as? String, let transport else { throw TrueConfError.disconnected }
        switch method {
        case "loginResponse":
            guard event["result"] as? Int == 0 else { throw TrueConfError.rejected }
            guard let cid = event["CID"] as? String, !cid.isEmpty, let id = event["trueconfId"] as? String, !id.isEmpty,
                  let target else { throw TrueConfError.invalidResponse }
            self.cid = cid; localID = id; transport.cid = cid
            try await transport.send(["method": "join", "conferenceId": target.roomID, "Password": "", "simulcastSupported": true])
        case "conferenceStateChange":
            guard let conference = event["conference"] as? [String: Any] else { throw TrueConfError.invalidResponse }
            let message = conference["message"] as? String
            if message == "deleteConference" { throw TrueConfError.ended }
            guard message == "joinResponse", streamID.isEmpty,
                  let stream = conference["streamConferenceId"] as? String, !stream.isEmpty else { return }
            streamID = stream
            if let title = conference["topic"] as? String, !title.isEmpty {
                let title = String(title.prefix(256)); view?.setRoomTitle(title); onRoomTitle?(title)
            }
            try await transport.send(["method": "getIceConfig", "streamConferenceId": stream])
        case "getIceConfig":
            guard publisher == nil, !streamID.isEmpty, let values = event["iceServers"] as? [[String: Any]], let factory else { return }
            let peer = NativeRTCPeer(target: "COMPOSITE", factory: factory,
                ice: try TrueConfICE.decode(values, cid: cid, stream: streamID), cameraPosition: cameraPosition, topology: .composite)
            publisher = peer
            let generation = epoch
            peer.onCandidate = { [weak self] candidate in Task { @MainActor in
                guard let self, self.epoch == generation else { return }
                do { try await self.sendMedia(["type": "candidate", "candidate": candidate["candidate"] ?? "",
                    "sdpMLineIndex": candidate["sdpMlineIndex"] ?? 0, "sdpMid": candidate["sdpMid"] ?? "0"]) }
                catch { if !Task.isCancelled { self.recover(error) } }
            } }
            peer.onState = { [weak self] state in Task { @MainActor in
                guard let self, self.epoch == generation else { return }
                if state == .failed || state == .disconnected { self.recover() } else { self.markConnectedIfReady() }
            } }
            peer.onDecoderFallback = { [weak self] in Task { @MainActor in
                guard let self, self.epoch == generation else { return }; self.recover()
            } }
            peer.onTrack = { [weak self] _, track in Task { @MainActor in
                guard let self, self.epoch == generation, self.receiveTrack?.isEqual(track) != true else { return }
                self.receiveTrack = track; self.streams.removeAll(); self.refresh()
            } }
            try await transport.send(["method": "connectMedia", "streamConferenceId": streamID, "type": 1])
            try await transport.send(["method": "DeviceStatus", "value": 262148])
        case "connectMedia":
            guard event["result"] as? Bool == true else { throw TrueConfError.rejected }
            mediaAccepted = true; markConnectedIfReady()
        case "webrtc":
            guard let type = event["type"] as? String, let peer = publisher else { return }
            switch type {
            case "offer":
                let answer = try await peer.answer(event)
                try await sendMedia(["type": "answer", "sdp": answer["sdp"] ?? "", "browser": "RockNRoll Native"])
                peer.localSDPSent(); peer.enablePublishing(); serverReady = true
                try await transport.send(["method": "ManageLayout", "func": "Get"])
                scheduleMedia()
            case "answer":
                do { try await peer.accept(event); completeAnswer(); markConnectedIfReady() }
                catch { completeAnswer(error); throw error }
            case "candidate":
                var candidate = event; candidate["sdpMlineIndex"] = event["sdpMLineIndex"]
                try await peer.addCandidate(candidate)
            case "layout": regions = try TrueConfRoster.regions(event); refresh()
            default: break
            }
        case "SendPartsList": try roster.apply(event); refresh()
        case "DeviceStatus": roster.updateDevices(event); refresh()
        case "setDeviceState":
            if event["Mute"] as? Bool == true {
                if event["Type"] as? String == "microphone" { setMicrophone(false) }
                if event["Type"] as? String == "camera" { setCamera(false) }
            }
        case "stopContentSharing": await stopScreenSharing()
        default: break
        }
    }
    private func sendMedia(_ fields: [String: Any]) async throws {
        guard let transport else { throw TrueConfError.disconnected }
        try await transport.send(fields.merging(["method": "webrtc", "my_peer_id": localID, "conf_id": streamID]) { _, value in value })
    }
    private func markConnectedIfReady() {
        guard !connected, mediaAccepted, serverReady, let publisher,
            [.connected, .completed].contains(publisher.connection.iceConnectionState) else { return }
        connected = true; retries = 0; connectionDeadline?.cancel()
        view?.sharingAvailable = !held && !quiet
        systemCall.markConnected(); view?.setConnectionRecovering(false); onMediaStatus?(nil)
        catchUp.end(.connection); onEvent?(.active); refresh(); updateMicrophoneStatus()
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
                    let microphone = microphoneIntent && !held && !quiet && canUseCallAudio
                    var camera = cameraIntent && !held && !quiet && UIApplication.shared.applicationState == .active
                    if camera { await studio.releasePrivateCamera() }
                    publisher.setMicrophone(microphone, profile: audioProfile)
                    do { try await publisher.setCamera(camera) }
                    catch {
                        guard !Task.isCancelled, epoch == generation else { return }
                        camera = false
                        if error is CancellationError { mediaDirty = true }
                        else { cameraIntent = false; view?.setCamera(false); onMediaStatus?(L("The camera is unavailable. Audio can continue.")) }
                    }
                    guard epoch == generation, !leaving else { return }
                    if camera && (!cameraIntent || held || quiet || UIApplication.shared.applicationState != .active) {
                        try await publisher.setCamera(false); camera = false; mediaDirty = true
                    }
                    let offer = try await publisher.offer()
                    try await withCheckedThrowingContinuation { (completion: CheckedContinuation<Void, Error>) in
                        answerCompletion = completion
                        answerTimeout = Task { [weak self] in
                            do { try await Task.sleep(for: .seconds(10)) } catch { return }; self?.completeAnswer(TrueConfError.timedOut)
                        }
                        Task { [weak self] in
                            do { try await self?.sendMedia(["type": "offer", "sdp": offer["sdp"] ?? "", "browser": "RockNRoll Native"]); publisher.localSDPSent() }
                            catch { guard let self, self.epoch == generation else { return }; self.completeAnswer(error) }
                        }
                    }
                    guard epoch == generation, !leaving else { return }
                    let audioOn = microphone && microphoneIntent && !held && !quiet
                    let videoOn = (camera && cameraIntent && !held && !quiet) || sharingActive
                    try await transport.send(["method": "VideoSourceType", "Type": sharingActive ? 2 : 0, "Conference": streamID])
                    try await transport.send(["method": "DeviceStatus", "value": (videoOn ? 0 : 4 << 16) | (audioOn ? 0 : 4)])
                    view?.setMicrophone(audioOn); view?.setCamera(camera); updateMicrophoneStatus(); refresh(); markConnectedIfReady()
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
        var items: [CallParticipant] = []
        if let receiveTrack {
            for (id, rectangle) in regions {
                if let existing = streams[id] { existing.update(rectangle) }
                else { streams[id] = CompositeVideoSource(track: receiveTrack, rectangle: rectangle) }
            }
        }
        streams = streams.filter { regions[$0.key] != nil }
        for person in roster.participants.values.sorted(by: { $0.id < $1.id }) where person.id != localID {
            var videos: [CallVideoStream] = []
            if let stream = streams[person.id], person.cameraOn || person.screenShareOn {
                videos = [.init(id: person.id + (person.screenShareOn ? ".share" : ".camera"),
                    source: person.screenShareOn ? .screenShareVideo : .camera, track: .composite(stream))]
            }
            items.append(.init(id: person.id, name: person.name, isLocal: false, microphoneOn: person.microphoneOn,
                cameraOn: person.cameraOn, screenShareOn: person.screenShareOn, isSpeaking: false, videoTracks: videos))
        }
        let localVideo = publisher?.videoTrack.map { CallVideoStream(id: localID + ".camera", source: .camera, track: .native($0)) }
        items.insert(.init(id: localID.isEmpty ? "local" : localID, name: name, isLocal: true,
            microphoneOn: publisher?.microphoneSending == true && !held && !quiet, cameraOn: localVideo != nil,
            screenShareOn: sharingActive, isSpeaking: studio.microphoneActivity.status == .on && studio.microphoneActivity.level > 0.1,
            videoTracks: localVideo.map { [$0] } ?? []), at: 0)
        let snapshot = CallMediaSnapshot(participants: items)
        if speakingOnly { view?.refreshSpeaking(snapshot: snapshot) } else { view?.render(snapshot: snapshot) }
    }
    private func recover(_ error: Error? = nil) {
        guard hasJoinStarted, !leaving, recoveryTask == nil else { return }
        if let error = error as? TrueConfError, !error.isRetryable {
            onMediaStatus?(error.localizedDescription); Task { await finish(failed: true) }; return
        }
        if retries >= 5 { Task { await finish(failed: true) }; return }
        retries += 1; epoch = UUID(); connected = false; mediaAccepted = false; serverReady = false
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
        await stopScreenSharing()
        let oldTransport = transport, oldPublisher = publisher
        transport = nil; publisher = nil; factory = nil; bootstrap = nil
        receiveTrack = nil; regions.removeAll(); streams.removeAll(); roster = .init(); cid = ""; localID = ""; streamID = ""
        await oldPublisher?.close(); await oldTransport?.close(room: target?.roomID)
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
    var snapshotForTesting: CallMediaSnapshot? { view?.snapshotForTesting }
    func setSendingForTesting(microphone: Bool, camera: Bool) { setMicrophone(microphone); setCamera(camera) }
    func interruptForTesting() { transport?.interruptForTesting() }
    func sentScreenFramesForTesting() async -> Int {
        guard let publisher else { return 0 }
        let report: LKRTCStatisticsReport = await withCheckedContinuation { completion in publisher.connection.statistics { completion.resume(returning: $0) } }
        return report.statistics.values.filter { $0.type == "outbound-rtp" && $0.values["kind"] as? String == "video" }
            .reduce(0) { $0 + (($1.values["framesEncoded"] as? NSNumber)?.intValue ?? 0) }
    }
    func receiveEvidenceForTesting() async -> (frames: Double, duration: Double, energy: Double) {
        guard let publisher else { return (0, 0, 0) }
        let report: LKRTCStatisticsReport = await withCheckedContinuation { completion in publisher.connection.statistics { completion.resume(returning: $0) } }
        let incoming = report.statistics.values.filter { $0.type == "inbound-rtp" }
        return (incoming.reduce(0) { $0 + (($1.values["framesDecoded"] as? NSNumber)?.doubleValue ?? 0) },
            incoming.reduce(0) { $0 + (($1.values["totalSamplesDuration"] as? NSNumber)?.doubleValue ?? 0) },
            incoming.reduce(0) { $0 + (($1.values["totalAudioEnergy"] as? NSNumber)?.doubleValue ?? 0) })
    }
    #endif
}
