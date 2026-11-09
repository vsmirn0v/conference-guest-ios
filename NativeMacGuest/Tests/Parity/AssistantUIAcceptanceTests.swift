import AppKit
import ApplicationServices
import AVFoundation
import ConferenceCore
import LiveKitWebRTC
import SwiftUI
import XCTest
@testable import RockNativeDesktop

/// Real SwiftUI presentation and AppKit accessibility actions over isolated data.
/// No cloud account, live meeting, model download, or physical audio is used.
@MainActor final class AssistantUIAcceptanceTests: XCTestCase {
    private enum Flow: String { case open, send, reaction, say, dismiss, decline }
    private struct Rendered {
        let window: NSWindow
        let hosting: NSHostingView<AnyView>
        let name: String
    }

    private var language: String { Bundle.main.preferredLocalizations.first ?? "en" }
    private var artifacts: URL {
        let folder = ProcessInfo.processInfo.environment["ASSISTANT_UI_ARTIFACTS"] ?? "assistant-ui-review"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func store() -> AttentionStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("assistant-ui-\(UUID().uuidString)")
        let defaults = UserDefaults(suiteName: "assistant-ui-\(UUID().uuidString)")!
        let keys = AttentionKeychain(service: "assistant-ui-tests-\(UUID().uuidString)")
        addTeardownBlock { keys.deleteAll(); try? FileManager.default.removeItem(at: root) }
        return AttentionStore(root: root, defaults: defaults, keychain: keys)
    }

    private func window(_ title: String, at: Date) -> (AttentionWindow, AttentionVerdict) {
        let line = AttentionWindow.Line(id: "line-\(title)", ref: "L1", source: .speech, speaker: "Anna",
            isYou: false, text: "Vitalii, could you answer the release question?", at: at, mentionsYou: true)
        let window = AttentionWindow(meetingTitle: title, lines: [line], reactions: [], joined: [], left: [],
            participantCount: 2, microphoneOn: false, soundOn: true, builtAt: at)
        return (window, AttentionVerdict(level: .now, probability: 0.9,
            reason: "Anna is waiting for your release answer.", evidence: [line.id], action: .chat))
    }

    @discardableResult
    private func seed(_ store: AttentionStore, _ title: String, at: Date = Date(),
                      outcome: AttentionDecisionRecord.Outcome = .crowdedOut) -> UUID {
        let id = UUID(), meetingID = UUID(), invitation = URL(string: "https://example.test/calls/\(UUID().uuidString)")!
        let (window, verdict) = window(title, at: at)
        store.log(.init(id: id, at: at, meetingTitle: title, meetingID: meetingID, invitation: invitation,
            presetID: nil, window: window, verdict: verdict, provider: "local", model: "fixture", outcome: outcome))
        return id
    }

    private func meeting(_ title: String) async throws -> NativeDesktopMeetingModel {
        let engine = AssistantUIEngine()
        let model = NativeDesktopMeetingModel(destination: try .verified(
            URL(string: "https://example.test/calls/\(UUID().uuidString)")!, engine: .guest),
            name: "Vitalii", title: title, engine: engine)
        try await model.connect()
        addTeardownBlock { _ = await model.leave() }
        return model
    }

