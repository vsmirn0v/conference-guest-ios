import AppKit
import AVFoundation
import ConferenceCore
import LiveKitWebRTC
import XCTest
@testable import RockNativeDesktop

@MainActor private final class WorkspaceArchiveTestEngine: NativeDesktopMeetingEngine {
    var onState: ((NativeDesktopExternalSnapshot) -> Void)?
    var onVideo: (([NativeDesktopExternalVideo]) -> Void)?
    var onLocalCamera: ((LKRTCVideoTrack?) -> Void)?
    var onTitle: ((String) -> Void)?
    var factory: LKRTCPeerConnectionFactory? { nil }
    var incomingVideo: [NativeDesktopExternalVideo] { [] }
    var snapshot = NativeDesktopExternalSnapshot()
    var gateChanges: [Bool] = []
    var voiceMicrophoneGateIsClosed = false
    var microphoneChanges: [Bool] = []
    var onCloseGate: (() async -> Void)?
    var voiceStarts = 0
    var supportsVoiceReply = false

    func connect(invitation: URL, name: String, quiet: Bool) async throws {
        snapshot = .init(phase: .connected, playoutOn: !quiet)
        onState?(snapshot)
    }

    func reconnect() async throws {}
    func setMicrophone(_ enabled: Bool) async throws {
        microphoneChanges.append(enabled)
        snapshot.microphoneOn = enabled
        onState?(snapshot)
    }
    func setCamera(_ enabled: Bool) async throws {}
    func setPlayout(_ enabled: Bool) async throws {
        snapshot.playoutOn = enabled
        onState?(snapshot)
    }
    func setScreenTrack(_ track: LKRTCVideoTrack?) async throws {}
    func setMicrophoneGate(open: Bool) async -> Bool {
        gateChanges.append(open)
        voiceMicrophoneGateIsClosed = !open
        if !open { await onCloseGate?() }
        return true
    }
    func playVoiceReply(_ buffer: AVAudioPCMBuffer) async -> Bool {
        voiceStarts += 1
        return true
    }
    func leave() async -> Bool { true }
}

private final class WorkspaceArchiveMemoryStorage: RoomHistoryStorage {
    var value: Data?
    func read() -> Data? { value }
    func write(_ data: Data) throws { value = data }
}

final class MeetingWorkspaceJournalTests: XCTestCase {
    private struct RestartMarker: Codable {
        let processID: Int32
        let sessionID: UUID
    }

    private static let restartTranscript = "The room kept the original Russian caption. Сохранили исходную реплику."
    private static let restartReply = "Принято, я запишу итог."
    private static let guestURL = URL(string: "https://workspace-fixture.invalid/meet/archived")!

    @MainActor func testTakeoverLeavesFollowingPausedUntilExplicitResume() async throws {
        let root = try temporaryRoot()
        let suite = "workspace-takeover-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let store = AttentionStore(root: root, defaults: defaults, keychain: .init(service: suite))
        store.enabled = true
        let attention = AttentionCoordinator(store: store)
        let model = NativeDesktopMeetingModel(destination: try .verified(Self.guestURL, engine: .guest),
            name: "Fixture", title: "Fixture", engine: WorkspaceArchiveTestEngine(),
            joinReadiness: .init(microphone: .off, camera: .off))
        attention.meetings = { [model] }
        try await model.connect()
        attention.setMode(.watch, for: model)
        XCTAssertEqual(attention.resolvedMode(model).mode, .watch)
        let state = MeetingWorkspaceViewState()
        let pause = try XCTUnwrap(state.beginTakeover(model, attention: attention))
        XCTAssertEqual(attention.resolvedMode(model).mode, .off)
        XCTAssertNotNil(attention.workspaceFollowingPauses[model.sessionID])
        // A global pause/restore cycle must not claim the takeover's pause.
        XCTAssertNil(state.restorePauses[model.sessionID])
        state.toggleAll([model], attention: attention)
        XCTAssertEqual(attention.resolvedMode(model).mode, .off)
        state.resume(model, pause: pause, attention: attention)
        XCTAssertEqual(attention.resolvedMode(model).mode, .watch)
        _ = await model.leave()
        attention.stop()
    }

