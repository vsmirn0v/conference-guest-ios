import CoreMedia
import CoreVideo
import Foundation
import LiveKit
import LiveKitWebRTC
import MeetingEngine
#if canImport(ScreenCaptureKit)
import ScreenCaptureKit
#endif

struct IOSNativeScreenCaptureUnavailableError: LocalizedError {
    var errorDescription: String? {
        L("Screen sharing is unavailable. Close any other sharing chooser and try again.")
    }
}

@MainActor
enum IOSNativeScreenCaptureAvailability {
    static var isAvailable: Bool {
        #if canImport(ScreenCaptureKit)
        if #available(iOS 27.0, *) {
            return SCContentSharingPicker.shared.isAvailable
        }
        #endif
        return false
    }

    static func make(
        onFrame: @escaping (CMSampleBuffer, LocalSharePreview.Source) -> Void,
        onEffect: @escaping (Bool) -> Void = { _ in },
        onSelection: @escaping (PresenterScreenSelection) -> Void = { _ in },
        onEnd: @escaping (String?) -> Void = { _ in },
        onError: @escaping (String) -> Void
    ) -> (any PresenterScreenSource)? {
        #if canImport(ScreenCaptureKit)
        if #available(iOS 27.0, *) {
            return IOSNativeScreenCapture(
                onFrame: onFrame,
                onEffect: onEffect,
                onSelection: onSelection,
                onEnd: onEnd,
                onError: onError
            )
        }
        #endif
        return nil
    }

    #if canImport(ScreenCaptureKit)
    @available(iOS 27.0, *)
    static func makePresenterSource(
        onFrame: @escaping (CMSampleBuffer) -> Void,
        onEffect: @escaping (Bool) -> Void,
        onSelection: @escaping (PresenterScreenSelection) -> Void,
        onEnd: @escaping (String?) -> Void
    ) -> any PresenterScreenSource {
        IOSNativeScreenCapture(
            onFrame: { sample, _ in onFrame(sample) },
            onEffect: onEffect,
            onSelection: onSelection,
            onEnd: onEnd,
            onError: { _ in }
        )
    }
    #endif
}

#if canImport(ScreenCaptureKit)
@available(iOS 27.0, *)
@MainActor
private final class IOSNativeScreenStreamLifecycle {
    private final class Operation: @unchecked Sendable {
        let stream: SCStream
        let output: any SCStreamOutput
        var starting = false
        var stopping = false
        var retiring = false
        var completions: [(Error?) -> Void] = []

        init(stream: SCStream, output: any SCStreamOutput) {
            self.stream = stream
            self.output = output
        }
    }

    private var operations: [ObjectIdentifier: Operation] = [:]
    private var waiters: [() -> Void] = []

    private func operation(for stream: SCStream, output: any SCStreamOutput) -> Operation {
        let key = ObjectIdentifier(stream)
        if let existing = operations[key] { return existing }
        let created = Operation(stream: stream, output: output)
        operations[key] = created
        return created
    }

    func startStream(_ stream: SCStream, output: any SCStreamOutput) async throws {
        let op = operation(for: stream, output: output)
        op.starting = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stream.startCapture { [weak self] error in
                Task { @MainActor [weak self] in
                    op.starting = false
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                    if op.retiring {
                        self?.stopOperation(op)
                    }
                }
            }
        }
    }

    func retireStream(_ stream: SCStream, output: any SCStreamOutput) async {
        let op = operation(for: stream, output: output)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            op.completions.append { _ in continuation.resume() }
            op.retiring = true
            stopOperation(op)
        }
    }

    private func stopOperation(_ op: Operation) {
        guard !op.starting, !op.stopping else { return }
        op.stopping = true
        op.stream.stopCapture { [weak self] error in
            Task { @MainActor [weak self] in
                try? op.stream.removeStreamOutput(op.output, type: .screen)
                self?.operations.removeValue(forKey: ObjectIdentifier(op.stream))
                let callbacks = op.completions
                op.completions.removeAll()
                callbacks.forEach { $0(error) }
                if let self, self.operations.isEmpty {
                    let current = self.waiters
                    self.waiters.removeAll()
                    current.forEach { $0() }
                }
            }
        }
    }

    func drain() async {
        guard !operations.isEmpty else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append { continuation.resume() }
        }
    }
}

