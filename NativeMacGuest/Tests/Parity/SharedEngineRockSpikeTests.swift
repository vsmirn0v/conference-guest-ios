import AVFoundation
import CryptoKit
import LiveKit
import LiveKitWebRTC
import XCTest
@testable import RockNativeDesktop

/// R4 spike S0b (docs/r4-shared-engine-plan.md): LiveKit rooms (Rock) on the app's shared
/// WebRTC factory and audio module, through the SDK patch
/// `Dependencies/native-macos/livekit-patches/shared-factory.patch`. Needs a local
/// `livekit-server --dev --bind 127.0.0.1` and must run alone (`-only-testing:` this class),
/// because the SDK's factory is fixed for the process the first time any LiveKit API runs.
final class SharedEngineRockSpikeTests: XCTestCase {

    func testRockRoomsRunOnTheAppsSharedEngineBesideAnotherCall() async throws {
        // Installing the shared factory changes the SDK for the whole test process, so this runs
        // only when asked: `TEST_RUNNER_R4_ROCK_SPIKE=1 xcodebuild test -only-testing:…/SharedEngineRockSpikeTests`.
        guard ProcessInfo.processInfo.environment["R4_ROCK_SPIKE"] == "1" else {
            throw XCTSkip("Opt-in: set TEST_RUNNER_R4_ROCK_SPIKE=1 and run this class alone")
        }
        guard await Self.serverAnswers() else { throw XCTSkip("Start `livekit-server --dev --bind 127.0.0.1 --node-ip 127.0.0.1` first") }
        _ = LKRTCInitializeSSL()
        // Built with the SDK's processing module and video factories, so LiveKit's hooks and
        // simulcast work on the shared factory exactly as on its own.
        let factory = LKRTCPeerConnectionFactory(audioDeviceModuleType: .audioEngine, bypassVoiceProcessing: true,
            encoderFactory: try XCTUnwrap(SharedPeerConnectionFactory.videoEncoderFactory as? LKRTCVideoEncoderFactory),
            decoderFactory: try XCTUnwrap(SharedPeerConnectionFactory.videoDecoderFactory as? LKRTCVideoDecoderFactory),
            audioProcessingModule: try XCTUnwrap(SharedPeerConnectionFactory.audioProcessingModule as? LKRTCAudioProcessingModule))
        let module = factory.audioDeviceModule
        let observer = SpikeToneObserver()
        module.observer = observer
        XCTAssertEqual(module.setManualRenderingMode(true), 0)
        XCTAssertEqual(module.setMuteMode(.inputMixer), 0)
        XCTAssertEqual(module.setMicrophoneMuted(false), 0)
        var availability = LKRTCAudioEngineAvailability()
        availability.isInputAvailable = true; availability.isOutputAvailable = true
        XCTAssertEqual(module.setEngineAvailability(availability), 0)

        guard SharedPeerConnectionFactory.install(factory) else {
            throw XCTSkip("The SDK already created its own factory in this process; run this class alone")
        }
        let sdkObserver = AudioManager.shared.sdkAudioDeviceModuleObserver as? LKRTCAudioDeviceModuleDelegate
        XCTAssertNotNil(sdkObserver, "The SDK exposes its own module observer")
        XCTAssertTrue(module.observer === observer, "The SDK leaves the app's observer on the shared module")
        // The app's observer passes module events on to the SDK, which tracks engine state with them.
        observer.forward = sdkObserver

        // Rock: a talker and a listener in one jam, both on the shared factory.
        let options = RoomOptions(reportRemoteTrackStatistics: true)
        let talker = Room(roomOptions: options), listener = Room(roomOptions: options)
        try await talker.connect(url: Self.url, token: Self.token(identity: "talker"))
        try await listener.connect(url: Self.url, token: Self.token(identity: "listener"))
        // A Guest-style call on the same engine, its sender disabled (it is not the talk meeting).
        let call = try await SpikeLoopCall.connect(factory: factory, name: "guest")
        call.sender.isEnabled = false

        let enginesBefore = observer.counts
        _ = try await talker.localParticipant.setMicrophone(enabled: true)
        let remote = try await Self.remoteAudio(in: listener)
        try await Task.sleep(for: .seconds(3))
        let talking = try await Self.receiveRate(remote, seconds: 3)

        // Rock mutes (its sender off); the Guest-style call takes the input.
        let switchStarted = ProcessInfo.processInfo.systemUptime
        _ = try await talker.localParticipant.setMicrophone(enabled: false)
        call.sender.isEnabled = true
        let guestHeard = await call.waitForBytes(rate: 3000, timeout: 3)
        let switchSeconds = ProcessInfo.processInfo.systemUptime - switchStarted
        try await Task.sleep(for: .seconds(2))
        let muted = try await Self.receiveRate(remote, seconds: 3)
        let enginesAfter = observer.counts

        let report: [String: Any] = ["rockTalkingBytesPerSecond": talking, "rockMutedBytesPerSecond": muted,
            "guestHeardAfterSwitch": guestHeard, "switchSeconds": switchSeconds,
            "enginesBefore": enginesBefore.description, "enginesAfter": enginesAfter.description,
            "moduleRecording": module.isRecording, "observerKept": module.observer === observer]
        print("R4-ROCK-SPIKE " + String(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), encoding: .utf8)!)

