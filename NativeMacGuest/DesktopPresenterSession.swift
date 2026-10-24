import AppKit
import AVFoundation
import Combine
import CoreMedia
import ImageIO
import LiveKitWebRTC

enum NativeDesktopPresenterError: LocalizedError {
    case notReady, invalidImage
    var errorDescription: String? {
        switch self {
        case .notReady: L("Prepare a presentation while connected to a meeting before sharing.")
        case .invalidImage: L("Choose an image smaller than 25 MB.")
        }
    }
}
protocol NativeDesktopPresenterCapture: GuestCameraCapture {
    var onEnd: (@Sendable (Error?) -> Void)? { get set }
    var onDimensions: (@Sendable (CGSize) -> Void)? { get set }
    func setScene(_ scene: PresenterScene?)
    func setCamera(_ pixels: CVPixelBuffer?)
    func setSelectionMode(_ mode: MacScreenCaptureSelectionMode)
}
extension NativeDesktopPresenterCapture { func setSelectionMode(_ mode: MacScreenCaptureSelectionMode) {} }
extension NativeDesktopShareCapture: NativeDesktopPresenterCapture {}

/// Owns a capturer until its single, shared stop has been acknowledged.
@MainActor private final class PresenterCaptureOwner {
    let capture: any GuestCameraCapture
    private var stopping: Task<Void, Error>?
    init(_ capture: any GuestCameraCapture) { self.capture = capture }
    func stop() async throws {
        capture.cancel()
        if let stopping { try await stopping.value; return }
        let task = Task { try await capture.stop() }; stopping = task
        try await task.value
    }
}

/// A private workspace. Camera consent, capture ownership and publishing are
/// independent: scene edits and camera preparation cannot publish a track.
@MainActor final class NativeDesktopPresenterSession: ObservableObject {
    enum Source: String { case canvas, screen }
    enum Tool: String, CaseIterable { case move, draw, crop }
    @Published var scene = PresenterScene() { didSet { capture?.setScene(scene) } }
    @Published var tool: Tool = .move
    @Published private(set) var source: Source = .canvas
    @Published private(set) var previewTrack: LKRTCVideoTrack?
    @Published private(set) var includeCamera = false
    @Published private(set) var isPreparing = false
    @Published private(set) var isPublishing = false
    @Published private(set) var isSharing = false
    @Published private(set) var isClosing = false
    @Published private(set) var cameraPreparing = false
    @Published private(set) var aspectRatio: CGFloat = 16 / 9
    @Published private(set) var error: String?
    @Published private(set) var undoStack: [PresenterCanvasEdit] = []
    @Published private(set) var redoStack: [PresenterCanvasEdit] = []
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var onDimensions: ((GuestVideoProfile) -> Void)?
    var imageImportRevision: UUID { generation }
    var canStartSharing: Bool { previewTrack != nil && !isPreparing && !isPublishing && !isClosing && !cleanupFailed }
    var cameraMirrored: Bool {
        get { scene.cameraMirrored }
        set { scene.cameraMirrored = newValue; preferences.set(newValue, forKey: "presenter.mirror-camera.v1") }
    }
    private let factoryProvider: () -> LKRTCPeerConnectionFactory?
    private let liveCamera: () -> LKRTCVideoTrack?
    private let publish: (LKRTCVideoTrack, GuestVideoProfile) async throws -> Void
    private let unpublish: () async throws -> Void
    private let preparePrivateCamera: () async throws -> Void
    private let makeCapture: (LKRTCVideoSource, Bool) -> any NativeDesktopPresenterCapture
    private let makeCamera: (LKRTCVideoSource) -> any GuestCameraCapture
    private let preferences: UserDefaults
    private let cameraLease: NativeDesktopCameraLease
    private let cameraLeaseOwner = UUID()
    private var cameraLeaseToken: NativeDesktopCameraLease.Token?
    private var factory: LKRTCPeerConnectionFactory?
    private var capture: (any NativeDesktopPresenterCapture)?
    private var captureOwner: PresenterCaptureOwner?
    private var cameraOwner: PresenterCaptureOwner?
    private var cameraTrack: LKRTCVideoTrack?
    private var cameraTap: NativeDesktopCameraTap?
    private var generation = UUID(), cameraGeneration = UUID(), publicationGeneration = UUID()
    private var preparation: Task<Void, Error>?, cameraOperation: Task<Void, Error>?, publication: Task<Void, Error>?
    private var stoppingShare: Task<Void, Error>?, closing: Task<Bool, Never>?
    private var publicationMayExist = false, cleanupFailed = false, opened = false
    private var liveCameraHandover = false
    private var profile = GuestVideoProfile(width: 1920, height: 1080, fps: 30, maximumBitrate: 18_000_000)
    private var pendingEdit: PresenterCanvasEdit?

