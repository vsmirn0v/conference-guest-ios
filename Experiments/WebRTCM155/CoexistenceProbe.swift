import Foundation
import WebRTC
import LiveKitWebRTC
import ObjectiveC
import Darwin

// The application loads both modules. Neither namespace may claim the other's
// policy exports or Objective-C classes, even though the native SDKs share types.
@main struct CoexistenceProbe {
    static func main() {
        let guest = RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(),
                                             decoderFactory: RTCDefaultVideoDecoderFactory())
        let native = LKRTCPeerConnectionFactory(encoderFactory: LKRTCDefaultVideoEncoderFactory(),
                                               decoderFactory: LKRTCDefaultVideoDecoderFactory())
        precondition(!guest.rtpSenderCapabilities(forKind: "audio").codecs.isEmpty)
        precondition(!native.rtpSenderCapabilities(forKind: "audio").codecs.isEmpty)
        let guestPath = Bundle(for: RTCPeerConnectionFactory.self).executableURL!.path
        let nativePath = Bundle(for: LKRTCPeerConnectionFactory.self).executableURL!.path
        precondition(guestPath != nativePath)
        let pairs = [("RTCPeerConnectionFactory", guestPath),
                     ("LKRTCPeerConnectionFactory", nativePath),
                     ("RTCConferenceYUVHelper", guestPath), ("LKRTCYUVHelper", nativePath)]
        for (name, expected) in pairs {
            guard let cls = NSClassFromString(name), let path = class_getImageName(cls) else {
                fatalError("Missing runtime class: \(name)")
            }
            precondition(URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath() ==
                         URL(fileURLWithPath: expected).resolvingSymlinksInPath())
        }
        let guestHandle = dlopen(guestPath, RTLD_NOW | RTLD_LOCAL)!
        let nativeHandle = dlopen(nativePath, RTLD_NOW | RTLD_LOCAL)!
        defer { dlclose(guestHandle); dlclose(nativeHandle) }
        for name in ["RTCSetConferencePlayoutReserved", "RTCConfigureScreenShareEncoderQuality",
                     "RTCGetScreenShareEncoderRates", "RTCSetScreenShareSenderResolution"] {
            precondition(dlsym(guestHandle, name) != nil)
            precondition(dlsym(nativeHandle, "LK" + name) != nil)
            precondition(dlsym(nativeHandle, name) == nil)
            precondition(dlsym(guestHandle, "LK" + name) == nil)
        }
        print("PASS: both factories, class ownership and isolated policy exports")
    }
}
