import AVFoundation
import ConferenceCore
import LiveKit
import LiveKitWebRTC
import XCTest
@testable import RockNativeDesktop

/// R4 S4: the app's Rock engine on the shared owner (a real `GuestSystemAudio`, manual
/// rendering so no device is needed) beside another meeting's attachment, against a local
/// `livekit-server --dev --bind 127.0.0.1 --node-ip 127.0.0.1`. Opt in with
/// `R4_ROCK_ENGINE=1` and run alone: installing the factory into LiveKit pins it for the
/// test process. A tone is played through LiveKit's app-audio mixer (no microphone).
@MainActor final class SharedEngineRockEngineTests: XCTestCase {

    func testRockRunsOnTheSharedOwnerAndSendsOnlyWithTheTalkRole() async throws {
        guard ProcessInfo.processInfo.environment["R4_ROCK_ENGINE"] == "1" else {
            throw XCTSkip("Opt-in: R4_ROCK_ENGINE=1 with a local livekit-server --dev")
        }
        guard await SharedEngineRockSpikeTests.serverAnswers() else { throw XCTSkip("No local LiveKit server on 127.0.0.1:7880") }
        GuestSystemAudio.microphoneAuthorizationOverrideForTesting = true
        defer { GuestSystemAudio.microphoneAuthorizationOverrideForTesting = nil }

        let engine = SharedAudioEngine.live(manualRenderingForTesting: true)
        let firstGuest = try await engine.attach(meetingID: UUID())
        ok(await firstGuest.assumeTalk())
        let firstOwner = try XCTUnwrap(engine.guestOwner)
        let legacyFixture = SpikeToneObserver()
        firstOwner.setManualLegacyInputFixtureForTesting(legacyFixture)
        defer { firstOwner.setManualLegacyInputFixtureForTesting(nil) }
        ok(await firstOwner.prepareIdleInput(), "Start the original Guest owner's manual audio engine")
        XCTAssertTrue(firstOwner.hasCreatedAudioEngines)
        XCTAssertGreaterThan(firstOwner.snapshot["engineStarts"] as? Int ?? 0, 0)
        let roomName = "r4-rock-engine-\(UUID().uuidString.prefix(6))"
        let rock = NativeDesktopRockEngine(sharedAudio: engine)
        rock.admissionForTesting = {
            ("ws://127.0.0.1:7880", SharedEngineRockSpikeTests.token(identity: "rock-talker", room: roomName), "R4")
        }
        let invitation = try XCTUnwrap(URL(string: "https://rock.example.test/jams/r4"))
        try await rock.connect(invitation: invitation, name: "Talker", quiet: true)
        let attachment = try XCTUnwrap(rock.sharedAttachmentForTesting, "Rock attached to the shared engine")
        XCTAssertTrue(engine.pinnedForProcess)
        XCTAssertEqual(engine.meetingIDs, [firstGuest.meetingID, attachment.meetingID])
        XCTAssertEqual(engine.talkMeetingID, firstGuest.meetingID)
        XCTAssertTrue(firstOwner.waitingForForwardedInputRoute)
        XCTAssertFalse(firstOwner.hasForwardedInputRoute)
        XCTAssertFalse(attachment.anySenderEnabled)
        let legacyReleaseCount = firstOwner.snapshot["enginesReleased"] as? Int ?? 0

        let chatReceiver = RockLegacyChatReceiver()
        let listener = Room(delegate: chatReceiver, roomOptions: RoomOptions(reportRemoteTrackStatistics: true))
        try await listener.connect(url: "ws://127.0.0.1:7880", token: SharedEngineRockSpikeTests.token(identity: "listener", room: roomName),
                                   connectOptions: ConnectOptions(autoSubscribe: true, enableMicrophone: false))
        defer { Task { await listener.disconnect() } }

        let incoming = RoomChatPacket(id: UUID().uuidString, text: "Chat while the Guest graph remains active")
        try await listener.localParticipant.publish(data: incoming.encoded(),
            options: DataPublishOptions(topic: RoomChatPacket.topic, reliable: true))
        XCTAssertTrue(rock.chat.send("Rock is listening"))
        for _ in 0..<100 {
            if rock.chat.items.contains(where: { $0.id == incoming.id }) && chatReceiver.contains("Rock is listening") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let chatRoundTrip = rock.chat.items.contains { $0.id == incoming.id && !$0.isOwn } &&
            chatReceiver.contains("Rock is listening")
        XCTAssertTrue(chatRoundTrip)

        try await rock.setPlayout(true)
        XCTAssertTrue(rock.snapshot.playoutOn)
        // The manual module has no microphone device. The other LiveKit peer
        // publishes its synthetic capture so Rock can receive and transcribe it.
        ok(await firstGuest.setMuted(false))
        _ = try await listener.localParticipant.setMicrophone(enabled: true)
        let receivedAudio = GuestPCMMeter()
        var currentAudioSource: MeetingAudioSource?
        var audioSink: MeetingAudioSink?
        rock.setTranscriptionAudioHandler { sources in
            guard currentAudioSource == nil, let source = sources.first else { return }
            let sink = MeetingAudioSink(trackID: source.id) { _, buffer in receivedAudio.render(pcmBuffer: buffer) }
            currentAudioSource = source
            audioSink = sink
            source.attach(sink)
        }
        for _ in 0..<100 {
            if receivedAudio.snapshot.rms > 0.01 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(currentAudioSource, "Rock subscribes to the remote audio track while Guest owns the engine")
        XCTAssertGreaterThan(receivedAudio.snapshot.rms, 0.01, "Rock receives the legacy source's nonzero decoded PCM")
        if let audioSink { currentAudioSource?.detach(audioSink) }
        rock.setTranscriptionAudioHandler(nil)
        XCTAssertFalse(listener.remoteParticipants.values.contains { !$0.audioTracks.isEmpty }, "Rock has not published its microphone")
        ok(await rock.setPhysicalInputPermitted(true))
        XCTAssertEqual(engine.talkMeetingID, attachment.meetingID)
        do { try await rock.setMicrophone(true); XCTFail("The legacy shared route cannot activate a Rock microphone") }
        catch NativeDesktopRockError.sharedAudioInputUnavailable {}
        let closedLegacyGate = await rock.setMicrophoneGate(open: false)
        XCTAssertFalse(closedLegacyGate)
        XCTAssertFalse(attachment.anySenderEnabled)
        XCTAssertTrue(firstOwner.waitingForForwardedInputRoute)
        let hasRawSender = listener.remoteParticipants.values.contains { !$0.audioTracks.isEmpty }
        XCTAssertFalse(hasRawSender)
        print("ROCK-LEGACY-LISTENER samples=\(receivedAudio.snapshot.samples) rms=\(receivedAudio.snapshot.rms) chatRoundTrip=\(chatRoundTrip) rawSender=\(hasRawSender)")

        for publication in listener.localParticipant.audioTracks {
            if let local = publication as? LocalTrackPublication { try await listener.localParticipant.unpublish(publication: local) }
        }
        try await rock.setPlayout(false)
        ok(await firstGuest.detach())
        // The synthetic ADM forces output availability, unlike the physical
        // engine. Simulate a native route loss after both senders are off.
        let unavailable = LKRTCAudioEngineAvailability()
        XCTAssertEqual(firstOwner.factory.audioDeviceModule.setEngineAvailability(unavailable), 0)
        XCTAssertGreaterThan(firstOwner.snapshot["enginesReleased"] as? Int ?? 0, legacyReleaseCount)
        XCTAssertFalse(firstOwner.waitingForForwardedInputRoute)
        let other = try await engine.attach(meetingID: UUID())
        ok(await rock.setPhysicalInputPermitted(true))
        XCTAssertEqual(engine.talkMeetingID, attachment.meetingID)

        let unmuteStarted = ProcessInfo.processInfo.systemUptime
        try await rock.setMicrophone(true)
        let unmuteSeconds = ProcessInfo.processInfo.systemUptime - unmuteStarted

        XCTAssertTrue(rock.snapshot.microphoneOn)
        XCTAssertTrue(firstOwner.hasForwardedInputRoute, "A fresh SDK-owned graph authorized the Rock microphone")
        XCTAssertTrue(attachment.anySenderEnabled, "Rock's published track is the attachment's sender and is on")
        let track = try await SharedEngineRockSpikeTests.remoteAudio(in: listener)
        try await Task.sleep(for: .seconds(1))
        let silent = try await Self.rate(track, seconds: 1.5)   // no microphone: silence (Opus DTX)

        // The app-audio mixer exists once the input graph is built (after the first publish).
        let tone = MicrophoneMoveTests.tone(seconds: 0.5, frequency: 440, amplitude: 0.3)
        let player = Task { @MainActor in
            while !Task.isCancelled {
                AudioManager.shared.mixer.capture(appAudio: tone)
                try? await Task.sleep(for: .milliseconds(480))
            }
        }
        defer { player.cancel() }
        try await Task.sleep(for: .milliseconds(500))
        let talking = try await Self.rate(track, seconds: 2)

        // Move the talk role to the other meeting: Rock's sender goes off and it unpublishes.
        let moveStarted = ProcessInfo.processInfo.systemUptime
        ok(await rock.setPhysicalInputPermitted(false))
        ok(await other.assumeTalk())
        let moveSeconds = ProcessInfo.processInfo.systemUptime - moveStarted
        XCTAssertFalse(attachment.anySenderEnabled)
        XCTAssertEqual(engine.talkMeetingID, other.meetingID)
        do { try await rock.setMicrophone(true); XCTFail("Rock cannot unmute without the talk role") } catch {}
        let afterMove = try await Self.rate(track, seconds: 1.5)
        let unpublished = listener.remoteParticipants.values.flatMap(\.audioTracks).isEmpty

        // And back.
        ok(await other.relinquishTalk())
        ok(await rock.setPhysicalInputPermitted(true))
        try await rock.setMicrophone(true)
        let back = try await SharedEngineRockSpikeTests.remoteAudio(in: listener)
        try await Task.sleep(for: .milliseconds(500))
        let talkingAgain = try await Self.rate(back, seconds: 2)

        let evidence: [String: Any] = ["silentBytesPerSecond": silent, "talkingBytesPerSecond": talking, "unpublishedAfterMove": unpublished, "afterMoveBytesPerSecond": afterMove,
            "talkingAgainBytesPerSecond": talkingAgain, "unmuteSeconds": unmuteSeconds, "moveSeconds": moveSeconds, "recoveries": engine.recoveries,
            "owner": engine.guestOwner?.snapshot.filter { ["enginesCreated", "engineStarts", "engineStops", "manualRendering"].contains($0.key) } ?? [:]]
        if let data = try? JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys]) {
            print("R4-ROCK-ENGINE \(String(decoding: data, as: UTF8.self))")
        }
        XCTAssertGreaterThan(talking, max(3_000, silent * 2), "The listener hears Rock's tone through the shared owner")
        XCTAssertLessThan(afterMove, talking / 4, "After the move Rock sends nothing")
        XCTAssertTrue(unpublished, "Without the talk role Rock's microphone is unpublished")
        XCTAssertGreaterThan(talkingAgain, max(3_000, silent * 2), "Back with the talk role Rock is heard again")

        player.cancel()
        await player.value
        try await Task.sleep(for: .milliseconds(850))
        try await rock.setPlayout(true)
        let closedGate = await rock.setMicrophoneGate(open: false)
        XCTAssertTrue(closedGate)
        let meter = RockReplyReceiverMeter()
        back.add(audioRenderer: meter)
        defer { back.remove(audioRenderer: meter) }
        // Leave room for WebRTC's voice processing to suppress individual
        // 10-ms frames while keeping the same minimum non-silent coverage.
        let longDuration = 2.8
        let long = Self.voicedFixture(seconds: longDuration)
        let beforeLong = ProcessInfo.processInfo.systemUptime
        let complete = await rock.playVoiceReplyWithoutMonitorForTesting(long)
        let renderSeconds = ProcessInfo.processInfo.systemUptime - beforeLong
        XCTAssertTrue(complete, "Rock confirms completion from the mixer")
        XCTAssertEqual(renderSeconds, longDuration, accuracy: 0.25,
            "The outgoing mixer renders the complete converted input and completes before the timeout")
        try await Task.sleep(for: .milliseconds(250))
        print("ROCK-APP-REPLY seconds=\(renderSeconds) receiver=\(meter.diagnostics)")
        XCTAssertGreaterThan(meter.audibleSeconds, 1.8, "The receiver hears the long converted reply")
        XCTAssertGreaterThan(meter.audibleSpan, longDuration - 0.15, "The receiver hears the reply through its final syllable")
        let longCoverage = meter.temporalCoverage(seconds: longDuration)
        XCTAssertGreaterThanOrEqual(longCoverage.activeBuckets, 26, meter.diagnostics)
        XCTAssertLessThan(longCoverage.longestGap, 2, meter.diagnostics)
        XCTAssertTrue(longCoverage.tailAudible, meter.diagnostics)

        meter.reset()
        let interrupted = Task { await rock.playVoiceReplyWithoutMonitorForTesting(long) }
        for _ in 0..<100 {
            if meter.audibleSeconds > 0.20 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThan(meter.audibleSeconds, 0.20, "The second reply reached the receiver before cancellation")
        interrupted.cancel()
        let stopped = await interrupted.value
        XCTAssertFalse(stopped)
        try await Task.sleep(for: .milliseconds(300))
        meter.reset()
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertLessThan(meter.audibleSeconds, 0.05, "The cancelled buffer never resumes on the open route")
        meter.reset()
        let nextDuration = 0.8
        let next = Self.voicedFixture(seconds: nextDuration)
        let playedNext = await rock.playVoiceReplyWithoutMonitorForTesting(next)
        XCTAssertTrue(playedNext)
        try await Task.sleep(for: .milliseconds(240))
        print("ROCK-APP-REPLY-NEXT receiver=\(meter.diagnostics)")
        XCTAssertGreaterThan(meter.audibleSeconds, 0.4, "Cancellation did not block the next approved reply")
        XCTAssertGreaterThan(meter.audibleSpan, nextDuration - 0.15, meter.diagnostics)
        let nextCoverage = meter.temporalCoverage(seconds: nextDuration)
        XCTAssertGreaterThanOrEqual(nextCoverage.activeBuckets, 7, meter.diagnostics)
        XCTAssertLessThan(nextCoverage.longestGap, 2, meter.diagnostics)
        XCTAssertTrue(nextCoverage.tailAudible, meter.diagnostics)
        let reopenedGate = await rock.setMicrophoneGate(open: true)
        XCTAssertTrue(reopenedGate)

        // Leaving keeps the pinned owner (LiveKit holds its factory); the other meeting still runs on it.
        ok(await rock.leave())
        XCTAssertNotNil(engine.factory)
        XCTAssertEqual(engine.meetingIDs, [other.meetingID])
        ok(await other.detach())
        XCTAssertNotNil(engine.factory, "The last meeting out idles a pinned owner instead of shutting it down")
        XCTAssertFalse(engine.cleanupFailed)
    }

    /// Bytes a second received on the track; a counter reset (track unpublished) counts as none.
    static func rate(_ track: RemoteAudioTrack, seconds: Double) async throws -> Double {
        func bytes() -> UInt64 { track.statistics?.inboundRtpStream.compactMap(\.bytesReceived).reduce(0, +) ?? 0 }
        let before = bytes(), started = ProcessInfo.processInfo.systemUptime
        try await Task.sleep(for: .seconds(seconds))
        let after = bytes()
        return after > before ? Double(after - before) / (ProcessInfo.processInfo.systemUptime - started) : 0
    }

    private static func voicedFixture(seconds: Double) -> AVAudioPCMBuffer {
        let sampleRate = 16_000.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let samples = buffer.floatChannelData![0]
        var phase = 0.0
        for index in 0..<Int(frames) {
            let time = Double(index) / sampleRate
            let pitch = 175 + 35 * sin(2 * .pi * 3.1 * time) + 20 * sin(2 * .pi * 7.1 * time)
            let envelope = 0.7 + 0.3 * sin(2 * .pi * 4.4 * time)
            phase += 2 * .pi * pitch / sampleRate
            samples[index] = Float(envelope * (0.30 * sin(phase) + 0.18 * sin(3 * phase) + 0.12 * sin(6 * phase)))
        }
        return buffer
    }

    private func ok(_ value: Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(value, message, file: file, line: line)
    }
}

private final class RockReplyReceiverMeter: NSObject, AudioRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private var audible = 0.0
    private var received = 0.0
    private var peakPerTenth: [Double] = []
    private var audibleBuckets: Set<Int> = []
    private var firstAudible: Double?
    private var lastAudible: Double?