    init(factory: @escaping () -> LKRTCPeerConnectionFactory?, liveCamera: @escaping () -> LKRTCVideoTrack?,
         publish: @escaping (LKRTCVideoTrack, GuestVideoProfile) async throws -> Void,
         unpublish: @escaping () async throws -> Void,
         preparePrivateCamera: @escaping () async throws -> Void = {}, preferences: UserDefaults = .standard,
         cameraLease: NativeDesktopCameraLease? = nil,
         makeCapture: @escaping (LKRTCVideoSource, Bool) -> any NativeDesktopPresenterCapture = { NativeDesktopShareCapture(source: $0, canvasOnly: $1) },
         makeCamera: @escaping (LKRTCVideoSource) -> any GuestCameraCapture = {
             let id = UserDefaults.standard.string(forKey: "nativeDesktop.cameraID")
             return GuestCamera(source: $0, deviceID: id?.isEmpty == false ? id : nil)
         }) {
        factoryProvider = factory; self.liveCamera = liveCamera; self.publish = publish; self.unpublish = unpublish
        self.preparePrivateCamera = preparePrivateCamera; self.preferences = preferences
        self.cameraLease = cameraLease ?? .shared
        self.makeCapture = makeCapture; self.makeCamera = makeCamera
        if let data = preferences.data(forKey: "presenter.placement.v1"), let saved = try? JSONDecoder().decode(PresenterPlacement.self, from: data) {
            scene.placement = saved; scene.placement.clamp()
        }
        if let raw = preferences.string(forKey: "presenter.layout.v1"), let saved = PresenterScene.Layout(rawValue: raw) { scene.layout = saved }
        scene.cameraMirrored = preferences.object(forKey: "presenter.mirror-camera.v1") == nil ? true : preferences.bool(forKey: "presenter.mirror-camera.v1")
    }