    private func settle() async {
        for _ in 0..<4 {
            await Task.yield()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private func wait(_ predicate: @escaping () -> Bool) async throws {
        for _ in 0..<200 where !predicate() { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate())
    }

    private func present<V: View>(_ view: V, size: NSSize, name: String) async -> Rendered {
        let hosting = NSHostingView(rootView: AnyView(view))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Assistant acceptance \(UUID().uuidString)"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 900, height: 560)
        window.contentView = hosting
        window.setContentSize(size)
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        await settle()
        addTeardownBlock { window.close() }
        return Rendered(window: window, hosting: hosting, name: name)
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func children(_ element: AXUIElement) -> [AXUIElement] {
        (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    private func nodes(_ root: AXUIElement) -> [AXUIElement] {
        [root] + children(root).flatMap(nodes)
    }

    private func nodes(_ rendered: Rendered) -> [AXUIElement] {
        let application = AXUIElementCreateApplication(getpid())
        guard let window = children(application).first(where: {
            (attribute($0, kAXTitleAttribute) as? String) == rendered.window.title
        }) else { return [] }
        return nodes(window)
    }

    private func strings(_ element: AXUIElement) -> [String] {
        var values = [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, "AXLabel", "AXAccessibilityLabel",
                      kAXValueAttribute, kAXIdentifierAttribute, kAXHelpAttribute]
            .compactMap { attribute(element, $0) as? String }
        var names: CFArray?
        if AXUIElementCopyAttributeNames(element, &names) == .success, let names {
            values += (names as NSArray).compactMap { name in
                guard let name = name as? String else { return nil }
                return attribute(element, name) as? String
            }
        }
        return Array(Set(values)).sorted()
    }

    private func button(_ rendered: Rendered, _ title: String) -> AXUIElement? {
        nodes(rendered).first {
            (attribute($0, kAXRoleAttribute) as? String) == kAXButtonRole && strings($0).contains(title)
        }
    }

    private func element(_ rendered: Rendered, identifier: String) -> AXUIElement? {
        nodes(rendered).first { (attribute($0, kAXIdentifierAttribute) as? String) == identifier }
    }

    private func containsText(_ rendered: Rendered, _ text: String) -> Bool {
        nodes(rendered).contains { strings($0).contains { $0.localizedCaseInsensitiveContains(text) } }
    }

    private func press(_ rendered: Rendered, _ title: String) async throws {
        if button(rendered, title) == nil { try? capture(rendered) }
        let target = try XCTUnwrap(button(rendered, title), "Missing button \(title)")
        XCTAssertEqual(AXUIElementPerformAction(target, kAXPressAction as CFString), .success)
        await settle()
    }

    private func press(_ rendered: Rendered, identifier: String) async throws {
        if element(rendered, identifier: identifier) == nil { try? capture(rendered) }
        let target = try XCTUnwrap(element(rendered, identifier: identifier), "Missing accessibility element \(identifier)")
        XCTAssertEqual(AXUIElementPerformAction(target, kAXPressAction as CFString), .success)
        await settle()
    }

    private func momentRow(_ rendered: Rendered, _ title: String) -> AXUIElement? {
        nodes(rendered).first {
            (attribute($0, kAXRoleAttribute) as? String) == kAXButtonRole &&
            (attribute($0, kAXIdentifierAttribute) as? String) == "attention.moment" &&
            strings($0).contains { $0.localizedCaseInsensitiveContains(title) }
        }
    }

    private func capture(_ rendered: Rendered) throws {
        rendered.hosting.layoutSubtreeIfNeeded()
        let bounds = rendered.hosting.bounds
        let image = try XCTUnwrap(rendered.hosting.bitmapImageRepForCachingDisplay(in: bounds))
        rendered.hosting.cacheDisplay(in: bounds, to: image)
        let data = try XCTUnwrap(image.representation(using: .png, properties: [:]))
        let base = "\(language)-\(rendered.name)"
        try data.write(to: artifacts.appendingPathComponent(base + ".png"))
        let report = nodes(rendered).flatMap(strings).joined(separator: "\n")
        try report.write(to: artifacts.appendingPathComponent(base + "-accessibility.txt"), atomically: true, encoding: .utf8)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = base
        attachment.lifetime = .keepAlways
        add(attachment)
        let tree = XCTAttachment(string: report)
        tree.name = base + "-accessibility"
        tree.lifetime = .keepAlways
        add(tree)
    }

    private func assertTerminal(_ rendered: Rendered, why: Bool = true) {
        for title in [L("Send"), L("Say it"), L("Open meeting"), L("Dismiss"), L("Decline")] {
            XCTAssertNil(button(rendered, title), "Terminal detail still exposes \(title)")
        }
        XCTAssertFalse(containsText(rendered, L("Why not?")), "Terminal detail must leave decline editing")
        XCTAssertNil(element(rendered, identifier: "attention.reply.send"))
        if why { XCTAssertNotNil(button(rendered, L("Why")), "Terminal detail keeps its inspector entry") }
    }

    func testOverflowButtonUsesAccessibilityActionWithoutDelivery() async throws {
        let store = store(); await store.waitForMoments()
        store.enabled = true
        store.provider = .init(kind: .local, baseURL: "http://192.168.1.5:1/v1", model: "fixture")
        let models = try await [meeting("Overflow A"), meeting("Overflow B"), meeting("Overflow C")]
        let judge = AssistantUIJudge(), coordinator = AttentionCoordinator(store: store)
        coordinator.meetings = { models }
        coordinator.hasTranscript = { _ in true }
        coordinator.makeJudge = { _, _ in judge }
        coordinator.replyChannels = { _ in ReplyChannels() }
        for (index, model) in models.enumerated() {
            model.receiveLocalLineForTesting(.init(id: "line-\(index)", trackID: "a", text: "Vitalii?",
                start: Date(), end: Date()))
        }
        judge.next = .init(level: .now, probability: 0.9, reason: "Waiting.", evidence: ["L1"], action: .open)
        await coordinator.tick(); await coordinator.tick(); await coordinator.tick()
        XCTAssertEqual(coordinator.cards.count, 2)
        XCTAssertEqual(coordinator.overflowMomentIDs.count, 1)
        var opened = 0, sent: [String] = [], reacted: [MeetingReaction] = []
        coordinator.deliverChat = { _, text in sent.append(text); return true }
        coordinator.deliverReaction = { _, reaction in reacted.append(reaction) }
        let rendered = await present(AttentionCardStack(attention: coordinator, openAssistant: { opened += 1 }),
            size: NSSize(width: 430, height: 650), name: "overflow")
        XCTAssertNotNil(element(rendered, identifier: "attention.overflow"))
        try await press(rendered, identifier: "attention.overflow")
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(store.momentHistory.moments(filter: .answered).count, 0)
        XCTAssertTrue(sent.isEmpty && reacted.isEmpty, "Opening Assistant does not deliver chat or a reaction")
        try capture(rendered)
    }

    func testTerminalFlowsRenderReadOnlyAndCannotDeliverTwice() async throws {
        for flow in [Flow.open, .send, .reaction, .say, .dismiss, .decline] {
            let store = store(); await store.waitForMoments()
            let model = try await meeting(flow.rawValue)
            let coordinator = AttentionCoordinator(store: store)
            coordinator.meetings = { [model] }
            var chat: [String] = [], reactions: [MeetingReaction] = [], spoken = 0, opened = 0
            coordinator.replyChannels = { _ in .init(chat: true, reactions: [.like]) }
            coordinator.deliverChat = { _, text in chat.append(text); return true }
            coordinator.deliverReaction = { _, reaction in reactions.append(reaction) }
            coordinator.deliverVoice = { _, _ in spoken += 1 }
            coordinator.voiceAvailable = { _ in true }
            coordinator.synthesizeOverride = { _ in
                let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
                buffer.frameLength = 480
                return buffer
            }
            coordinator.openMeeting = { _ in opened += 1 }

            let at = Date(), id = UUID(), (window, initialVerdict) = window(flow.rawValue, at: at)
            let verdict = AttentionVerdict(level: flow == .dismiss ? .soon : .now, probability: initialVerdict.probability,
                reason: initialVerdict.reason, evidence: initialVerdict.evidence, action: initialVerdict.action)
            store.log(.init(id: id, at: at, meetingTitle: model.title, meetingID: model.sessionID, invitation: model.invitation,
                presetID: nil, window: window, verdict: verdict, provider: "local", model: "fixture", outcome: .shown))
            let draft = ReplyDraft(chat: "The release is ready.", reaction: .like)
            store.log(.init(at: at, meetingTitle: model.title, meetingID: model.sessionID, invitation: model.invitation,
                provider: "local", model: "fixture", outcome: .drafted, decisionID: id, draft: draft))
            let card = AttentionCoordinator.Card(id: id, meetingID: model.sessionID, meetingTitle: model.title,
                invitation: model.invitation, seriesID: nil, verdict: verdict, window: window, presetID: nil,
                threshold: 0.5, provider: "local", model: "fixture", latency: 0.1, createdAt: at,
                channels: .init(chat: true, reactions: [.like]), draft: draft,
                canDraft: false, canSpeak: true)
            coordinator.selectedCard = card
            let rendered = await present(AttentionMomentsView(attention: coordinator, store: store),
                size: NSSize(width: 900, height: 560), name: "terminal-\(flow.rawValue)")
            coordinator.showMoment(id)
            await settle()

            switch flow {
            case .open: try await press(rendered, L("Open meeting"))
            case .send:
                try await wait { self.element(rendered, identifier: "attention.reply.send") != nil }
                try await press(rendered, identifier: "attention.reply.send")
            case .reaction: try await press(rendered, MeetingReaction.like.emoji)
            case .say:
                try await press(rendered, L("Say it"))
                try await wait { store.momentHistory.moment(id)?.state == .answered }
            case .dismiss: try await press(rendered, L("Dismiss"))
            case .decline:
                try await press(rendered, L("Decline"))
                try await press(rendered, PresetExample.DeclineReason.notUrgent.title)
            }
            await settle()
            let expected: AttentionMoment.State = [.dismiss, .decline].contains(flow)
                ? (flow == .dismiss ? .dismissed : .notForMe) : .answered
            let moment = try XCTUnwrap(store.momentHistory.moment(id))
            XCTAssertEqual(moment.state, expected, flow.rawValue)
            XCTAssertEqual(coordinator.selectedCard?.readOnly, true, flow.rawValue)
            XCTAssertFalse(containsText(rendered, L("This meeting is not open. The Moment is read-only; join it again to answer.")),
                "An active terminal meeting must not claim to be closed")
            assertTerminal(rendered)
            try capture(rendered)

            coordinator.selectMoment(moment)
            let selected = try XCTUnwrap(coordinator.selectedCard)
            XCTAssertTrue(selected.readOnly)
            XCTAssertFalse(coordinator.sendReply(selected, text: "Second delivery"))
            XCTAssertFalse(coordinator.sendReaction(selected, .fire))
            coordinator.sayReply(selected, text: "Second delivery")
            await settle()
            XCTAssertEqual(chat.count, flow == .send ? 1 : 0, flow.rawValue)
            XCTAssertEqual(reactions.count, flow == .reaction ? 1 : 0, flow.rawValue)
            XCTAssertEqual(spoken, flow == .say ? 1 : 0, flow.rawValue)
            XCTAssertEqual(opened, flow == .open ? 1 : 0, flow.rawValue)
        }
    }

    func testVoiceOverAuditoryReview() async throws {
        guard ProcessInfo.processInfo.environment["ASSISTANT_UI_VOICEOVER_REVIEW"] == "1" else {
            throw XCTSkip("Explicit auditory VoiceOver review only")
        }
        let store = store(); await store.waitForMoments()
        let model = try await meeting("VoiceOver review")
        let coordinator = AttentionCoordinator(store: store)
        coordinator.meetings = { [model] }
        coordinator.replyChannels = { _ in .init(chat: true, reactions: [.like]) }
        coordinator.voiceAvailable = { _ in true }
        let at = Date(), id = UUID(), (window, verdict) = window("VoiceOver review", at: at)
        store.log(.init(id: id, at: at, meetingTitle: model.title, meetingID: model.sessionID, invitation: model.invitation,
            presetID: nil, window: window, verdict: verdict, provider: "local", model: "fixture", outcome: .shown))
        let draft = ReplyDraft(chat: "The release is ready.", reaction: .like)
        coordinator.selectedCard = .init(id: id, meetingID: model.sessionID, meetingTitle: model.title,
            invitation: model.invitation, seriesID: nil, verdict: verdict, window: window, presetID: nil,
            threshold: 0.5, provider: "local", model: "fixture", latency: 0.1, createdAt: at,
            channels: .init(chat: true, reactions: [.like]), draft: draft, canDraft: false, canSpeak: true)
        let rendered = await present(AttentionMomentsView(attention: coordinator, store: store),
            size: NSSize(width: 900, height: 560), name: "voiceover-review")
        coordinator.showMoment(id)
        await settle()
        XCTAssertEqual(coordinator.selectedCard?.draft?.chat, "The release is ready.")
        XCTAssertTrue(containsText(rendered, "The release is ready."))
        XCTAssertNotNil(element(rendered, identifier: "attention.moment"))
        rendered.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSLog("VOICEOVER_REVIEW_BEGIN \(self.language)")
        try await Task.sleep(for: .seconds(5))
        for _ in 0..<16 {
            for key in [CGKeyCode(124)] {
                let source = CGEventSource(stateID: .hidSystemState)
                let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
                let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
                down?.flags = [.maskControl, .maskAlternate]; up?.flags = [.maskControl, .maskAlternate]
                down?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)
            }
            try await Task.sleep(for: .seconds(4))
        }
        NSLog("VOICEOVER_REVIEW_END \(self.language)")
    }

    func testLocalizedErrorsNotificationSelectionAndNarrowLayout() async throws {
        let store = store(); await store.waitForMoments()
        let coordinator = AttentionCoordinator(store: store)
        let now = Date()
        let firstID = seed(store, "Summary failure", at: now.addingTimeInterval(-80))
        XCTAssertTrue(store.momentsLoaded)
        XCTAssertEqual(store.momentHistory.moments.map(\.id), [firstID])
        let first = try XCTUnwrap(store.momentHistory.moment(firstID))
        let secondID = seed(store, "Reminder failure", at: now.addingTimeInterval(-90))
        XCTAssertEqual(Set(store.momentHistory.moments.map(\.id)), [firstID, secondID])
        let second = try XCTUnwrap(store.momentHistory.moment(secondID))
        for index in 0..<30 { seed(store, "Unread \(index)", at: now.addingTimeInterval(TimeInterval(index))) }
        await coordinator.summarize(first)
        coordinator.scheduleReminder = { _, _ in throw NSError(domain: "AssistantUI", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Reminder fixture failed"]) }
        coordinator.remind(second)
        try await wait { coordinator.reminderErrorByMoment[second.id] != nil }

        let rendered = await present(AttentionMomentsView(attention: coordinator, store: store),
            size: NSSize(width: 900, height: 560), name: "errors-first")
        coordinator.showMoment(first.id)
        await settle()
        XCTAssertTrue(containsText(rendered, first.verdict.reason))
        XCTAssertTrue(containsText(rendered, L("The meeting is not open, so there is no later conversation to summarize.")))
        XCTAssertFalse(containsText(rendered, "Reminder fixture failed"))
        XCTAssertNotNil(button(rendered, L("Remind me")))
        XCTAssertNotNil(button(rendered, L("Since then")))
        try capture(rendered)

        coordinator.showMoment(second.id)
        await settle()
        XCTAssertFalse(containsText(rendered, L("The meeting is not open, so there is no later conversation to summarize.")))
        XCTAssertTrue(containsText(rendered, "Reminder fixture failed"))
        try capture(Rendered(window: rendered.window, hosting: rendered.hosting, name: "errors-second"))

        let notificationID = seed(store, "Notification target", at: now.addingTimeInterval(-200))
        let target = try XCTUnwrap(store.momentHistory.moment(notificationID))
        XCTAssertFalse(target.seen, "The notification target must begin outside the rendered list")
        XCTAssertNil(momentRow(rendered, target.meetingTitle), "The old target must not already be in the viewport")
        coordinator.showMoment(target.id)
        try await wait { store.momentHistory.moment(target.id)?.seen == true }
        await settle()
        XCTAssertNotNil(momentRow(rendered, target.meetingTitle),
            "Notification selection must expose and retain the target row in the viewport")
        XCTAssertTrue(containsText(rendered, target.meetingTitle))
        try capture(Rendered(window: rendered.window, hosting: rendered.hosting, name: "notification-selection"))

        let answered = seed(store, "Narrow terminal layout", at: now.addingTimeInterval(100), outcome: .shown)
        store.log(.init(at: now.addingTimeInterval(101), meetingTitle: "Narrow terminal layout", provider: "local",
            model: "fixture", outcome: .replied, decisionID: answered,
            sent: "The release is ready and the complete verification notes are available in Assistant."))
        coordinator.showMoment(answered)
        await settle()
        assertTerminal(rendered)
        try capture(Rendered(window: rendered.window, hosting: rendered.hosting, name: "narrow-terminal"))

        let closed = try XCTUnwrap(store.momentHistory.moment(first.id))
        coordinator.showMoment(closed.id)
        await settle()
        XCTAssertTrue(containsText(rendered, L("This meeting is not open. The Moment is read-only; join it again to answer.")))
    }

    func testTranscriptionPopoverStaysOpenAcrossLocalAndRemoteUpdates() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("listen-ui-\(UUID().uuidString)", isDirectory: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("listen-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: root)
        }
        func makeFile(_ name: String) throws -> ListenModelCatalog.File {
            let url = source.appendingPathComponent(name)
            try Data(name.utf8).write(to: url)
            return .init(name: name, size: Int64(name.utf8.count), url: url, sha256: try ListenModelStore.sha256(of: url))
        }
        let vad = ListenModelCatalog.Model(id: "vad", role: "vad", title: "VAD", kind: "silero_vad", featureDim: nil,
            languages: [], licence: "MIT", source: source, files: [try makeFile("vad.onnx")], config: ["model": "vad.onnx"])
        let listen = ListenModelCatalog.Model(id: "giga", role: "listen", title: "GigaAM", kind: ListenModelStore.coreMLGigaAMKind,
            featureDim: 64, languages: ["ru"], licence: "MIT", source: source,
            files: [try makeFile("encoder"), try makeFile("decoder"), try makeFile("joint"), try makeFile("tokens.txt")],
            config: ["encoder": "encoder", "decoder": "decoder", "joint": "joint", "tokens": "tokens.txt"])
        let defaults = UserDefaults(suiteName: "listen-ui-\(UUID().uuidString)")!
        let listenStore = ListenModelStore(catalog: .init(schemaVersion: 1, runtime: "test", models: [vad, listen]),
            root: root, defaults: defaults)
        listenStore.selectedID = "giga"
        listenStore.enabled = true
        listenStore.download(listen)
        try await wait { listenStore.ready }

        let engine = AssistantUIEngine()
        let model = NativeDesktopMeetingModel(destination: try .verified(
            URL(string: "https://example.test/calls/\(UUID().uuidString)")!, engine: .guest),
            name: "Vitalii", title: "Popover stability", engine: engine, listenStore: listenStore)
        try await model.connect()
        addTeardownBlock { _ = await model.leave() }
        XCTAssertEqual(model.transcriptionIndicator, .local)

        let workspace = NativeDesktopWorkspace(
            detect: { .verified(.guest(endpoint: $0)) },
            makeMeeting: { _, _, _, _ in model }
        )
        workspace.join(model.invitation, engine: .guest, title: model.title)
        try await wait { workspace.selectedMeeting === model && !workspace.preparing }
        workspace.show()
        await settle()
        addTeardownBlock { _ = await workspace.leave() }

        let app = AXUIElementCreateApplication(getpid())
        func findIndicator() -> AXUIElement? {
            children(app).flatMap(nodes).first { (attribute($0, kAXIdentifierAttribute) as? String) == "transcription.indicator" }
        }
        func hasPopoverWindow() -> Bool {
            NSApp.windows.contains { $0.isVisible && $0.className.localizedCaseInsensitiveContains("Popover") }
        }

        // 1. Local transcription popover remains open across incoming local lines, speaking changes, and workspace updates.
        let localButton = try XCTUnwrap(findIndicator(), "Missing local transcription indicator in toolbar")
        XCTAssertEqual(AXUIElementPerformAction(localButton, kAXPressAction as CFString), .success)
        await settle()
        XCTAssertTrue(hasPopoverWindow(), "Local transcription popover must open on click")

        for index in 1...3 {
            model.receiveLocalLineForTesting(.init(id: "local-\(index)", trackID: "anna", text: "Line \(index)", start: Date(), end: Date()))
            var snap = engine.snapshot
            snap.participants = [.init(id: "me", name: "Vitalii", isLocal: true), .init(id: "anna", name: "Anna", speaking: index % 2 == 1)]
            engine.onState?(snap)
            workspace.objectWillChange.send()
            await settle()
            XCTAssertTrue(hasPopoverWindow(), "Local transcription popover must not auto-close on update \(index)")
        }

        // Close local popover explicitly via button toggle.
        XCTAssertEqual(AXUIElementPerformAction(try XCTUnwrap(findIndicator()), kAXPressAction as CFString), .success)
        try await wait { !hasPopoverWindow() }

        // 2. Remote transcription popover remains open across incoming server transcript snapshots and workspace updates.
        var features = GuestMeetingSnapshot()
        features.transcriptionStatus = .active
        model.receiveFeaturesForTesting(features)
        model.dismissTranscriptionAnnouncement()
        await settle()
        XCTAssertEqual(model.transcriptionIndicator, .on)

        let remoteButton = try XCTUnwrap(findIndicator(), "Missing remote transcription indicator in toolbar")
        XCTAssertEqual(AXUIElementPerformAction(remoteButton, kAXPressAction as CFString), .success)
        await settle()
        XCTAssertTrue(hasPopoverWindow(), "Remote transcription popover must open on click")

        for index in 1...3 {
            features.transcript.append(.init(id: "remote-\(index)", participantID: "anna", participantName: "Anna",
                text: "Remote line \(index)", sentAt: Date(), isOwn: false, receivedAt: Date()))
            model.receiveFeaturesForTesting(features)
            workspace.objectWillChange.send()
            await settle()
            XCTAssertTrue(hasPopoverWindow(), "Remote transcription popover must not auto-close on remote update \(index)")
        }
    }
}

private final class AssistantUIJudge: AttentionJudge, @unchecked Sendable {
    var next = AttentionVerdict(level: .no, probability: 0.1, reason: "Quiet.", evidence: [], action: .none)
    func judge(_ request: JudgeRequest) async throws -> JudgeResult {
        let evidence = next.evidence.compactMap { request.window.line(ref: $0)?.id }
        var verdict = next; verdict.evidence = evidence
        return .init(verdict: verdict, latency: 0.1)
    }
}

@MainActor private final class AssistantUIEngine: NativeDesktopMeetingEngine {
    var onState: ((NativeDesktopExternalSnapshot) -> Void)?
    var onVideo: (([NativeDesktopExternalVideo]) -> Void)?
    var onLocalCamera: ((LKRTCVideoTrack?) -> Void)?
    var onTitle: ((String) -> Void)?
    var supportsLocalTranscription: Bool { true }
    var factory: LKRTCPeerConnectionFactory? { nil }
    private(set) var snapshot = NativeDesktopExternalSnapshot()
    var incomingVideo: [NativeDesktopExternalVideo] { [] }
    func connect(invitation: URL, name: String, quiet: Bool) async throws {
        snapshot = .init(phase: .connected, playoutOn: !quiet, participants: [
            .init(id: "me", name: name, isLocal: true), .init(id: "anna", name: "Anna")])
        onState?(snapshot)
    }
    func reconnect() async throws {}
    func setMicrophone(_ enabled: Bool) async throws { snapshot.microphoneOn = enabled; onState?(snapshot) }
    func setCamera(_ enabled: Bool) async throws {}
    func setPlayout(_ enabled: Bool) async throws { snapshot.playoutOn = enabled; onState?(snapshot) }
    func setScreenTrack(_ track: LKRTCVideoTrack?) async throws {}
    func leave() async -> Bool { snapshot.phase = .left; onState?(snapshot); return true }
}