    @MainActor func testRestartWriterLeavesThroughWorkspace() async throws {
        let root = try restartRoot()
        let markerURL = root.appendingPathComponent("workspace-restart.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path), "Use a fresh fixture directory")
        let id = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "workspace-archive-test-" + id))
        defer { defaults.removePersistentDomain(forName: "workspace-archive-test-" + id) }
        let store = AttentionStore(root: root, defaults: defaults, keychain: .init(service: "workspace-archive-test-" + id))
        let library = NativeDesktopLibrary(preferences: defaults,
            history: RoomHistoryStore(storage: WorkspaceArchiveMemoryStorage()),
            syncStorage: WorkspaceArchiveMemoryStorage())
        library.displayName = "Archive fixture"
        let workspace = NativeDesktopWorkspace(library: library,
            detect: { _ in .verified(.guest(endpoint: Self.guestURL)) },
            makeMeeting: { destination, name, title, quiet in
                NativeDesktopMeetingModel(destination: destination, name: name, title: title, quiet: quiet,
                    engine: WorkspaceArchiveTestEngine(), joinReadiness: .init(microphone: .off, camera: .off))
            }, attention: AttentionCoordinator(store: store))
        await store.waitForMeetingLibrary()
        workspace.join(Self.guestURL, engine: .guest, title: "Workspace restart fixture")
        for _ in 0..<200 {
            if workspace.meeting?.connected == true, !workspace.preparing { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let model = try XCTUnwrap(workspace.meeting)
        XCTAssertTrue(model.connected)
        let journal = store.meetingLibrary.workspaceJournal
        let timestamp = Date()
        model.receiveLocalLineForTesting(.init(id: "restart-caption", trackID: MeetingTranscriber.localTrackID,
            text: "Earlier caption revision", start: timestamp, end: timestamp))
        XCTAssertNil(journal.session(id: model.sessionID)?.endedAt)

        workspace.toggleWindow(model)
        let detachedWindow = try XCTUnwrap(NSApp.windows.first { $0.title == model.title })
        detachedWindow.performClose(nil)
        XCTAssertTrue(model.connected)
        XCTAssertNil(journal.session(id: model.sessionID)?.endedAt)
        model.receiveLocalLineForTesting(.init(id: "restart-caption", trackID: MeetingTranscriber.localTrackID,
            text: Self.restartTranscript, start: timestamp, end: timestamp))
        let evidence = MeetingWorkspaceEvent.SourceSnapshot(id: "trigger:restart-caption", title: model.displayName,
            text: Self.restartTranscript, revision: "original", capturedAt: timestamp)
        XCTAssertTrue(journal.recordAssistantReply(sessionID: model.sessionID, id: "restart-reply",
            text: Self.restartReply, source: "voice", status: .sending, sourceSnapshots: [evidence]))
        XCTAssertTrue(journal.updateReplyStatus(sessionID: model.sessionID, id: "restart-reply", status: .spoken))

        let clean = await workspace.leave(model)
        XCTAssertTrue(clean)
        XCTAssertTrue(workspace.meetings.isEmpty)
        XCTAssertNotNil(journal.session(id: model.sessionID)?.endedAt)
        await store.closeLibrarySyncForTeardown()
        journal.close()
        try JSONEncoder().encode(RestartMarker(processID: ProcessInfo.processInfo.processIdentifier,
            sessionID: model.sessionID)).write(to: markerURL, options: .atomic)
    }

    @MainActor func testRestartReaderUsesDifferentAppProcess() throws {
        let root = try restartRoot()
        let marker = try JSONDecoder().decode(RestartMarker.self,
            from: Data(contentsOf: root.appendingPathComponent("workspace-restart.json")))
        XCTAssertNotEqual(ProcessInfo.processInfo.processIdentifier, marker.processID)
        let journal = MeetingWorkspaceJournal(root: root)
        journal.prepare()
        defer { journal.close() }
        let session = try XCTUnwrap(journal.session(id: marker.sessionID))
        XCTAssertNotNil(session.endedAt)
        XCTAssertFalse(session.interrupted)
        let transcript = try XCTUnwrap(session.events.first { $0.id == "transcript:local:restart-caption" })
        XCTAssertEqual(transcript.text, Self.restartTranscript)
        XCTAssertEqual(transcript.revisions.map(\.text), ["Earlier caption revision", Self.restartTranscript])
        let reply = try XCTUnwrap(session.events.first { $0.id == "assistant:restart-reply" })
        XCTAssertEqual(reply.text, Self.restartReply)
        XCTAssertEqual(reply.statusHistory.map(\.status), [.sending, .spoken])
        XCTAssertEqual(reply.sourceSnapshots.first?.text, Self.restartTranscript)
    }

    @MainActor func testRecoveryPreservesAmbiguousDeliveryAndPrivateDrafts() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = MeetingWorkspaceJournal(root: root)
        let session = UUID()
        first.begin(sessionID: session, title: "Review", calendarSeriesID: "series", roomIdentity: "room")
        let evidence = MeetingWorkspaceEvent.SourceSnapshot(id: "trigger:1", title: "Mira", text: "Original",
            revision: "before", capturedAt: .now)
        XCTAssertTrue(first.recordAssistantReply(sessionID: session, id: "chat", text: "Exact chat", source: "chat",
            status: .queued, isPrivate: true, sourceSnapshots: [evidence]))
        XCTAssertTrue(first.recordAssistantReply(sessionID: session, id: "chat", text: "Exact chat", source: "chat",
            status: .sending, linkedChatID: "chat:guest:chat-id"))
        XCTAssertFalse(first.recordAssistantReply(sessionID: session, id: "chat", text: "Repeated", source: "chat", status: .sending))
        XCTAssertTrue(first.recordAssistantReply(sessionID: session, id: "voice", text: "Exact voice", source: "voice",
            status: .queued, isPrivate: true))
        XCTAssertTrue(first.recordAssistantReply(sessionID: session, id: "voice", text: "Exact voice", source: "voice",
            status: .sending))
        XCTAssertTrue(first.updateReplyStatus(sessionID: session, id: "voice", status: .spoken))
        XCTAssertTrue(first.recordAssistantReply(sessionID: session, id: "held", text: "Held", source: "voice",
            status: .queued, isPrivate: true))
        XCTAssertTrue(first.updateReplyStatus(sessionID: session, id: "held", status: .held))
        XCTAssertTrue(first.reviseHeldReply(sessionID: session, id: "held", text: "Edited privately"))
        XCTAssertTrue(first.recordAssistantReply(sessionID: session, id: "queued", text: "Pending", source: "chat",
            status: .queued, isPrivate: true))
        XCTAssertTrue(first.recordAssistantReply(sessionID: session, id: "insight", text: "Quiet suggestion",
            source: "assistantInsight", status: .privateOnly, isPrivate: true, sourceSnapshots: [evidence]))
        first.recordGap(sessionID: session, reason: "connection", from: .now)
        XCTAssertThrowsError(try first.delete(sessionID: session))
        first.prepare()
        XCTAssertNil(first.session(id: session)?.endedAt)
        first.close()

        let reopened = MeetingWorkspaceJournal(root: root)
        reopened.prepare()
        defer { reopened.close() }
        let archived = try XCTUnwrap(reopened.session(id: session))
        XCTAssertTrue(archived.interrupted)
        XCTAssertEqual(archived.calendarSeriesID, "series")
        let replies = Dictionary(uniqueKeysWithValues: archived.events.filter { $0.kind == .assistantReply }.map { ($0.id, $0) })
        XCTAssertEqual(replies["assistant:chat"]?.text, "Exact chat")
        XCTAssertEqual(replies["assistant:chat"]?.statusHistory.map(\.status), [.queued, .sending, .unknown])
        XCTAssertEqual(replies["assistant:chat"]?.isPrivate, false)
        XCTAssertEqual(replies["assistant:chat"]?.linkedChatID, "chat:guest:chat-id")
        XCTAssertEqual(replies["assistant:chat"]?.sourceSnapshots, [evidence])
        XCTAssertEqual(replies["assistant:voice"]?.statusHistory.map(\.status), [.queued, .sending, .spoken])
        XCTAssertEqual(replies["assistant:voice"]?.isPrivate, false)
        XCTAssertEqual(replies["assistant:queued"]?.status, .interrupted)
        XCTAssertEqual(replies["assistant:queued"]?.isPrivate, true)
        XCTAssertEqual(replies["assistant:held"]?.revisions.map(\.text), ["Held", "Edited privately"])
        XCTAssertEqual(replies["assistant:insight"]?.status, .privateOnly)
        XCTAssertEqual(replies["assistant:insight"]?.sourceSnapshots, [evidence])
        XCTAssertNotNil(archived.events.first { $0.kind == .captureGap }?.endedAt)
    }

