import Foundation
import XCTest
@testable import RockNRoll

final class GuestPresenterCameraSubscriptionTests: XCTestCase {
    func testLeaseSnapshotsAreScopedStableAndRevokedWithoutLockedCallbacks() throws {
        let f = try Fixture(), policy = f.policy!, generation = f.generation
        var events: [GuestPresenterCameraLease?] = []
        policy.onLeaseChange = { [weak policy] lease in
            XCTAssertEqual(policy?.currentLease, lease)
            events.append(lease)
        }
        try f.owner("owner", identity: "person", camera: "camera", share: true, version: 1)
        policy.setDemand("person", generation: generation)
        let lease = try XCTUnwrap(policy.currentLease)
        XCTAssertEqual(lease.generation, generation)
        XCTAssertEqual(lease.socketID, f.socket)
        XCTAssertEqual(lease.participantID, "person")
        XCTAssertEqual(lease.cameraSID, "camera")
        try f.owner("owner", identity: "person", camera: "camera", share: false, version: 2)
        XCTAssertEqual(policy.currentLease, lease)
        XCTAssertEqual(events.count, 1)
        policy.setDemand(nil, generation: generation)
        XCTAssertEqual(events.count, 2)
        XCTAssertNil(try XCTUnwrap(events.last))
        // Synchronous reentry proves callbacks own neither policy lock.
        policy.onLeaseChange = { [weak policy] lease in
            if lease != nil { policy?.setDemand(nil, generation: generation) }
        }
        try f.owner("owner", identity: "person", camera: "camera", share: true, version: 3)
        policy.setDemand("person", generation: generation)
        XCTAssertNil(policy.currentLease)
    }

    func testSubscriberAnswerEventRequiresQualifiedCurrentScopeAndAllowsReentry() throws {
        let f = try Fixture(group: "group"), policy = f.policy!, generation = f.generation
        try f.owner("owner", identity: "person", camera: "camera", share: true, version: 1)
        policy.setDemand("person", generation: generation)
        let lease = try XCTUnwrap(policy.currentLease)
        var answers: [GuestPresenterCameraLease] = []
        policy.onSubscriberAnswer = { answers.append($0) }
        func answer(socket: UUID? = nil, room: String = "room", group: String? = "group", type: String = "answer") throws {
            var fields: [String: Any] = ["event": "media-in", "roomId": room, "payload": ["method": "rtc:answer",
                "description": ["type": type, "sdp": "v=0\r\n"]]]
            if let group { fields["groupId"] = group }
            _ = policy.outgoing(socket: socket ?? f.socket, data: try JSONSerialization.data(withJSONObject: fields))
        }
        try answer(socket: UUID()); try answer(room: "wrong"); try answer(type: "offer")
        XCTAssertTrue(answers.isEmpty)
        try answer(); try answer(group: nil)
        XCTAssertEqual(answers, [lease, lease])
        policy.onSubscriberAnswer = { [weak policy] snapshot in
            XCTAssertEqual(policy?.currentLease, snapshot)
            policy?.setDemand(nil, generation: generation)
        }
        try answer()
        XCTAssertNil(policy.currentLease)
        policy.onSubscriberAnswer = { answers.append($0) }
        try answer()
        XCTAssertEqual(answers.count, 2)
        policy.setDemand("person", generation: generation)
        XCTAssertNotEqual(policy.currentLease?.token, lease.token)
        try answer(group: "different")
        XCTAssertNil(policy.currentLease)
        XCTAssertEqual(answers.count, 2)
    }

