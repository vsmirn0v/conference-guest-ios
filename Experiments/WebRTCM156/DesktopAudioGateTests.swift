import Darwin
import Foundation
import LiveKitWebRTC

/// Exact-binary export and callback-boundary probe. Two custom synthetic ADMs
/// are used; no physical audio device, meeting, or network connection is opened.
@main struct DesktopAudioGateTests {
    static func main() {
        let symbols = ["LKRTCSetApplicationCaptureMuted", "LKRTCApplicationCaptureMuted",
                       "LKRTCSetApplicationInputMuteIntent", "LKRTCApplicationInputMuteReconfiguring",
                       "LKRTCApplicationCaptureState", "LKRTCUnmuteApplicationCaptureIfState"]
        for name in symbols {
            precondition(dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) != nil, "Missing exact native export: \(name)")
        }
        LKRTCSetApplicationCaptureMuted(1)
        let pendingOpen = LKRTCApplicationCaptureState()
        LKRTCSetApplicationCaptureMuted(1)
        precondition(!LKRTCUnmuteApplicationCaptureIfState(pendingOpen) && LKRTCApplicationCaptureMuted() == 1)
        precondition(LKRTCUnmuteApplicationCaptureIfState(LKRTCApplicationCaptureState()))
        LKRTCSetApplicationCaptureMuted(1)
        let first = GuestSyntheticAudio(), second = GuestSyntheticAudio()
        var factoryA: LKRTCPeerConnectionFactory? = makeFactory(first)
        var factoryB: LKRTCPeerConnectionFactory? = makeFactory(second)
        precondition(factoryA != nil && factoryB != nil && LKRTCApplicationCaptureMuted() == 1,
                     "Factory replacement bypassed process capture mute")
        // Deliberately block the main queue while an OS-style off-main callback
        // executes. Native setter/getter must require no main or ADM-worker hop.
        let finished = DispatchSemaphore(value: 0)
        let measured = Measurement()
        DispatchQueue.global(qos: .userInitiated).async {
            let began = ProcessInfo.processInfo.systemUptime
            for _ in 0..<1_000 {
                LKRTCSetApplicationCaptureMuted(0)
                precondition(LKRTCApplicationCaptureMuted() == 0)
                LKRTCSetApplicationCaptureMuted(1)
                precondition(LKRTCApplicationCaptureMuted() == 1)
            }
            measured.seconds = ProcessInfo.processInfo.systemUptime - began
            finished.signal()
        }
        precondition(finished.wait(timeout: .now() + 2) == .success, "Capture callback waited for blocked main queue")
        LKRTCSetApplicationInputMuteIntent(1)
        precondition(LKRTCApplicationInputMuteReconfiguring() == 0)
        LKRTCSetApplicationInputMuteIntent(-1)
        factoryA = nil; factoryB = nil
        precondition(first.terminateDevice() && second.terminateDevice())
        LKRTCSetApplicationCaptureMuted(0)
        print("PASS: six native exports, conditional opening, process gate across two factories, 2000 callback toggles with main blocked (\(Int(measured.seconds * 1_000_000)) us total); no physical media")
    }
    static func makeFactory(_ audio: GuestSyntheticAudio) -> LKRTCPeerConnectionFactory {
        LKRTCPeerConnectionFactory(encoderFactory: LKRTCDefaultVideoEncoderFactory(),
            decoderFactory: LKRTCDefaultVideoDecoderFactory(), audioDevice: audio)
    }
    /// Written before the semaphore signal, read only after its successful wait.
    final class Measurement: @unchecked Sendable { var seconds: TimeInterval = 0 }
}