@available(iOS 27.0, *)
@MainActor
private final class IOSNativeScreenCapture: NSObject, PresenterScreenSource, SCStreamOutput, SCStreamDelegate {
    private let lifecycle = IOSNativeScreenStreamLifecycle()
    private let picker: SCContentSharingPicker
    private var pickerObserver: PickerObserver?
    private var stream: SCStream?
    private var retirement: Task<Void, Never>?
    private var picking = false
    private var selectionPending = false
    private var pickerRegistered = false
    private var generation = 0
    private var selectionGeneration = 0
    private var captureSource: LocalSharePreview.Source = .screen
    private var cadence = OutgoingVideoCadence()
    private let onFrame: (CMSampleBuffer, LocalSharePreview.Source) -> Void
    private let onEffect: (Bool) -> Void
    private let onSelection: (PresenterScreenSelection) -> Void
    private let onEnd: (String?) -> Void
    private let onError: (String) -> Void

    init(
        onFrame: @escaping (CMSampleBuffer, LocalSharePreview.Source) -> Void,
        onEffect: @escaping (Bool) -> Void,
        onSelection: @escaping (PresenterScreenSelection) -> Void,
        onEnd: @escaping (String?) -> Void,
        onError: @escaping (String) -> Void,
        picker: SCContentSharingPicker = .shared
    ) {
        self.onFrame = onFrame
        self.onEffect = onEffect
        self.onSelection = onSelection
        self.onEnd = onEnd
        self.onError = onError
        self.picker = picker
        super.init()
    }

    func start() {
        guard !selectionPending, retirement == nil else { return }
        guard picker.isAvailable, !picker.isActive || pickerRegistered else {
            let message = L("Screen sharing is unavailable. Close any other sharing chooser and try again.")
            onError(message)
            onEnd(message)
            return
        }
        if stream == nil { generation += 1 }
        picking = true
        if let pickerObserver { picker.remove(pickerObserver) }
        let observer = PickerObserver(owner: self, generation: generation)
        pickerObserver = observer
        picker.add(observer)
        pickerRegistered = true
        picker.isActive = true
        picker.present()
    }

    func stop() async {
        if let retirement { await retirement.value; return }
        generation += 1
        selectionGeneration += 1
        let previous = stream
        stream = nil
        releasePicker()
        let ending = Task { @MainActor [self] in
            if let previous { await lifecycle.retireStream(previous, output: self) }
            await lifecycle.drain()
        }
        retirement = ending
        await ending.value
        retirement = nil
    }

    private func releasePicker() {
        picking = false
        selectionPending = false
        guard stream == nil, pickerRegistered else { return }
        pickerRegistered = false
        let observer = pickerObserver
        pickerObserver = nil
        if let observer { picker.remove(observer) }
        picker.isActive = false
    }

    private static func boundedCaptureSize(for size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return .zero }
        let longEdge = max(size.width, size.height)
        let shortEdge = min(size.width, size.height)
        let scale = min(1, min(1920 / longEdge, 1080 / shortEdge))
        let width = max(2, Int(size.width * scale) / 2 * 2)
        let height = max(2, Int(size.height * scale) / 2 * 2)
        return CGSize(width: width, height: height)
    }

    private func selected(_ filter: SCContentFilter) async {
        guard picking || stream != nil else { return }
        selectionPending = true
        let attempt = generation
        selectionGeneration += 1
        let selection = selectionGeneration

        let source: LocalSharePreview.Source
        switch filter.style {
        case .window: source = .window
        case .application: source = .application
        default: source = .screen
        }
        captureSource = source

        let config = SCStreamConfiguration()
        let content = filter.contentRect.size
        let scale = CGFloat(filter.pointPixelScale)
        let bounded = Self.boundedCaptureSize(for: CGSize(width: content.width * scale, height: content.height * scale))
        let size = bounded == .zero ? CGSize(width: 1920, height: 1080) : bounded
        config.width = Int(size.width)
        config.height = Int(size.height)
        config.capturesAudio = false

        if let previous = stream {
            stream = nil
            await lifecycle.retireStream(previous, output: self)
            guard generation == attempt, selectionGeneration == selection else { return }
            onEffect(false)
        }
        onSelection(.selected)
        guard generation == attempt, selectionGeneration == selection else { return }

        let capture = SCStream(filter: filter, configuration: config, delegate: self)
        stream = capture
        do {
            try capture.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
            try await lifecycle.startStream(capture, output: self)
            guard generation == attempt, selectionGeneration == selection else { return }
            releasePicker()
        } catch {
            guard generation == attempt, selectionGeneration == selection else { return }
            let retirementGeneration = generation + 1
            await stop()
            guard generation == retirementGeneration else { return }
            let message = L("Could not share screen: %@", error.localizedDescription)
            onError(message)
            onEnd(message)
        }
    }

    private func selectionCancelled() {
        guard picking, !selectionPending else { return }
        releasePicker()
        onSelection(.cancelled)
        if stream == nil { onEnd(nil) }
    }

    private func selectionFailed(_ error: Error) {
        guard picking, !selectionPending else { return }
        releasePicker()
        let message = L("Could not open screen sharing: %@", error.localizedDescription)
        onSelection(.cancelled)
        onError(message)
        onEnd(message)
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                            of type: SCStreamOutputType) {
        MainActor.assumeIsolated {
            guard self.stream === stream, type == .screen, sampleBuffer.isValid,
                  CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return }
            guard cadence.accept(sampleBuffer, fps: MediaEnergyBudget.shared.sharingFPS) else { return }
            onFrame(sampleBuffer, captureSource)
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.stream === stream else { return }
            let retirementGeneration = self.generation + 1
            await self.stop()
            guard self.generation == retirementGeneration else { return }
            if (error as NSError).code != SCStreamError.Code.userStopped.rawValue {
                let message = L("Screen sharing stopped: %@", error.localizedDescription)
                self.onError(message)
                self.onEnd(message)
            } else {
                self.onEnd(nil)
            }
        }
    }

    nonisolated func outputVideoEffectDidStart(for stream: SCStream) {
        Task { @MainActor [weak self] in
            guard let self, self.stream === stream else { return }
            self.onEffect(true)
        }
    }

    nonisolated func outputVideoEffectDidStop(for stream: SCStream) {
        Task { @MainActor [weak self] in
            guard let self, self.stream === stream else { return }
            self.onEffect(false)
        }
    }

    private final class PickerObserver: NSObject, SCContentSharingPickerObserver {
        private weak var owner: IOSNativeScreenCapture?
        private let generation: Int

        init(owner: IOSNativeScreenCapture, generation: Int) {
            self.owner = owner
            self.generation = generation
        }

        nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker,
                                             didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
            Task { @MainActor [weak self] in
                guard let self, let owner = self.owner, owner.generation == self.generation,
                      owner.pickerObserver === self else { return }
                await owner.selected(filter)
            }
        }

        nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
            Task { @MainActor [weak self] in
                guard let self, let owner = self.owner, owner.generation == self.generation,
                      owner.pickerObserver === self else { return }
                owner.selectionCancelled()
            }
        }

        nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
            Task { @MainActor [weak self] in
                guard let self, let owner = self.owner, owner.generation == self.generation,
                      owner.pickerObserver === self else { return }
                owner.selectionFailed(error)
            }
        }
    }
}
#endif