        XCTAssertGreaterThan(talking, 2500, "Rock sends the shared module's input (the tone)")
        XCTAssertLessThan(muted, talking / 2, "Muting Rock stops its audio")
        XCTAssertTrue(guestHeard, "The other call carries the input on the same engine")
        XCTAssertEqual(enginesAfter.created, enginesBefore.created, "Rock never built its own engine")
        XCTAssertTrue(module.observer === observer)

        await call.close()
        await talker.disconnect(); await listener.disconnect()
    }

    // MARK: Helpers

    static let url = "ws://127.0.0.1:7880"

    static func serverAnswers() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:7880") else { return false }
        var request = URLRequest(url: url, timeoutInterval: 2); request.httpMethod = "GET"
        return (try? await URLSession.shared.data(for: request)) != nil
    }

    /// A LiveKit access token signed with the dev server's placeholder key ("devkey"/"secret").
    static func token(identity: String, room: String = "r4-spike") -> String {
        func encode(_ object: [String: Any]) -> String {
            let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let now = Int(Date().timeIntervalSince1970)
        let header = encode(["alg": "HS256", "typ": "JWT"])
        let payload = encode(["iss": "devkey", "sub": identity, "name": identity, "nbf": now - 10, "exp": now + 3600,
                              "video": ["room": room, "roomJoin": true, "canPublish": true, "canSubscribe": true]])
        let signature = HMAC<SHA256>.authenticationCode(for: Data("\(header).\(payload)".utf8), using: SymmetricKey(data: Data("secret".utf8)))
        let signed = Data(signature).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "\(header).\(payload).\(signed)"
    }

    static func remoteAudio(in room: Room) async throws -> RemoteAudioTrack {
        for _ in 0..<200 {
            if let track = room.remoteParticipants.values.flatMap(\.audioTracks).compactMap({ $0.track as? RemoteAudioTrack }).first {
                return track
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw NSError(domain: "R4Spike", code: 2, userInfo: [NSLocalizedDescriptionKey: "listener got no Rock audio track"])
    }

    /// Bytes a second the listener receives on the Rock track, from the SDK's statistics.
    static func receiveRate(_ track: RemoteAudioTrack, seconds: Double) async throws -> Double {
        func bytes() -> UInt64 { track.statistics?.inboundRtpStream.compactMap(\.bytesReceived).reduce(0, +) ?? 0 }
        let before = bytes(), started = ProcessInfo.processInfo.systemUptime
        try await Task.sleep(for: .seconds(seconds))
        let after = bytes()
        return Double(after &- before) / (ProcessInfo.processInfo.systemUptime - started)
    }
}