    @MainActor func testProviderCaptureRetainsOlderPagesAndFullTextBeforeVisibleTrim() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = MeetingWorkspaceJournal(root: root)
        defer { journal.close() }
        let sessionID = UUID()
        journal.begin(sessionID: sessionID, title: "Large archive", calendarSeriesID: nil, roomIdentity: nil)
        var features = GuestMeetingFeatures()
        features.receive(["event": "joined", "payload": [
            "participant": ["participantId": "local", "permissions": ["canViewTranscription": true, "canViewChat": true]],
            "participantGroup": ["groupId": "group"], "roomId": "room"
        ]])
        let capture: ([GuestMeetingMessage], Bool) -> Void = { messages, transcript in
            journal.observe(sessionID: sessionID, events: messages.map { message in
                .init(id: (transcript ? "transcript:guest:" : "chat:guest:") + message.id,
                      kind: transcript ? .transcript : .chat, occurredAt: message.sentAt ?? .now,
                      author: message.participantName, text: message.text)
            })
        }
        func page(_ range: Range<Int>, title: String) -> [[String: Any]] {
            range.reversed().map { index in
                ["id": "\(title)-\(index)", "participantId": "speaker", "participantName": "Speaker",
                 "text": index == 0 ? String(repeating: "я", count: 5000) : title,
                 "createdAt": 1_725_000_000 + index]
            }
        }
        try features.acceptHistory(["messages": page(25..<1025, title: "speech")],
            transcript: true, epoch: features.epoch, capture: capture)
        try features.acceptHistory(["messages": page(0..<25, title: "speech")],
            transcript: true, epoch: features.epoch, capture: capture)
        try features.acceptHistory(["messages": page(25..<250, title: "chat")],
            transcript: false, epoch: features.epoch, capture: capture)
        try features.acceptHistory(["messages": page(0..<25, title: "chat")],
            transcript: false, epoch: features.epoch, capture: capture)
        XCTAssertEqual(features.snapshot.transcript.count, 1000)
        XCTAssertEqual(features.snapshot.messages.count, 200)
        journal.end(sessionID: sessionID)
        features.receive(["event": "transcription-message", "payload": ["message": [
            "id": "speech-0", "participantId": "speaker", "participantName": "Speaker", "text": "Corrected"
        ]]], capture: capture)
        journal.close()

