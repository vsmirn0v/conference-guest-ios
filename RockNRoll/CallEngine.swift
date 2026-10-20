import Combine
import Foundation
import UIKit

@MainActor
protocol CallEngine: AnyObject {
    var callWorkspacePublisher: AnyPublisher<CallWorkspaceControls?, Never> { get }
    var activityMicrophonePublisher: AnyPublisher<PiPMicrophoneStatus, Never> { get }
    var hasJoinStarted: Bool { get }
    func leave()
    func resumeSystemCallIfPossible()
    func prepareToFloat()
    func restoreFromFloatingVideo()
    func showMediaStatus(_ message: String?)
    var isSharingScreen: Bool { get }
    var continuationHostView: UIView? { get }
    func setTransferHeld(_ held: Bool, restoreSending: Bool) async throws
}

extension CallEngine {
    // A future engine without confirmed capture evidence must show unknown.
    var activityMicrophonePublisher: AnyPublisher<PiPMicrophoneStatus, Never> {
        Just(.unavailable).eraseToAnyPublisher()
    }
}
