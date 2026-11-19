import Combine
import Foundation
import LiveKitWebRTC

/// Session-scoped coordinator for screen capture, Presenter sessions, camera hardware leases,
/// and join-readiness camera metadata/priming. UI models keep presentation state and policy
/// decisions while delegating capture and hardware lease lifecycles here.
@MainActor
final class MeetingCaptureCoordinator {
    private(set) var presenterStorage: NativeDesktopPresenterSession?
    private var subscriptions = Set<AnyCancellable>()
    private var shareReportTask: Task<Void, Never>?
    private var capture: NativeDesktopShareCapture?
    private var sharingTask: Task<Void, Never>?
    private(set) var shareGeneration = UUID()
    private var stoppingShare: Task<Bool, Never>?
    private(set) var shareCleanupSucceeded = true
    private var shareSource: LKRTCVideoSource?
    private var cameraLease: NativeDesktopCameraLease.Token?
    private var joinCameraPrime: NativeDesktopJoinCameraPrime?
    private var joinCameraPrimeTask: Task<Void, Never>?
    let cameraMetadata: NativeDesktopCameraMetadataPreparation
    private var cameraMetadataTask: Task<NativeDesktopCameraMetadataPreparation.Outcome, Error>?
    private(set) var cameraMetadataReport: [String: Any] = [:]

    init(joinCameraPrime: NativeDesktopJoinCameraPrime? = nil,
         cameraMetadata: NativeDesktopCameraMetadataPreparation? = nil) {
        self.joinCameraPrime = joinCameraPrime
        self.cameraMetadata = cameraMetadata ?? .shared
    }

    var hasActiveCameraLease: Bool { cameraLease != nil }
    var hasActiveCapture: Bool { capture != nil }
    var isShareRetiring: Bool { stoppingShare != nil }
    var isPresenterSharing: Bool { presenterStorage?.isSharing == true }
    var isPresenterSharingWithCamera: Bool { presenterStorage?.isSharing == true && presenterStorage?.includeCamera == true }
    var presenterCameraPreparing: Bool { presenterStorage?.cameraPreparing ?? false }
    var presenterOwnershipDiagnostics: [String: Any] { presenterStorage?.ownershipDiagnostics ?? ["state": "not-created"] }
    var joinCameraPrimeCleanupSucceeded: Bool { joinCameraPrime?.cleanupSucceeded ?? true }

    func isSharingLive(snapshotSharing: Bool) -> Bool {
        snapshotSharing || presenterStorage?.isSharing == true
    }

    var shareSourceTitle: String {
        guard let presenter = presenterStorage, presenter.isSharing else { return L("Screen") }
        if presenter.source == .screen { return L("Screen or window") }
        return presenter.scene.image != nil ? L("Image or slides") : L("Presenter studio")
    }

    func privatePresenterCameraDevice() async -> AVCaptureDevice? {
        await presenterStorage?.privateCameraDevice()
    }

    func refreshBorrowedCamera() async {
        await presenterStorage?.refreshBorrowedCamera()
    }

