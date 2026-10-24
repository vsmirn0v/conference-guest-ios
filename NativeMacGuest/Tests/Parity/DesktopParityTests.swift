import AppKit
import ConferenceCore
import LiveKitWebRTC
import SwiftUI
import XCTest
@testable import RockNativeDesktop

@MainActor private final class DesktopTestEngine: NativeDesktopMeetingEngine {
    var onState: ((NativeDesktopExternalSnapshot) -> Void)?
    var onVideo: (([NativeDesktopExternalVideo]) -> Void)?
    var onLocalCamera: ((LKRTCVideoTrack?) -> Void)?
    var onTitle: ((String) -> Void)?
    var factory: LKRTCPeerConnectionFactory? { nil }
    var incomingVideo: [NativeDesktopExternalVideo] { [] }
    var snapshot = NativeDesktopExternalSnapshot()
    var microphoneCommands: [Bool] = []
    var completedMicrophoneCommands = 0
    var cameraCommands: [Bool] = []
    var leaves = 0
    var clean = true
    var demands: [(ids: Set<String>?, focused: String?)] = []
    var onConnect: (() async throws -> Void)?
    func connect(invitation: URL, name: String, quiet: Bool) async throws {
        snapshot.phase = .connecting; onState?(snapshot)
        try await onConnect?()
        try Task.checkCancellation()
        snapshot = .init(phase: .connected, playoutOn: !quiet); onState?(snapshot)
    }
    func reconnect() async throws {}
    func setMicrophone(_ enabled: Bool) async throws {
        microphoneCommands.append(enabled); try await Task.sleep(for: .milliseconds(25))
        snapshot.microphoneOn = enabled; completedMicrophoneCommands += 1; onState?(snapshot)
    }
    func setCamera(_ enabled: Bool) async throws { cameraCommands.append(enabled); snapshot.cameraOn = enabled; onState?(snapshot) }
    func setPlayout(_ enabled: Bool) async throws { snapshot.playoutOn = enabled; onState?(snapshot) }
    func setScreenTrack(_ track: LKRTCVideoTrack?) async throws { snapshot.sharing = track != nil; onState?(snapshot) }
    func setVisibleParticipantIDs(_ ids: Set<String>?, focusedParticipantID: String?) async throws { demands.append((ids, focusedParticipantID)) }
    func leave() async -> Bool { leaves += 1; snapshot.phase = clean ? .left : .failed; onState?(snapshot); return clean }
}
private final class DesktopMemoryStorage: RoomHistoryStorage, @unchecked Sendable {
    var value: Data?
    func read() -> Data? { value }
    func write(_ data: Data) throws { value = data }
}

