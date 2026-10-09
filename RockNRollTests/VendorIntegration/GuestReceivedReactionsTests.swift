import ConferenceCore
import JazzCore
import UIKit
import XCTest
@testable import RockNRoll

@MainActor
final class GuestReceivedReactionsTests: XCTestCase {
    func testAllPinnedSDKWireValuesAndDocumentedEnumValues() {
        let pairs: [(MeetingReaction, JitsiReaction)] = [(.applause, .applause), (.like, .like),
            (.dislike, .dislike), (.smile, .smile), (.surprise, .surprise)]
        for (kind, native) in pairs {
            let pinned = GuestReceivedReaction(payload: ["participantId": "remote", "value": kind.rawValue])
            let documented = GuestReceivedReaction(payload: ["participantFromId": "remote", "value": native.rawValue])
            XCTAssertEqual(pinned?.kind, kind)
            XCTAssertEqual(pinned?.participantID, "remote")
            XCTAssertEqual(documented, pinned)
        }
    }

    func testMalformedPayloadsCannotInventAReactionOrSender() {
        let invalid: [NSDictionary] = [
            [:], ["participantId": "", "value": "like"],
            ["participantId": 1, "value": "like"],
            ["participantId": "a", "participantFromId": "b", "value": "like"],
            ["participantId": "a", "value": "👍"],
            ["participantId": "a", "value": "unknown"],
            ["participantId": "a", "value": true],
            ["participantId": "a", "value": -1],
            ["participantId": "a", "value": 0.5],
            ["participantId": "a", "value": Double.infinity],
            ["participantId": "a", "value": Double(UInt64.max)]
        ]
        for payload in invalid { XCTAssertNil(GuestReceivedReaction(payload: payload)) }
    }

    func testObserverForwardsUnchangedAndOnlyReceivesItsDelegate() throws {
        let watched = ReactionDelegateFixture(), other = ReactionDelegateFixture()
        var received: [GuestReceivedReaction] = []
        let tap = try XCTUnwrap(GuestReactionDelegateTap(delegate: watched) { received.append($0) })
        defer { tap.invalidate() }
        let payload: NSDictionary = ["participantId": "remote", "value": "applause"]
        emit(payload, to: other)
        XCTAssertEqual(other.calls, 1); XCTAssertTrue(received.isEmpty)
        emit(payload, to: watched)
        XCTAssertEqual(watched.calls, 1); XCTAssertTrue(watched.lastPayload === payload)
        XCTAssertEqual(received.map(\.kind), [.applause])
        emit(["unexpected": "data"], to: watched)
        XCTAssertEqual(watched.calls, 2, "Invalid app payload must still reach the original SDK delegate")
        XCTAssertEqual(received.count, 1)
    }

    func testInvalidationStopsOurDeliveryAndPreservesSDKDelegate() throws {
        let delegate = ReactionDelegateFixture()
        var count = 0
        let tap = try XCTUnwrap(GuestReactionDelegateTap(delegate: delegate) { _ in count += 1 })
        emit(["participantId": "remote", "value": "like"], to: delegate)
        tap.invalidate()
        emit(["participantId": "remote", "value": "like"], to: delegate)
        XCTAssertEqual(delegate.calls, 2); XCTAssertEqual(count, 1)
    }

    func testInheritedPublicCallbackIsNotWrappedTwice() throws {
        let base = ReactionDelegateFixture(), child = DerivedReactionDelegateFixture()
        var baseCount = 0, childCount = 0
        let first = try XCTUnwrap(GuestReactionDelegateTap(delegate: base) { _ in baseCount += 1 })
        let second = try XCTUnwrap(GuestReactionDelegateTap(delegate: child) { _ in childCount += 1 })
        defer { first.invalidate(); second.invalidate() }
        emit(["participantId": "remote", "value": "surprise"], to: child)
        XCTAssertEqual(child.calls, 1); XCTAssertEqual(childCount, 1); XCTAssertEqual(baseCount, 0)
    }

    func testNoPublicTransportMeansNoReceiveCapability() {
        let receiver = GuestReceivedReactions(valid: { true }, participant: { _ in nil }, onReaction: { _, _ in
            XCTFail("A plain UI root cannot produce guest reaction events")
        })
        receiver.start(in: UIView())
        XCTAssertFalse(receiver.isObserving)
        receiver.stop()
    }

