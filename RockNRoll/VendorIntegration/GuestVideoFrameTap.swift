import Foundation
import ObjectiveC
import UIKit
import WebRTC

/// One qualified camera receiver. The token changes whenever policy ownership
/// is revoked or replaced, even when WebRTC reuses the same track object.
struct GuestPresenterCameraReceiverSource {
    let leaseToken: UUID
    let participant: String
    let track: RTCVideoTrack
    func matches(_ other: Self) -> Bool {
        leaseToken == other.leaseToken && participant == other.participant && track === other.track
    }
}

/// Resolve only the exact policy camera SID in peers created for this media
/// attempt. Re-evaluation is driven by leases and qualified subscriber answers.
@MainActor
final class GuestPresenterCameraReceiver {
    struct Candidate {
        let scope: GuestPeerRegistry.Scope?
        let closed: Bool
        let stopped: Bool
        let direction: RTCRtpTransceiverDirection?
        let track: RTCVideoTrack
    }
    private var scope: GuestPeerRegistry.Scope?
    private var lease: GuestPresenterCameraLease?
    private(set) var source: GuestPresenterCameraReceiverSource?
    var onChange: ((GuestPresenterCameraReceiverSource?) -> Void)?
    func begin(_ scope: GuestPeerRegistry.Scope) {
        clear(); lease = nil; self.scope = scope
    }
    func end() { clear(); lease = nil; scope = nil }
    func setLease(_ lease: GuestPresenterCameraLease?, candidates: [Candidate]? = nil) {
        guard let scope, lease == nil || lease?.generation == scope.generation else { return }
        guard self.lease != lease else { return }
        self.lease = lease
        resolveCurrent(candidates: candidates)
    }
    func refresh(lease: GuestPresenterCameraLease, candidates: [Candidate]? = nil) {
        guard self.lease == lease else { return }
        resolveCurrent(candidates: candidates)
    }
    private func resolveCurrent(candidates: [Candidate]?) {
        guard let scope, let lease,
              let track = Self.resolve(cameraSID: lease.cameraSID, scope: scope,
                  candidates: candidates ?? GuestPeerRegistry.receiverCandidates()) else { clear(); return }
        let next = GuestPresenterCameraReceiverSource(leaseToken: lease.token, participant: lease.participantID, track: track)
        if let source, source.matches(next) { return }
        // Withdraw first so every old display delivery is retired before the
        // replacement track can attach, including reuse of the same RTC track.
        clear(); source = next; onChange?(next)
    }
    static func resolve(cameraSID: String, scope: GuestPeerRegistry.Scope, candidates: [Candidate]) -> RTCVideoTrack? {
        let matches = candidates.filter {
            $0.scope == scope && !$0.closed && !$0.stopped &&
                ($0.direction == .recvOnly || $0.direction == .sendRecv) && $0.track.readyState == .live &&
                $0.track.kind == "video" && $0.track.trackId == cameraSID
        }
        return matches.count == 1 ? matches.first?.track : nil
    }
    private func clear() {
        guard source != nil else { return }
        source = nil; onChange?(nil)
    }
}

/// Compatibility boundary for the pinned provider SDK: it exposes a video view,
/// but not a frame subscription. Observe the bundled WebRTC renderer's public
/// renderFrame(_:) callback, always forwarding to its original implementation.
/// No SDK fields, Apple private APIs, or global call/audio state are changed.
final class GuestVideoFrameTap: @unchecked Sendable {
    /// Owned by one active remote share, across SDK tile/view replacements.
    /// Retains one decoded buffer in memory; retirement rejects late callbacks.
    final class Snapshot {
        fileprivate var frame: RTCVideoFrame?
        fileprivate var revision: UInt64 = 0
        fileprivate var active = true
        func retire() {
            GuestVideoFrameTap.lock.lock(); defer { GuestVideoFrameTap.lock.unlock() }
            active = false; frame = nil
        }
    }
    private static let lock = NSLock()
    private static var revision: UInt64 = 0
    private static let observers = NSMapTable<UIView, NSHashTable<GuestVideoFrameTap>>(
        keyOptions: .weakMemory, valueOptions: .strongMemory)
    private weak var renderer: UIView?
    private var track: RTCVideoTrack?
    private var directRenderer: DirectRenderer?
    private var leaseToken: UUID?
    private let onFrame: (RTCVideoFrame) -> Void
    private let snapshot: Snapshot?
    private var active = true
    private let deliveryLock = NSRecursiveLock()
    private var deliveredRevision: UInt64 = 0
#if DEBUG
    private var receivedFrames = 0
    var receivedFramesForTesting: Int { Self.lock.lock(); defer { Self.lock.unlock() }; return receivedFrames }
    func receiveDirectFrameForTesting(_ frame: RTCVideoFrame) { receiveDirect(frame) }
#endif

    static func prepare() { _ = installed }

