import Foundation
import UIKit

@MainActor
protocol CallEngine: AnyObject {
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