    func testReceivedTransportEventsRequireCurrentRemoteRosterAndLiveReceiver() {
        let root = UIView()
        var valid = true
        var received: [MeetingReaction] = []
        let receiver = GuestReceivedReactions(valid: { valid }, participant: { id in
            if id == "remote" { return .init(name: "Remote", isLocal: false) }
            if id == "local" { return .init(name: "Local", isLocal: true) }
            return nil
        }, onReaction: { kind, _ in received.append(kind) })
        receiver.start(in: root)
        receiver.receive(.init(kind: .heart, participantID: "unknown"))
        receiver.receive(.init(kind: .heart, participantID: "local"))
        receiver.receive(.init(kind: .heart, participantID: "remote"))
        XCTAssertEqual(received, [.heart])
        valid = false
        receiver.receive(.init(kind: .like, participantID: "remote"))
        valid = true; receiver.stop()
        receiver.receive(.init(kind: .like, participantID: "remote"))
        XCTAssertEqual(received, [.heart])
    }

    func testVisibleOverlayMountsCardsBeforeConstrainingAndBoundsBurst() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 640)
        let host = UIViewController()
        window.rootViewController = host; window.isHidden = false
        defer { window.isHidden = true }
        let overlay = ReceivedReactionOverlay(frame: host.view.bounds)
        host.view.addSubview(overlay)
        host.view.layoutIfNeeded()
        for kind in MeetingReaction.allCases { overlay.show(kind, from: "Remote participant") }
        overlay.layoutIfNeeded()
        let stack = try XCTUnwrap(overlay.subviews.first as? UIStackView)
        XCTAssertEqual(stack.arrangedSubviews.count, 3)
        XCTAssertFalse(stack.bounds.isEmpty)
        for card in stack.arrangedSubviews {
            XCTAssertTrue(card.superview === stack)
            XCTAssertLessThanOrEqual(card.frame.maxX, stack.bounds.maxX + 0.5)
        }
        overlay.suppressed = true
        XCTAssertTrue(stack.arrangedSubviews.isEmpty)
        overlay.show(.heart, from: "Remote participant")
        XCTAssertTrue(stack.arrangedSubviews.isEmpty)
    }

    /// An independent connected client must send every supported reaction.
    /// This qualifies the real SDK callback and visible app overlay, not a mock.
    func testLiveGuestReceivesAllTwelveReactions() async throws {
        guard let invitation = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_REACTIONS_RECEIVE_INVITE"] else {
            throw XCTSkip("Opt-in guest receive qualification with an independent reaction sender")
        }
        let target = try JoinTarget.parse(invitation)
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first?.windows.first { $0.isKeyWindow })
        let previous = window.rootViewController, container = UIViewController()
        window.rootViewController = container; window.makeKeyAndVisible()
        let engine = NativeConferenceEngine(systemCall: SystemCallCoordinator(), catchUp: CatchUpStore())
        var ready = false, ended = false
        engine.onEvent = { event in
            switch event { case .active: ready = true; case .left, .failed: ended = true; default: break }
        }
        defer { engine.leave(); window.rootViewController = previous }
        try engine.configure(container: container, networkURL: await VendorEndpointResolver.make().resolve(for: target),
                             displayName: "Reaction receive QA")
        try engine.join(target: target, displayName: "Reaction receive QA")
        let connectDeadline = Date().addingTimeInterval(40)
        while !ended && Date() < connectDeadline &&
                (!ready || GuestReceivedReactions.currentForTesting?.isObserving != true) {
            try await Task.sleep(for: .milliseconds(100))
        }
        let receiver = try XCTUnwrap(GuestReceivedReactions.currentForTesting)
        XCTAssertTrue(ready); XCTAssertFalse(ended)
        XCTAssertTrue(receiver.isObserving, "The live transport must expose the public receive callback")
        guard ready, receiver.isObserving, !ended else { return }
        print("GUEST_REACTIONS_RECEIVER_READY observing=true supported=12")
        let expected = Set(MeetingReaction.allCases)
        var visible = Set<MeetingReaction>()
        let receiveDeadline = Date().addingTimeInterval(90)
        while !ended && Date() < receiveDeadline && visible != expected {
            func inspect(_ view: UIView, visible ancestorsVisible: Bool) {
                let shown = ancestorsVisible && !view.isHidden && view.alpha > 0.01
                if shown, let label = view as? UILabel,
                   let kind = MeetingReaction.allCases.first(where: { label.accessibilityIdentifier == "reactions.received." + $0.rawValue }),
                   !label.bounds.isEmpty, label.convert(label.bounds, to: window).intersects(window.bounds) {
                    visible.insert(kind)
                }
                view.subviews.forEach { inspect($0, visible: shown) }
            }
            inspect(window, visible: true)
            try await Task.sleep(for: .milliseconds(100))
        }
        print("GUEST_REACTIONS_RECEIVED \(receiver.receivedByKind.map { ($0.key.rawValue, $0.value) })")
        print("GUEST_REACTIONS_VISIBLE \(visible.map(\.rawValue).sorted())")
        XCTAssertFalse(ended)
        XCTAssertEqual(Set(receiver.receivedByKind.keys), expected)
        XCTAssertEqual(visible, expected, "Every received kind must draw a visible transient label")
    }

    /// Qualifies the SDK's own rendering beneath our custom stage without
    /// subscribing to private state or identifying private SDK view classes.
    func testLiveGuestNativeReactionPresentation() async throws {
        guard let invitation = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_REACTIONS_NATIVE_INVITE"] else {
            throw XCTSkip("Opt-in inspection of SDK receive presentation with an independent sender")
        }
        let target = try JoinTarget.parse(invitation)
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first?.windows.first { $0.isKeyWindow })
        let previous = window.rootViewController, container = UIViewController()
        window.rootViewController = container; window.makeKeyAndVisible()
        let engine = NativeConferenceEngine(systemCall: SystemCallCoordinator(), catchUp: CatchUpStore())
        var ready = false, ended = false
        engine.onEvent = { event in
            switch event { case .active: ready = true; case .left, .failed: ended = true; default: break }
        }
        defer { engine.leave(); window.rootViewController = previous }
        try engine.configure(container: container, networkURL: await VendorEndpointResolver.make().resolve(for: target),
                             displayName: "Native reaction QA")
        try engine.join(target: target, displayName: "Native reaction QA")
        let connectDeadline = Date().addingTimeInterval(40)
        while !ready && !ended && Date() < connectDeadline { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(ready); XCTAssertFalse(ended)
        guard ready, !ended else { return }

        if ProcessInfo.processInfo.environment["CONFERENCE_TEST_REACTIONS_SEND_PROBE"] == "1" {
            for kind: MeetingReaction in [.like, .dislike, .applause, .smile, .surprise] {
                print("GUEST_REACTION_SEND_PROBE kind=\(kind.rawValue) submitted=\(engine.sendReactionForTesting(kind))")
                try await Task.sleep(for: .seconds(2))
            }
        }

        var controls: [CallControls] = []
        func findControls(_ view: UIView) {
            if let control = view as? CallControls { controls.append(control) }
            view.subviews.forEach(findControls)
        }
        findControls(window)
        let sdkDefault = ProcessInfo.processInfo.environment["CONFERENCE_TEST_REACTIONS_NATIVE_DEFAULT"] == "1"
        XCTAssertEqual(controls.count, sdkDefault ? 0 : 1)
        controls.forEach { $0.hideNativeSurfaceForTesting(true) }
        defer { controls.forEach { $0.hideNativeSurfaceForTesting(false) } }
        window.layoutIfNeeded()
        captureNativePresentation(window, name: "SDK stage before external reaction")
        print("GUEST_NATIVE_REACTIONS_READY sdkDefault=\(sdkDefault) customControlsHidden=\(controls.count)")
        var seen = Set<String>()
        let deadline = Date().addingTimeInterval(90)
        while !ended && Date() < deadline {
            func inspect(_ view: UIView) {
                if let label = view as? UILabel, let text = label.text,
                   !text.isEmpty, text.count <= 4, text.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation }),
                   seen.insert(text).inserted {
                    let visible = sequence(first: view, next: { $0.superview }).allSatisfy { !$0.isHidden && $0.alpha > 0.01 }
                    let frame = view.convert(view.bounds, to: window)
                    print("GUEST_NATIVE_REACTION_LABEL glyph=\(text) visible=\(visible) frame=\(frame)")
                    captureNativePresentation(window, name: "SDK reaction \(seen.count)")
                }
                view.subviews.forEach(inspect)
            }
            inspect(window)
            try await Task.sleep(for: .milliseconds(100))
        }
        print("GUEST_NATIVE_REACTIONS_END glyphCount=\(seen.count)")
        XCTAssertFalse(ended)
    }

    private func captureNativePresentation(_ window: UIWindow, name: String) {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func emit(_ data: NSDictionary, to delegate: NSObject) {
        delegate.perform(NSSelectorFromString("reactionReceived:"), with: data)
    }
}

private class ReactionDelegateFixture: NSObject {
    var calls = 0
    var lastPayload: NSDictionary?
    @objc dynamic func reactionReceived(_ data: NSDictionary) { calls += 1; lastPayload = data }
}
private final class DerivedReactionDelegateFixture: ReactionDelegateFixture {}
