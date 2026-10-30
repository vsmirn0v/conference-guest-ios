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
    var testFactory: LKRTCPeerConnectionFactory?
    var factory: LKRTCPeerConnectionFactory? { testFactory }
    var incomingVideo: [NativeDesktopExternalVideo] { [] }
    var snapshot = NativeDesktopExternalSnapshot()
    var microphoneReadinessPolicy: (() -> Bool)?
    var initialMicrophoneReadiness = false
    private var preparing: Task<Void, Error>?
    var preparationBeforeConnection = false
    var microphoneCommands: [Bool] = []
    var completedMicrophoneCommands = 0
    var cameraCommands: [Bool] = []
    var leaves = 0
    var leaveRequests = 0
    private var retired = false
    var mutedPreparationCalls = 0
    var recoveryReadiness: [Bool] = []
    var onMutedPreparation: (() async throws -> Void)?
    var clean = true
    var demands: [(ids: Set<String>?, focused: String?)] = []
    var cameraDemands: [Bool] = []
    var screenOnlySupported = true
    var supportsScreenOnlyVideo: Bool { screenOnlySupported }
    var onConnect: (() async throws -> Void)?
    var onMicrophoneEnable: (() async throws -> Void)?
    var onMicrophoneDisable: (() async throws -> Void)?
    var onCameraEnable: (() async throws -> Void)?
    var onLeaveCleanup: (() async -> Void)?
    func connect(invitation: URL, name: String, quiet: Bool) async throws {
        retired = false
        snapshot.phase = .connecting; onState?(snapshot)
        try await onConnect?()
        try Task.checkCancellation()
        if !quiet, microphoneReadinessPolicy?() == true {
            let task = Task { @MainActor in try await self.prepareMutedCaptureForAccessories() }
            preparing = task; try await task.value
            preparationBeforeConnection = true
        }
        guard snapshot.phase == .connecting else { throw CancellationError() }
        snapshot = .init(phase: .connected, playoutOn: !quiet); onState?(snapshot)
    }
    func reconnect() async throws {}
    func prepareMutedCaptureForAccessories() async throws {
        mutedPreparationCalls += 1; try await onMutedPreparation?()
    }
    func setMicrophoneReadinessForRecovery(_ enabled: Bool) {
        if snapshot.phase == .idle || snapshot.phase == .connecting { initialMicrophoneReadiness = enabled }
        else { recoveryReadiness.append(enabled) }
    }
    func setMicrophone(_ enabled: Bool) async throws {
        microphoneCommands.append(enabled)
        if enabled { try await onMicrophoneEnable?() }
        else { try await onMicrophoneDisable?() }
        try await Task.sleep(for: .milliseconds(25))
        snapshot.microphoneOn = enabled; completedMicrophoneCommands += 1; onState?(snapshot)
    }
    func setCamera(_ enabled: Bool) async throws {
        cameraCommands.append(enabled)
        if enabled { try await onCameraEnable?() }
        try Task.checkCancellation()
        snapshot.cameraOn = enabled; onState?(snapshot)
    }
    func setPlayout(_ enabled: Bool) async throws { snapshot.playoutOn = enabled; onState?(snapshot) }
    func setScreenTrack(_ track: LKRTCVideoTrack?) async throws { snapshot.sharing = track != nil; onState?(snapshot) }
    func setVisibleParticipantIDs(_ ids: Set<String>?, focusedParticipantID: String?) async throws { demands.append((ids, focusedParticipantID)) }
    func setVisibleParticipantIDs(_ ids: Set<String>?, focusedParticipantID: String?, cameras: Bool) async throws {
        cameraDemands.append(cameras); demands.append((ids, focusedParticipantID))
    }
    func leave() async -> Bool {
        leaveRequests += 1
        if retired { return clean }
        snapshot.phase = .leaving
        _ = try? await preparing?.value
        leaves += 1; await onLeaveCleanup?()
        retired = true
        snapshot.phase = clean ? .left : .failed; onState?(snapshot); return clean
    }
}
private final class DesktopMemoryStorage: RoomHistoryStorage, @unchecked Sendable {
    var value: Data?
    func read() -> Data? { value }
    func write(_ data: Data) throws { value = data }
}

@MainActor private final class DesktopContinuationTransport: MeetingContinuationTransport {
    var failWithdrawal = false
    func connect(account: String) async throws {}
    func jams() async throws -> [ActiveJam] { [] }
    func publish(_ jam: ActiveJam) async throws {}
    func withdraw(deviceID: String, sessionID: UUID?) async throws {
        if failWithdrawal { throw ContinuationError.unavailable }
    }
    func claim(_ transfer: JamTransfer) async throws {}
    func transfer(sourceSession: UUID) async throws -> JamTransfer? { nil }
    func transition(_ transfer: JamTransfer, to phase: JamTransfer.Phase, actor: String) async throws -> JamTransfer {
        var result = transfer; result.phase = phase; return result
    }
    func clear() async throws {}
}
private final class DesktopActivitySpy: NSUserActivity {
    var advertisements = 0
    var invalidations = 0
    override func becomeCurrent() { advertisements += 1 }
    override func invalidate() { invalidations += 1 }
}

