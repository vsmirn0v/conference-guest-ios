import Foundation
import ObjectiveC

/// The UIKit app on macOS must not nap in the middle of a live meeting.
/// Uses public macOS Foundation APIs only, with no effect on iPhone/iPad.
@MainActor
final class MacCallActivity {
    private var token: AnyObject?
    private let begin: () -> AnyObject?
    private let end: (AnyObject) -> Void

    init(begin: @escaping () -> AnyObject? = MacCallActivity.beginNative,
         end: @escaping (AnyObject) -> Void = MacCallActivity.endNative) {
        self.begin = begin
        self.end = end
    }

    func setActive(_ active: Bool) {
        if active {
            if token == nil { token = begin() }
        } else if let token {
            self.token = nil
            end(token)
        }
    }

    private static func beginNative() -> AnyObject? {
        guard ProcessInfo.processInfo.isiOSAppOnMac else { return nil }
        let process = ProcessInfo.processInfo
        let selector = NSSelectorFromString("beginActivityWithOptions:reason:")
        guard process.responds(to: selector), let method = process.method(for: selector) else { return nil }
        // The public macOS method is unavailable in the iOS SDK. Invoke it only
        // in the Mac runtime, with its exact Objective-C uint64_t ABI.
        typealias Begin = @convention(c) (AnyObject, Selector, UInt64, NSString) -> Unmanaged<AnyObject>
        let invoke = unsafeBitCast(method, to: Begin.self)
        let options = ProcessInfo.ActivityOptions.userInitiatedAllowingIdleSystemSleep.rawValue
        let token = invoke(process, selector, options, "Active audio/video meeting").takeUnretainedValue()
        #if DEBUG
        NSLog("Mac meeting activity began")
        #endif
        return token
    }

    private static func endNative(_ token: AnyObject) {
        let process = ProcessInfo.processInfo
        let selector = NSSelectorFromString("endActivity:")
        guard ProcessInfo.processInfo.isiOSAppOnMac, process.responds(to: selector),
              let method = process.method(for: selector) else { return }
        typealias End = @convention(c) (AnyObject, Selector, AnyObject) -> Void
        unsafeBitCast(method, to: End.self)(process, selector, token)
        #if DEBUG
        NSLog("Mac meeting activity ended")
        #endif
    }
}
