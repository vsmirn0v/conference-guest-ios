import JazzSDKScreenShare
import ReplayKit
import ImageIO

final class SampleHandler: RPBroadcastSampleHandler, @unchecked Sendable {
    private lazy var screenShare = JazzScreenShare { [weak self] error in
        self?.stop(reason: error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                   ? L("The meeting has ended.") : error.localizedDescription)
    }
    private let preview = LocalSharePreviewSender()
    private let stopLock = NSLock()
    private var stopped = false
    private var cadence = OutgoingVideoCadence()
    private let cadenceLock = NSLock()
    #if DEBUG
    private var deliveryExperiment: OutgoingShareExperiment?
    #endif

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        #if DEBUG
        deliveryExperiment = OutgoingShareExperiment.configuredForBroadcast()
        #endif
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
        screenShare.broadcastStarted(withSetupInfo: setupInfo)
    }

    override func broadcastFinished() {
        #if DEBUG
        if let deliveryExperiment, deliveryExperiment.received > 0 { print(deliveryExperiment.summary) }
        deliveryExperiment?.reset()
        #endif
        removeObserver()
        screenShare.broadcastFinished()
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer,
                                      with sampleBufferType: RPSampleBufferType) {
        stopLock.lock()
        let shouldStop = stopped
        stopLock.unlock()
        guard !shouldStop else { return }
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
            cadenceLock.lock(); let wanted = cadence.accept(sampleBuffer, fps: fps); cadenceLock.unlock()
            guard wanted else { return }
        }
        if sampleBufferType == .video { sendPreview(sampleBuffer) }
        screenShare.processSampleBuffer(sampleBuffer, with: sampleBufferType)
    }

    private func sendPreview(_ sampleBuffer: CMSampleBuffer) {
        if let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) {
            let orientation = (CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString,
                                                attachmentModeOut: nil) as? NSNumber)?.uint32Value ?? 1
            preview.send(pixels, orientation: CGImagePropertyOrientation(rawValue: orientation) ?? .up)
        }
    }

    private func stop(reason: String) {
        stopLock.lock()
        let alreadyStopped = stopped
        stopped = true
        stopLock.unlock()
        guard !alreadyStopped else { return }
        #if DEBUG
        if let deliveryExperiment, deliveryExperiment.received > 0 { print(deliveryExperiment.summary) }
        deliveryExperiment?.reset()
        #endif
        removeObserver()
        screenShare.broadcastFinished()
        // ReplayKit exposes only error-based termination to upload extensions.
        // Supply a useful explanation instead of the SDK's empty error string.
        finishBroadcastWithError(NSError(domain: "GuestBroadcast", code: 1,
                                        userInfo: [NSLocalizedDescriptionKey: reason]))
    }

    private func removeObserver() {
        CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(), GuestBroadcastStop.notification, nil)
    }

    deinit { removeObserver() }
}
