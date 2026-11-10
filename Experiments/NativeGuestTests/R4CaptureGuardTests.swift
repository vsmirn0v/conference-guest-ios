// The capture predicate is extracted from production; stubs supply inputs only.
import Foundation
private struct ModelSnapshot { let microphoneOn: Bool }
private struct NativeDesktopMeetingModel { let snapshot: ModelSnapshot; let microphoneStarting: Bool }
private struct NativeGuestEngine {
    let audioSenderTrackEnabledForTesting: [Bool]
}
private struct GuestSystemAudio { let snapshot: [String: Any] }
private var captureMuted: Int32 = 1
private func LKRTCApplicationCaptureMuted() -> Int32 { captureMuted }

// @production captureGuard

@main private struct Tests {
    static func main() {
        for bits in 0..<256 {
            func bit(_ n: Int) -> Bool { bits & (1 << n) != 0 }
            let model = NativeDesktopMeetingModel(snapshot: .init(microphoneOn: bit(0)), microphoneStarting: bit(1))
            captureMuted = bit(2) ? 1 : 0
            let owner = GuestSystemAudio(snapshot: ["microphoneMuted": bit(3), "inputAvailable": bit(4)])
            let native = NativeGuestEngine(audioSenderTrackEnabledForTesting: bit(5) ? [bit(6)] : [])
            let publicationClosed = !bit(0) && !bit(1) && bit(2) && bit(3) && bit(5) && !bit(6)
            precondition(privateSoundCaptureClosed(model, native: native, owner: owner) == (publicationClosed && !bit(4)))
            let duringPrivate = privateSoundCaptureClosed(model, native: native, owner: owner, allowPrivateInput: bit(7))
            precondition(duringPrivate == (publicationClosed && (!bit(4) || bit(7))))
        }
        print("PASS 256 contexts, 512 actual-guard assertions: default input-off and scoped physical input preserve all publication gates")
    }
}