/// Drives `NativeScreenSender` (ScreenCaptureKit on iOS 27+ or ReplayKit `RockBroadcast`,
/// plus composed Studio Presenter frames) for any unified `MeetingSession`, using
/// `NativeDesktopRelayCapture` for providers with dedicated share publication (`.guest`)
/// or direct `setScreenTrack(_:)` for single-publisher / LiveKit providers (`.community`, `.telemost`, `.trueconf`).
@MainActor
final class IOSScreenShareCapture {
    private static let videoFactory: LKRTCPeerConnectionFactory = {
        _ = LKRTCInitializeSSL()
        return LKRTCPeerConnectionFactory(
            encoderFactory: LKRTCDefaultVideoEncoderFactory(),
            decoderFactory: LKRTCDefaultVideoDecoderFactory(),
            audioDevice: nil
        )
    }()

    private weak var session: MeetingSession?
    private let preview: LocalSharePreview
    private var sender: NativeScreenSender?
    private var publishTask: Task<Void, Never>?
    private var publishWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var generation = UUID()
    private var stopping = false

    private(set) var isSharing = false
    var isBroadcastSharing: Bool { sender?.isBroadcast == true }
    var isComposedSharing: Bool { sender?.composed == true }
    var onSharingChanged: ((Bool) -> Void)?
    var onEndMessage: ((String?) -> Void)?
    var onExternalEnd: (() -> Void)?
    var onError: ((Error) -> Void)?

    init(session: MeetingSession, preview: LocalSharePreview) {
        self.session = session
        self.preview = preview
    }

    func start(broadcast: Bool = true, profile: GuestVideoProfile = GuestVideoProfile(width: 1920, height: 1080, fps: 15, maximumBitrate: 1_500_000), codec: String = "h264") async throws {
        if !broadcast, let existing = sender, !existing.isBroadcast, !existing.composed, !isSharing {
            existing.retrySelection()
            return
        }
        await stop()
        let attempt = UUID()
        generation = attempt
        let created = makeSender(attempt: attempt, profile: profile, codec: codec)
        sender = created
        do {
            try await created.start(broadcast: broadcast)
        } catch {
            if generation == attempt {
                await stop()
            }
            throw error
        }
    }

