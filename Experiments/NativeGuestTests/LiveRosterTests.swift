import Foundation
import LiveKitWebRTC
import Darwin

/// Disposable synthetic clients only. No physical audio/video or host app is opened.
@main @MainActor struct LiveRosterTests {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 2 else { throw GuestCompanionPeerError.invalidControl }
        Darwin.signal(SIGALRM, SIG_DFL); Darwin.alarm(150)
        let invitation = try GuestInvitation.parse(String(contentsOfFile: args[1], encoding: .utf8))
        _ = LKRTCInitializeSSL()
        let observer = GuestSession(makeEngine: { NativeGuestEngine(label: "Roster observer") })
        let visitor = GuestSession(makeEngine: { NativeGuestEngine(label: "Roster visitor") })
        do {
            try await observer.connect(invitation, publish: true, codec: "h264", camera: false)
            guard observer.engine?.admittedParticipants == 1 else { throw GuestEngineError.mediaMissing }
            try await visitor.connect(invitation, publish: true, codec: "h264", camera: false)
            func ready() async throws {
                let deadline = ProcessInfo.processInfo.systemUptime + 15
                while observer.engine?.connectedRemoteParticipants.count != 1 || visitor.engine?.connectedRemoteParticipants.count != 1 {
                    guard ProcessInfo.processInfo.systemUptime < deadline else { throw GuestEngineError.mediaMissing }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            try await ready()
            for _ in 1...3 {
                try await visitor.mute(true); try await visitor.mute(false)
                try await visitor.mute(true, video: true); try await visitor.mute(false, video: true)
            }
            try await observer.reconnectForTesting(); try await ready()
            try await visitor.mute(true); try await visitor.mute(true, video: true)
            try await visitor.reconnectForTesting(); try await ready()
            try await visitor.mute(false); try await visitor.mute(false, video: true)
            try await Task.sleep(nanoseconds: 3_000_000_000)
            guard await visitor.leave() else { throw GuestEngineError.disconnected }
            try await Task.sleep(nanoseconds: 5_000_000_000)
            let count = observer.engine?.connectedRemoteParticipants.count ?? -1
            probeLog("roster-after-reconnect-leave", ["remoteParticipants": count])
            guard await observer.leave(), count == 0 else { throw GuestEngineError.mediaMissing }
            Darwin.alarm(0)
            print("PASS: synthetic remote reconnect/leave roster lifecycle")
        } catch { _ = await visitor.leave(); _ = await observer.leave(); throw error }
    }
}
