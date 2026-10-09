import Foundation
import ObjectiveC
import WebRTC

/// Bind public track IDs to the original source. Sender.track/source getters
/// can create different Objective-C wrappers for the same native objects.
enum GuestCameraTrackBinding {
    private static let lock = NSLock()
    private static var trackIDsKey: UInt8 = 0
    static func prepare() { _ = installed }
    static func source(_ source: RTCVideoSource, owns trackID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return (objc_getAssociatedObject(source, &trackIDsKey) as? NSArray)?.contains(trackID) == true
    }
    private static let installed: Bool = {
        let selector = #selector(RTCPeerConnectionFactory.videoTrack(with:trackId:))
        guard let method = class_getInstanceMethod(RTCPeerConnectionFactory.self, selector) else { return false }
        typealias Create = @convention(c) (RTCPeerConnectionFactory, Selector, RTCVideoSource, NSString) -> RTCVideoTrack
        let original = unsafeBitCast(method_getImplementation(method), to: Create.self)
        let forward: @convention(block) (RTCPeerConnectionFactory, RTCVideoSource, NSString) -> RTCVideoTrack = { factory, source, trackID in
            let track = original(factory, selector, source, trackID)
            lock.lock()
            var ids = objc_getAssociatedObject(source, &trackIDsKey) as? [String] ?? []
            ids.removeAll { $0 == trackID as String }; ids.append(trackID as String)
            if ids.count > 64 { ids.removeFirst(ids.count - 64) }
            objc_setAssociatedObject(source, &trackIDsKey, ids as NSArray, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            lock.unlock()
            return track
        }
        method_setImplementation(method, imp_implementationWithBlock(forward))
        return true
    }()
}
