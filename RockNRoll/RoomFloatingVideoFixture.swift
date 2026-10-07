#if DEBUG
import LiveKit
import UIKit

/// Generated motion checks the actual room-track PiP path without a live service.
@MainActor
final class RoomFloatingVideoFixture: UIViewController {
    private var track: LocalVideoTrack?
    private var floating: RockVideoPictureInPicture?
    private var timer: Timer?
    private var frame = 0
    private var foregroundObservation: NSObjectProtocol?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        foregroundObservation = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.floating?.foregrounded() }
            }
        let start = UIButton(type: .system)
        start.setTitle("Start room PiP", for: .normal)
        start.accessibilityIdentifier = "energy.start-pip"
        start.frame = CGRect(x: 40, y: 100, width: 240, height: 80)
        view.addSubview(start)
        let end = UIButton(type: .system)
        end.setTitle("End room video", for: .normal)
        end.accessibilityIdentifier = "energy.end-pip"
        end.frame = CGRect(x: 40, y: 210, width: 240, height: 80)
        view.addSubview(end)
        floating = RockVideoPictureInPicture(sourceView: view)
        start.addAction(UIAction { [weak self] _ in self?.floating?.start() }, for: .touchUpInside)
        end.addAction(UIAction { [weak self] _ in self?.end() }, for: .touchUpInside)
        backgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in self?.end() }
        Task {
            let track = await LocalVideoTrack.createBufferTrack()
            self.track = track
            try? await track.start()
            floating?.show(track: track, name: "Generated room video", isScreenShare: true)
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.drawFrame() }
            }
        }
    }
    private func drawFrame() {
        guard let capturer = track?.capturer as? BufferCapturer else { return }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess,
            let buffer else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        if let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 320, height: 180,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
            context.setFillColor(UIColor(red: 0.08, green: 0.2, blue: 0.35, alpha: 1).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
            context.setFillColor(UIColor.orange.cgColor)
            context.fill(CGRect(x: frame % 280, y: 30, width: 40, height: 120))
        }
        frame += 8; capturer.capture(buffer)
    }
    private func end() {
        floating?.end(); timer?.invalidate(); timer = nil
        if let track { floating?.show(track: track); Task { try? await track.stop() } }
        track = nil
        if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid }
    }
    deinit { if let foregroundObservation { NotificationCenter.default.removeObserver(foregroundObservation) } }
}
#endif
