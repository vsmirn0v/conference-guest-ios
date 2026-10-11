import AVFoundation
import Combine
import UIKit

/// Borrow the owner's capture session for native, unencoded preview. Visible
/// views request preview cadence without changing the outgoing encoder budget.
@MainActor
final class CameraCapturePreview {
    let session: AVCaptureSession
    nonisolated let frames: CameraPreviewFrames
    private var floatingDemand = false
    var device: AVCaptureDevice? { didSet { views.allObjects.forEach { $0.refreshDevice() } } }
    var onDemandChanged: (() -> Void)?
    private let views = NSHashTable<CameraCapturePreviewView>.weakObjects()
    private var energy: AnyCancellable?
    private var lastDemand = false
    private let budget: MediaEnergyBudget
    var wantsFrames: Bool { floatingDemand || views.allObjects.contains { $0.isDisplaying } }
    var frameRate: Int { wantsFrames ? budget.previewFPS : 0 }

    init(session: AVCaptureSession, device: AVCaptureDevice?, budget: MediaEnergyBudget? = nil, frames: CameraPreviewFrames = CameraPreviewFrames()) {
        self.session = session; self.device = device; self.budget = budget ?? .shared; self.frames = frames
        energy = self.budget.$pressure.dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }; self.views.allObjects.forEach { $0.refreshDemand() }; self.onDemandChanged?()
            }
        }
    }
    func setFloatingDemand(_ wanted: Bool) { floatingDemand = wanted; refreshDemand() }
    func makeView() -> CameraCapturePreviewView {
        let view = CameraCapturePreviewView(source: self, native: views.allObjects.isEmpty)
        views.add(view)
        return view
    }
    fileprivate func refreshDemand() {
        let wanted = wantsFrames
        if wanted != lastDemand { lastDemand = wanted; onDemandChanged?() }
    }
}

