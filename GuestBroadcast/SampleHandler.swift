import JazzSDKScreenShare
import ReplayKit

final class SampleHandler: RPBroadcastSampleHandler, @unchecked Sendable {
    private lazy var screenShare = JazzScreenShare(onError: finishBroadcastWithError(_:))

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        screenShare.broadcastStarted(withSetupInfo: setupInfo)
    }

    override func broadcastFinished() {
        screenShare.broadcastFinished()
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer,
                                      with sampleBufferType: RPSampleBufferType) {
        screenShare.processSampleBuffer(sampleBuffer, with: sampleBufferType)
    }
}
