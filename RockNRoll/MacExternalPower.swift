import Darwin
import Foundation

/// Public IOKit power-source APIs, resolved only in Designed-for-iPad on Mac.
/// The iOS SDK omits these declarations; unavailable access remains unknown.
enum MacExternalPower {
    private typealias CopyInfo = @convention(c) () -> Unmanaged<CFTypeRef>?
    private typealias GetType = @convention(c) (CFTypeRef) -> Unmanaged<CFString>?
    private final class Functions {
        let handle: UnsafeMutableRawPointer
        let copy: CopyInfo
        let type: GetType
        init?() {
            guard ProcessInfo.processInfo.isiOSAppOnMac,
                  let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY | RTLD_LOCAL) else { return nil }
            guard let copy = dlsym(handle, "IOPSCopyPowerSourcesInfo"),
                  let type = dlsym(handle, "IOPSGetProvidingPowerSourceType") else { dlclose(handle); return nil }
            self.handle = handle; self.copy = unsafeBitCast(copy, to: CopyInfo.self); self.type = unsafeBitCast(type, to: GetType.self)
        }
        deinit { dlclose(handle) }
    }
    private static let functions = Functions()
    static var current: CameraQualityPolicy.Power {
        guard let functions, let snapshot = functions.copy()?.takeRetainedValue(),
              let type = functions.type(snapshot)?.takeUnretainedValue() as String? else { return .unknown }
        switch type {
        case "AC Power": return .connected // kIOPMACPowerKey, IOPowerSources.h
        case "Battery Power", "UPS Power": return .battery // kIOPMBatteryPowerKey / kIOPMUPSPowerKey
        default: return .unknown
        }
    }
}