    func presenter(engine: @escaping @MainActor () -> (any NativeDesktopMeetingEngine)?,
                   liveCamera: @escaping @MainActor () -> LKRTCVideoTrack?,
                   isConnected: @escaping @MainActor () -> Bool,
                   isTransferHeld: @escaping @MainActor () -> Bool,
                   isClosed: @escaping @MainActor () -> Bool,
                   isSnapshotSharing: @escaping @MainActor () -> Bool,
                   localShare: @escaping @MainActor () -> LKRTCVideoTrack?,
                   setLocalShare: @escaping @MainActor (LKRTCVideoTrack?) -> Void,
                   setSharingPending: @escaping @MainActor (Bool) -> Void,
                   onPresenterChange: @escaping @MainActor () -> Void,
                   onError: @escaping @MainActor (String) -> Void) -> NativeDesktopPresenterSession {
        if let presenterStorage { return presenterStorage }
        let session = NativeDesktopPresenterSession(factory: { engine()?.factory },
            liveCamera: liveCamera,
            publish: { [weak self] track, profile in
                guard let self, let activeEngine = engine(), !isClosed(), !isTransferHeld(), isConnected() else { throw CancellationError() }
                let retired = await self.retireShare(waitForStartup: true, engine: activeEngine,
                                                     isSnapshotSharing: isSnapshotSharing(),
                                                     setSharingPending: setSharingPending,
                                                     setLocalShare: setLocalShare, onError: onError)
                guard retired else { throw NativeDesktopRTCError.cleanupFailed }
                if let meetingSession = activeEngine as? MeetingSession, meetingSession.supportsScreenSharePublication {
                    let preference = self.presenterStorage?.activeEncodingPreference ?? .efficient
                    try await meetingSession.startScreenShare(.init(profile: profile, codec: preference.codec) {
                        NativeDesktopRelayCapture(track: track, source: $0)
                    })
                    self.refreshShareEncodingReport(session: meetingSession, track: track, isClosed: isClosed,
                                                    localShare: localShare, activeEngine: engine)
                } else {
                    try await activeEngine.setScreenTrack(track)
                }
                guard !isClosed(), !isTransferHeld() else { throw CancellationError() }
                setLocalShare(track)
            }, unpublish: {
                guard let activeEngine = engine() else { return }
                if let meetingSession = activeEngine as? MeetingSession, meetingSession.supportsScreenSharePublication {
                    try await meetingSession.stopScreenShare()
                } else {
                    try await activeEngine.setScreenTrack(nil)
                }
                setLocalShare(nil)
            })
        session.onDimensions = { profile in
            guard !isClosed(), let meetingSession = engine() as? MeetingSession,
                  meetingSession.supportsScreenSharePublication else { return }
            do { try meetingSession.updateScreenShareProfile(profile) }
            catch {
                let detail = error as NSError
                probeLog("screen-profile-update-error", ["domain": detail.domain, "code": detail.code])
            }
        }
        session.objectWillChange.sink {
            onPresenterChange()
        }.store(in: &subscriptions)
        updateVP9Support(presenter: session, engine: engine())
        presenterStorage = session
        return session
    }

    func updateVP9Support(engine: (any NativeDesktopMeetingEngine)?) {
        guard let presenterStorage else { return }
        updateVP9Support(presenter: presenterStorage, engine: engine)
    }

    private func updateVP9Support(presenter: NativeDesktopPresenterSession, engine: (any NativeDesktopMeetingEngine)?) {
        presenter.supportsVP9 = (engine as? MeetingSession)?.capabilities.supportsScreenShareVP9 == true
        presenter.vp9UnavailableReason = presenter.supportsVP9 ? nil : L("VP9 sharing is unavailable in this meeting.")
    }

    private func refreshShareEncodingReport(session: MeetingSession, track: LKRTCVideoTrack,
                                            isClosed: @escaping @MainActor () -> Bool,
                                            localShare: @escaping @MainActor () -> LKRTCVideoTrack?,
                                            activeEngine: @escaping @MainActor () -> (any NativeDesktopMeetingEngine)?) {
        shareReportTask?.cancel()
        shareReportTask = Task { @MainActor [weak self, weak session] in
            for _ in 0..<4 {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, let session, !isClosed(), !Task.isCancelled,
                      localShare() === track, activeEngine() === session else { return }
                if let evidence = await session.screenEncodingEvidence(),
                   !Task.isCancelled, localShare() === track, activeEngine() === session {
                    presenterStorage?.encodingReport = .measured(codec: evidence.codec, powerEfficient: evidence.powerEfficient, encoder: evidence.encoder)
                    return
                }
            }
        }
    }