/// The system owns display timing, orientation and camera effects. This view
/// neither captures again nor converts camera pixels on the app's main thread.
@MainActor
final class CameraCapturePreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    private var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    private var source: CameraCapturePreview?
    private let native: Bool
    private var sampleView: GuestSampleBufferView?
    private var sink: RoomFloatingVideoSink?
    #if DEBUG
    private(set) var hasDisplayedFrameForTesting = false
    #endif
    private var rotationCoordinator: AnyObject?
    private var rotationObservation: NSKeyValueObservation?
    private var displaySize = CGSize.zero
    private var lifecycle: [NSObjectProtocol] = []
    var onDisplaySizeChanged: ((CGSize) -> Void)?
    var enabled = true { didSet { refreshDemand() } }
    var mirrored = true { didSet { sampleView?.mirrored = mirrored; setNeedsLayout() } }
    fileprivate var isDisplaying: Bool {
        guard enabled, window != nil, source != nil, UIApplication.shared.applicationState != .background else { return false }
        var ancestor: UIView? = self
        while let view = ancestor { if view.isHidden { return false }; ancestor = view.superview }
        return true
    }

    fileprivate init(source: CameraCapturePreview, native: Bool) {
        self.source = source; self.native = native
        super.init(frame: .zero)
        backgroundColor = .black
        isUserInteractionEnabled = false
        if native { preview.session = source.session }
        else {
            // UIKit-on-Mac renders only one native preview reliably. Additional
            // Studio surfaces share raw frames without a second capture output.
            let surface = GuestSampleBufferView(); surface.contentMode = .scaleAspectFit
            surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(surface); sampleView = surface
            let sink = RoomFloatingVideoSink { [weak self] sample, rotation in
                guard let self else { return }
                self.sampleView?.enqueue(sample, rotation: rotation)
                #if DEBUG
                self.hasDisplayedFrameForTesting = true
                #endif
                if let pixels = CMSampleBufferGetImageBuffer(sample) {
                    let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
                    self.updateSize(rotation == 90 || rotation == 270 ? CGSize(width: height, height: width) : CGSize(width: width, height: height))
                }
            }
            self.sink = sink; source.frames.add(sink)
        }
        preview.videoGravity = .resizeAspect
        refreshDevice()
        for event in [UIApplication.didEnterBackgroundNotification, UIApplication.didBecomeActiveNotification] {
            lifecycle.append(NotificationCenter.default.addObserver(forName: event, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshDemand() }
            })
        }
    }
    required init?(coder: NSCoder) { nil }
    override var isHidden: Bool { didSet { refreshDemand() } }
    override var contentMode: UIView.ContentMode {
        didSet { preview.videoGravity = contentMode == .scaleAspectFill ? .resizeAspectFill : .resizeAspect; sampleView?.contentMode = contentMode }
    }
    fileprivate func refreshDevice() {
        if native, let source, preview.session !== source.session { preview.session = source.session }
        rotationObservation = nil; rotationCoordinator = nil
        if #available(iOS 17.0, *), !ProcessInfo.processInfo.isiOSAppOnMac, let device = source?.device {
            let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: preview)
            rotationCoordinator = coordinator
            rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) {
                [weak self] _, _ in Task { @MainActor in self?.setNeedsLayout() }
            }
        }
        setNeedsLayout()
    }
    override func didMoveToWindow() { super.didMoveToWindow(); refreshDevice(); refreshDemand() }
    fileprivate func refreshDemand() {
        preview.connection?.isEnabled = isDisplaying
        sink?.setWanted(isDisplaying, fps: source?.frameRate == 0 ? 30 : source?.frameRate ?? 30)
        source?.refreshDemand()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        sampleView?.frame = bounds
        guard let connection = preview.connection else { refreshDemand(); return }
        if #available(iOS 17.0, *), !ProcessInfo.processInfo.isiOSAppOnMac,
           let coordinator = rotationCoordinator as? AVCaptureDevice.RotationCoordinator {
            let angle = PrivateCameraPreview.connectionAngle(horizon: coordinator.videoRotationAngleForHorizonLevelPreview)
            if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
        } else if !ProcessInfo.processInfo.isiOSAppOnMac, connection.isVideoOrientationSupported {
            switch window?.windowScene?.interfaceOrientation {
            case .landscapeLeft: connection.videoOrientation = .landscapeLeft
            case .landscapeRight: connection.videoOrientation = .landscapeRight
            case .portraitUpsideDown: connection.videoOrientation = .portraitUpsideDown
            default: connection.videoOrientation = .portrait
            }
        }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirrored
        }
        if let device = source?.device {
            let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            let sideways: Bool
            if ProcessInfo.processInfo.isiOSAppOnMac { sideways = false }
            else if #available(iOS 17.0, *) {
                sideways = Int(connection.videoRotationAngle.rounded()) % 180 != 0
            } else { sideways = connection.videoOrientation == .portrait || connection.videoOrientation == .portraitUpsideDown }
            let size = sideways ? CGSize(width: Int(dimensions.height), height: Int(dimensions.width)) :
                CGSize(width: Int(dimensions.width), height: Int(dimensions.height))
            updateSize(size)
        }
        refreshDemand()
    }
    private func updateSize(_ size: CGSize) {
        if size != displaySize { displaySize = size; onDisplaySizeChanged?(size) }
    }
    func stop() {
        let previous = source
        if let sink { sink.retire(); previous?.frames.remove(sink) }
        sink = nil; sampleView?.clear(); source = nil
        rotationObservation = nil; rotationCoordinator = nil
        preview.session = nil
        previous?.refreshDemand()
    }
    deinit {
        // UIKit removes a detached/deallocated surface from the weak view set.
        sink?.retire()
        lifecycle.forEach(NotificationCenter.default.removeObserver)
        let previous = source
        Task { @MainActor in previous?.refreshDemand() }
    }
}

/// Raw capture fan-out for PiP. It adds no output, encoder or pixel copy, and
/// sends nothing when no floating surface is observing the camera.
final class CameraPreviewFrames: @unchecked Sendable {
    private let lock = NSLock()
    private let sinks = NSHashTable<RoomFloatingVideoSink>.weakObjects()
    func add(_ sink: RoomFloatingVideoSink) { lock.lock(); sinks.add(sink); lock.unlock() }
    func remove(_ sink: RoomFloatingVideoSink) { lock.lock(); sinks.remove(sink); lock.unlock() }
    var hasSinks: Bool { lock.lock(); defer { lock.unlock() }; return !sinks.allObjects.isEmpty }
    func render(_ pixels: CVPixelBuffer, rotation: Int) {
        lock.lock(); let targets = sinks.allObjects; lock.unlock()
        targets.forEach { $0.render(pixels: pixels, rotation: rotation) }
    }
}
