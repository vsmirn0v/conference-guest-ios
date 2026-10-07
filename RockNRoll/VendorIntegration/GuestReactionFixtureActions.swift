#if DEBUG
import AVFoundation
import UIKit

enum GuestReactionFixtureActions {
    private static let lock = NSLock()
    static func trace(_ message: String) {
        guard ProcessInfo.processInfo.environment["CONFERENCE_TEST_REACTIONS"] == "1" else { return }
        lock.lock(); defer { lock.unlock() }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-reaction-trace.log")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        guard let file = try? FileHandle(forWritingTo: url) else { return }
        defer { try? file.close() }
        try? file.seekToEnd(); try? file.write(contentsOf: Data((message + "\n").utf8))
    }
    static func make(model: MeetingReactionsModel) -> [UIAction] {
        guard #available(iOS 17.0, *) else { return [] }
        return [("Test camera reaction: Like", AVCaptureReactionType.thumbsUp),
                ("Test camera reaction: Dislike", AVCaptureReactionType.thumbsDown)].map { title, type in
            UIAction(title: title) { _ in
                guard let device = GuestCaptureDeviceObserver.currentDevice(), device.canPerformReactionEffects,
                      device.availableReactionTypes.contains(type) else {
                    print("Reaction qualification: no supported published camera"); return
                }
                print("Reaction qualification: performing \(type.rawValue) on published device")
                trace("Performing \(type.rawValue), gestures=\(AVCaptureDevice.reactionEffectGesturesEnabled) forwarding=\(model.shareCameraReactions) ready=\(model.canSend) camera=\(model.cameraStatus)")
                device.performEffect(for: type)
            }
        }
    }
}
#endif