    func prepareJoinCameraMetadata(eligible: @escaping @MainActor () -> Bool) async throws {
        let began = ProcessInfo.processInfo.systemUptime
        let metadata = cameraMetadata
        let task = Task { @MainActor in
            // Completed foreground metadata is cached. An eligible cold join
            // finishes discovery before audio starts, avoiding its main-thread
            // AVFoundation refresh during the first camera action.
            return try await metadata.prepare(eligible: eligible,
                deviceID: UserDefaults.standard.string(forKey: "nativeDesktop.cameraID"))
        }
        cameraMetadataTask = task
        defer { cameraMetadataTask = nil }
        let outcome = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
        cameraMetadataReport = ["state": outcome.rawValue, "startedUptime": began,
            "completedUptime": ProcessInfo.processInfo.systemUptime,
            "milliseconds": (ProcessInfo.processInfo.systemUptime - began) * 1000]
    }

    func scheduleJoinCameraPrime(isEligible: @escaping @MainActor () -> Bool,
                                 videoSource: @escaping @MainActor () -> LKRTCVideoSource?,
                                 onReport: @escaping @MainActor ([String: Any]) -> Void,
                                 onCleanupError: @escaping @MainActor (String) -> Void) {
        let prime = joinCameraPrime ?? NativeDesktopJoinCameraPrime()
        joinCameraPrime = prime
        // Camera first-frame initialization never occupies the media-control queue.
        joinCameraPrimeTask = Task { @MainActor in
            guard isEligible() else { prime.cancel(); return }
            do { try await prime.run(source: videoSource) }
            catch { if !prime.cleanupSucceeded { onCleanupError(error.localizedDescription) } }
            onReport(prime.report)
        }
    }

    func cancelJoinCameraPrime() {
        joinCameraPrime?.cancel()
        joinCameraPrimeTask?.cancel()
    }

    func waitForJoinReadinessForTesting() async {
        await joinCameraPrimeTask?.value
    }

    func applyCameraEnabled(_ enabled: Bool, sessionID: UUID,
                            isValid: @escaping @MainActor () -> Bool,
                            setCamera: @escaping @MainActor (Bool) async throws -> Void) async throws {
        // Reserve the transition before lease revocation can emit a nil
        // track; Presenter must wait until the live owner is settled.
        presenterStorage?.beginLiveCameraHandover()
        do {
            try await joinCameraPrime?.stop()
            if enabled {
                cameraLease = try await NativeDesktopCameraLease.shared.acquireLive(owner: sessionID) {
                    try await setCamera(false)
                }
                try await presenterStorage?.releasePrivateCameraBeforeLiveCapture()
            }
            if enabled, !(await NativeDesktopDeviceModel.stopPrivateCameraPreview()) {
                throw NativeDesktopRTCError.cleanupFailed
            }
            if enabled {
                try Task.checkCancellation()
                guard isValid() else { throw CancellationError() }
            }
            try await setCamera(enabled)
            if !enabled, let lease = cameraLease {
                NativeDesktopCameraLease.shared.release(lease)
                cameraLease = nil
            }
            await presenterStorage?.finishLiveCameraHandover()
        } catch {
            var stopped = true
            if let lease = cameraLease {
                do {
                    try await Task { @MainActor in try await setCamera(false) }.value
                    NativeDesktopCameraLease.shared.release(lease)
                    cameraLease = nil
                } catch {
                    stopped = false
                    NativeDesktopCameraLease.shared.reportFailedStop(lease)
                }
            }
            if stopped { await presenterStorage?.finishLiveCameraHandover() }
            throw error
        }
    }

    func releaseCameraLease() {
        if let lease = cameraLease {
            NativeDesktopCameraLease.shared.release(lease)
            cameraLease = nil
        }
    }

    @discardableResult
    func closePresenter() async -> Bool {
        await presenterStorage?.close() ?? true
    }

    var presenterIsPreparingForReactions: Bool { presenterStorage?.cameraPreparing ?? false }

    func canStartSharing() -> Bool {
        capture == nil && stoppingShare == nil && shareCleanupSucceeded
    }