    func render(pcmBuffer: AVAudioPCMBuffer) {
        let frames = Int(pcmBuffer.frameLength)
        guard frames > 0 else { return }
        let energy: Double
        if let samples = pcmBuffer.floatChannelData?[0] {
            energy = (0..<frames).reduce(0) { sum, index in
                let value = Double(samples[index])
                return sum + value * value
            }
        } else if let samples = pcmBuffer.int16ChannelData?[0] {
            energy = (0..<frames).reduce(0) { sum, index in
                let value = Double(samples[index]) / 32_768
                return sum + value * value
            }
        } else { return }
        let rms = (energy / Double(frames)).squareRoot()
        lock.lock()
        let bucket = Int(received * 10)
        if bucket >= peakPerTenth.count {
            peakPerTenth += Array(repeating: 0, count: bucket - peakPerTenth.count + 1)
        }
        peakPerTenth[bucket] = max(peakPerTenth[bucket], rms)
        let duration = Double(frames) / pcmBuffer.format.sampleRate
        if rms > 0.02 {
            let first = firstAudible ?? received
            firstAudible = first
            audibleBuckets.insert(Int((received - first + duration / 2) * 10))
            lastAudible = received + duration
            audible += duration
        }
        received += duration
        lock.unlock()
    }

    var audibleSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        return audible
    }

    var audibleSpan: Double {
        lock.lock(); defer { lock.unlock() }
        guard let firstAudible, let lastAudible else { return 0 }
        return lastAudible - firstAudible
    }

    func temporalCoverage(seconds: Double) -> (activeBuckets: Int, longestGap: Int, tailAudible: Bool) {
        lock.withLock {
            let expected = Int((seconds * 10).rounded())
            var count = 0, gap = 0, longestGap = 0
            for bucket in 0..<expected {
                if audibleBuckets.contains(bucket) {
                    count += 1
                    gap = 0
                } else {
                    gap += 1
                    longestGap = max(longestGap, gap)
                }
            }
            return (count, longestGap, (expected - 2..<expected).contains { audibleBuckets.contains($0) })
        }
    }

    func reset() {
        lock.lock()
        audible = 0; received = 0; peakPerTenth.removeAll(); audibleBuckets.removeAll()
        firstAudible = nil; lastAudible = nil
        lock.unlock()
    }

    var diagnostics: String {
        lock.lock(); defer { lock.unlock() }
        return "received=\(received) audible=\(audible) activeBuckets=\(audibleBuckets.sorted()) peakPerTenth=\(peakPerTenth)"
    }
}


private final class RockLegacyChatReceiver: NSObject, RoomDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var texts: Set<String> = []

    func contains(_ text: String) -> Bool { lock.withLock { texts.contains(text) } }

    func room(_ room: Room, participant: RemoteParticipant?, didReceiveData data: Data,
              forTopic topic: String, encryptionType: EncryptionType) {
        guard topic == RoomChatPacket.topic, let message = try? RoomChatPacket.decode(data) else { return }
        lock.withLock { _ = texts.insert(message.text) }
    }
}