    /// Public WebRTC renderer attachment, with no extra rendering view or
    /// mutation of the SDK's track, subscription, audio, or layout state.
    private final class DirectRenderer: NSObject, RTCVideoRenderer {
        weak var owner: GuestVideoFrameTap?
        func setSize(_ size: CGSize) {}
        func renderFrame(_ frame: RTCVideoFrame?) {
            guard let frame else { return }
            owner?.receiveDirect(frame)
        }
    }

    private static let installed: Bool = {
        let selector = #selector(RTCEAGLVideoView.renderFrame(_:))
        var installed = false
        for type in [RTCEAGLVideoView.self, RTCMTLVideoView.self] as [AnyClass] {
            guard let method = class_getInstanceMethod(type, selector) else { continue }
            typealias Render = @convention(c) (AnyObject, Selector, RTCVideoFrame?) -> Void
            let original = unsafeBitCast(method_getImplementation(method), to: Render.self)
            let forwarding: @convention(block) (UIView, RTCVideoFrame?) -> Void = { view, frame in
                original(view, selector, frame)
                // A nil render clears a particular SDK surface, not the share.
                // Roster/session ownership retires snapshots when media ends.
                guard let frame else { return }
                lock.lock()
                let observers = observers.object(forKey: view)?.allObjects ?? []
                revision &+= 1
                let frameRevision = revision
                for observer in observers where observer.active && observer.snapshot?.active == true {
                    observer.snapshot?.frame = frame
                    observer.snapshot?.revision = frameRevision
                }
                lock.unlock()
                observers.forEach { observer in
#if DEBUG
                    lock.lock(); observer.receivedFrames += 1; lock.unlock()
#endif
                    observer.deliver(frame, revision: frameRevision)
                }
            }
            method_setImplementation(method, imp_implementationWithBlock(forwarding))
            installed = true
        }
        return installed
    }()

    static func findRenderer(_ view: UIView) -> UIView? {
        if view is RTCEAGLVideoView || view is RTCMTLVideoView { return view }
        for child in view.subviews {
            if let renderer = findRenderer(child) { return renderer }
        }
        return nil
    }

    func matches(_ view: UIView) -> Bool {
        guard let renderer else { return false }
        return Self.findRenderer(view) === renderer
    }

    func matches(_ source: GuestPresenterCameraReceiverSource) -> Bool {
        leaseToken == source.leaseToken && track === source.track
    }

    init(source: GuestPresenterCameraReceiverSource, onFrame: @escaping (RTCVideoFrame) -> Void) {
        self.onFrame = onFrame; snapshot = nil
        track = source.track; leaseToken = source.leaseToken
        let renderer = DirectRenderer(); renderer.owner = self
        directRenderer = renderer
        source.track.add(renderer)
    }

    private func receiveDirect(_ frame: RTCVideoFrame) {
        Self.lock.lock()
        Self.revision &+= 1
        let revision = Self.revision
        #if DEBUG
        receivedFrames += 1
        #endif
        Self.lock.unlock()
        deliver(frame, revision: revision)
    }

    init?(view: UIView, snapshot: Snapshot? = nil, onFrame: @escaping (RTCVideoFrame) -> Void) {
        guard let renderer = Self.findRenderer(view), Self.installed else { return nil }
        self.renderer = renderer
        self.onFrame = onFrame
        self.snapshot = snapshot
        Self.lock.lock()
        let subscriptions = Self.observers.object(forKey: renderer) ?? NSHashTable(options: .weakMemory)
        subscriptions.add(self)
        Self.observers.setObject(subscriptions, forKey: renderer)
        Self.lock.unlock()
    }

    /// Called only after the new display sink is enabled. Normal decoding can
    /// overtake a replay; the revision gate prevents painting an older frame.
    func replayLatestFrame() {
        Self.lock.lock()
        let subscriptions = renderer.flatMap { Self.observers.object(forKey: $0)?.allObjects } ?? []
        let cached = subscriptions.compactMap { $0.snapshot }.first { $0.active && $0.frame != nil }
        let frame = cached?.frame, revision = cached?.revision ?? 0
        Self.lock.unlock()
        if let frame { deliver(frame, revision: revision) }
    }

    private func deliver(_ frame: RTCVideoFrame, revision: UInt64) {
        deliveryLock.lock(); defer { deliveryLock.unlock() }
        Self.lock.lock(); let active = self.active; Self.lock.unlock()
        guard active, revision >= deliveredRevision else { return }
        deliveredRevision = revision
        onFrame(frame)
    }

    func invalidate() {
        deliveryLock.lock()
        Self.lock.lock()
        active = false
        if let renderer, let subscriptions = Self.observers.object(forKey: renderer) {
            subscriptions.remove(self)
            if subscriptions.allObjects.isEmpty { Self.observers.removeObject(forKey: renderer) }
        }
        Self.lock.unlock()
        deliveryLock.unlock()
        if let track, let directRenderer { track.remove(directRenderer) }
        track = nil; directRenderer = nil; leaseToken = nil
    }

    deinit { invalidate() }
}