    func startSharing(canvas: Bool,
                      isValidGeneration: @escaping @MainActor () -> Bool,
                      isClosed: @escaping @MainActor () -> Bool,
                      isSnapshotSharing: @escaping @MainActor () -> Bool,
                      engine: @escaping @MainActor () -> (any NativeDesktopMeetingEngine)?,
                      setSharingPending: @escaping @MainActor (Bool) -> Void,
                      setLocalShare: @escaping @MainActor (LKRTCVideoTrack?) -> Void,
                      onError: @escaping @MainActor (String) -> Void) {
        guard canStartSharing() else { return }
        setSharingPending(true)
        let shareToken = UUID()
        shareGeneration = shareToken
        sharingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if isValidGeneration() && shareToken == shareGeneration {
                    setSharingPending(false)
                    sharingTask = nil
                }
            }
            do {
                if let presenter = presenterStorage, !(await presenter.close()) {
                    throw NativeDesktopRTCError.cleanupFailed
                }
                guard let activeEngine = engine() else { throw CancellationError() }
                let profile = GuestVideoProfile(width: 3840, height: 2160, fps: 30, maximumBitrate: 18_000_000)
                if let session = activeEngine as? MeetingSession, session.supportsScreenSharePublication {
                    try await session.startScreenShare(.init(profile: profile) { [weak self] source in
                        let capture = NativeDesktopShareCapture(source: source, canvasOnly: canvas)
                        self?.configure(capture, shareToken: shareToken, isValidGeneration: isValidGeneration,
                                        isClosed: isClosed, isSnapshotSharing: isSnapshotSharing,
                                        engine: engine, setSharingPending: setSharingPending,
                                        setLocalShare: setLocalShare, onError: onError)
                        return capture
                    })
                    setLocalShare(session.localScreenTrack)
                } else {
                    guard let factory = activeEngine.factory else {
                        throw NativeDesktopError.unavailable(L("Connect before sharing."))
                    }
                    let source = factory.videoSource(forScreenCast: true)
                    shareSource = source
                    let capture = NativeDesktopShareCapture(source: source, canvasOnly: canvas)
                    configure(capture, shareToken: shareToken, isValidGeneration: isValidGeneration,
                              isClosed: isClosed, isSnapshotSharing: isSnapshotSharing,
                              engine: engine, setSharingPending: setSharingPending,
                              setLocalShare: setLocalShare, onError: onError)
                    _ = try await capture.start()
                    guard isValidGeneration(), shareToken == shareGeneration, !isClosed() else {
                        throw CancellationError()
                    }
                    let track = factory.videoTrack(with: source, trackId: UUID().uuidString)
                    try await activeEngine.setScreenTrack(track)
                    setLocalShare(track)
                }
                guard isValidGeneration(), shareToken == shareGeneration, !isClosed() else {
                    throw CancellationError()
                }
            } catch {
                let cancelled = Task.isCancelled
                if !cancelled, let activeEngine = engine() {
                    _ = await retireShare(waitForStartup: false, engine: activeEngine,
                                          isSnapshotSharing: isSnapshotSharing(),
                                          setSharingPending: setSharingPending,
                                          setLocalShare: setLocalShare, onError: onError)
                }
                if isValidGeneration(), !cancelled, !isClosed() {
                    onError(error.localizedDescription)
                }
            }
        }
    }

    private func configure(_ capture: NativeDesktopShareCapture,
                           shareToken: UUID,
                           isValidGeneration: @escaping @MainActor () -> Bool,
                           isClosed: @escaping @MainActor () -> Bool,
                           isSnapshotSharing: @escaping @MainActor () -> Bool,
                           engine: @escaping @MainActor () -> (any NativeDesktopMeetingEngine)?,
                           setSharingPending: @escaping @MainActor (Bool) -> Void,
                           setLocalShare: @escaping @MainActor (LKRTCVideoTrack?) -> Void,
                           onError: @escaping @MainActor (String) -> Void) {
        self.capture = capture
        capture.onDimensions = { [weak self] size in
            Task { @MainActor in
                guard let self, isValidGeneration(), shareToken == self.shareGeneration, !isClosed() else { return }
                if let session = engine() as? MeetingSession, session.supportsScreenSharePublication {
                    try? session.updateScreenShareProfile(.init(width: Int32(size.width), height: Int32(size.height), fps: 30, maximumBitrate: 18_000_000))
                }
            }
        }
        capture.onEnd = { [weak self] failure in
            Task { @MainActor in
                guard let self, isValidGeneration(), shareToken == self.shareGeneration else { return }
                if let activeEngine = engine() {
                    _ = await self.stopSharing(engine: activeEngine, isSnapshotSharing: isSnapshotSharing(),
                                               setSharingPending: setSharingPending, setLocalShare: setLocalShare,
                                               onError: onError)
                }
                if let failure { onError(failure.localizedDescription) }
            }
        }
    }

    @discardableResult
    func stopSharing(engine: any NativeDesktopMeetingEngine,
                     isSnapshotSharing: Bool,
                     setSharingPending: @escaping @MainActor (Bool) -> Void,
                     setLocalShare: @escaping @MainActor (LKRTCVideoTrack?) -> Void,
                     onError: @escaping @MainActor (String) -> Void) async -> Bool {
        do { try await presenterStorage?.stopSharing() }
        catch { onError(error.localizedDescription); return false }
        return await retireShare(waitForStartup: true, engine: engine, isSnapshotSharing: isSnapshotSharing,
                                 setSharingPending: setSharingPending, setLocalShare: setLocalShare,
                                 onError: onError)
    }

    func retireShare(waitForStartup: Bool,
                     engine: any NativeDesktopMeetingEngine,
                     isSnapshotSharing: Bool,
                     setSharingPending: @escaping @MainActor (Bool) -> Void,
                     setLocalShare: @escaping @MainActor (LKRTCVideoTrack?) -> Void,
                     onError: @escaping @MainActor (String) -> Void) async -> Bool {
        if let stoppingShare { return await stoppingShare.value }
        guard capture != nil || sharingTask != nil || isSnapshotSharing else { return shareCleanupSucceeded }
        shareGeneration = UUID()
        let startup = sharingTask
        sharingTask = nil
        if waitForStartup { startup?.cancel() }
        let capture = capture
        self.capture = nil
        capture?.cancel()
        setLocalShare(nil)
        shareSource = nil
        setSharingPending(false)
        let cleanup = Task { @MainActor in
            if waitForStartup { await startup?.value }
            var clean = true
            do {
                if let session = engine as? MeetingSession, session.supportsScreenSharePublication {
                    try await session.stopScreenShare()
                } else {
                    try await engine.setScreenTrack(nil)
                }
            } catch { clean = false }
            do { try await capture?.stop() } catch { clean = false }
            return clean
        }
        stoppingShare = cleanup
        let clean = await cleanup.value
        stoppingShare = nil
        shareCleanupSucceeded = clean
        if !clean { onError(L("Screen capture could not stop cleanly. Leave the meeting before sharing again.")) }
        return clean
    }

    func drainJoinPrimeForTransferHold() async throws {
        await joinCameraPrimeTask?.value
        try await joinCameraPrime?.stop()
    }

    func beginLeave(sessionID: UUID) {
        cancelJoinCameraPrime()
        cameraMetadataTask?.cancel()
        shareReportTask?.cancel()
        shareReportTask = nil
        NativeDesktopCameraLease.shared.setLiveTrack(nil, owner: sessionID)
    }

    func awaitJoinPrimeAndMetadata() async {
        _ = try? await cameraMetadataTask?.value
        await joinCameraPrimeTask?.value
        do { try await joinCameraPrime?.stop() } catch {}
    }

    func finishLeaveLease(engineStopped: Bool) {
        if let lease = cameraLease {
            if engineStopped {
                NativeDesktopCameraLease.shared.release(lease)
                cameraLease = nil
            } else {
                NativeDesktopCameraLease.shared.reportFailedStop(lease)
            }
        }
    }
}