        let reopened = MeetingWorkspaceJournal(root: root)
        reopened.prepare()
        defer { reopened.close() }
        let events = try XCTUnwrap(reopened.session(id: sessionID)?.events)
        XCTAssertEqual(events.filter { $0.kind == .transcript }.count, 1025)
        XCTAssertEqual(events.filter { $0.kind == .chat }.count, 250)
        let corrected = try XCTUnwrap(events.first { $0.id == "transcript:guest:speech-0" })
        XCTAssertEqual(corrected.revisions.first?.text.count, 5000)
        XCTAssertEqual(corrected.text, "Corrected")
        XCTAssertEqual(events.first { $0.id == "chat:guest:chat-0" }?.text?.count, 5000)
        reopened.toggleBookmark(sessionID: sessionID, eventID: corrected.id)
        XCTAssertEqual(reopened.session(id: sessionID)?.events.first { $0.id == corrected.id }?.isBookmarked, true)
        try reopened.delete(sessionID: sessionID)
        reopened.close()
        reopened.prepare()
        XCTAssertNil(reopened.session(id: sessionID))
    }

    @MainActor func testApprovedVoiceRechecksTheRawGateBeforeEnablingTheSender() async throws {
        let engine = WorkspaceArchiveTestEngine()
        engine.supportsVoiceReply = true
        let model = NativeDesktopMeetingModel(destination: try .verified(Self.guestURL, engine: .guest),
            name: "Me", title: "Gate", engine: engine, joinReadiness: .init(microphone: .off, camera: .off))
        try await model.connect()
        model.setMeetingVolume(1, persist: false)
        engine.onCloseGate = {
            Task { @MainActor in
                // A graph is replaced after closure is acknowledged, while the gain settles.
                try await Task.sleep(for: .milliseconds(20))
                engine.voiceMicrophoneGateIsClosed = false
            }
        }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
        pcm.frameLength = 160
        do {
            try await model.speak(pcm)
            XCTFail("A replaced microphone gate must fail closed")
        } catch NativeDesktopMeetingModel.VoiceReplyError.gate {}
        XCTAssertFalse(engine.microphoneChanges.contains(true))
        XCTAssertEqual(engine.voiceStarts, 0)
        _ = await model.leave()
    }

    @MainActor func testVolumeZeroCancelsApprovedVoiceWhileTheGateIsSettling() async throws {
        let engine = WorkspaceArchiveTestEngine()
        engine.supportsVoiceReply = true
        let model = NativeDesktopMeetingModel(destination: try .verified(Self.guestURL, engine: .guest),
            name: "Me", title: "Gate", engine: engine, joinReadiness: .init(microphone: .off, camera: .off))
        try await model.connect()
        model.setMeetingVolume(1, persist: false)
        let entered = expectation(description: "Closed microphone gate before speech")
        var release: CheckedContinuation<Void, Never>?
        engine.onCloseGate = {
            await withCheckedContinuation {
                release = $0
                entered.fulfill()
            }
        }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
        pcm.frameLength = 160
        let playback = try XCTUnwrap(model.startWorkspaceApprovedVoice {
            do { try await model.speak(pcm); return false }
            catch { return error is CancellationError }
        })
        await fulfillment(of: [entered], timeout: 2)
        model.setMeetingVolume(0, persist: false)
        model.setMeetingVolume(1, persist: false)
        release?.resume()
        let cancelled = await playback.value
        XCTAssertTrue(cancelled)
        XCTAssertEqual(engine.voiceStarts, 0)
        XCTAssertFalse(engine.microphoneChanges.contains(true))
        XCTAssertEqual(engine.gateChanges, [false, true])
        _ = await model.leave()
    }

    @MainActor func testAssistantTalkReservesAndRetainsExactMeetingContributionsOnce() async throws {
        let root = try temporaryRoot()
        let preferences = "workspace-command-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: preferences))
        defer {
            defaults.removePersistentDomain(forName: preferences)
            try? FileManager.default.removeItem(at: root)
        }
        let store = AttentionStore(root: root, defaults: defaults, keychain: .init(service: preferences))
        let engine = WorkspaceArchiveTestEngine()
        engine.supportsVoiceReply = true
        let model = NativeDesktopMeetingModel(destination: try .verified(Self.guestURL, engine: .guest),
            name: "Me", title: "Talk command fixture", engine: engine,
            joinReadiness: .init(microphone: .off, camera: .off))
        model.meetingLibrary = store.meetingLibrary
        try await model.connect()
        model.setMeetingVolume(1, persist: false)
        let attention = AttentionCoordinator(store: store)
        attention.meetings = { [model] }
        var voices = 0, chats = 0, reactions = 0
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
        buffer.frameLength = 160
        attention.synthesizeOverride = { _ in buffer }
        attention.deliverVoice = { _, _ in voices += 1 }
        attention.deliverChat = { _, _ in chats += 1; return true }
        attention.deliverReaction = { _, _ in reactions += 1 }
        model.chat.canSend = true
        var features = GuestMeetingSnapshot()
        features.permissions.canSendReaction = true
        model.receiveFeaturesForTesting(features)
        model.chat.canSend = true

        let context = attention.talk.makeContext()
        let commands: [(AssistantCommand, UUID, String)] = [
            (.init(action: .say, meetingID: model.sessionID, text: Self.restartReply), UUID(), "Say the exact result"),
            (.init(action: .sendChat, meetingID: model.sessionID, text: "Chat approval"), UUID(), "Send the approved chat"),
            (.init(action: .react, meetingID: model.sessionID, reaction: MeetingReaction.allCases[0]), UUID(), "React to this meeting")
        ]
        for (command, id, original) in commands {
            _ = try await attention.talk.execute(command, context: context, attention: attention, id: id, originalInput: original)
            do {
                _ = try await attention.talk.execute(command, context: context, attention: attention, id: id, originalInput: original)
                XCTFail("A reserved command was executed twice")
            } catch {}
        }
        XCTAssertEqual(voices, 1)
        XCTAssertEqual(chats, 1)
        XCTAssertEqual(reactions, 1)
        _ = await model.leave()
        await store.closeLibrarySyncForTeardown()

        let reopened = MeetingWorkspaceJournal(root: root)
        reopened.prepare()
        defer { reopened.close() }
        let archived = try XCTUnwrap(reopened.session(id: model.sessionID))
        let speech = try XCTUnwrap(archived.events.first { $0.id == "assistant:" + commands[0].1.uuidString.lowercased() })
        XCTAssertEqual(speech.text, Self.restartReply)
        XCTAssertEqual(speech.statusHistory.map(\.status), [.queued, .sending, .spoken])
        XCTAssertEqual(speech.sourceSnapshots.first?.text, commands[0].2)
        let chat = try XCTUnwrap(archived.events.first { $0.id == "assistant:" + commands[1].1.uuidString.lowercased() })
        XCTAssertEqual(chat.text, "Chat approval")
        XCTAssertEqual(chat.status, .submitted)
        let reaction = try XCTUnwrap(archived.events.first { $0.id == "action:" + commands[2].1.uuidString.lowercased() })
        XCTAssertEqual(reaction.kind, .action)
        XCTAssertEqual(reaction.status, .submitted)
        XCTAssertEqual(reaction.sourceSnapshots.first?.text, commands[2].2)
    }

    private func restartRoot() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["ROCK_WORKSPACE_RESTART_ROOT"] ?? environment["TEST_RUNNER_ROCK_WORKSPACE_RESTART_ROOT"],
              path.hasPrefix("/"), URL(fileURLWithPath: path).lastPathComponent.hasPrefix("workspace-restart-")
        else { throw XCTSkip("Set ROCK_WORKSPACE_RESTART_ROOT to a dedicated workspace-restart-* fixture directory.") }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-journal-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