@MainActor final class DesktopParityTests: XCTestCase {
    private let url = URL(string: "https://example.test/calls/native-parity")!
    private func model(_ engine: DesktopTestEngine) throws -> NativeDesktopMeetingModel {
        NativeDesktopMeetingModel(destination: try .verified(url, engine: .guest), name: "Parity Test", title: "Fixture", engine: engine)
    }
    private func spin(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 { if predicate() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("The asynchronous operation did not complete")
    }
    func testRapidTogglePreservesBothIntentsWithoutMutingPlayout() async throws {
        let engine = DesktopTestEngine(), model = try model(engine)
        try await model.connect(); model.toggleMicrophone(); model.toggleMicrophone()
        try await spin { engine.completedMicrophoneCommands == 2 && !model.snapshot.microphoneOn }
        XCTAssertEqual(engine.microphoneCommands, [true, false]); XCTAssertTrue(model.snapshot.playoutOn)
        let left = await model.leave(); XCTAssertTrue(left); XCTAssertEqual(engine.leaves, 1)
    }
    func testCleanLeaveClearsAllConfirmedMediaState() async throws {
        let engine = DesktopTestEngine(), model = try model(engine)
        try await model.connect(); try await engine.setMicrophone(true); try await engine.setCamera(true)
        let clean = await model.leave(); XCTAssertTrue(clean)
        XCTAssertFalse(model.snapshot.microphoneOn); XCTAssertFalse(model.snapshot.cameraOn)
        XCTAssertFalse(model.snapshot.playoutOn); XCTAssertFalse(model.snapshot.sharing)
        XCTAssertNil(model.localCamera); XCTAssertNil(model.localShare)
    }
    func testUncertainHandoffDoesNotRestoreSending() async throws {
        let engine = DesktopTestEngine(), model = try model(engine)
        try await model.connect(); try await engine.setMicrophone(true); try await engine.setCamera(true)
        try await model.setTransferHeld(true)
        XCTAssertFalse(model.snapshot.microphoneOn); XCTAssertFalse(model.snapshot.cameraOn)
        try await model.setTransferHeld(false, restoreSending: false)
        XCTAssertTrue(model.snapshot.playoutOn); XCTAssertFalse(model.snapshot.microphoneOn); XCTAssertFalse(model.snapshot.cameraOn)
        _ = await model.leave()
    }
    func testHandoffHoldBlocksNewSendingCommandsUntilResume() async throws {
        let engine = DesktopTestEngine(), model = try model(engine)
        try await model.connect(); model.toggleMicrophone()
        let hold = Task { try await model.setTransferHeld(true) }
        try await Task.sleep(for: .milliseconds(5))
        model.toggleMicrophone(); model.toggleCamera(); model.startSharing(presenter: false)
        try await hold.value
        XCTAssertEqual(engine.microphoneCommands, [true, false]); XCTAssertEqual(engine.cameraCommands, [false])
        XCTAssertFalse(model.snapshot.microphoneOn); XCTAssertFalse(model.snapshot.cameraOn)
        model.toggleMicrophone(); model.toggleCamera()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(engine.microphoneCommands.count, 2); XCTAssertEqual(engine.cameraCommands.count, 1)
        try await model.setTransferHeld(false, restoreSending: false)
        _ = await model.leave()
    }
    func testLeaveDrainsPendingControlsBeforeReleasingEngine() async throws {
        let engine = DesktopTestEngine(), model = try model(engine)
        try await model.connect(); model.toggleMicrophone()
        try await Task.sleep(for: .milliseconds(5))
        let clean = await model.leave(); XCTAssertTrue(clean)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(engine.leaves, 1); XCTAssertEqual(model.snapshot.phase, .left)
        XCTAssertFalse(model.snapshot.microphoneOn)
    }
    func testLeaveIsIdempotentAndFailedCleanupCannotReportSuccess() async throws {
        let engine = DesktopTestEngine(), model = try model(engine)
        try await model.connect(); engine.clean = false
        let first = await model.leave(), second = await model.leave()
        XCTAssertFalse(first); XCTAssertFalse(second)
        XCTAssertEqual(engine.leaves, 1); XCTAssertEqual(model.snapshot.phase, .failed)
    }
    func testCancellingDuringEngineDetectionDoesNotJoinOrCreateHistory() async throws {
        let preferences = UserDefaults(suiteName: "native-parity-\(UUID())")!
        let history = RoomHistoryStore(storage: DesktopMemoryStorage())
        let library = NativeDesktopLibrary(preferences: preferences, history: history, syncStorage: DesktopMemoryStorage())
        library.displayName = "Parity Test"
        var modelsCreated = 0
        let workspace = NativeDesktopWorkspace(library: library, detect: { _ in
            try await Task.sleep(for: .seconds(30)); return .verified(.guest(endpoint: self.url))
        }, makeMeeting: { destination, name, title, quiet in
            modelsCreated += 1
            return NativeDesktopMeetingModel(destination: destination, name: name, title: title, quiet: quiet, engine: DesktopTestEngine())
        })
        workspace.join(url)
        XCTAssertTrue(workspace.preparing)
        let stopped = await workspace.leave(); XCTAssertTrue(stopped)
        XCTAssertEqual(modelsCreated, 0); XCTAssertTrue(library.recent.isEmpty); XCTAssertNil(workspace.meeting)
    }
    func testCloseMeetingWindowKeepsMediaUntilExplicitLeave() async throws {
        let engine = DesktopTestEngine(), model = try model(engine)
        try await model.connect()
        let window = NativeDesktopMeetingWindow(model: model)
        window.show(); window.close()
        XCTAssertEqual(engine.leaves, 0); XCTAssertEqual(model.snapshot.phase, .connected)
        _ = await model.leave(); XCTAssertEqual(engine.leaves, 1)
    }
    func testFirstMeetingShowMountsRendererAndCloseAllowsRemount() async throws {
        let engine = DesktopTestEngine(), model = try model(engine)
        try await model.connect()
        let meetingWindow = NativeDesktopMeetingWindow(model: model)
        meetingWindow.show()
        let native = try XCTUnwrap(NSApp.windows.first { $0.delegate === meetingWindow })
        XCTAssertTrue(native.contentView is NSHostingView<NativeDesktopMeetingView>, "AppKit's default plain content view must be replaced on the first show")
        meetingWindow.close()
        XCTAssertNil(native.contentView, "Hidden meeting must detach native renderers")
        meetingWindow.show()
        XCTAssertTrue(native.contentView is NSHostingView<NativeDesktopMeetingView>)
        meetingWindow.close(); _ = await model.leave()
    }
    func testTypedScreenFocusSurvivesMissingTrackAndHiddenViewPreservesAudio() async throws {
        let engine = DesktopTestEngine(), model = try model(engine)
        try await model.connect()
        let factory = LKRTCPeerConnectionFactory(encoderFactory: LKRTCDefaultVideoEncoderFactory(), decoderFactory: LKRTCDefaultVideoDecoderFactory())
        func video(_ id: String, _ source: NativeDesktopVideoSource) -> NativeDesktopExternalVideo {
            .init(id: id + "-" + source.rawValue, participantID: id, source: source,
                  track: factory.videoTrack(with: factory.videoSource(), trackId: UUID().uuidString))
        }
        let aCamera = video("a", .camera), aScreen = video("a", .screen), bScreen = video("b", .screen)
        engine.snapshot.participants = [
            .init(id: "b", name: "Second sharer", sharing: true), .init(id: "a", name: "First sharer", sharing: true)]
        engine.onState?(engine.snapshot)
        try await spin { engine.demands.last?.focused == "b" }
        XCTAssertTrue(model.showsFocus); XCTAssertNil(model.focusedVideo, "Metadata should demand a share before it has an incoming track")
        engine.onVideo?([aCamera, aScreen, bScreen])
        model.focus(participantID: "a", source: .screen)
        try await spin { engine.demands.last?.focused == "a" }
        XCTAssertEqual(model.focusedVideo?.id, aScreen.id)
        engine.onVideo?([aCamera, bScreen])
        XCTAssertNil(model.focusedVideo, "A transient missing share must not switch to the same participant's camera")
        XCTAssertEqual(model.focusedParticipantID, "a")
        engine.onVideo?([bScreen, aScreen, aCamera])
        XCTAssertEqual(model.focusedVideo?.id, aScreen.id)
        model.setMediaVisible(false)
        try await spin { engine.demands.last?.ids == Set<String>() }
        XCTAssertNil(engine.demands.last?.focused, "A hidden focused window must not retain a subscription through the engine's focus override")
        XCTAssertTrue(model.snapshot.playoutOn); XCTAssertTrue(engine.microphoneCommands.isEmpty)
        model.setMediaVisible(true)
        try await spin { engine.demands.last?.ids == Set(["a"]) }
        model.viewMode = .audioOnly
        try await spin { engine.demands.last?.ids == Set<String>() }
        XCTAssertNil(engine.demands.last?.focused)
        XCTAssertTrue(model.snapshot.playoutOn)
        _ = await model.leave()
    }
    func testFloatingMeetingRequestsOneVideoAndRestoresGalleryWithoutChangingAudioOnly() async throws {
        let engine = DesktopTestEngine(), model = try model(engine)
        try await model.connect()
        let factory = LKRTCPeerConnectionFactory(encoderFactory: LKRTCDefaultVideoEncoderFactory(), decoderFactory: LKRTCDefaultVideoDecoderFactory())
        engine.snapshot.participants = (0..<12).map { .init(id: "person-\($0)", name: "Participant \($0)", cameraOn: true) }
        engine.onState?(engine.snapshot)
        engine.onVideo?(engine.snapshot.participants.map { .init(id: $0.id + "-camera", participantID: $0.id, source: .camera,
            track: factory.videoTrack(with: factory.videoSource(), trackId: $0.id)) })
        model.viewMode = .gallery
        try await spin { engine.demands.last?.ids?.count == 6 }
        model.setMediaPresentation(.floating)
        try await spin { engine.demands.last?.ids?.count == 1 }
        XCTAssertEqual(engine.demands.last?.focused, model.floatingVideo?.participantID)
        let floatingID = engine.demands.last?.focused
        model.setMediaPresentation(.hidden)
        engine.onVideo?([])
        try await spin { engine.demands.last?.ids == [] && engine.demands.last?.focused == nil }
        model.setMediaPresentation(.floating)
        try await spin { engine.demands.last?.ids == Set([floatingID].compactMap { $0 }) }
        model.setMediaPresentation(.meeting)
        try await spin { engine.demands.last?.ids?.count == 6 }
        model.viewMode = .focused
        try await spin { engine.demands.last?.ids?.count == 1 }
        let focusID = engine.demands.last?.focused
        model.setMediaPresentation(.hidden); engine.onVideo?([])
        model.setMediaPresentation(.meeting)
        try await spin { engine.demands.last?.ids == Set([focusID].compactMap { $0 }) && engine.demands.last?.focused == focusID }
        model.viewMode = .audioOnly; model.setMediaPresentation(.floating)
        try await spin { engine.demands.last?.ids == [] && engine.demands.last?.focused == nil }
        XCTAssertEqual(model.viewMode, .audioOnly); XCTAssertTrue(model.snapshot.playoutOn)
        _ = await model.leave()
    }
    func testMinimizingSuspendsMediaAndPreservesEditorShellWithoutLeaving() async throws {
        let engine = DesktopTestEngine(), model = try model(engine)
        try await model.connect()
        engine.snapshot.participants = [.init(id: "remote", name: "Remote", cameraOn: true)]
        engine.onState?(engine.snapshot); model.viewMode = .gallery
        let meetingWindow = NativeDesktopMeetingWindow(model: model)
        meetingWindow.show()
        let native = try XCTUnwrap(NSApp.windows.first { $0.delegate === meetingWindow })
        native.miniaturize(nil)
        try await spin { native.isMiniaturized && model.mediaPresentation == .hidden && engine.demands.last?.ids == [] && engine.demands.last?.focused == nil }
        XCTAssertTrue(native.contentView is NSHostingView<NativeDesktopMeetingView>, "Temporary occlusion must preserve private Presenter editor state")
        XCTAssertEqual(engine.leaves, 0); XCTAssertTrue(model.snapshot.playoutOn)
        meetingWindow.show()
        try await spin { !native.isMiniaturized && native.contentView is NSHostingView<NativeDesktopMeetingView> && engine.demands.last?.ids == ["remote"] }
        meetingWindow.close(); _ = await model.leave()
    }
    func testFocusViewportSurvivesRendererRemountAndResetsForAnotherSource() {
        let viewport = NativeDesktopVideoViewport()
        viewport.select(participant: "a", source: .camera); viewport.zoom = 3; viewport.savedZoom = 3
        viewport.pan = CGSize(width: 0.3, height: -0.2); viewport.savedPan = viewport.pan
        viewport.select(participant: "a", source: .camera)
        XCTAssertEqual(viewport.zoom, 3); XCTAssertEqual(viewport.pan, CGSize(width: 0.3, height: -0.2))
        viewport.select(participant: "a", source: .screen)
        XCTAssertEqual(viewport.zoom, 1); XCTAssertEqual(viewport.savedZoom, 1)
        XCTAssertEqual(viewport.pan, .zero); XCTAssertEqual(viewport.savedPan, .zero)
    }
    func testLeaveBlocksReplacementUntilCancelledDetectionDrains() async throws {
        let preferences = UserDefaults(suiteName: "native-leave-barrier-\(UUID())")!
        let history = RoomHistoryStore(storage: DesktopMemoryStorage())
        let library = NativeDesktopLibrary(preferences: preferences, history: history, syncStorage: DesktopMemoryStorage())
        library.displayName = "Parity Test"
        let gate = GuestCompletion<Void>()
        var detections = 0, modelsCreated = 0
        let workspace = NativeDesktopWorkspace(library: library, detect: { _ in
            detections += 1
            if detections == 1 {
                // A detector can finish a non-cancellable network callback late.
                try await withCheckedThrowingContinuation { gate.install($0, timeout: 5) }
            }
            return .verified(.guest(endpoint: self.url))
        }, makeMeeting: { destination, name, title, quiet in
            modelsCreated += 1
            return NativeDesktopMeetingModel(destination: destination, name: name, title: title, quiet: quiet, engine: DesktopTestEngine())
        })
        workspace.join(url); try await spin { detections == 1 }
        let leaving = Task { await workspace.leave() }
        try await Task.sleep(for: .milliseconds(20))
        workspace.join(URL(string: "https://example.test/calls/replacement")!)
        XCTAssertTrue(workspace.preparing); XCTAssertEqual(detections, 1)
        gate.finish(.success(()))
        let clean = await leaving.value
        XCTAssertTrue(clean); XCTAssertNil(workspace.meeting); XCTAssertEqual(modelsCreated, 0)
        workspace.join(url)
        try await spin { workspace.meeting?.connected == true && !workspace.preparing }
        XCTAssertEqual(modelsCreated, 1); XCTAssertEqual(detections, 2)
        _ = await workspace.leave()
    }
    func testScheduledAdmissionRevokedByConnectionSuccessLeavesExactTarget() async throws {
        let preferences = UserDefaults(suiteName: "native-scheduled-admission-\(UUID())")!
        let history = RoomHistoryStore(storage: DesktopMemoryStorage())
        let library = NativeDesktopLibrary(preferences: preferences, history: history, syncStorage: DesktopMemoryStorage())
        library.displayName = "Scheduled Test"
        let engine = DesktopTestEngine()
        var allowed = true, finished = 0
        engine.onConnect = { allowed = false }
        let event = CalendarMeeting(id: "revoked", seriesID: "revoked", calendarID: "work", calendarTitle: "Work", title: "Revoked occurrence",
            start: Date(), end: Date().addingTimeInterval(3600), links: [url])
        let request = NativeDesktopScheduledJoin(meeting: event, admission: { allowed }, finish: { finished += 1 })
        let workspace = NativeDesktopWorkspace(library: library, detect: { _ in .verified(.guest(endpoint: self.url)) },
            makeMeeting: { destination, name, title, quiet in
                NativeDesktopMeetingModel(destination: destination, name: name, title: title, quiet: quiet, engine: engine)
            })
        workspace.join(url, engine: .guest, scheduled: request)
        try await spin { !workspace.preparing }
        XCTAssertEqual(engine.leaves, 1); XCTAssertNil(workspace.meeting)
        XCTAssertTrue(library.recent.isEmpty); XCTAssertEqual(finished, 1)
    }
}
