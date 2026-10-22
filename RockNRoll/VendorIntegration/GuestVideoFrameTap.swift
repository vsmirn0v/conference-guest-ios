import Foundation
import ObjectiveC
import UIKit
import WebRTC

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
    private let onFrame: (RTCVideoFrame) -> Void
    private let snapshot: Snapshot?
    private var active = true
    private let deliveryLock = NSRecursiveLock()
    private var deliveredRevision: UInt64 = 0
#if DEBUG
    private var receivedFrames = 0
    var receivedFramesForTesting: Int { Self.lock.lock(); defer { Self.lock.unlock() }; return receivedFrames }
#endif

    static func prepare() { _ = installed }

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
        Self.lock.lock()
        active = false
        if let renderer, let subscriptions = Self.observers.object(forKey: renderer) {
            subscriptions.remove(self)
            if subscriptions.allObjects.isEmpty { Self.observers.removeObject(forKey: renderer) }
        }
        Self.lock.unlock()
    }

    deinit { invalidate() }
}