    func testConcurrentHandoffsEnqueueWholeBatchesBeforeNextMutation() throws {
        let wire = GatedWire(), generation = UUID(), socket = UUID()
        let policy = GuestPresenterCameraSubscriptions(send: wire.send)
        func data(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
        policy.begin(generation: generation, room: "room")
        _ = policy.outgoing(socket: socket, data: try data(["event": "join", "roomId": "room",
            "payload": ["jazzToken": "fixture", "participantName": "fixture"]]))
        _ = policy.outgoing(socket: socket, data: try data(["event": "media-in", "roomId": "room",
            "payload": ["method": "rtc:ping"]]))
        let owners: [[String: Any]] = ["a", "b", "c"].map { id in
            ["sid": id, "identity": id, "tracks": [
                ["sid": id, "source": "CAMERA", "type": "VIDEO", "muted": false],
                ["sid": "share-" + id, "source": "SCREEN_SHARE", "type": "VIDEO", "muted": false]]]
        }
        policy.incoming(socket: socket, data: try data(["event": "media-out", "roomId": "room",
            "payload": ["update": ["participants": owners]]]))
        policy.setDemand("a", generation: generation)
        wire.flush(); wire.arm()
        let bDone = DispatchSemaphore(value: 0), cStarted = DispatchSemaphore(value: 0), cDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { policy.setDemand("b", generation: generation); bDone.signal() }
        XCTAssertEqual(wire.paused.wait(timeout: .now() + 2), .success)
        DispatchQueue.global().async {
            cStarted.signal(); policy.setDemand("c", generation: generation); cDone.signal()
        }
        XCTAssertEqual(cStarted.wait(timeout: .now() + 2), .success)
        let overtook = cDone.wait(timeout: .now() + 0.1)
        wire.flush() // A→B is paused before enqueue; C must not get onto the wire.
        wire.resume.signal()
        XCTAssertEqual(bDone.wait(timeout: .now() + 2), .success)
        if overtook == .timedOut { XCTAssertEqual(cDone.wait(timeout: .now() + 2), .success) }
        wire.flush()
        XCTAssertEqual(overtook, .timedOut)
        XCTAssertEqual(wire.peak, 1)
        XCTAssertEqual(wire.actual, ["c"])
    }

    func testUnavailableSocketBindingLeavesSDKSubscriptionsUntouched() throws {
        let f = try Fixture(bindingAllowed: false)
        try f.owner("owner", identity: "person", camera: "camera", share: true, version: 1)
        f.policy.setVisibleCandidates(["person"], generation: f.generation)
        XCTAssertNil(try f.sdk(["camera"], subscribed: false))
        XCTAssertTrue(f.commands.isEmpty)
        XCTAssertEqual(f.bindings, [f.socket])
    }

    func testReplacementBindingFailureQueuesOldCleanupBeforeUnbind() throws {
        let f = try prepared(), old = f.socket
        f.bindingAllowed = false
        try f.join(socket: UUID())
        XCTAssertEqual(f.unbound, [old])
        XCTAssertEqual(Array(f.lifecycle.suffix(2)), ["send", "unbind"])
        let cleanup = try XCTUnwrap(f.commands.last)
        XCTAssertEqual(cleanup.socket, old)
        XCTAssertTrue(cleanup.current())
        XCTAssertEqual(try subscription(cleanup.data)["subscribe"] as? Bool, false)
        try f.owner("owner", identity: "person", camera: "camera", share: true, version: 2)
        XCTAssertNil(try f.sdk(["camera"], subscribed: false))
    }
    func testVisibleCameraIsArmedBeforeShareMetadataAndSDKUnsubscribe() throws {
        let f = try Fixture()
        try f.owner("owner", identity: "person", camera: "camera", share: false, version: 1)
        _ = try f.sdk(["camera"], subscribed: true)
        f.policy.setVisibleCandidates(["person"], generation: f.generation)
        XCTAssertTrue(f.commands.isEmpty)
        // This arrives before the same update is forwarded into the SDK's UI.
        try f.owner("owner", identity: "person", camera: "camera", share: true, version: 2)
        XCTAssertEqual(f.commands.count, 1)
        XCTAssertTrue(try XCTUnwrap(f.commands.last).current())
        let rewritten = try XCTUnwrap(f.sdk(["camera"], subscribed: false))
        XCTAssertEqual(try subscription(rewritten)["subscribe"] as? Bool, true)
        // Gallery-to-stage keeps the same semantic candidate; no stop/restart.
        f.policy.setVisibleCandidates(["person"], generation: f.generation)
        XCTAssertEqual(f.commands.count, 1)
    }

    func testVisibleCandidatesRetainOneCameraAndHandoffOnlyWhenItLeavesVisibility() throws {
        let f = try Fixture()
        try f.owner("a", identity: "first", camera: "camera-a", share: true, version: 1)
        try f.owner("b", identity: "second", camera: "camera-b", share: true, version: 1)
        _ = try f.sdk(["camera-a", "camera-b"], subscribed: false)
        f.policy.setVisibleCandidates(["first", "second"], generation: f.generation)
        XCTAssertEqual(try subscription(XCTUnwrap(f.commands.last).data)["trackSids"] as? [String], ["camera-a"])
        f.policy.setVisibleCandidates(["second", "first"], generation: f.generation)
        XCTAssertEqual(f.commands.count, 1)
        f.policy.setVisibleCandidates(["second"], generation: f.generation)
        XCTAssertEqual(f.commands.count, 3)
        XCTAssertEqual(try subscription(f.commands[1].data)["subscribe"] as? Bool, false)
        XCTAssertEqual(try subscription(f.commands[2].data)["trackSids"] as? [String], ["camera-b"])
        XCTAssertNil(try f.sdk(["camera-a"], subscribed: false))
        XCTAssertNotNil(try f.sdk(["camera-b"], subscribed: false))
    }

    func testVisibleCandidateListIsBoundedBeforeItCanRetainCamera() throws {
        let f = try Fixture()
        try f.owner("owner", identity: "p64", camera: "camera", share: true, version: 1)
        f.policy.setVisibleCandidates((0..<65).map { "p\($0)" }, generation: f.generation)
        XCTAssertTrue(f.commands.isEmpty)
        f.policy.setVisibleCandidates(["p64"], generation: f.generation)
        XCTAssertEqual(f.commands.count, 1)
    }
    func testExactSocketAcceptsOmittedRoomAndVersionZeroAndPreservesGroupRouting() throws {
        let f = try Fixture(group: "validated-group")
        let data = try JSONSerialization.data(withJSONObject: ["event": "media-out", "payload": ["update": ["participants": [[
            "sid": "owner", "identity": "person", "tracks": [
                ["sid": "camera", "type": "VIDEO", "source": "CAMERA", "muted": false],
                ["sid": "share", "type": "VIDEO", "source": "SCREEN_SHARE", "muted": false]]]]]]])
        f.policy.incoming(socket: f.socket, data: data)
        f.policy.setDemand("person", generation: f.generation)
        let subscribe = try XCTUnwrap(f.commands.last)
        XCTAssertEqual(try json(subscribe.data)["groupId"] as? String, "validated-group")
        XCTAssertEqual(try subscription(subscribe.data)["trackSids"] as? [String], ["camera"])
        var conflicting = try json(data); conflicting["roomId"] = "other-room"
        f.policy.incoming(socket: f.socket, data: try JSONSerialization.data(withJSONObject: conflicting))
        XCTAssertTrue(subscribe.current())
        // Routing may be omitted by a later SDK notification, not changed to nil.
        _ = f.policy.outgoing(socket: f.socket, data: try JSONSerialization.data(withJSONObject: [
            "event": "media-in", "roomId": "room", "payload": ["method": "rtc:ping"]]))
        XCTAssertTrue(subscribe.current())
    }
    func testDirectCameraSelectionNeedsNoCompanionNavigationHistory() {
        XCTAssertEqual(GuestPresenterCameraDemand.stageOwner(participant: "presenter", isShare: false, sharing: ["presenter"]), "presenter")
        XCTAssertNil(GuestPresenterCameraDemand.stageOwner(participant: "listener", isShare: false, sharing: ["presenter"]))
        XCTAssertNil(GuestPresenterCameraDemand.stageOwner(participant: "presenter", isShare: false, sharing: []))
    }
    func testBoundedIntentOverflowCannotCountermandGroupedSDKSubscribe() throws {
        let f = try prepared()
        _ = try f.sdk((0..<127).map { "other-\($0)" }, subscribed: false)
        let count = f.commands.count
        XCTAssertNil(try f.sdk(["overflow", "camera"], subscribed: true))
        XCTAssertEqual(f.commands.count, count)
        f.policy.setDemand(nil, generation: f.generation)
        f.policy.setDemand("person", generation: f.generation)
        XCTAssertNil(try f.sdk(["camera"], subscribed: false))
        XCTAssertEqual(f.commands.count, count)
    }
    func testGalleryDemandUsesOnlyVisibleCamerasAndKeepsOnePresenter() {
        let sharing: Set<String> = ["offscreen", "second", "third"]
        XCTAssertEqual(GuestPresenterCameraDemand.galleryOwner(visibleCameras: ["listener", "second", "third"],
            sharing: sharing, preferred: "offscreen"), "second")
        XCTAssertEqual(GuestPresenterCameraDemand.galleryOwner(visibleCameras: ["second", "third"],
            sharing: sharing, preferred: "third"), "third")
        XCTAssertNil(GuestPresenterCameraDemand.galleryOwner(visibleCameras: ["listener"], sharing: sharing, preferred: "offscreen"))
        XCTAssertNil(GuestPresenterCameraDemand.galleryOwner(visibleCameras: [], sharing: sharing, preferred: "second"))
    }
    func testOnlySelectedPresenterCameraSurvivesMixedUnsubscribe() throws {
        let f = try Fixture()
        try f.owner("owner", identity: "person", camera: "camera", share: true, version: 1)
        try f.owner("other", identity: "other", camera: "other-camera", share: true, version: 1)
        f.policy.setDemand("person", generation: f.generation)
        let rewritten = try XCTUnwrap(f.sdk(["camera", "other-camera"], subscribed: false))
        XCTAssertEqual(try subscription(rewritten)["trackSids"] as? [String], ["other-camera"])
        XCTAssertEqual(try subscription(rewritten)["subscribe"] as? Bool, false)
        XCTAssertEqual(try subscription(XCTUnwrap(f.sdk(["camera"], subscribed: false)))["subscribe"] as? Bool, true)
        XCTAssertEqual(f.commands.count, 1)
    }

    func testWithdrawalRestoresSDKIntentWithoutAnotherSDKMessage() throws {
        let f = try prepared()
        let subscribe = try XCTUnwrap(f.commands.last)
        XCTAssertTrue(subscribe.current())
        f.policy.setDemand(nil, generation: f.generation)
        XCTAssertFalse(subscribe.current())
        let stop = try XCTUnwrap(f.commands.last)
        XCTAssertTrue(stop.current())
        XCTAssertEqual(try subscription(stop.data)["subscribe"] as? Bool, false)
        XCTAssertNotNil(try json(stop.data)["requestId"] as? String)
    }

    func testWithdrawalPreservesCameraStillWantedBySDK() throws {
        let f = try prepared()
        _ = try f.sdk(["camera"], subscribed: true)
        let count = f.commands.count
        f.policy.setDemand(nil, generation: f.generation)
        XCTAssertEqual(f.commands.count, count)
        XCTAssertNil(try f.sdk(["camera"], subscribed: false))
    }

    func testCollapseBackgroundAudioOnlyHoldAndUnmountWithdraw() throws {
        let mutations: [(inout GuestPresenterCameraDemand) -> Void] = [
            { $0.collapsed = true }, { $0.foreground = false }, { $0.allVideo = false },
            { $0.held = true }, { $0.mounted = false }, { $0.cameraOn = false }
        ]
        for mutate in mutations {
            let f = try prepared()
            var demand = visibleDemand()
            mutate(&demand)
            XCTAssertNil(demand.identity)
            f.policy.setDemand(demand.identity, generation: f.generation)
            XCTAssertEqual(try subscription(XCTUnwrap(f.commands.last).data)["subscribe"] as? Bool, false)
        }
        var focused = visibleDemand(); focused.collapsed = true; focused.cameraFocused = true
        XCTAssertEqual(focused.identity, "person")
    }

    func testShareEndKeepsSameVisibleCameraAcrossSDKIntentChanges() throws {
        let f = try prepared()
        let initial = try XCTUnwrap(f.commands.last)
        try f.owner("owner", identity: "person", camera: "camera", share: false, version: 2)
        XCTAssertEqual(f.commands.count, 1)
        XCTAssertTrue(initial.current())
        _ = try f.sdk(["camera"], subscribed: true)
        XCTAssertEqual(try subscription(XCTUnwrap(f.sdk(["camera"], subscribed: false)))["subscribe"] as? Bool, true)
        XCTAssertEqual(f.commands.count, 1)
        f.policy.setVisibleCandidates([], generation: f.generation)
        XCTAssertFalse(initial.current())
        XCTAssertEqual(try subscription(XCTUnwrap(f.commands.last).data)["subscribe"] as? Bool, false)
        XCTAssertNil(try f.sdk(["camera"], subscribed: false))
    }

    func testNewVisiblePresenterPreemptsFormerPresenterContinuity() throws {
        let f = try prepared()
        try f.owner("owner", identity: "person", camera: "camera", share: false, version: 2)
        try f.owner("second-owner", identity: "second", camera: "second-camera", share: true, version: 1)
        XCTAssertEqual(f.commands.count, 1, "An offscreen presenter cannot acquire the lease")
        f.policy.setVisibleCandidates(["person", "second"], generation: f.generation)
        XCTAssertEqual(f.commands.count, 3)
        XCTAssertEqual(try subscription(f.commands[1].data)["subscribe"] as? Bool, false)
        XCTAssertEqual(try subscription(f.commands[2].data)["trackSids"] as? [String], ["second-camera"])
        XCTAssertNil(try f.sdk(["camera"], subscribed: false))
        XCTAssertNotNil(try f.sdk(["second-camera"], subscribed: false))
    }

    func testCameraMuteAndDepartureReleaseContinuityLease() throws {
        for change in 1..<3 {
            let f = try prepared()
            try f.owner("owner", identity: "person", camera: "camera", share: false, version: 2)
            try f.owner("owner", identity: "person", camera: "camera", share: false,
                muted: change == 1, disconnected: change == 2, version: 3)
            XCTAssertEqual(try subscription(XCTUnwrap(f.commands.last).data)["subscribe"] as? Bool, false)
            XCTAssertNil(try f.sdk(["camera"], subscribed: false))
        }
    }

    func testDemandBeforeTrackMappingActivelySubscribesWhenMappingArrives() throws {
        let f = try Fixture()
        f.policy.setDemand("person", generation: f.generation)
        XCTAssertTrue(f.commands.isEmpty)
        try f.owner("owner", identity: "person", camera: "camera", share: true, version: 1)
        XCTAssertEqual(try subscription(XCTUnwrap(f.commands.last).data)["subscribe"] as? Bool, true)
    }

    func testReconnectRetiresOldSocketAndRejectsOldSessionDemand() throws {
        let f = try prepared(), old = f.socket
        let pending = try XCTUnwrap(f.commands.last)
        let replacement = UUID()
        try f.join(socket: replacement)
        XCTAssertFalse(pending.current())
        XCTAssertEqual(f.commands.last?.socket, old)
        XCTAssertEqual(try subscription(XCTUnwrap(f.commands.last).data)["subscribe"] as? Bool, false)
        try f.owner("owner", identity: "person", camera: "camera", share: true, version: 2, socket: old)
        XCTAssertNil(try f.sdk(["camera"], subscribed: false, socket: old))
        let nextGeneration = UUID()
        f.policy.begin(generation: nextGeneration, room: "room")
        f.policy.setDemand("person", generation: f.generation)
        try f.join(socket: UUID())
        let count = f.commands.count
        try f.owner("owner", identity: "person", camera: "camera", share: true, version: 3)
        XCTAssertEqual(f.commands.count, count)
    }

    func testReexpansionRejectsQueuedWithdrawalAndStaleOwnerCannotReplaceNewSID() throws {
        let f = try prepared()
        f.policy.setDemand(nil, generation: f.generation)
        let stop = try XCTUnwrap(f.commands.last)
        f.policy.setDemand("person", generation: f.generation)
        XCTAssertFalse(stop.current())
        try f.owner("replacement", identity: "person", camera: "new-camera", share: true, version: 1)
        try f.owner("owner", identity: "person", camera: "camera", share: true, version: 99)
        XCTAssertNil(try f.sdk(["camera"], subscribed: false))
        XCTAssertNotNil(try f.sdk(["new-camera"], subscribed: false))
    }

    func testUnrelatedRoomUnknownOwnerAndEndPassThrough() throws {
        let f = try prepared()
        let wrongRoom = try JSONSerialization.data(withJSONObject: ["event": "media-in", "roomId": "wrong",
            "payload": ["subscription": ["subscribe": false, "trackSids": ["camera"]]]])
        XCTAssertNil(f.policy.outgoing(socket: f.socket, data: wrongRoom))
        XCTAssertNil(try f.sdk(["unknown"], subscribed: false))
        f.policy.end(generation: f.generation)
        XCTAssertNil(try f.sdk(["camera"], subscribed: false))
    }

    private func visibleDemand() -> GuestPresenterCameraDemand {
        .init(participant: "person", cameraOn: true, sharing: true, allVideo: true,
              mounted: true, foreground: true, held: false, collapsed: false, cameraFocused: false)
    }
    private func prepared() throws -> Fixture {
        let f = try Fixture()
        try f.owner("owner", identity: "person", camera: "camera", share: true, version: 1)
        _ = try f.sdk(["camera"], subscribed: false)
        f.policy.setDemand("person", generation: f.generation)
        return f
    }
    private func json(_ data: Data) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]) }
    private func subscription(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap((json(data)["payload"] as? [String: Any])?["subscription"] as? [String: Any])
    }

    private final class GatedWire: @unchecked Sendable {
        let paused = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
        private let queue = DispatchQueue(label: "presenter-subscription-test-wire"), gate = NSLock()
        private var armed = false
        private(set) var actual = Set<String>(), peak = 0
        func arm() { gate.lock(); armed = true; gate.unlock() }
        func flush() { queue.sync {} }
        func send(_ socket: UUID, _ data: Data, _ current: @escaping () -> Bool) {
            // A synchronous validator must be safe: Send never owns the state lock.
            _ = current()
            let envelope = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
            let subscription = (envelope["payload"] as! [String: Any])["subscription"] as! [String: Any]
            let track = (subscription["trackSids"] as! [String])[0], subscribed = subscription["subscribe"] as! Bool
            gate.lock()
            let pause = armed && track == "a" && !subscribed
            if pause { armed = false }
            gate.unlock()
            if pause { paused.signal(); _ = resume.wait(timeout: .now() + 5) }
            queue.async { [self] in
                guard current() else { return }
                if subscribed { actual.insert(track) } else { actual.remove(track) }
                peak = max(peak, actual.count)
            }
        }
    }

    private final class Fixture {
        struct Sent { let socket: UUID; let data: Data; let current: () -> Bool }
        let generation = UUID()
        var socket = UUID()
        let group: String?
        var bindingAllowed: Bool
        var bindings: [UUID] = []
        var unbound: [UUID] = []
        var lifecycle: [String] = []
        var commands: [Sent] = []
        var policy: GuestPresenterCameraSubscriptions!
        init(group: String? = nil, bindingAllowed: Bool = true) throws {
            self.group = group
            self.bindingAllowed = bindingAllowed
            policy = GuestPresenterCameraSubscriptions(bind: { [weak self] socket in
                self?.bindings.append(socket)
                return self?.bindingAllowed == true
            }, unbind: { [weak self] socket in
                self?.unbound.append(socket); self?.lifecycle.append("unbind")
            }) { [weak self] socket, data, current in
                self?.lifecycle.append("send")
                self?.commands.append(Sent(socket: socket, data: data, current: current))
            }
            policy.begin(generation: generation, room: "room")
            try join(socket: socket)
        }
        func join(socket: UUID) throws {
            self.socket = socket
            _ = policy.outgoing(socket: socket, data: try JSONSerialization.data(withJSONObject: [
                "event": "join", "roomId": "room", "payload": ["jazzToken": "fixture", "participantName": "fixture"]]))
            var route: [String: Any] = ["event": "media-in", "roomId": "room", "payload": ["method": "rtc:ping"]]
            if let group { route["groupId"] = group }
            _ = policy.outgoing(socket: socket, data: try JSONSerialization.data(withJSONObject: route))
        }
        func owner(_ sid: String, identity: String, camera: String, share: Bool, muted: Bool = false,
                   disconnected: Bool = false, version: Int, socket: UUID? = nil) throws {
            let tracks: [[String: Any]] = [["sid": camera, "source": "CAMERA", "type": "VIDEO", "muted": muted],
                ["sid": "share-" + sid, "source": "SCREEN_SHARE", "type": "VIDEO", "muted": !share]]
            policy.incoming(socket: socket ?? self.socket, data: try JSONSerialization.data(withJSONObject: [
                "event": "media-out", "roomId": "room", "payload": ["update": ["participants": [[
                    "sid": sid, "identity": identity, "version": version, "state": disconnected ? "DISCONNECTED" : "ACTIVE", "tracks": tracks]]]]]))
        }
        func sdk(_ tracks: [String], subscribed: Bool, socket: UUID? = nil) throws -> Data? {
            var envelope: [String: Any] = ["event": "media-in", "roomId": "room",
                "payload": ["subscription": ["trackSids": tracks, "subscribe": subscribed]]]
            if let group { envelope["groupId"] = group }
            return policy.outgoing(socket: socket ?? self.socket, data: try JSONSerialization.data(withJSONObject: envelope))
        }
    }
}
