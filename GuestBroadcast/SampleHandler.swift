import JazzSDKScreenShare
import ReplayKit
import ImageIO

final class SampleHandler: RPBroadcastSampleHandler, @unchecked Sendable {
    private lazy var screenShare = JazzScreenShare { [weak self] error in
        self?.stop(reason: error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                   ? L("The meeting has ended.") : error.localizedDescription)
    }
    private let preview = LocalSharePreviewSender()
    private let lifecycle = BroadcastLifecycle()
    private var cadence = OutgoingVideoCadence()
    #if DEBUG
    private var deliveryExperiment: OutgoingShareExperiment?
    #endif

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(), { _, observer, _, _, _ in
                guard let observer else { return }
                Unmanaged<SampleHandler>.fromOpaque(observer).takeUnretainedValue()
                    .stop(reason: L("Screen sharing was stopped by Rock’n’Roll."))
            }, GuestBroadcastStop.notification.rawValue, nil, .deliverImmediately)
        guard GuestBroadcastStop.isPermitted else {
            stop(reason: L("The meeting is no longer sharing. Open Rock’n’Roll to start a new share."))
            return
        }
        lifecycle.start {
            #if DEBUG
            deliveryExperiment = OutgoingShareExperiment.configuredForBroadcast()
            #endif
            screenShare.broadcastStarted(withSetupInfo: setupInfo)
        }
    }

    override func broadcastFinished() {
        finish(reason: nil, wait: true)
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer,
                                      with sampleBufferType: RPSampleBufferType) {
        lifecycle.send {
            #if DEBUG
            if sampleBufferType == .video, let deliveryExperiment {
                deliveryExperiment.deliver(sampleBuffer,
                    send: { screenShare.processSampleBuffer(sampleBuffer, with: sampleBufferType) },
                    preview: { sendPreview(sampleBuffer) })
                return
            }
            #endif
            if sampleBufferType == .video {
                let process = ProcessInfo.processInfo
                let fps = process.thermalState == .critical ? 5 : (process.isLowPowerModeEnabled || process.thermalState == .serious ? 10 : 15)
                guard cadence.accept(sampleBuffer, fps: fps) else { return }
            }
            if sampleBufferType == .video { sendPreview(sampleBuffer) }
            screenShare.processSampleBuffer(sampleBuffer, with: sampleBufferType)
        }
    }

    private func sendPreview(_ sampleBuffer: CMSampleBuffer) {
        if let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) {
            let orientation = (CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString,
                                                attachmentModeOut: nil) as? NSNumber)?.uint32Value ?? 1
            preview.send(pixels, orientation: CGImagePropertyOrientation(rawValue: orientation) ?? .up)
        }
    }

    private func stop(reason: String) {
        finish(reason: reason)
    }

    private func finish(reason: String?, wait: Bool = false) {
        lifecycle.finish(wait: wait) { [self] started in
            #if DEBUG
            if let deliveryExperiment, deliveryExperiment.received > 0 { print(deliveryExperiment.summary) }
            deliveryExperiment?.reset()
            #endif
            removeObserver()
            if started { screenShare.broadcastFinished() }
            // ReplayKit exposes only error-based termination to upload extensions.
            // Supply a useful explanation instead of the SDK's empty error string.
            if let reason {
                finishBroadcastWithError(NSError(domain: "GuestBroadcast", code: 1,
                                                userInfo: [NSLocalizedDescriptionKey: reason]))
            }
        }
    }

    private func removeObserver() {
        CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(), GuestBroadcastStop.notification, nil)
    }

    deinit { removeObserver() }
}
