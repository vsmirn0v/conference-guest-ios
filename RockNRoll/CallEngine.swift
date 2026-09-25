import Foundation

@MainActor
protocol CallEngine: AnyObject {
    var hasJoinStarted: Bool { get }
    func leave()
    func resumeSystemCallIfPossible()
    func prepareToFloat()
    func restoreFromFloatingVideo()
    func showMediaStatus(_ message: String?)
}