    func startComposed(
        initialSample: CMSampleBuffer,
        profile: GuestVideoProfile = GuestVideoProfile(width: 1920, height: 1080, fps: 15, maximumBitrate: 1_500_000),
        codec: String = "h264"
    ) async throws {
        await stop()
        let attempt = UUID()
        generation = attempt
        let created = makeSender(attempt: attempt, profile: profile, codec: codec)
        sender = created
        do {
            try created.startComposed()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                publishWaiters[attempt] = continuation
                created.send(initialSample)
            }
        } catch {
            if generation == attempt {
                await stop()
            }
            throw error
        }
    }

    func sendComposed(_ sample: CMSampleBuffer) {
        guard sender?.composed == true else { return }
        sender?.send(sample)
    }

    func stop() async {
        generation = UUID()
        stopping = true
        publishTask?.cancel()
        publishTask = nil
        let waiters = publishWaiters
        publishWaiters.removeAll()
        waiters.values.forEach { $0.resume(throwing: CancellationError()) }

        let currentSender = sender
        sender = nil
        let wasSharing = isSharing
        isSharing = false
        let shouldStopBroadcast = currentSender?.isBroadcast == true || BroadcastManager.shared.isBroadcasting

        if let session {
            if session.supportsScreenSharePublication {
                try? await session.stopScreenShare()
            } else {
                try? await session.setScreenTrack(nil)
            }
        }
        if shouldStopBroadcast {
            BroadcastManager.shared.requestStop()
        }
        await currentSender?.stop()
        stopping = false
        if wasSharing {
            onSharingChanged?(false)
        }
    }

    #if DEBUG
    func startForTesting(profile: GuestVideoProfile = GuestVideoProfile(width: 1920, height: 1080, fps: 15, maximumBitrate: 1_500_000), codec: String = "h264") {
        generation = UUID()
        let attempt = generation
        let created = makeSender(attempt: attempt, profile: profile, codec: codec)
        sender = created
    }

    func sendFrameForTesting(_ pixels: CVPixelBuffer, timestamp: Int64) {
        sender?.receiveForTesting(pixels, timestamp: timestamp)
    }

    func waitForPublishForTesting() async {
        await publishTask?.value
    }

    var screenTrackForTesting: LKRTCVideoTrack? {
        sender?.track
    }
    #endif

    // MARK: - Private

    private func makeSender(attempt: UUID, profile: GuestVideoProfile, codec: String) -> NativeScreenSender {
        NativeScreenSender(
            factory: session?.factory ?? Self.videoFactory,
            preview: preview,
            onFirstFrame: { [weak self] in
                guard let self, self.generation == attempt, !self.stopping,
                      let activeSender = self.sender, let session = self.session else {
                    if let self {
                        self.publishWaiters.removeValue(forKey: attempt)?.resume(throwing: CancellationError())
                    }
                    return
                }
                self.publishTask?.cancel()
                self.publishTask = Task { @MainActor [weak self] in
                    guard let self, self.generation == attempt, !self.stopping else {
                        self?.publishWaiters.removeValue(forKey: attempt)?.resume(throwing: CancellationError())
                        return
                    }
                    do {
                        if session.supportsScreenSharePublication {
                            let track = activeSender.track
                            let initial = activeSender.latestFrame
                            let request = MeetingScreenShareRequest(profile: profile, codec: codec) { source in
                                NativeDesktopRelayCapture(track: track, source: source, initialFrame: initial)
                            }
                            try await session.startScreenShare(request)
                        } else {
                            let replayTask = Task { @MainActor [weak activeSender] in
                                while !Task.isCancelled {
                                    await Task.yield()
                                    activeSender?.replayLatestFrame()
                                    try? await Task.sleep(for: .milliseconds(50))
                                }
                            }
                            defer { replayTask.cancel() }
                            try await session.setScreenTrack(activeSender.track)
                            activeSender.replayLatestFrame()
                        }
                        guard self.generation == attempt, !self.stopping else {
                            self.publishWaiters.removeValue(forKey: attempt)?.resume(throwing: CancellationError())
                            return
                        }
                        self.isSharing = true
                        self.onSharingChanged?(true)
                        self.publishWaiters.removeValue(forKey: attempt)?.resume()
                    } catch is CancellationError {
                        self.publishWaiters.removeValue(forKey: attempt)?.resume(throwing: CancellationError())
                        return
                    } catch {
                        guard self.generation == attempt else {
                            self.publishWaiters.removeValue(forKey: attempt)?.resume(throwing: CancellationError())
                            return
                        }
                        self.publishWaiters.removeValue(forKey: attempt)?.resume(throwing: error)
                        self.onError?(error)
                        self.onExternalEnd?()
                        await self.stop()
                    }
                }
            },
            onEnd: { [weak self] message in
                guard let self, self.generation == attempt else { return }
                if let message { self.onEndMessage?(message) }
                self.onExternalEnd?()
                Task { @MainActor [weak self] in
                    await self?.stop()
                }
            }
        )
    }
}
