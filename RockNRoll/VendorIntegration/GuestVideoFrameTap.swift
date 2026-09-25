import Foundation
import ObjectiveC
import UIKit
import WebRTC

/// Compatibility boundary for the pinned provider SDK: it exposes a video view,
/// but not a frame subscription. Observe the bundled WebRTC renderer's public
/// renderFrame(_:) callback, always forwarding to its original implementation.
/// No SDK fields, Apple private APIs, or global call/audio state are changed.
final class GuestVideoFrameTap: @unchecked Sendable {
    private static let lock = NSLock()
    private static let observers = NSMapTable<UIView, GuestVideoFrameTap>(
        keyOptions: .weakMemory, valueOptions: .weakMemory)
    private weak var renderer: UIView?
    private let onFrame: (RTCVideoFrame) -> Void

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
                guard let frame else { return }
                lock.lock()
                let observer = observers.object(forKey: view)
                lock.unlock()
                observer?.onFrame(frame)
            }
            method_setImplementation(method, imp_implementationWithBlock(forwarding))
            installed = true
        }
        return installed
    }()

    private static func findRenderer(_ view: UIView) -> UIView? {
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

    init?(view: UIView, onFrame: @escaping (RTCVideoFrame) -> Void) {
        guard let renderer = Self.findRenderer(view), Self.installed else { return nil }
        self.renderer = renderer
        self.onFrame = onFrame
        Self.lock.lock()
        Self.observers.setObject(self, forKey: renderer)
        Self.lock.unlock()
    }

    func invalidate() {
        Self.lock.lock()
        if let renderer, Self.observers.object(forKey: renderer) === self {
            Self.observers.removeObject(forKey: renderer)
        }
        Self.lock.unlock()
    }

    deinit { invalidate() }
}