    func open() async {
        guard !isClosing, !cleanupFailed else { return }
        opened = true
        if previewTrack == nil && !isPreparing { await chooseCanvas() }
    }
    func chooseCanvas() async { await prepare(.canvas) }
    func chooseScreen() async { await prepare(.screen) }
    func chooseWindow() async { await prepare(.screen, selectionMode: .window) }
    private func prepare(_ next: Source, selectionMode: MacScreenCaptureSelectionMode = .automatic) async {
        guard !isSharing, !isPublishing, !isClosing, !cleanupFailed else { return }
        opened = true; error = nil; isPreparing = true
        let token = UUID(); generation = token
        let previous = preparation, old = captureOwner
        previous?.cancel(); old?.capture.cancel()
        detachCameraTap(); capture = nil; captureOwner = nil; previewTrack = nil
        let task = Task { [self] in
            _ = await previous?.result
            do { try await old?.stop() } catch { captureOwner = old; failCleanup(error); throw error }
            try Task.checkCancellation()
            guard generation == token, opened else { throw CancellationError() }
            guard !cleanupFailed else { throw NativeDesktopRTCError.cleanupFailed }
            guard let factory = factory ?? factoryProvider() else { throw NativeDesktopPresenterError.notReady }
            self.factory = factory
            let videoSource = factory.videoSource(), track = factory.videoTrack(with: videoSource, trackId: "private-presenter-\(token)")
            let value = makeCapture(videoSource, next == .canvas), owner = PresenterCaptureOwner(value)
            value.setSelectionMode(selectionMode)
            capture = value; captureOwner = owner; value.setScene(scene)
            value.onDimensions = { [weak self] size in Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.aspectRatio = size.width / max(1, size.height)
                self.profile = GuestVideoProfile(width: Int32(size.width), height: Int32(size.height), fps: 30, maximumBitrate: 18_000_000)
                if self.isSharing { self.onDimensions?(self.profile) }
            } }
            value.onEnd = { [weak self] failure in Task { @MainActor in
                guard let self, self.generation == token else { return }
                await self.sourceEnded(failure)
            } }
            attachCameraTap()
            do {
                let info = try await value.start()
                try Task.checkCancellation()
                guard generation == token, opened else { throw CancellationError() }
                source = next; previewTrack = track
                aspectRatio = CGFloat(info.width) / CGFloat(max(1, info.height))
                profile = GuestVideoProfile(width: info.width, height: info.height, fps: 30, maximumBitrate: 18_000_000)
            } catch { try await owner.stop(); throw error }
        }
        preparation = task
        do { try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() }) }
        catch {
            guard generation == token else { return }
            if !(error is CancellationError) { self.error = error.localizedDescription }
            // Retain a failed owner so close() can report unconfirmed teardown.
            let failedOwner = captureOwner
            if let failedOwner { do { try await failedOwner.stop() } catch { failCleanup(error) } }
            guard generation == token else { return }
            // A failed source has no preview. Retire its private camera instead
            // of leaving an invisible input running behind disabled controls.
            includeCamera = false
            do { try await releaseCamera() } catch { failCleanup(error) }
            guard generation == token else { return }
            capture = nil; previewTrack = nil
        }
        if generation == token { isPreparing = false; preparation = nil }
    }
    private func sourceEnded(_ failure: Error?) async {
        if let failure { error = failure.localizedDescription }
        _ = await close()
    }

    func setIncludeCamera(_ enabled: Bool) async {
        guard !isClosing, !cleanupFailed else { return }
        includeCamera = enabled
        if enabled { await refreshBorrowedCamera() }
        else { do { try await releaseCamera() } catch { failCleanup(error) } }
    }
    /// Reconcile after ordinary camera changes; borrowing never changes its intent.
    func refreshBorrowedCamera() async {
        guard opened, includeCamera, !isClosing, !cleanupFailed else { return }
        let available = liveCamera()
        guard !liveCameraHandover || available != nil else { return }
        if cameraTrack === available && available != nil { return }
        if cameraOwner != nil && available == nil { return }
        do { try await releaseCamera() } catch { failCleanup(error); return }
        guard includeCamera, opened, !isClosing, !liveCameraHandover || available != nil else { return }
        if let available { cameraTrack = available; attachCameraTap(); return }
        let token = UUID(); cameraGeneration = token; cameraPreparing = true
        let task = Task { [self] in
            try await preparePrivateCamera()
            try Task.checkCancellation()
            guard cameraGeneration == token, includeCamera, opened, !liveCameraHandover else { throw CancellationError() }
            let acquisition = try await cameraLease.acquirePrivate(owner: cameraLeaseOwner, revoke: { [weak self] in try await self?.releaseCamera() })
            try Task.checkCancellation()
            guard cameraGeneration == token, includeCamera, opened, !liveCameraHandover else {
                if case .owned(let lease) = acquisition { cameraLease.release(lease) }
                throw CancellationError()
            }
            switch acquisition {
            case .borrowed(let track): cameraTrack = track; attachCameraTap(); return
            case .livePending: return
            case .owned(let lease): cameraLeaseToken = lease
            }
            guard let factory else { throw NativeDesktopPresenterError.notReady }
            let source = factory.videoSource(), value = makeCamera(source), owner = PresenterCaptureOwner(value)
            cameraOwner = owner
            do {
                _ = try await value.start()
                try Task.checkCancellation()
                guard cameraGeneration == token, includeCamera, opened,
                      cameraLeaseToken.map(cameraLease.isCurrent) == true else { throw CancellationError() }
                cameraTrack = factory.videoTrack(with: source, trackId: "private-presenter-camera-\(token)")
                attachCameraTap()
            } catch { try await owner.stop(); throw error }
        }
        cameraOperation = task
        do { try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() }) } catch {
            if cameraGeneration == token {
                includeCamera = false
                if !(error is CancellationError) { self.error = error.localizedDescription }
                do { try await releaseCamera() } catch { failCleanup(error) }
            }
        }
        if cameraGeneration == token { cameraPreparing = false; cameraOperation = nil }
    }
    func releasePrivateCameraBeforeLiveCapture() async throws { liveCameraHandover = true; try await releaseCamera() }
    /// Call after the ordinary camera start succeeds or fails, including failure
    /// before a local-track callback. The barrier spans the whole device handover.
    func finishLiveCameraHandover() async { liveCameraHandover = false; await refreshBorrowedCamera() }
    /// Private-device metadata only. A borrowed camera is resolved by the engine;
    /// the caller additionally gates room reactions on publication and preference.
    func privateCameraDevice() async -> AVCaptureDevice? {
        guard includeCamera, !isClosing, let owner = cameraOwner else { return nil }
        let token = cameraGeneration, device = await owner.capture.captureDevice()
        return cameraGeneration == token && cameraOwner === owner && includeCamera && !isClosing ? device : nil
    }
    private func releaseCamera() async throws {
        cameraGeneration = UUID(); cameraPreparing = false
        let operation = cameraOperation, owner = cameraOwner, lease = cameraLeaseToken
        cameraOperation = nil; cameraOwner = nil
        cameraLeaseToken = nil
        operation?.cancel(); owner?.capture.cancel(); detachCameraTap(); cameraTrack = nil; capture?.setCamera(nil)
        _ = await operation?.result
        do { try await owner?.stop(); if let lease { cameraLease.release(lease) } }
        catch { cameraOwner = owner; cameraLeaseToken = lease; if let lease { cameraLease.reportFailedStop(lease) }; failCleanup(error); throw error }
    }
    private func attachCameraTap() {
        detachCameraTap()
        guard includeCamera, let cameraTrack, let capture else { return }
        let tap = NativeDesktopCameraTap(); cameraTap = tap
        tap.onFrame = { [weak capture] pixels in capture?.setCamera(pixels) }
        cameraTrack.add(tap)
    }
    private func detachCameraTap() {
        if let cameraTap { cameraTap.stop(); cameraTrack?.remove(cameraTap) }
        cameraTap = nil
    }

    func startSharing() async throws {
        guard canStartSharing, !isSharing, let track = previewTrack else { throw NativeDesktopPresenterError.notReady }
        let token = UUID(); publicationGeneration = token; isPublishing = true; error = nil
        track.isEnabled = true; publicationMayExist = true
        let task = Task { try Task.checkCancellation(); try await publish(track, profile) }
        publication = task
        do {
            try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() }); try Task.checkCancellation()
            guard publicationGeneration == token, opened, !isClosing else { throw CancellationError() }
            isSharing = true; isPublishing = false; publication = nil
        } catch {
            let original = error
            do { try await stopSharing() } catch { failCleanup(error); throw error }
            if !(original is CancellationError) { self.error = original.localizedDescription }
            throw original
        }
    }
    func stopSharing() async throws {
        if let stoppingShare { try await stoppingShare.value; return }
        publicationGeneration = UUID()
        let pending = publication; pending?.cancel(); previewTrack?.isEnabled = false
        let task = Task {
            _ = await pending?.result
            if publicationMayExist { try await unpublish() }
            publicationMayExist = false; isSharing = false; isPublishing = false; publication = nil
            if !isClosing { previewTrack?.isEnabled = true }
        }
        stoppingShare = task
        do { try await task.value; stoppingShare = nil }
        catch { failCleanup(error); throw error }
    }
    @discardableResult func close() async -> Bool {
        if let closing { return await closing.value }
        opened = false; isClosing = true; generation = UUID(); cameraGeneration = UUID()
        let pending = preparation, owner = captureOwner
        pending?.cancel(); owner?.capture.cancel(); previewTrack?.isEnabled = false
        cameraOperation?.cancel(); cameraOwner?.capture.cancel(); detachCameraTap()
        let task = Task { () -> Bool in
            var clean = !cleanupFailed
            do { try await stopSharing() } catch { clean = false; self.error = error.localizedDescription }
            do { try await releaseCamera() } catch { clean = false; self.error = error.localizedDescription }
            _ = await pending?.result
            do { try await owner?.stop() } catch { clean = false; self.error = error.localizedDescription }
            // A superseded preparation may discover a failed old-source stop
            // while Close is draining it, after Close captured its local owner.
            clean = clean && !cleanupFailed
            previewTrack = nil; preparation = nil
            includeCamera = false; isPreparing = false; isClosing = false; liveCameraHandover = false
            cleanupFailed = !clean
            if clean { capture = nil; captureOwner = nil; factory = nil }
            else if captureOwner == nil { captureOwner = owner }
            return clean
        }
        closing = task; let result = await task.value
        if result { closing = nil }
        return result
    }
    private func failCleanup(_ failure: Error) { cleanupFailed = true; error = failure.localizedDescription }

    func beginEdit() { if pendingEdit == nil { pendingEdit = PresenterCanvasEdit(scene) } }
    func commitEdit() {
        guard let previous = pendingEdit else { return }; pendingEdit = nil
        scene.placement.clamp()
        guard previous != PresenterCanvasEdit(scene) else { return }
        undoStack.append(previous); if undoStack.count > 32 { undoStack.removeFirst() }; redoStack = []; savePlacement()
    }
    func edit(_ action: (inout PresenterScene) -> Void) { beginEdit(); action(&scene); commitEdit() }
    func cancelEdit() { pendingEdit?.restore(into: &scene); pendingEdit = nil; scene.draftStroke = [] }
    func undo() { cancelEdit(); guard let previous = undoStack.popLast() else { return }; redoStack.append(PresenterCanvasEdit(scene)); previous.restore(into: &scene); savePlacement() }
    func redo() { cancelEdit(); guard let next = redoStack.popLast() else { return }; undoStack.append(PresenterCanvasEdit(scene)); next.restore(into: &scene); savePlacement() }
    func clearDrawings() { edit { $0.strokes = []; $0.draftStroke = [] } }
    func appendStroke(_ points: [CGPoint]) {
        guard !points.isEmpty else { return }
        edit {
            if $0.strokes.count >= 32 { $0.strokes.removeFirst() }
            $0.strokes.append(Array(points.prefix(512)).map { Self.normalized($0) }); $0.draftStroke = []
        }
    }
    static func normalized(_ point: CGPoint) -> CGPoint { CGPoint(x: min(1, max(0, point.x.isFinite ? point.x : 0.5)), y: min(1, max(0, point.y.isFinite ? point.y : 0.5))) }
    func savePlacement() {
        if let value = try? JSONEncoder().encode(scene.placement) { preferences.set(value, forKey: "presenter.placement.v1") }
        preferences.set(scene.layout.rawValue, forKey: "presenter.layout.v1")
    }
    private struct ImageResult: @unchecked Sendable { let image: CGImage? }
    func loadImage(_ data: Data, expectedRevision: UUID? = nil, selectCanvas: Bool = false) async {
        guard opened, !isClosing, expectedRevision == nil || expectedRevision == generation else { return }
        let token = generation
        let decoded = await Task.detached(priority: .userInitiated) { () -> ImageResult in
            guard data.count <= 25_000_000, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return ImageResult(image: nil) }
            return ImageResult(image: CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 1920, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true] as CFDictionary))
        }.value
        guard generation == token, opened, !Task.isCancelled else { return }
        guard let image = decoded.image else { error = L("Choose an image smaller than 25 MB."); return }
        if selectCanvas, source == .screen, isSharing {
            error = L("Stop sharing before choosing different screen content."); return
        }
        scene.image = image; error = nil
        if selectCanvas, source == .screen { await prepare(.canvas) }
    }
    func reportError(_ failure: Error) { if !(failure is CancellationError) { error = failure.localizedDescription } }
}