@MainActor final class DesktopParityTests: XCTestCase {
    private let url = URL(string: "https://example.test/calls/native-parity")!
    private func model(_ engine: DesktopTestEngine) throws -> NativeDesktopMeetingModel {
        NativeDesktopMeetingModel(destination: try .verified(url, engine: .guest), name: "Parity Test", title: "Fixture",
            engine: engine, joinReadiness: .init(microphone: .off, camera: .off), power: joinTestPower())
    }
    private func spin(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 { if predicate() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("The asynchronous operation did not complete")
    }
    func testJoinMicReadinessUsesMutedAccessoryPathOnlyWhenAllowed() async throws {
        for enabled in [false, true] {
            let engine = DesktopTestEngine()
            let model = NativeDesktopMeetingModel(destination: try .verified(url, engine: .guest), name: "Fixture", title: nil,
                engine: engine, joinReadiness: .init(microphone: enabled ? .alsoOnBattery : .off, camera: .off), power: joinTestPower())
            try await model.connect(); await model.waitForJoinReadinessForTesting()
            XCTAssertEqual(engine.mutedPreparationCalls, enabled ? 1 : 0)
            XCTAssertEqual(engine.preparationBeforeConnection, enabled, "Readiness must finish before transport/playout begins")
            XCTAssertTrue(engine.microphoneCommands.isEmpty); XCTAssertFalse(model.snapshot.microphoneOn)
            XCTAssertTrue(engine.cameraCommands.isEmpty); XCTAssertFalse(model.snapshot.cameraOn)
            model.reconnect(); await model.waitForMediaActionsForTesting()
            XCTAssertEqual(engine.mutedPreparationCalls, enabled ? 1 : 0, "Reconnect must not prime again")
            let left = await model.leave(); XCTAssertTrue(left)
        }
    }
    func testOtherProvidersKeepExplicitHeadsetPreparationWithoutAdoptingGuestDefaults() async throws {
        let invitations: [(MeetingEngineKind, URL)] = [
            (.telemost, URL(string: "https://telemost.yandex.ru/j/readiness-fixture")!),
            (.trueconf, URL(string: "https://example.test/c/readiness-fixture")!),
            (.community, URL(string: "https://rock.glowsoft.ru/jams/test")!)]
        for (kind, url) in invitations {
            for explicit in [false, true] {
                for mode in NativeDesktopMediaReadinessMode.allCases {
                    let engine = DesktopTestEngine()
                    let model = NativeDesktopMeetingModel(destination: try .verified(url, engine: kind), name: "Provider fixture", title: nil,
                        engine: engine, joinReadiness: .init(microphone: mode, camera: .alsoOnBattery, microphoneExplicit: explicit),
                        power: joinTestPower())
                    try await model.connect(); await model.waitForJoinReadinessForTesting()
                    XCTAssertEqual(engine.mutedPreparationCalls, explicit && mode != .off ? 1 : 0)
                    XCTAssertTrue(engine.cameraCommands.isEmpty)
                    let left = await model.leave(); XCTAssertTrue(left)
                }
            }
        }
    }
    func testJoinDeadlineCoversSuspendedEngineAfterConnectedCallbackAndRejectsLateMedia() async throws {
        let engine = DesktopTestEngine()
        var startupReply: CheckedContinuation<Void, Never>?, cleanupReply: CheckedContinuation<Void, Never>?
        engine.onConnect = {
            engine.snapshot.phase = .connected; engine.onState?(engine.snapshot)
            await withCheckedContinuation { startupReply = $0 }
        }
        engine.onLeaveCleanup = { await withCheckedContinuation { cleanupReply = $0 } }
        let model = NativeDesktopMeetingModel(destination: try .verified(url, engine: .guest), name: "Deadline fixture", title: "Original title",
            engine: engine, joinReadiness: .init(microphone: .off, camera: .off), joinTimeout: 0.05, power: joinTestPower())
        let state = engine.onState, video = engine.onVideo, camera = engine.onLocalCamera, title = engine.onTitle
        var returned = false, failure: Error?
        let joining = Task {
            do { try await model.connect() } catch { failure = error }
            returned = true
        }
        try await spin { startupReply != nil && returned && cleanupReply != nil }
        guard returned else {
            startupReply?.resume(); startupReply = nil; cleanupReply?.resume(); cleanupReply = nil; joining.cancel(); return
        }
        if case .timedOut? = failure as? GuestTransportError {} else { XCTFail("Expected the outer join deadline") }
        XCTAssertFalse(model.connected)
        let factory = LKRTCPeerConnectionFactory(), track = factory.videoTrack(with: factory.videoSource(), trackId: "late-callback")
        state?(.init(phase: .connected, microphoneOn: true, cameraOn: true, playoutOn: true))
        video?([.init(id: "late", participantID: "late", source: .camera, track: track)])
        camera?(track); title?("Late title")
        XCTAssertFalse(model.connected); XCTAssertFalse(model.snapshot.microphoneOn); XCTAssertFalse(model.snapshot.cameraOn)
        XCTAssertNil(model.localCamera); XCTAssertTrue(model.videos.isEmpty); XCTAssertEqual(model.title, "Original title")
        model.toggleMicrophone(); model.toggleCamera()
        XCTAssertTrue(engine.microphoneCommands.isEmpty && engine.cameraCommands.isEmpty)
        var retired = false
        let leaving = Task { let clean = await model.leave(); retired = true; return clean }
        await Task.yield(); await Task.yield(); XCTAssertFalse(retired)
        startupReply?.resume(); startupReply = nil
        await Task.yield(); XCTAssertFalse(retired, "Startup completion alone is not affirmative retirement")
        engine.onLeaveCleanup = nil; cleanupReply?.resume(); cleanupReply = nil
        let clean = await leaving.value; XCTAssertTrue(clean); XCTAssertEqual(engine.leaves, 1); XCTAssertEqual(engine.leaveRequests, 2)
        await joining.value
    }
    func testCancelingJoinStartsEngineRetirementBeforeDrainingStartup() async throws {
        let engine = DesktopTestEngine(); var startupReply: CheckedContinuation<Void, Never>?
        engine.onConnect = { await withCheckedContinuation { startupReply = $0 } }
        engine.onLeaveCleanup = { startupReply?.resume(); startupReply = nil }
        let model = try model(engine)
        let joining = Task { try await model.connect() }
        try await spin { startupReply != nil }
        joining.cancel()
        do { try await joining.value; XCTFail("Canceled join succeeded") } catch { XCTAssertTrue(error is CancellationError) }
        let clean = await model.leave()
        XCTAssertTrue(clean); XCTAssertEqual(engine.leaves, 1); XCTAssertEqual(engine.leaveRequests, 2)
        XCTAssertFalse(model.connected); XCTAssertFalse(model.snapshot.microphoneOn)
    }
    func testTimedOutJoinBlocksWorkspaceReplacementUntilCleanupAndKeepsFailedCleanupBlocked() async throws {
        for cleanupSucceeds in [false, true] {
            let preferences = UserDefaults(suiteName: "native-join-deadline-\(UUID())")!
            let library = NativeDesktopLibrary(preferences: preferences, history: RoomHistoryStore(storage: DesktopMemoryStorage()),
                                               syncStorage: DesktopMemoryStorage())
            library.displayName = "Deadline workspace"
            let engine = DesktopTestEngine(); engine.clean = cleanupSucceeds
            var startupReply: CheckedContinuation<Void, Never>?, cleanupReply: CheckedContinuation<Void, Never>?, created = 0
            engine.onConnect = { await withCheckedContinuation { startupReply = $0 } }
            engine.onLeaveCleanup = { await withCheckedContinuation { cleanupReply = $0 } }
            let workspace = NativeDesktopWorkspace(library: library, detect: { _ in .verified(.guest(endpoint: self.url)) },
                makeMeeting: { destination, name, title, quiet in
                    created += 1
                    return NativeDesktopMeetingModel(destination: destination, name: name, title: title, quiet: quiet,
                        engine: created == 1 ? engine : DesktopTestEngine(), joinReadiness: .init(microphone: .off, camera: .off),
                        joinTimeout: created == 1 ? 0.05 : 45, power: joinTestPower())
                })
            workspace.join(url, engine: .guest)
            try await spin { startupReply != nil && cleanupReply != nil }
            XCTAssertTrue(workspace.preparing); XCTAssertNotNil(workspace.error)
            workspace.join(URL(string: "https://example.test/calls/replacement")!, engine: .guest)
            XCTAssertEqual(created, 1)
            startupReply?.resume(); startupReply = nil
            await Task.yield(); XCTAssertTrue(workspace.preparing)
            engine.onLeaveCleanup = nil; cleanupReply?.resume(); cleanupReply = nil
            try await spin { !workspace.preparing }
            XCTAssertEqual(workspace.meeting == nil, cleanupSucceeds)
            workspace.join(URL(string: "https://example.test/calls/replacement")!, engine: .guest)
            if cleanupSucceeds {
                try await spin { created == 2 && workspace.meeting?.connected == true && !workspace.preparing }
                let clean = await workspace.leave(); XCTAssertTrue(clean)
            } else {
                await Task.yield(); XCTAssertEqual(created, 1)
                let clean = await workspace.leave(); XCTAssertFalse(clean)
            }
        }
    }
    func testCameraMetadataCompletesBeforeEngineConnectionWithoutStartingCapture() async throws {
        let engine = DesktopTestEngine()
        var release: CheckedContinuation<Void, Never>?, reads = 0, completed = false, connects = 0
        let metadata = NativeDesktopCameraMetadataPreparation(authorized: { true }, read: { _ in
            reads += 1; await withCheckedContinuation { release = $0 }; completed = true
        })
        engine.onConnect = { XCTAssertTrue(completed); connects += 1 }
        let model = NativeDesktopMeetingModel(destination: try .verified(url, engine: .guest), name: "Metadata fixture", title: nil,
            engine: engine, joinReadiness: .init(microphone: .off, camera: .whenPluggedIn),
            joinCameraPrime: .init(authorized: { false }), cameraMetadata: metadata, power: joinTestPower())
        let warming = Task { try await metadata.prepare(eligible: { true }, deviceID: nil) }
        try await spin { release != nil }
        let connecting = Task { try await model.connect() }
        await Task.yield(); await Task.yield()
        XCTAssertEqual(reads, 1); XCTAssertEqual(connects, 0)
        XCTAssertTrue(engine.microphoneCommands.isEmpty && engine.cameraCommands.isEmpty)
        release?.resume(); release = nil
        try await connecting.value
        _ = try await warming.value
        XCTAssertEqual(connects, 1)
        let state = (model.joinReadinessReport["cameraMetadata"] as? [String: Any])?["state"] as? String
        // Foreground discovery may finish during another join preflight await;
        // an already-completed read needs no additional barrier or discovery.
        XCTAssertTrue(state == "drained" || state == "skipped")
        let left = await model.leave(); XCTAssertTrue(left)
    }
    func testColdJoinMetadataFallbackRequiresExistingPermissionAndEligiblePolicy() async throws {
        for scenario in 0..<8 {
            let engine = DesktopTestEngine(); var reads = 0
            let metadata = NativeDesktopCameraMetadataPreparation(authorized: { scenario != 4 }, read: { _ in reads += 1 })
            let mode: NativeDesktopMediaReadinessMode = scenario == 1 ? .off : .whenPluggedIn
            let invitation = scenario == 7 ? URL(string: "https://telemost.yandex.ru/j/12345678901234")! : url
            let destination = try JoinDestination.verified(invitation, engine: scenario == 7 ? .telemost : .guest)
            let model = NativeDesktopMeetingModel(destination: destination, name: "Metadata skip fixture", title: nil,
                quiet: scenario == 5, engine: engine, joinReadiness: .init(microphone: .off, camera: mode),
                joinCameraPrime: .init(authorized: { false }), cameraMetadata: metadata,
                power: joinTestPower(pluggedIn: scenario != 2, lowPowerMode: scenario == 3))
            if scenario == 6 { model.display = .audioOnly }
            try await model.connect(); await model.waitForJoinReadinessForTesting()
            XCTAssertEqual(reads, scenario == 0 ? 1 : 0, "Only an eligible authorized Guest video join may need cold metadata")
            XCTAssertTrue(engine.microphoneCommands.isEmpty && engine.cameraCommands.isEmpty)
            let left = await model.leave(); XCTAssertTrue(left)
        }
    }
    func testColdMetadataFallbackPreparesOnlyTheMissingSelectionBeforeConnection() async throws {
        let selection = UserDefaults.standard.string(forKey: "nativeDesktop.cameraID")
        for scenario in 0..<3 {
            let engine = DesktopTestEngine(), capture = JoinPrimeCapture()
            engine.testFactory = LKRTCPeerConnectionFactory()
            var reads = 0
            let metadata = NativeDesktopCameraMetadataPreparation(authorized: { true }, read: { _ in reads += 1 })
            if scenario != 0 {
                _ = try await metadata.prepare(eligible: { true }, deviceID: scenario == 1 ? selection : "unselected-fixture-camera")
            }
            engine.onConnect = { XCTAssertTrue(metadata.isPrepared(deviceID: selection)) }
            let model = NativeDesktopMeetingModel(destination: try .verified(url, engine: .guest), name: "Foreground metadata fixture", title: nil,
                engine: engine, joinReadiness: .init(microphone: .off, camera: .whenPluggedIn),
                joinCameraPrime: .init(authorized: { true }, makeCapture: { _ in capture }), cameraMetadata: metadata,
                power: joinTestPower())
            try await model.connect(); await model.waitForJoinReadinessForTesting()
            XCTAssertEqual(reads, scenario == 2 ? 2 : 1, "A completed matching foreground read is reused")
            XCTAssertEqual(capture.starts, 1)
            XCTAssertTrue(engine.cameraCommands.isEmpty)
            let clean = await model.leave(); XCTAssertTrue(clean)
        }
    }
    func testCameraMetadataRequiresFrozenAndLatestPolicyAndSkipsUnstartedPowerLoss() async throws {
        for frozenEnabled in [false, true] {
            let engine = DesktopTestEngine(); var reads = 0, policyReads = 0
            let metadata = NativeDesktopCameraMetadataPreparation(authorized: { true }, read: { _ in reads += 1 })
            let model = NativeDesktopMeetingModel(destination: try .verified(url, engine: .guest), name: "Metadata policy fixture", title: nil,
                engine: engine, joinCameraPrime: .init(authorized: { false }), cameraMetadata: metadata,
                power: joinTestPower(), readinessPolicy: {
                    policyReads += 1
                    let enabled = policyReads == 1 ? frozenEnabled : !frozenEnabled
                    return .init(microphone: .off, camera: enabled ? .whenPluggedIn : .off)
                })
            try await model.connect(); XCTAssertEqual(reads, 0)
            let left = await model.leave(); XCTAssertTrue(left)
        }
        let engine = DesktopTestEngine(); var reads = 0
        var state = NativeDesktopPowerSnapshot(pluggedIn: true, lowPowerMode: false)
        var changedPower: (@MainActor () -> Void)?
        let metadata = NativeDesktopCameraMetadataPreparation(authorized: { state.lowPowerMode = true; changedPower?(); return true }, read: { _ in reads += 1 })
        let model = NativeDesktopMeetingModel(destination: try .verified(url, engine: .guest), name: "Unstarted metadata fixture", title: nil,
            engine: engine, joinReadiness: .init(), joinCameraPrime: .init(authorized: { false }), cameraMetadata: metadata,
            power: .init(read: { state }, observe: { changedPower = $0; return {} }))
        try await model.connect(); XCTAssertEqual(reads, 0)
        let left = await model.leave(); XCTAssertTrue(left)
    }
    func testPowerLossDrainsEnteredMetadataThenJoinsWithoutSensorPrime() async throws {
        let engine = DesktopTestEngine(), capture = JoinPrimeCapture()
        var release: CheckedContinuation<Void, Never>?, connects = 0
        var state = NativeDesktopPowerSnapshot(pluggedIn: true, lowPowerMode: false)
        var notify: (@MainActor () -> Void)?
        let power = NativeDesktopPowerMonitor(read: { state }, observe: { notify = $0; return {} })
        let metadata = NativeDesktopCameraMetadataPreparation(authorized: { true }, read: { _ in await withCheckedContinuation { release = $0 } })
        engine.onConnect = { connects += 1 }
        let model = NativeDesktopMeetingModel(destination: try .verified(url, engine: .guest), name: "Entered metadata fixture", title: nil,
            engine: engine, joinReadiness: .init(), joinCameraPrime: .init(authorized: { true }, makeCapture: { _ in capture }),
            cameraMetadata: metadata, power: power)
        let warming = Task { try await metadata.prepare(eligible: { true }, deviceID: nil) }
        try await spin { release != nil }
        let connecting = Task { try await model.connect() }; await Task.yield(); await Task.yield()
        state.lowPowerMode = true; notify?(); await Task.yield()
        XCTAssertEqual(connects, 0, "An entered AVFoundation read remains a barrier after policy withdrawal")
        release?.resume(); release = nil
        try await connecting.value; _ = try await warming.value; await model.waitForJoinReadinessForTesting()
        XCTAssertEqual(connects, 1); XCTAssertEqual(capture.starts, 0)
        let left = await model.leave(); XCTAssertTrue(left)
    }
    func testCanceledJoinRetainsMetadataBarrierForLaterCameraOffJoin() async throws {
        let firstEngine = DesktopTestEngine(), secondEngine = DesktopTestEngine()
        var release: CheckedContinuation<Void, Never>?, firstConnects = 0, secondConnects = 0, reads = 0
        let metadata = NativeDesktopCameraMetadataPreparation(authorized: { true }, read: { _ in
            reads += 1; await withCheckedContinuation { release = $0 }
        })
        firstEngine.onConnect = { firstConnects += 1 }; secondEngine.onConnect = { secondConnects += 1 }
        let first = NativeDesktopMeetingModel(destination: try .verified(url, engine: .guest), name: "Canceled metadata fixture", title: nil,
            engine: firstEngine, joinReadiness: .init(), cameraMetadata: metadata, power: joinTestPower())
        let warming = Task { try await metadata.prepare(eligible: { true }, deviceID: nil) }
        try await spin { release != nil }
        let connecting = Task { try await first.connect() }; await Task.yield(); await Task.yield()
        let left = await first.leave(); XCTAssertTrue(left)
        do { try await connecting.value; XCTFail("Canceled join connected") } catch {}
        let second = NativeDesktopMeetingModel(destination: try .verified(url, engine: .guest), name: "Off metadata fixture", title: nil,
            engine: secondEngine, joinReadiness: .init(microphone: .off, camera: .off), cameraMetadata: metadata, power: joinTestPower())
        let later = Task { try await second.connect() }; await Task.yield(); await Task.yield()
        XCTAssertEqual(firstConnects, 0); XCTAssertEqual(secondConnects, 0)
        release?.resume(); release = nil
        try await later.value; _ = try await warming.value
        XCTAssertEqual(reads, 1); XCTAssertEqual(secondConnects, 1)
        let secondLeft = await second.leave(); XCTAssertTrue(secondLeft)
    }
    func testJoinReadinessPowerMatrixWithoutRealDevicesOrPowerChanges() async throws {
        for mode in NativeDesktopMediaReadinessMode.allCases {
            for pluggedIn in [false, true] {
                for lowPowerMode in [false, true] {
                    let engine = DesktopTestEngine(), capture = JoinPrimeCapture()
                    engine.testFactory = LKRTCPeerConnectionFactory()
                    let prime = NativeDesktopJoinCameraPrime(authorized: { true }, makeCapture: { _ in capture })
                    let model = NativeDesktopMeetingModel(destination: try .verified(url, engine: .guest), name: "Power fixture", title: nil,
                        engine: engine, joinReadiness: .init(microphone: mode, camera: mode), joinCameraPrime: prime, cameraMetadata: await joinTestCameraMetadata(),
                        power: joinTestPower(pluggedIn: pluggedIn, lowPowerMode: lowPowerMode))
                    try await model.connect(); await model.waitForJoinReadinessForTesting()
                    let expected = mode.allows(.init(pluggedIn: pluggedIn, lowPowerMode: lowPowerMode)) ? 1 : 0
                    XCTAssertEqual(engine.mutedPreparationCalls, expected)
                    XCTAssertEqual(engine.preparationBeforeConnection, expected == 1)
                    XCTAssertEqual(capture.starts, expected); XCTAssertEqual(capture.stops, expected)
                    XCTAssertTrue(engine.microphoneCommands.isEmpty); XCTAssertTrue(engine.cameraCommands.isEmpty)
                    let left = await model.leave(); XCTAssertTrue(left)
                }
            }
        }
    }
    func testPowerLossDuringInitialOwnerCreationPreventsPendingPreparation() async throws {
        for mode in [NativeDesktopMediaReadinessMode.whenPluggedIn, .alsoOnBattery] {
            let engine = DesktopTestEngine()
            var state = NativeDesktopPowerSnapshot(pluggedIn: true, lowPowerMode: false)
            var notify: (@MainActor () -> Void)?, ownerReady: CheckedContinuation<Void, Never>?
            let power = NativeDesktopPowerMonitor(read: { state }, observe: { notify = $0; return { notify = nil } })
            engine.onConnect = { await withCheckedContinuation { ownerReady = $0 } }
            let model = NativeDesktopMeetingModel(destination: try .verified(url, engine: .guest), name: "Initial power fixture", title: nil,
                engine: engine, joinReadiness: .init(microphone: mode, camera: .off), power: power)
            let connecting = Task { try await model.connect() }
            try await spin { ownerReady != nil }
            XCTAssertTrue(engine.initialMicrophoneReadiness)
            if mode == .whenPluggedIn { state.pluggedIn = false } else { state.lowPowerMode = true }
            notify?()
            XCTAssertFalse(engine.initialMicrophoneReadiness, "A connecting power event withdraws future preparation")
            ownerReady?.resume(); ownerReady = nil
            try await connecting.value; await model.waitForJoinReadinessForTesting()
            XCTAssertEqual(engine.mutedPreparationCalls, 0); XCTAssertFalse(engine.preparationBeforeConnection)
            XCTAssertTrue(engine.microphoneCommands.isEmpty); XCTAssertTrue(model.snapshot.playoutOn)
            let left = await model.leave(); XCTAssertTrue(left)
        }
    }
    func testPowerLossCancelsPrivateCameraButKeepsLiveAudioUntilRecoveryPolicyIsRead() async throws {
        let engine = DesktopTestEngine(), capture = JoinPrimeCapture()
        engine.testFactory = LKRTCPeerConnectionFactory()
        var state = NativeDesktopPowerSnapshot(pluggedIn: true, lowPowerMode: false)
        var notify: (@MainActor () -> Void)?
        let power = NativeDesktopPowerMonitor(read: { state }, observe: { notify = $0; return { notify = nil } })
        capture.starting = {
            while capture.cancellations == 0 { try await Task.sleep(for: .milliseconds(10)) }
            throw CancellationError()
        }
        let prime = NativeDesktopJoinCameraPrime(authorized: { true }, makeCapture: { _ in capture })
        let model = NativeDesktopMeetingModel(destination: try .verified(url, engine: .guest), name: "Power fixture", title: nil,
            engine: engine, joinReadiness: .init(), joinCameraPrime: prime, cameraMetadata: await joinTestCameraMetadata(), power: power)
        try await model.connect(); try await spin { capture.starts == 1 && engine.mutedPreparationCalls == 1 }
        model.toggleMicrophone(); await model.waitForMediaActionsForTesting()
        state.pluggedIn = false; notify?()
        XCTAssertGreaterThan(capture.cancellations, 0, "Power notification cancels pending private capture immediately")
        await model.waitForJoinReadinessForTesting()
        XCTAssertTrue(model.snapshot.microphoneOn); XCTAssertEqual(engine.microphoneCommands, [true])
        XCTAssertTrue(engine.recoveryReadiness.isEmpty, "Power loss must not change the live microphone graph")
        engine.snapshot.phase = .reconnecting; engine.onState?(engine.snapshot)
        XCTAssertEqual(engine.recoveryReadiness, [false], "Recovery reads current power before restoring readiness-only input")
        XCTAssertEqual(engine.microphoneCommands, [true], "Updating recovery intent must not mute user media")
        let left = await model.leave(); XCTAssertTrue(left); XCTAssertNil(notify)
    }
    func testPowerChangesDuringReconnectRefreshOnlyPreparationIntent() async throws {
        let engine = DesktopTestEngine()
        var state = NativeDesktopPowerSnapshot(pluggedIn: true, lowPowerMode: false)
        var notify: (@MainActor () -> Void)?
        let power = NativeDesktopPowerMonitor(read: { state }, observe: { notify = $0; return { notify = nil } })
        let model = NativeDesktopMeetingModel(destination: try .verified(url, engine: .guest), name: "Recovery power fixture", title: nil,
            engine: engine, joinReadiness: .init(microphone: .whenPluggedIn, camera: .off), power: power)
        try await model.connect(); await model.waitForJoinReadinessForTesting()
        model.toggleMicrophone(); await model.waitForMediaActionsForTesting()
        engine.snapshot.phase = .reconnecting; engine.onState?(engine.snapshot)
        XCTAssertEqual(engine.recoveryReadiness, [true])

        state.pluggedIn = false; notify?()
        XCTAssertEqual(engine.recoveryReadiness, [true, false], "Unplugging during backoff withdraws readiness-only restoration")
        state.pluggedIn = true; notify?()
        state.lowPowerMode = true; notify?()
        XCTAssertEqual(engine.recoveryReadiness, [true, false, true, false], "Low Power also blocks replacement preparation")
        state.lowPowerMode = false; notify?()
        XCTAssertEqual(engine.recoveryReadiness, [true, false, true, false, true])
        XCTAssertEqual(engine.mutedPreparationCalls, 1, "Power events never perform new activation on the current graph")
        XCTAssertEqual(engine.microphoneCommands, [true], "Power events preserve explicit microphone intent")
        XCTAssertTrue(engine.cameraCommands.isEmpty); XCTAssertTrue(model.snapshot.playoutOn)
        XCTAssertEqual(engine.leaves, 0, "Policy observation never rebuilds or retires the current owner")

        engine.snapshot.phase = .connected; engine.onState?(engine.snapshot)
        state.lowPowerMode = true; notify?()
        XCTAssertEqual(engine.recoveryReadiness.count, 5, "Connected audio is unaffected by later power changes")
        XCTAssertTrue(model.snapshot.microphoneOn); XCTAssertTrue(model.snapshot.playoutOn)
        let left = await model.leave(); XCTAssertTrue(left); XCTAssertNil(notify)
    }
    func testLowPowerCancelsPrivateCameraEvenWithBatteryOptIn() async throws {
        let engine = DesktopTestEngine(), capture = JoinPrimeCapture()
        engine.testFactory = LKRTCPeerConnectionFactory()
        var state = NativeDesktopPowerSnapshot(pluggedIn: true, lowPowerMode: false)
        var notify: (@MainActor () -> Void)?
        let power = NativeDesktopPowerMonitor(read: { state }, observe: { notify = $0; return { notify = nil } })
        capture.starting = {
            while capture.cancellations == 0 { try await Task.sleep(for: .milliseconds(10)) }
            throw CancellationError()
        }
        let prime = NativeDesktopJoinCameraPrime(authorized: { true }, makeCapture: { _ in capture })
        let model = NativeDesktopMeetingModel(destination: try .verified(url, engine: .guest), name: "Power fixture", title: nil,
            engine: engine, joinReadiness: .init(microphone: .alsoOnBattery, camera: .alsoOnBattery), joinCameraPrime: prime, cameraMetadata: await joinTestCameraMetadata(), power: power)
        try await model.connect(); try await spin { capture.starts == 1 }
        state.lowPowerMode = true; notify?()
        XCTAssertGreaterThan(capture.cancellations, 0)
        await model.waitForJoinReadinessForTesting()
        XCTAssertEqual(capture.stops, 1); XCTAssertTrue(engine.microphoneCommands.isEmpty)
        state.lowPowerMode = false; notify?(); await Task.yield()
        XCTAssertEqual(capture.starts, 1, "Eligibility returning does not repeat preparation")
        let left = await model.leave(); XCTAssertTrue(left)
    }
    func testMicrophonePolicyChangesApplyAtRecoveryAndTogglesDoNotReprepare() async throws {
        let engine = DesktopTestEngine()
        var policy = NativeDesktopJoinReadinessPolicy(microphone: .alsoOnBattery, camera: .off)
        let model = NativeDesktopMeetingModel(destination: try .verified(url, engine: .guest), name: "Policy fixture", title: nil,
            engine: engine, power: joinTestPower(pluggedIn: false), readinessPolicy: { policy })
        try await model.connect(); await model.waitForJoinReadinessForTesting()
        for _ in 0..<3 { model.toggleMicrophone(); await model.waitForMediaActionsForTesting() }
        XCTAssertEqual(engine.mutedPreparationCalls, 1)
        XCTAssertEqual(engine.microphoneCommands, [true, false, true])
        XCTAssertEqual(engine.leaves, 0, "Quick toggles retain the same meeting/audio owner")
        policy.microphone = .off
        XCTAssertTrue(model.snapshot.microphoneOn); XCTAssertTrue(engine.recoveryReadiness.isEmpty)
        engine.snapshot.phase = .reconnecting; engine.onState?(engine.snapshot)
        XCTAssertEqual(engine.recoveryReadiness, [false])
        XCTAssertEqual(engine.microphoneCommands, [true, false, true])
        let left = await model.leave(); XCTAssertTrue(left)
    }
    func testAudioOnlyQuietJoinSkipsBothReadinessExperiments() async throws {
        let engine = DesktopTestEngine()
        let model = NativeDesktopMeetingModel(destination: try .verified(url, engine: .guest), name: "Fixture", title: nil,
            quiet: true, engine: engine, joinReadiness: .init(microphone: .alsoOnBattery, camera: .alsoOnBattery), power: joinTestPower())
        try await model.connect(); await model.waitForJoinReadinessForTesting()
        XCTAssertEqual(engine.mutedPreparationCalls, 0)
        XCTAssertEqual(model.joinReadinessReport["reason"] as? String, "meetingPolicy")
        let left = await model.leave(); XCTAssertTrue(left)
    }
    func testAudioOnlyViewSkipsCameraPrimeAndPreservesMicrophoneReadiness() async throws {
        let engine = DesktopTestEngine(), capture = JoinPrimeCapture()
        engine.testFactory = LKRTCPeerConnectionFactory()
        let prime = NativeDesktopJoinCameraPrime(authorized: { true }, makeCapture: { _ in capture })
        let model = NativeDesktopMeetingModel(destination: try .verified(url, engine: .guest), name: "Fixture", title: nil,
            engine: engine, joinReadiness: .init(microphone: .alsoOnBattery, camera: .alsoOnBattery), joinCameraPrime: prime, cameraMetadata: await joinTestCameraMetadata(), power: joinTestPower())
        model.display = .audioOnly
        try await model.connect(); await model.waitForJoinReadinessForTesting()
        XCTAssertEqual(capture.starts, 0); XCTAssertEqual(capture.stops, 0)
        XCTAssertEqual(engine.mutedPreparationCalls, 1)
        XCTAssertEqual((model.joinReadinessReport["camera"] as? [String: Any])?["reason"] as? String, "audioOnly")
        XCTAssertTrue(engine.microphoneCommands.isEmpty); XCTAssertTrue(engine.cameraCommands.isEmpty)
        XCTAssertFalse(model.snapshot.microphoneOn); XCTAssertNil(model.localCamera)
        let left = await model.leave(); XCTAssertTrue(left)
    }
    func testSwitchingToAudioOnlyCancelsPendingCameraPrimeWithoutCancellingMicrophoneReadiness() async throws {
        let engine = DesktopTestEngine(), capture = JoinPrimeCapture()
        engine.testFactory = LKRTCPeerConnectionFactory()
        capture.starting = {
            while capture.cancellations == 0 { try await Task.sleep(for: .milliseconds(10)) }
            throw CancellationError()
        }
        let prime = NativeDesktopJoinCameraPrime(authorized: { true }, makeCapture: { _ in capture })
        let model = NativeDesktopMeetingModel(destination: try .verified(url, engine: .guest), name: "Fixture", title: nil,
            engine: engine, joinReadiness: .init(microphone: .alsoOnBattery, camera: .alsoOnBattery), joinCameraPrime: prime, cameraMetadata: await joinTestCameraMetadata(), power: joinTestPower())
        try await model.connect(); try await spin { capture.starts == 1 }
        model.display = .audioOnly
        await model.waitForJoinReadinessForTesting()
        XCTAssertEqual(capture.starts, 1); XCTAssertEqual(capture.stops, 1)
        XCTAssertFalse(capture.frameReady)
        XCTAssertEqual(engine.mutedPreparationCalls, 1)
        let cameraReport = model.joinReadinessReport["camera"] as? [String: Any]
        XCTAssertEqual(cameraReport?["state"] as? String, "cancelled")
        XCTAssertEqual(cameraReport?["stopped"] as? Bool, true)
        XCTAssertTrue(engine.microphoneCommands.isEmpty); XCTAssertTrue(engine.cameraCommands.isEmpty)
        XCTAssertFalse(model.snapshot.microphoneOn); XCTAssertNil(model.localCamera)
        model.display = .all; await Task.yield()
        XCTAssertEqual(capture.starts, 1, "Returning to video view must not restart the one-shot prime")
        let left = await model.leave(); XCTAssertTrue(left)
    }
    func testLeaveDrainsPendingMutedPreparationAndEngineCleanupBeforeReturning() async throws {
        let engine = DesktopTestEngine()
        var preparationReply: CheckedContinuation<Void, Never>?
        var cleanupReply: CheckedContinuation<Void, Never>?
        var preparationCompletions = 0, leaveCompleted = false
        engine.onMutedPreparation = {
            // Model the independent native activation call: cancelling its
            // caller does not abort this await or manufacture a stop witness.
            await withCheckedContinuation { preparationReply = $0 }
            preparationCompletions += 1
        }
        engine.onLeaveCleanup = { await withCheckedContinuation { cleanupReply = $0 } }
        let model = NativeDesktopMeetingModel(destination: try .verified(url, engine: .guest), name: "Fixture", title: nil,
            engine: engine, joinReadiness: .init(microphone: .alsoOnBattery, camera: .off), power: joinTestPower())
        let connecting = Task { try await model.connect() }
        try await spin { preparationReply != nil }
        let leaving = Task { let result = await model.leave(); leaveCompleted = true; return result }
        try await spin { model.snapshot.phase == .leaving }
        await Task.yield()
        XCTAssertFalse(leaveCompleted)
        XCTAssertEqual(preparationCompletions, 0)
        XCTAssertEqual(engine.leaves, 0, "Engine teardown must wait for in-flight muted preparation to drain")
        XCTAssertTrue(engine.microphoneCommands.isEmpty, "Preparation and Leave must never authorize unmute")

        preparationReply?.resume(); preparationReply = nil
        try await spin { cleanupReply != nil }
        XCTAssertEqual(preparationCompletions, 1)
        XCTAssertEqual(engine.leaves, 1)
        XCTAssertFalse(leaveCompleted, "Drained preparation is not confirmed engine cleanup")
        XCTAssertFalse(model.snapshot.microphoneOn)
        XCTAssertTrue(engine.microphoneCommands.isEmpty)

        cleanupReply?.resume(); cleanupReply = nil
        let left = await leaving.value; XCTAssertTrue(left)
        do { try await connecting.value; XCTFail("Leaving during preparation must prevent transport join") }
        catch is CancellationError {}
        await model.waitForJoinReadinessForTesting()
        for _ in 0..<5 { await Task.yield() }
        XCTAssertTrue(leaveCompleted); XCTAssertEqual(model.snapshot.phase, .left)
        XCTAssertEqual(preparationCompletions, 1, "No readiness completion may arrive after Leave returns")
        XCTAssertEqual(engine.mutedPreparationCalls, 1); XCTAssertEqual(engine.leaves, 1)
        XCTAssertTrue(engine.microphoneCommands.isEmpty); XCTAssertFalse(model.snapshot.microphoneOn)
    }
    func testJoinCameraFirstFrameWaitDoesNotDelayMicrophoneAndLeaveStopsPrime() async throws {
        let engine = DesktopTestEngine(), capture = JoinPrimeCapture()
        engine.testFactory = LKRTCPeerConnectionFactory()
        capture.starting = {
            while capture.cancellations == 0 { try await Task.sleep(for: .milliseconds(10)) }
            throw CancellationError()
        }
        let prime = NativeDesktopJoinCameraPrime(authorized: { true }, makeCapture: { _ in capture })
        let model = NativeDesktopMeetingModel(destination: try .verified(url, engine: .guest), name: "Fixture", title: nil,
            engine: engine, joinReadiness: .init(microphone: .off, camera: .alsoOnBattery), joinCameraPrime: prime, cameraMetadata: await joinTestCameraMetadata(), power: joinTestPower())
        try await model.connect()
        try await spin { capture.starts == 1 }
        model.toggleMicrophone(); await model.waitForMediaActionsForTesting()
        XCTAssertTrue(model.snapshot.microphoneOn)
        XCTAssertEqual(capture.stops, 0, "Mic enable must not wait for the camera prime")
        XCTAssertTrue(engine.cameraCommands.isEmpty); XCTAssertNil(model.localCamera)
        let left = await model.leave(); XCTAssertTrue(left)
        XCTAssertEqual(capture.stops, 1); XCTAssertFalse(capture.frameReady)
        XCTAssertFalse(model.snapshot.microphoneOn); XCTAssertFalse(model.snapshot.cameraOn)
    }
    func testRapidOffSupersedesAnEnableThatHasNotStartedWithoutMutingPlayout() async throws {
        let engine = DesktopTestEngine(), model = try model(engine)
        try await model.connect(); model.toggleMicrophone(); model.toggleMicrophone()
        try await spin { engine.completedMicrophoneCommands == 1 && !model.snapshot.microphoneOn }
        XCTAssertEqual(engine.microphoneCommands, [false]); XCTAssertTrue(model.snapshot.playoutOn)
        let left = await model.leave(); XCTAssertTrue(left); XCTAssertEqual(engine.leaves, 1)
    }
    func testOffCancelsEachPendingPermissionAndLateAllowCannotEnableMedia() async throws {
        for video in [false, true] {
            let engine = DesktopTestEngine(), model = try model(engine)
            var reply: ((Bool) -> Void)?
            let permission: () async throws -> Void = {
                _ = try await GuestCaptureAuthorization.request(status: { .notDetermined }, prompt: { reply = $0 })
            }
            if video { engine.onCameraEnable = permission } else { engine.onMicrophoneEnable = permission }
            try await model.connect()
            if video { model.toggleCamera() } else { model.toggleMicrophone() }
            try await spin { reply != nil }
            XCTAssertTrue(video ? model.cameraStarting : model.microphoneStarting)
            if video { model.toggleCamera() } else { model.toggleMicrophone() }
            try await spin { video ? engine.cameraCommands.last == false : engine.completedMicrophoneCommands > 0 }
            reply?(true); await model.waitForMediaActionsForTesting()
            XCTAssertFalse(model.snapshot.microphoneOn); XCTAssertFalse(model.snapshot.cameraOn)
            XCTAssertFalse(model.microphoneStarting); XCTAssertFalse(model.cameraStarting)
            XCTAssertTrue(model.snapshot.playoutOn)
            XCTAssertNil(model.error)
            let left = await model.leave(); XCTAssertTrue(left)
        }
    }
    func testTransferCancelsPendingPermissionWithoutWaitingForTheUser() async throws {
        let engine = DesktopTestEngine(), model = try model(engine)
        var reply: ((Bool) -> Void)?, held = false
        engine.onMicrophoneEnable = {
            _ = try await GuestCaptureAuthorization.request(status: { .notDetermined }, prompt: { reply = $0 })
        }
        try await model.connect(); model.toggleMicrophone()
        try await spin { reply != nil }
        let hold = Task { try await model.setTransferHeld(true); held = true }
        try await spin { held }
        reply?(true); try await hold.value
        XCTAssertFalse(model.snapshot.microphoneOn); XCTAssertFalse(model.snapshot.playoutOn)
        try await model.setTransferHeld(false)
        XCTAssertFalse(model.snapshot.microphoneOn, "Pending permission was never accepted sending intent")
        let left = await model.leave(); XCTAssertTrue(left)
    }
    func testPrivacyOffBypassesTheOtherDevicesPermissionPrompt() async throws {
        for pendingVideo in [false, true] {
            let engine = DesktopTestEngine(), model = try model(engine)
            var reply: ((Bool) -> Void)?
            let permission: () async throws -> Void = {
                _ = try await GuestCaptureAuthorization.request(status: { .notDetermined }, prompt: { reply = $0 })
            }
            try await model.connect()
            if pendingVideo {
                try await engine.setMicrophone(true); engine.onCameraEnable = permission; model.toggleCamera()
            } else {
                try await engine.setCamera(true); engine.onMicrophoneEnable = permission; model.toggleMicrophone()
            }
            try await spin { reply != nil }
            if pendingVideo { model.toggleMicrophone() } else { model.toggleCamera() }
            try await spin { !model.snapshot.microphoneOn && !model.snapshot.cameraOn }
            reply?(true); await model.waitForMediaActionsForTesting()
            XCTAssertFalse(model.snapshot.microphoneOn); XCTAssertFalse(model.snapshot.cameraOn)
            XCTAssertTrue(model.snapshot.playoutOn)
            let left = await model.leave(); XCTAssertTrue(left)
        }
    }
    func testOldCanceledEnableCannotEraseNewerIntentDuringCleanup() async throws {
        let engine = DesktopTestEngine(), model = try model(engine)
        var reply: ((Bool) -> Void)?, cleanupStarted = false
        engine.onMicrophoneEnable = {
            _ = try await GuestCaptureAuthorization.request(status: { .notDetermined }, prompt: { reply = $0 })
        }
        engine.onMicrophoneDisable = {
            cleanupStarted = true
            try await Task.sleep(for: .milliseconds(150))
        }
        try await model.connect(); model.toggleMicrophone()
        try await spin { reply != nil }
        model.toggleMicrophone(); model.toggleMicrophone()
        try await spin { cleanupStarted }
        model.toggleMicrophone() // The newest requested On must still toggle to Off.
        reply?(true); await model.waitForMediaActionsForTesting()
        XCTAssertFalse(model.snapshot.microphoneOn)
        let left = await model.leave(); XCTAssertTrue(left)
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
        XCTAssertEqual(engine.microphoneCommands.first, true)
        XCTAssertTrue(engine.microphoneCommands.dropFirst().allSatisfy { !$0 })
        XCTAssertEqual(engine.microphoneCommands.last, false); XCTAssertEqual(engine.cameraCommands, [false])
        let microphoneCommandsWhileHeld = engine.microphoneCommands.count
        XCTAssertFalse(model.snapshot.microphoneOn); XCTAssertFalse(model.snapshot.cameraOn)
        model.toggleMicrophone(); model.toggleCamera()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(engine.microphoneCommands.count, microphoneCommandsWhileHeld); XCTAssertEqual(engine.cameraCommands.count, 1)
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
    func testHandoffAdvertisementRetiresWithoutCloudWithdrawalOnLeaveAndFailure() async throws {
        for failMeeting in [false, true] {
            let domain = "native-handoff-retirement-\(UUID())"
            let preferences = UserDefaults(suiteName: domain)!
            defer { preferences.removePersistentDomain(forName: domain) }
            preferences.set(true, forKey: "shareActiveJams")
            let cloud = DesktopContinuationTransport(), engine = DesktopTestEngine()
            let library = NativeDesktopLibrary(preferences: preferences,
                history: RoomHistoryStore(storage: DesktopMemoryStorage()), syncStorage: DesktopMemoryStorage(),
                continuationTransport: cloud)
            library.displayName = "Activity test"
            var activities: [DesktopActivitySpy] = []
            let workspace = NativeDesktopWorkspace(library: library,
                detect: { _ in .verified(.guest(endpoint: self.url)) },
                makeMeeting: { destination, name, title, quiet in
                    NativeDesktopMeetingModel(destination: destination, name: name, title: title, quiet: quiet, engine: engine)
                }, makeHandoffActivity: { _ in
                    let value = DesktopActivitySpy(activityType: NativeDesktopHandoff.activityType)
                    activities.append(value); return value
                })
            library.continuation.setCloudAccount("fixture-account")
            workspace.join(url)
            try await spin { workspace.meeting?.connected == true && !workspace.preparing && activities.last?.advertisements == 1 }
            let advertised = try XCTUnwrap(activities.last), count = activities.count
            XCTAssertEqual(advertised.invalidations, 0)
            cloud.failWithdrawal = true
            if failMeeting {
                engine.snapshot.phase = .failed; engine.onState?(engine.snapshot)
                try await spin { advertised.invalidations > 0 }
                XCTAssertNotNil(workspace.meeting, "Failed meeting remains available for recovery")
            } else {
                let clean = await workspace.leave(); XCTAssertTrue(clean)
                XCTAssertGreaterThan(advertised.invalidations, 0, "Local retirement must not await successful cloud withdrawal")
            }
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(activities.count, count, "An ended/failed meeting must not advertise a replacement activity")
            _ = await workspace.leave()
            library.continuation.setCloudAccount(nil)
        }
    }
    func testContinuationUsesSourceNameWithoutChangingSavedProfile() async throws {
        for savedName in ["", "Different Mac name"] {
            let domain = "native-handoff-name-\(UUID())"
            let preferences = UserDefaults(suiteName: domain)!
            defer { preferences.removePersistentDomain(forName: domain) }
            let library = NativeDesktopLibrary(preferences: preferences,
                history: RoomHistoryStore(storage: DesktopMemoryStorage()), syncStorage: DesktopMemoryStorage())
            library.displayName = savedName
            var joinedName: String?
            let workspace = NativeDesktopWorkspace(library: library,
                detect: { _ in .verified(.guest(endpoint: self.url)) },
                makeMeeting: { destination, name, title, quiet in
                    joinedName = name
                    return NativeDesktopMeetingModel(destination: destination, name: name, title: title,
                        quiet: quiet, engine: DesktopTestEngine())
                })
            let source = ActiveJam(deviceID: "source-phone", sessionID: UUID(), invitation: url,
                title: "Transfer fixture", name: "Source session name", deviceLabel: "iPhone")
            XCTAssertNotNil(workspace.library.continuation.onJoinTarget?(source, false))
            try await spin { workspace.meeting?.connected == true && !workspace.preparing }
            XCTAssertEqual(joinedName, source.name)
            XCTAssertEqual(library.displayName, savedName)
            XCTAssertEqual(preferences.string(forKey: "savedDisplayName"), savedName)
            let clean = await workspace.leave(); XCTAssertTrue(clean)
        }
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
        model.display = .audioOnly
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
        model.display = .audioOnly; model.setMediaPresentation(.floating)
        try await spin { engine.demands.last?.ids == [] && engine.demands.last?.focused == nil }
        XCTAssertEqual(model.display, .audioOnly); XCTAssertTrue(model.snapshot.playoutOn)
        _ = await model.leave()
    }
    func testScreenSharesModeReceivesScreensWithoutCameras() async throws {
        let engine = DesktopTestEngine(), model = try model(engine)
        try await model.connect()
        let factory = LKRTCPeerConnectionFactory(encoderFactory: LKRTCDefaultVideoEncoderFactory(), decoderFactory: LKRTCDefaultVideoDecoderFactory())
        func video(_ participant: String, _ source: NativeDesktopVideoSource) -> NativeDesktopExternalVideo {
            .init(id: participant + "-" + source.rawValue, participantID: participant, source: source,
                  track: factory.videoTrack(with: factory.videoSource(), trackId: participant + source.rawValue))
        }
        engine.snapshot.participants = [.init(id: "me", name: "Me", isLocal: true, cameraOn: true),
            .init(id: "a", name: "A", cameraOn: true), .init(id: "b", name: "B", cameraOn: true, sharing: true),
            .init(id: "c", name: "C", cameraOn: true, sharing: true)]
        engine.onState?(engine.snapshot)
        engine.onVideo?([video("a", .camera), video("b", .camera), video("b", .screen), video("c", .screen)])
        model.viewMode = .gallery
        model.focus(participantID: "a", source: .camera)
        try await spin { engine.cameraDemands.last == true }
        XCTAssertEqual(model.availableDisplays, [.all, .screenShares, .audioOnly])

        model.display = .screenShares; model.viewMode = .gallery
        try await spin { engine.cameraDemands.last == false && engine.demands.last?.ids == Set(["b", "c"]) }
        XCTAssertEqual(model.pinnedID, "a", "Changing what is received keeps the user's pin")
        XCTAssertEqual(model.galleryParticipants.map(\.id), ["me", "a", "b", "c"], "Every participant keeps a tile")
        XCTAssertEqual(model.videoParticipants.map(\.id), ["b", "c"], "Video is requested only for remote sharers")
        XCTAssertTrue(model.visibleVideos.allSatisfy { $0.source == .screen }, "A late camera frame is never shown")
        model.unpin(); model.viewMode = .automatic
        try await spin { engine.demands.last?.ids?.count == 1 && engine.cameraDemands.last == false }
        XCTAssertEqual(model.focusedVideo?.source, .screen)
        model.focus(participantID: "c", source: .camera)
        XCTAssertEqual(model.pinnedSource, .screen, "Focusing in Screen shares targets the participant's screen")
        try await spin { engine.demands.last?.ids == Set(["c"]) }
        XCTAssertEqual(model.focusedVideo?.id, "c-screen")

        model.unpin(); model.viewMode = .gallery
        engine.snapshot.participants = engine.snapshot.participants.map { var p = $0; p.sharing = false; return p }
        engine.onState?(engine.snapshot); engine.onVideo?([video("a", .camera), video("b", .camera)])
        try await spin { engine.demands.last?.ids == Set<String>() }
        XCTAssertTrue(model.videoParticipants.isEmpty && model.visibleVideos.isEmpty, "No share leaves audio only, not cameras")
        XCTAssertEqual(model.galleryParticipants.count, 4, "Participants stay visible while nobody shares")
        XCTAssertTrue(model.snapshot.playoutOn)

        model.display = .audioOnly; model.viewMode = .focused
        XCTAssertTrue(model.showsFocus, "Audio only keeps every layout available")
        XCTAssertNotNil(model.focusedParticipantID, "Focus still names a participant for the avatar tile")
        try await spin { engine.demands.last?.ids == Set<String>() && engine.demands.last?.focused == nil }
        model.viewMode = .automatic
        XCTAssertFalse(model.showsFocus, "Automatic audio only shows the participant gallery")
        XCTAssertEqual(model.galleryParticipants.count, 4)

        model.display = .all
        try await spin { engine.cameraDemands.last == true && engine.demands.last?.ids == Set(["me", "a", "b", "c"]) }
        engine.screenOnlySupported = false
        XCTAssertEqual(model.availableDisplays, [.all, .audioOnly], "Engines without screen-only reception never offer it")
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
