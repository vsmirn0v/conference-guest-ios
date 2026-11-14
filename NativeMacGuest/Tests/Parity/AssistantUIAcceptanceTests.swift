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
        let url = folder.hasPrefix("/") ? URL(fileURLWithPath: folder, isDirectory: true)
            : FileManager.default.temporaryDirectory.appendingPathComponent(folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func store() -> AttentionStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("assistant-ui-\(UUID().uuidString)")
        let defaults = UserDefaults(suiteName: "assistant-ui-\(UUID().uuidString)")!
        let keys = AttentionKeychain(service: "assistant-ui-tests-\(UUID().uuidString)")
        addTeardownBlock { keys.deleteAll(); try? FileManager.default.removeItem(at: root) }
        let store = AttentionStore(root: root, defaults: defaults, keychain: keys)
        closeLibraryAtTeardown(store)
        return store
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

    private func present<V: View>(_ view: V, size: NSSize, name: String, minSize: NSSize? = nil) async -> Rendered {
        let hosting = NSHostingView(rootView: AnyView(view))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Assistant acceptance \(UUID().uuidString)"
        window.isReleasedWhenClosed = false
        window.minSize = minSize ?? NSSize(width: 900, height: 560)
        window.contentView = hosting
        window.setContentSize(size)
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        await settle()
        addTeardownBlock { window.close() }
        return Rendered(window: window, hosting: hosting, name: name)
    }

    private func views(_ root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(views)
    }

    /// The Debug host intentionally resets launch preferences. Route localization
    /// through a temporary Bundle subclass so this test always renders Russian.
    private final class RussianBundleForTesting: Bundle, @unchecked Sendable {
        override var preferredLocalizations: [String] { ["ru"] }
        override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
            guard let path = Bundle.main.path(forResource: "ru", ofType: "lproj"),
                  let bundle = Bundle(path: path) else { return super.localizedString(forKey: key, value: value, table: tableName) }
            return bundle.localizedString(forKey: key, value: value, table: tableName)
        }
    }

    private func withRussianBundle<T>(_ body: () async throws -> T) async throws -> T {
        let original = object_getClass(Bundle.main)
        let russianPath = try XCTUnwrap(Bundle.main.path(forResource: "ru", ofType: "lproj"))
        XCTAssertTrue(Bundle(path: russianPath)?.localizedString(forKey: "Mentions", value: nil, table: nil) == "Упоминания",
            "The Russian fixture must load the app's resources")
        XCTAssertNotNil(original)
        XCTAssertNotNil(object_setClass(Bundle.main, RussianBundleForTesting.self))
        defer { object_setClass(Bundle.main, original!) }
        return try await body()
    }

    func testDisabledTranscriptionShowsPendingDetectorRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pending-detector-ui-\(UUID())", isDirectory: true)
        let suite = "pending-detector-ui-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let file = ListenModelCatalog.File(name: "missing.bin", size: 10,
            url: root.appendingPathComponent("missing.bin"), sha256: String(repeating: "a", count: 64))
        func model(_ id: String, role: String, kind: String) -> ListenModelCatalog.Model {
            .init(id: id, role: role, title: id, kind: kind, featureDim: nil, languages: [], licence: "",
                  source: root, files: [file], config: ["model": "missing.bin"])
        }
        let old = model("Old", role: "listen", kind: "nemo_ctc")
        let replacement = model("Replacement", role: "listen", kind: "nemo_ctc")
        let vad = model("Detector", role: "vad", kind: "silero_vad")
        defaults.set(old.id, forKey: ListenModelStore.modelKey)
        let listen = ListenModelStore(catalog: .init(schemaVersion: 1, runtime: "fixture", models: [old, replacement, vad]),
                                      root: root, defaults: defaults)
        listen.selectModel(replacement)
        XCTAssertFalse(listen.enabled)
        XCTAssertEqual(listen.pendingID, replacement.id)
        let rendered = await present(NativeDesktopTranscriptionSettings(store: listen),
                                     size: NSSize(width: 760, height: 760), name: "transcription-pending-detector")
        XCTAssertTrue(containsText(rendered, L("Voice detector")))
        listen.cancel(replacement); listen.cancel(vad)
    }

    func testAssistantSettingsNavigationAndPrivacyCopyInRussian() async throws {
        try await withRussianBundle {
            let store = store()
            let coordinator = AttentionCoordinator(store: store)
            let rendered = await present(AssistantSettingsHarness(store: store, attention: coordinator),
                                         size: NSSize(width: 760, height: 760), name: "assistant-settings-sections",
                                         minSize: NSSize(width: 620, height: 500))
            XCTAssertNotNil(element(rendered, identifier: "assistant.settings.privacy"))
            XCTAssertTrue(containsText(rendered, "Когда микрофон включён"))
            try capture(rendered)
            try await press(rendered, identifier: "assistant.settings.privacy")
            XCTAssertTrue(containsText(rendered, "Когда микрофон включён, звук отправляется участникам встречи"))
            XCTAssertFalse(containsText(rendered, "Звук никогда не покидает этот Mac"))
            try capture(.init(window: rendered.window, hosting: rendered.hosting, name: "assistant-settings-privacy"))
        }
    }

    func testRussianVoiceRecoveryOffersRepairWithoutRemovingVoiceOrModel() async throws {
        try await withRussianBundle {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("voice-ui-\(UUID())", isDirectory: true)
            let suite = "voice-ui-\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            addTeardownBlock {
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: root)
            }
            let file = ListenModelCatalog.File(name: "model.json", size: 2, url: URL(fileURLWithPath: "/fixture"),
                                               sha256: String(repeating: "a", count: 64))
            let model = ListenModelCatalog.Model(id: "voice-ui-fixture", role: VoiceCloneSupport.role, title: "Fixture",
                kind: VoiceCloneSupport.kind, featureDim: nil, languages: ["ru"], licence: "",
                source: URL(fileURLWithPath: "/fixture"), files: [file], config: ["architecture": "test"])
            let catalog = ListenModelCatalog(schemaVersion: 1, runtime: "fixture", models: [model])
            let listen = ListenModelStore(catalog: catalog, root: root, defaults: defaults)
            let folder = listen.folder(model)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let modelURL = folder.appendingPathComponent(file.name)
            let modelData = Data("{}".utf8)
            try modelData.write(to: modelURL)
            try "\(file.name) \(file.sha256)".write(to: folder.appendingPathComponent(".verified"), atomically: true, encoding: .utf8)
            listen.refresh()
            let asset = "encoder.h16g.aimodelc"
            let message = "The Neural Engine could not run \(asset) (Foundation._GenericObjCError 0)."
            let identity = ClonedVoicePreparation.identity(for: model, osBuild: "fixture")
            try ClonedVoicePreparation(identity: identity, attempt: UUID(), state: .failed, startedAt: Date(),
                recentStarts: [], message: message).write(folder)
            let voice = VoxVoice(mode: .clone, transcript: "", reference: nil, continuation: nil, patches: 0)
            let voiceURL = root.appendingPathComponent("voxcpm2-voice.json")
            let voiceData = try JSONEncoder().encode(StoredClonedVoice(voice: voice, recordedAt: Date(), seconds: 5))
            try voiceData.write(to: voiceURL)
            let worker = AssistantVoiceUIWorker()
            let engine = ClonedVoiceEngine(connect: { worker })
            let clone = VoiceCloneStore(model: model, listen: listen, folder: root, engine: engine, osBuild: "fixture")
            let rendered = await present(VoiceCloneSettingsView(clone: clone, listen: listen),
                                         size: NSSize(width: 1000, height: 600), name: "voice-recovery")
            XCTAssertTrue(containsText(rendered, "Причина неизвестна"))
            XCTAssertNotNil(button(rendered, "Восстановить голосовую модель"))
            XCTAssertFalse(containsText(rendered, "Foundation._GenericObjCError"))
            // SwiftUI exposes this button's localized title to AX, but does not
            // consistently surface its identifier through the macOS AX tree.
            try await press(rendered, "Восстановить голосовую модель")
            try await wait { clone.preparation == .ready }
            let requests = await worker.requests
            XCTAssertEqual(requests.first?.repairAsset, asset)
            XCTAssertEqual(try Data(contentsOf: modelURL), modelData)
            XCTAssertEqual(try Data(contentsOf: voiceURL), voiceData)
            await engine.unload()
        }
    }

    func testRussianVoicePreparationSpaceShowsShortfallAndRetriesWithoutRemovingSavedData() async throws {
        try await withRussianBundle {
            let gib: Int64 = 1_024 * 1_024 * 1_024
            let initialAvailable = 4 * gib
            var available: Int64? = initialAvailable
            let required = 12 * gib
            let fixture = try voiceRecoveryFixture(failure: .init(kind: .preparationSpace)) {
                .init(availableBytes: available, requiredBytes: required, location: .model)
            }
            let rendered = await present(VoiceCloneSettingsView(clone: fixture.clone, listen: fixture.listen),
                                         size: NSSize(width: 1000, height: 900), name: "voice-preparation-space")
            XCTAssertTrue(containsText(rendered, "Недостаточно места на диске для подготовки вашего голоса"))
            XCTAssertTrue(containsText(rendered, L("Available for preparation: %@.", ByteCountFormatter.string(fromByteCount: initialAvailable, countStyle: .file))))
            XCTAssertTrue(containsText(rendered, L("Estimated free space needed for preparation: %@.", ByteCountFormatter.string(fromByteCount: required, countStyle: .file))))
            XCTAssertTrue(containsText(rendered, L("Free at least %@ more before retrying.", ByteCountFormatter.string(fromByteCount: required - initialAvailable, countStyle: .file))))
            XCTAssertTrue(containsText(rendered, "Загруженная модель и сохранённый голос останутся на месте"))
            XCTAssertNotNil(button(rendered, L("Open Storage Settings")))

            available = nil
            fixture.clone.refreshStorage()
            await settle()
            XCTAssertTrue(containsText(rendered, L("Check working space for voice preparation.")))
            XCTAssertTrue(containsText(rendered, L("The available space could not be checked. Open Storage Settings and try again.")))
            XCTAssertFalse(containsText(rendered, L("Not enough working space to prepare your voice.")))
            XCTAssertFalse(containsText(rendered, L("Ready to retry voice preparation.")))

            available = 14 * gib
            fixture.clone.refreshStorage()
            await settle()
            XCTAssertTrue(containsText(rendered, L("Ready to retry voice preparation.")))
            XCTAssertFalse(containsText(rendered, L("Not enough working space to prepare your voice.")))
            XCTAssertTrue(containsText(rendered, "По этой оценке свободного места достаточно"))
            try await press(rendered, L("Check Again"))
            try await wait { fixture.clone.preparation == .ready }
            let requests = await fixture.worker.requests
            XCTAssertEqual(requests.count, 1)
            XCTAssertNil(requests.first?.repairAsset)
            XCTAssertEqual(try Data(contentsOf: fixture.modelURL), fixture.modelData)
            XCTAssertEqual(try Data(contentsOf: fixture.voiceURL), fixture.voiceData)
            await fixture.engine.unload()
        }
    }

    func testRussianCompilationFailureShowsTechnicalDetailsWithoutClaimingDiskFull() async throws {
        try await withRussianBundle {
            let details = "encoder.h16g.aimodelc (CoreAI 2)"
            let fixture = try voiceRecoveryFixture(failure: .init(kind: .compilation, technicalDetails: details)) {
                .init(availableBytes: 20 * 1_024 * 1_024 * 1_024, requiredBytes: 12 * 1_024 * 1_024 * 1_024)
            }
            let rendered = await present(VoiceCloneSettingsView(clone: fixture.clone, listen: fixture.listen),
                                         size: NSSize(width: 1000, height: 900), name: "voice-compilation-failure")
            XCTAssertTrue(containsText(rendered, "Не удалось скомпилировать модель для Neural Engine"))
            XCTAssertFalse(containsText(rendered, L("Not enough disk space to prepare the voice model.")))
            XCTAssertFalse(containsText(rendered, L("Not enough working space to prepare your voice.")))
            XCTAssertTrue(containsText(rendered, "По этой оценке свободного места достаточно"))
            XCTAssertFalse(containsText(rendered, details))
            // SwiftUI propagates the failure container's identifier to this
            // child on macOS. Find the actual native disclosure by role/title.
            let disclosure = try XCTUnwrap(nodes(rendered).first {
                (attribute($0, kAXRoleAttribute) as? String) == kAXDisclosureTriangleRole &&
                    strings($0).contains(L("Technical details"))
            })
            XCTAssertEqual(AXUIElementPerformAction(disclosure, kAXPressAction as CFString), .success)
            await settle()
            XCTAssertTrue(containsText(rendered, details))
            XCTAssertEqual(try Data(contentsOf: fixture.modelURL), fixture.modelData)
            XCTAssertEqual(try Data(contentsOf: fixture.voiceURL), fixture.voiceData)
            await fixture.engine.unload()
        }
    }

    private struct VoiceRecoveryFixture {
        let clone: VoiceCloneStore
        let listen: ListenModelStore
        let worker: AssistantVoiceUIWorker
        let engine: ClonedVoiceEngine
        let modelURL: URL
        let modelData: Data
        let voiceURL: URL
        let voiceData: Data
    }

    private func voiceRecoveryFixture(failure: ClonedVoiceFailure,
                                      storage: @escaping () -> VoiceStorageSnapshot) throws -> VoiceRecoveryFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voice-recovery-ui-\(UUID())", isDirectory: true)
        let suite = "voice-recovery-ui-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let file = ListenModelCatalog.File(name: "model.json", size: 2, url: URL(fileURLWithPath: "/fixture"),
                                           sha256: String(repeating: "a", count: 64))
        let model = ListenModelCatalog.Model(id: "voice-recovery-ui", role: VoiceCloneSupport.role, title: "Fixture",
            kind: VoiceCloneSupport.kind, featureDim: nil, languages: ["ru"], licence: "",
            source: URL(fileURLWithPath: "/fixture"), files: [file], config: ["architecture": "test"])
        let listen = ListenModelStore(catalog: .init(schemaVersion: 1, runtime: "fixture", models: [model]),
                                      root: root, defaults: defaults)
        let folder = listen.folder(model)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let modelURL = folder.appendingPathComponent(file.name), modelData = Data("{}".utf8)
        try modelData.write(to: modelURL)
        try "\(file.name) \(file.sha256)".write(to: folder.appendingPathComponent(".verified"), atomically: true, encoding: .utf8)
        listen.refresh()
        let identity = ClonedVoicePreparation.identity(for: model, osBuild: "fixture")
        try ClonedVoicePreparation(identity: identity, attempt: UUID(), state: .failed, startedAt: Date(),
            recentStarts: [], message: failure.technicalDetails, failureInfo: failure).write(folder)
        let voice = VoxVoice(mode: .clone, transcript: "", reference: nil, continuation: nil, patches: 0)
        let voiceURL = root.appendingPathComponent("voxcpm2-voice.json")
        let voiceData = try JSONEncoder().encode(StoredClonedVoice(voice: voice, recordedAt: Date(), seconds: 5))
        try voiceData.write(to: voiceURL)
        let worker = AssistantVoiceUIWorker()
        let engine = ClonedVoiceEngine(connect: { worker })
        let clone = VoiceCloneStore(model: model, listen: listen, folder: root, engine: engine, osBuild: "fixture",
                                   preparationStorage: { _ in storage() })
        return .init(clone: clone, listen: listen, worker: worker, engine: engine, modelURL: modelURL,
                     modelData: modelData, voiceURL: voiceURL, voiceData: voiceData)
    }

    private func requiredWidth(of control: NSSegmentedControl) -> CGFloat {
        let labels = (0..<control.segmentCount).compactMap { control.label(forSegment: $0) }
        let measuring = NSSegmentedControl(labels: labels, trackingMode: control.trackingMode,
            target: nil, action: nil)
        measuring.controlSize = control.controlSize
        measuring.segmentStyle = control.segmentStyle
        if let font = control.font { measuring.font = font }
        measuring.sizeToFit()
        return measuring.frame.width
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

    func testRussianMeetingWorkspaceLiveParallelAndReloadedReview() async throws {
        let store = store()
        store.enabled = true
        let coordinator = AttentionCoordinator(store: store)
        let name = "workspace-ui-\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { preferences.removePersistentDomain(forName: name) }
        let history = RoomHistoryStore(storage: OutcomeFixtureCalendarStorage())
        let library = NativeDesktopLibrary(preferences: preferences, history: history,
            syncStorage: OutcomeFixtureCalendarStorage())
        let workspace = NativeDesktopWorkspace(library: library, detect: { _ in .unknown },
            makeMeeting: { destination, name, title, quiet in
                NativeDesktopMeetingModel(destination: destination, name: name, title: title, quiet: quiet, engine: AssistantUIEngine())
            }, attention: coordinator)
        addTeardownBlock {
            _ = await workspace.leave()
            await MainActor.run { coordinator.stop() }
        }
        let rooms = ["Проверка релиза", "План инфраструктуры", "Резервное восстановление"]
        for (index, title) in rooms.enumerated() {
            workspace.join(URL(string: "https://example.test/calls/workspace-\(index)")!,
                engine: .guest, title: title, quiet: index == 2, nameOverride: "Виталий")
            try await wait { workspace.meetings.count == index + 1 && workspace.meetings.allSatisfy(\.connected) }
        }
        let first = try XCTUnwrap(workspace.meetings.first)
        let journal = store.meetingLibrary.workspaceJournal
        let at = Date().addingTimeInterval(-10)
        let line = "Начинаем с десяти процентов после успешной проверки."
        let reply = "Я проверю восстановление перед расширением."
        journal.observe(sessionID: first.sessionID, events: [
            .init(id: "speech:fixture", kind: .transcript, occurredAt: at, source: "local", author: "Анна", text: line)
        ])
        journal.recordGap(sessionID: first.sessionID, reason: "connection", from: at - 20, until: at - 15)
        let source = MeetingWorkspaceEvent.SourceSnapshot(id: "trigger:fixture", title: "Анна", text: line,
            revision: "fixture", capturedAt: at)
        XCTAssertTrue(journal.recordAssistantReply(sessionID: first.sessionID, id: "reply", text: reply, source: "voice",
            status: .spoken, sourceSnapshots: [source]))
        try await withRussianBundle {
            let view = NativeDesktopMeetingWorkspaceView(workspace: workspace)
            let rendered = await present(view, size: NSSize(width: 1030, height: 815), name: "workspace-live")
            XCTAssertTrue(containsText(rendered, "Текущие встречи"))
            XCTAssertTrue(containsText(rendered, "Микрофон назначен на"))
            XCTAssertTrue(containsText(rendered, "Расшифровка речи недоступна"))
            XCTAssertTrue(containsText(rendered, line))
            let guidanceInput = element(rendered, identifier: "meetingWorkspace.privateGuidance") ?? nodes(rendered).first {
                let role = attribute($0, kAXRoleAttribute) as? String
                return (role == kAXTextFieldRole || role == kAXTextAreaRole) && strings($0).contains("Приватное указание")
            }
            if guidanceInput == nil { try capture(rendered) }
            let input = try XCTUnwrap(guidanceInput, "Missing editable private-guidance field")
            let instruction = "Уточни, кто отвечает за проверку."
            rendered.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            await settle()
            XCTAssertEqual(AXUIElementSetAttributeValue(input, kAXFocusedAttribute as CFString, kCFBooleanTrue), .success)
            for character in instruction {
                let text = String(character)
                let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: rendered.window.windowNumber,
                    context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: 0))
                rendered.window.sendEvent(key)
            }
            await settle()
            XCTAssertEqual(workspace.workspaceViewState.guidanceDrafts[first.sessionID], instruction)
            try await press(rendered, identifier: "meetingWorkspace.applyGuidance")
            XCTAssertEqual(first.participation.workspaceGuidance, [instruction])
            XCTAssertTrue(workspace.meetings.dropFirst().allSatisfy { $0.participation.workspaceGuidance.isEmpty })
            try capture(rendered)
            try await press(rendered, identifier: "meetingWorkspace.parallel")
            XCTAssertTrue(workspace.workspaceViewState.parallel)
            for title in rooms { XCTAssertTrue(containsText(rendered, title)) }
            XCTAssertTrue(containsText(rendered, "Звук встречи выключен"))
            XCTAssertEqual(workspace.talkID, first.sessionID)
            XCTAssertFalse(first.assistantMicrophoneOn)
            try capture(Rendered(window: rendered.window, hosting: rendered.hosting, name: "workspace-parallel"))

            let ended = await workspace.leave(first)
            XCTAssertTrue(ended)
            let allEnded = await workspace.leave()
            XCTAssertTrue(allEnded)
            let reloaded = MeetingWorkspaceJournal(root: store.root)
            reloaded.prepare()
            defer { reloaded.close() }
            XCTAssertNotNil(reloaded.session(id: first.sessionID)?.endedAt)
            workspace.workspaceViewState.reviewID = first.sessionID
            let review = MeetingWorkspaceReview(workspace: workspace, state: workspace.workspaceViewState, journal: reloaded)
            let archive = await present(review, size: NSSize(width: 1030, height: 720), name: "workspace-review-reloaded")
            archive.window.makeKeyAndOrderFront(nil)
            await settle()
            XCTAssertTrue(containsText(archive, "Сохранённые встречи"))
            XCTAssertTrue(containsText(archive, "В записи этого разговора есть пропуски."))
            XCTAssertTrue(containsText(archive, line))
            XCTAssertTrue(containsText(archive, reply))
            let reviewReply = try XCTUnwrap(button(archive, "Посмотреть ответ"))
            // A same-process AX action can update SwiftUI before AppKit returns its status.
            _ = AXUIElementPerformAction(reviewReply, kAXPressAction as CFString)
            try await wait { self.containsText(archive, "Контекст в момент ответа") }
            try capture(archive)
        }
    }

    func testWorkspacePauseRestoresOnlyCurrentPauseTokens() async throws {
        let store = store()
        store.enabled = true
        let coordinator = AttentionCoordinator(store: store)
        let models = [try await meeting("Release"), try await meeting("Infra"), try await meeting("Recovery")]
        coordinator.meetings = { models }
        for model in models { coordinator.setMode(.watch, for: model) }
        let state = MeetingWorkspaceViewState()
        let previous = try XCTUnwrap(state.pause(models[0], attention: coordinator))
        state.toggleAll(models, attention: coordinator)
        XCTAssertNil(state.restorePauses[models[0].sessionID])
        XCTAssertEqual(state.restorePauses.count, 2)
        XCTAssertTrue(models.allSatisfy { coordinator.resolvedMode($0).mode == .off })
        let second = try XCTUnwrap(state.restorePauses[models[1].sessionID])
        state.restorePauses[models[1].sessionID] = nil
        state.resume(models[1], pause: second, attention: coordinator)
        let repaused = try XCTUnwrap(state.pause(models[1], attention: coordinator))
        state.toggleAll(models, attention: coordinator)
        XCTAssertEqual(coordinator.resolvedMode(models[0]).mode, .off)
        XCTAssertEqual(coordinator.resolvedMode(models[1]).mode, .off)
        XCTAssertEqual(coordinator.resolvedMode(models[2]).mode, .watch)
        state.resume(models[0], pause: previous, attention: coordinator)
        state.resume(models[1], pause: repaused, attention: coordinator)
        XCTAssertTrue(models.allSatisfy { coordinator.resolvedMode($0).mode == .watch })
    }

    func testWorkspaceGuidanceScopesAndSurvivesReloadForFollowingPrompts() async throws {
        let store = store()
        store.enabled = true
        store.provider = .init(kind: .local, baseURL: "http://192.0.2.1:1/v1", model: "workspace-fixture")
        let coordinator = AttentionCoordinator(store: store)
        let release = try await meeting("Release")
        let infra = try await meeting("Infra")
        release.calendarSeriesID = "release-series"
        let room = try XCTUnwrap(MeetingWorkspaceGuidance.roomKey(for: release))
        XCTAssertTrue(coordinator.applyWorkspaceGuidance("Flag this meeting’s recovery risk.", for: release))
        try store.workspaceGuidance.append("Keep replies concise.", to: .allMeetings)
        try store.workspaceGuidance.append("Use the rollout terminology.", to: .calendarSeries("release-series"))
        try store.workspaceGuidance.append("Focus on staging only.", to: .room(room))
        let reloaded = MeetingWorkspaceGuidance(root: store.root)
        XCTAssertEqual(reloaded.instructions(for: release),
            ["Keep replies concise.", "Focus on staging only.", "Use the rollout terminology."])
        XCTAssertEqual(reloaded.instructions(for: infra), ["Keep replies concise."])
        let judge = AssistantUIJudge()
        judge.next = .init(level: .now, probability: 0.9, reason: "Release confirmation requested.",
                           evidence: ["L1"], action: .chat)
        let writer = WorkspaceFixtureWriter()
        coordinator.meetings = { [release, infra] }
        coordinator.hasTranscript = { _ in true }
        coordinator.makeJudge = { _, _ in judge }
        coordinator.makeWriter = { _, _ in writer }
        coordinator.replyChannels = { _ in .init(chat: true) }
        coordinator.setMode(.watch, for: release)
        let now = Date()
        release.receiveLocalLineForTesting(.init(id: "guide", trackID: "anna", text: "Vitalii, what is the rollout plan?",
            start: now, end: now))
        await coordinator.tick()
        try await wait { coordinator.card(for: release.sessionID)?.draft != nil }
        let captured = await writer.lastRequest
        let request = try XCTUnwrap(captured)
        XCTAssertTrue(AttentionPrompt.userContent(request.judge).contains("Flag this meeting’s recovery risk."))
        XCTAssertTrue(ReplyPrompt.userContent(request).contains("Use the rollout terminology."))
        let rule = try XCTUnwrap(reloaded.rules.first { $0.scope == .room(room) })
        try reloaded.replace(rule, text: "Check staging first.")
        XCTAssertTrue(MeetingWorkspaceGuidance(root: store.root).instructions(for: release).contains("Check staging first."))
        try reloaded.remove(try XCTUnwrap(reloaded.rules.first { $0.scope == .room(room) }))
        XCTAssertFalse(MeetingWorkspaceGuidance(root: store.root).instructions(for: release).contains("Check staging first."))
    }

    func testRussianSituationDefaultsDoNotCropSegmentedControls() async throws {
        try await withRussianBundle {
            XCTAssertEqual(language, "ru", "The test host must render the Russian resources")
            XCTAssertEqual(AttentionMode.off.title, "Выключено")
            XCTAssertEqual(AttentionMode.mentions.title, "Упоминания")
            XCTAssertEqual(AttentionMode.watch.title, "Следить")

            let store = store()
            let cases: [(size: NSSize, segmented: Int, name: String)] = [
                (NSSize(width: 760, height: 360), 3, "wide"),
                (NSSize(width: 460, height: 420), 3, "stacked"),
                (NSSize(width: 280, height: 520), 0, "menu"),
            ]
            for fixture in cases {
                let view = Form {
                    Section { AttentionSituationDefaults(store: store) }
                }
                .formStyle(.grouped)
                .padding(20)
                let rendered = await present(view, size: fixture.size,
                    name: "situation-defaults-\(fixture.name)", minSize: fixture.size)
                await settle()

                for situation in AttentionSituation.allCases {
                    XCTAssertNotNil(element(rendered, identifier: "attention.situation.\(situation.rawValue)"),
                        "\(fixture.name) retains the \(situation.rawValue) row")
                }
                let segmentedControls = views(rendered.hosting).compactMap { $0 as? NSSegmentedControl }
                XCTAssertEqual(segmentedControls.count, fixture.segmented,
                    "\(fixture.name) uses the expected attention-control presentation")
                for control in segmentedControls {
                    let requiredWidth = requiredWidth(of: control)
                    XCTAssertGreaterThan(requiredWidth, 240,
                        "The Russian fixture must prove that the previous fixed width cropped the control")
                    XCTAssertLessThanOrEqual(requiredWidth, control.frame.width + 0.5,
                        "The segmented control is wide enough for every Russian segment")
                    XCTAssertLessThanOrEqual(control.frame.maxX, rendered.hosting.frame.width + 0.5,
                        "The segmented control stays inside its window")
                }
                try capture(rendered)
            }
        }
    }

    func testOverflowButtonUsesAccessibilityActionWithoutDelivery() async throws {
        let store = store(); await store.waitForMoments()
        store.situationModes[.background] = .mentions
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
        let quietAt = now.addingTimeInterval(-70)
        store.log(.init(at: quietAt, meetingTitle: "Quiet diagnostics", provider: "local",
            model: "fixture", outcome: .belowThreshold))
        XCTAssertEqual(store.momentHistory.quietChecks.count, 1)
        let quietText = L("%ld quiet checks · latest %@", 1,
            quietAt.formatted(date: .abbreviated, time: .shortened))
        for index in 0..<30 { seed(store, "Unread \(index)", at: now.addingTimeInterval(TimeInterval(index))) }
        await coordinator.summarize(first)
        coordinator.scheduleReminder = { _, _ in throw NSError(domain: "AssistantUI", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Reminder fixture failed"]) }
        coordinator.remind(second)
        try await wait { coordinator.reminderErrorByMoment[second.id] != nil }

        let rendered = await present(AttentionMomentsView(attention: coordinator, store: store),
            size: NSSize(width: 900, height: 560), name: "errors-first")
        XCTAssertFalse(containsText(rendered, quietText),
            "Quiet diagnostics must stay out of the Assistant inbox")
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

    func testMultipleMeetingTargetAndComposerRemainUsableInNarrowLayout() async throws {
        let store = store(); await store.waitForMoments()
        let models = try await [
            meeting("Weekly infrastructure planning"),
            meeting("Daily product review"),
            meeting("Engineering design and release coordination"),
        ]
        models[0].configureForConcurrentJoin(ownsMicrophone: false)
        models[1].configureForConcurrentJoin(ownsMicrophone: true)
        models[2].configureForConcurrentJoin(ownsMicrophone: false)
        let coordinator = AttentionCoordinator(store: store)
        coordinator.meetings = { models }
        var opened = 0
        coordinator.openMeeting = { _ in opened += 1 }
        let rendered = await present(AssistantTalkView(attention: coordinator),
            size: NSSize(width: 760, height: 560), name: "talk-multiple-meetings")
        try await wait { self.element(rendered, identifier: "assistant.meeting-target") != nil }
        XCTAssertEqual(coordinator.talk.targetMeetingID, models[1].sessionID)
        for identifier in ["assistant.meeting-target", "assistant.input", "assistant.ask", "assistant.listen"] {
            XCTAssertNotNil(element(rendered, identifier: identifier), "Missing usable Assistant control \(identifier)")
        }

        rendered.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        await settle()
        try capture(rendered)
        coordinator.talk.targetMeetingID = models[2].sessionID
        await settle()
        XCTAssertEqual(opened, 0, "Changing Assistant context never opens a meeting")
        XCTAssertFalse(models[0].ownsMicrophone)
        XCTAssertFalse(models[2].ownsMicrophone)
        XCTAssertTrue(models[1].ownsMicrophone, "Changing Assistant context never moves microphone ownership")

        let input = try XCTUnwrap(element(rendered, identifier: "assistant.input"))
        XCTAssertEqual(AXUIElementSetAttributeValue(input, kAXValueAttribute as CFString, "Remember this selector" as CFTypeRef), .success)
        await settle()
        XCTAssertEqual(attribute(input, kAXValueAttribute) as? String, "Remember this selector", "The hosted composer accepts text")
        try capture(rendered)

        rendered.window.minSize = NSSize(width: 480, height: 420)
        rendered.window.setContentSize(NSSize(width: 520, height: 480))
        await settle()
        for identifier in ["assistant.meeting-target", "assistant.input", "assistant.ask", "assistant.listen"] {
            XCTAssertNotNil(element(rendered, identifier: identifier), "Narrow layout lost \(identifier)")
        }
        try capture(Rendered(window: rendered.window, hosting: rendered.hosting, name: "talk-multiple-meetings-narrow"))
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
        workspace.join(model.invitation, engine: .guest, title: model.title, nameOverride: "Vitalii")
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

    /// Regression: an embedded meeting suppressed the in-stage header (the detached
    /// window's Notes icon) and the main-window toolbar had no Notes button, so the
    /// notes panel was unreachable in the default configuration.
    func testEmbeddedMeetingToolbarOpensNotesPanel() async throws {
        let model = try await meeting("Notes entry")
        let workspace = NativeDesktopWorkspace(
            detect: { .verified(.guest(endpoint: $0)) },
            makeMeeting: { _, _, _, _ in model }
        )
        workspace.join(model.invitation, engine: .guest, title: model.title, nameOverride: "Vitalii")
        try await wait { workspace.selectedMeeting === model && !workspace.preparing }
        workspace.show()
        await settle()
        addTeardownBlock { _ = await workspace.leave() }

        let app = AXUIElementCreateApplication(getpid())
        let notesButton = try XCTUnwrap(children(app).flatMap(nodes).first {
            (attribute($0, kAXIdentifierAttribute) as? String) == "meeting.notes"
        }, "Main-window toolbar must expose a Notes button for the embedded meeting")
        XCTAssertEqual(AXUIElementPerformAction(notesButton, kAXPressAction as CFString), .success)
        try await wait { model.panel == .notes }
    }

    func testHistoricalOutcomeDisplaysEndTimeFallbackLabel() async throws {
        let store = store()
        await store.waitForMeetingLibrary()
        let outcome = MeetingOutcome(meetingTitle: "Imported meeting", endedAt: Date(timeIntervalSince1970: 1_700_000_000),
            summary: "Imported historical outcome")
        try await store.meetingLibrary.store.importLegacyOutcomes([outcome])
        await store.meetingLibrary.refresh()
        let card = try XCTUnwrap(store.meetingLibrary.cards.first { $0.outcomeID == outcome.id })
        let attention = AttentionCoordinator(store: store)
        attention.requestedOutcomeSessionID = card.sessionID
        let rendered = await present(AssistantOutcomesView(attention: attention),
            size: NSSize(width: 1100, height: 700), name: "legacy-outcome-end-time")
        XCTAssertTrue(containsText(rendered, "Imported meeting"))
        XCTAssertTrue(containsText(rendered, L("By end time")))
        XCTAssertNotNil(element(rendered, identifier: "assistant.date-end-fallback"))
    }

    func testRenameSheetCancelAndBlankSubmissionPreserveStoredTitle() async throws {
        let store = store()
        await store.waitForMeetingLibrary()
        let library = store.meetingLibrary
        let title = "Original occurrence title"
        let session = MeetingSessionRecord(title: title, startedAt: Date())
        try await library.store.upsertSession(session)
        await library.refresh()
        let attention = AttentionCoordinator(store: store)
        attention.requestedOutcomeSessionID = session.id
        let rendered = await present(AssistantOutcomesView(attention: attention),
            size: NSSize(width: 1100, height: 700), name: "rename-cancel-validation")
        rendered.window.makeKeyAndOrderFront(nil)
        let errorMessage = L("Enter a meeting title.")

        func sheet() -> AXUIElement? {
            nodes(rendered).first { (attribute($0, kAXRoleAttribute) as? String) == kAXSheetRole }
        }
        func replaceTitle(with value: String) async throws {
            let form = try XCTUnwrap(sheet(), "Rename must present a native sheet")
            let field = try XCTUnwrap(nodes(form).first {
                (attribute($0, kAXRoleAttribute) as? String) == kAXTextFieldRole
            })
            XCTAssertEqual(attribute(field, kAXValueAttribute) as? String, title)
            XCTAssertEqual(AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, value as CFTypeRef), .success)
            await settle()
            XCTAssertEqual(attribute(field, kAXValueAttribute) as? String, value)
        }
        func assertOriginalTitle() async throws {
            let persisted = try await library.store.session(session.id)
            XCTAssertEqual(persisted?.title, title)
            XCTAssertEqual(persisted?.exportRevision, session.exportRevision)
            XCTAssertEqual(library.cards.first { $0.sessionID == session.id }?.title, title)
        }

        try await press(rendered, L("Rename meeting"))
        try await replaceTitle(with: "Discard this title")
        try await press(rendered, L("Cancel"))
        try await wait { sheet() == nil }
        try await assertOriginalTitle()
        XCTAssertFalse(containsText(rendered, "Discard this title"))

        for invalidTitle in ["", "   "] {
            try await press(rendered, L("Rename meeting"))
            try await replaceTitle(with: invalidTitle)
            try await press(rendered, L("Save"))
            let form = try XCTUnwrap(sheet(), "The sheet must stay open for correction")
            XCTAssertTrue(nodes(form).contains { strings($0).contains(errorMessage) },
                          "The rename form must explain the invalid title inline")
            try await assertOriginalTitle()
            try await press(rendered, L("Cancel"))
            try await wait { sheet() == nil }
        }
        XCTAssertTrue(containsText(rendered, title))
    }

    func testOccurrenceRenameSurvivesCalendarRefreshAndOutcomeRegeneration() async throws {
        let store = store()
        await store.waitForMeetingLibrary()
        let library = store.meetingLibrary
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let room = try XCTUnwrap(URL(string: "https://example.test/calls/shared-room"))
        let series = "weekly-planning"
        let earlier = MeetingSessionRecord(title: "Planning", invitation: room, roomIdentity: "shared-room",
            calendarSeriesID: series, startedAt: now - 86_400, endedAt: now - 84_600, state: .ended)
        var chosen = MeetingSessionRecord(title: "Planning", invitation: room, roomIdentity: "shared-room",
            calendarSeriesID: series, startedAt: now - 3_600, endedAt: now - 1_800, state: .ended)
        try await library.store.upsertSession(earlier)
        try await library.store.upsertSession(chosen)
        let original = MeetingOutcome(meetingID: chosen.id, meetingTitle: chosen.title, invitation: room,
            seriesID: series, endedAt: now - 1_800, summary: "First published outcome")
        let sibling = MeetingOutcome(meetingID: earlier.id, meetingTitle: earlier.title, invitation: room,
            seriesID: series, endedAt: now - 84_600, summary: "Other occurrence outcome")
        try await library.store.saveOutcome(original, state: .ready)
        try await library.store.saveOutcome(sibling, state: .ready)
        try await library.store.saveNote(sessionID: chosen.id, markdown: "Occurrence-specific notes")
        let preferencesName = "outcome-calendar-fixture-\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: preferencesName))
        defer { preferences.removePersistentDomain(forName: preferencesName) }
        preferences.set(true, forKey: "calendarMeetings.enabled")
        preferences.set(["fixture"], forKey: "calendarMeetings.selected")
        let reader = OutcomeFixtureCalendar()
        let calendar = CalendarMeetingStore(reader: reader,
            detector: MeetingEngineDetector(serviceName: "fixture"), preferences: preferences,
            storage: OutcomeFixtureCalendarStorage())
        func event(_ title: String) -> CalendarMeeting {
            CalendarMeeting(id: "current-event", seriesID: series, calendarID: "fixture",
                calendarTitle: "Work", title: title, start: chosen.startedAt, end: now - 1_800)
        }
        await reader.replace(with: event("Calendar planning"))
        calendar.refresh()
        try await wait { !calendar.loading && calendar.meetings.first?.title == "Calendar planning" }

        try await library.renameSession(chosen.id, title: "  Session-only title  ")
        XCTAssertEqual(calendar.meetings.first?.title, "Calendar planning")
        await reader.replace(with: event("Calendar updated planning"))
        calendar.refresh()
        try await wait { !calendar.loading && calendar.meetings.first?.title == "Calendar updated planning" }
        chosen.title = "Provider updated planning"
        try await library.store.upsertSession(chosen)
        let draft = try await startFixtureOutcome(store, session: chosen, endedAt: now - 1_800)
        XCTAssertEqual(draft.id, original.id)
        var generated = draft
        generated.meetingTitle = chosen.title
        generated.summary = "Regenerated fixture outcome"
        let commit = try await library.store.finishOutcome(generated, owner: "fixture-writer", errorCode: nil)
        XCTAssertEqual(commit?.outcome.meetingTitle, "Session-only title")
        XCTAssertEqual(commit?.outcome.meetingID, chosen.id)
        XCTAssertEqual(commit?.outcome.seriesID, series)
        XCTAssertEqual(commit?.outcome.invitation, room)
        let unchanged = try await library.store.outcomeBySession(earlier.id)
        XCTAssertEqual(unchanged, sibling)
        let calendarItem = try XCTUnwrap(calendar.meetings.first)
        XCTAssertEqual(calendarItem.id, "current-event")
        XCTAssertEqual(calendarItem.seriesID, series)
        XCTAssertEqual(calendarItem.title, "Calendar updated planning")
        let note = try await library.store.note(chosen.id)
        XCTAssertEqual(note?.markdown, "Occurrence-specific notes")
        await library.refresh()
        store.assistant.restorePersistedOutcomes(try await library.store.outcomes())
        let attention = AttentionCoordinator(store: store)
        attention.requestedOutcomeSessionID = chosen.id
        let rendered = await present(AssistantOutcomesView(attention: attention),
            size: NSSize(width: 1100, height: 700), name: "renamed-occurrence")
        XCTAssertTrue(containsText(rendered, "Session-only title"))
        XCTAssertTrue(containsText(rendered, "Regenerated fixture outcome"))
        XCTAssertTrue(containsText(rendered, "Other occurrence outcome"))
        XCTAssertFalse(containsText(rendered, "Provider updated planning"))
    }

    func testOutcomeDaysRenderNewestFirstAndCountEachRepeatedRoomOccurrence() async throws {
        let store = store()
        await store.waitForMeetingLibrary()
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: Date())
        let previousDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: day))
        let room = try XCTUnwrap(URL(string: "https://example.test/calls/shared-room"))
        let starts = [previousDay + 11 * 3_600, day + 9 * 3_600, day + 14 * 3_600]
        let summaries = ["Older day occurrence", "Morning occurrence", "Afternoon occurrence"]
        for (start, summary) in zip(starts, summaries) {
            let session = MeetingSessionRecord(title: "Repeated room title", invitation: room, roomIdentity: "shared-room",
                calendarSeriesID: "shared-series", startedAt: start, endedAt: start + 900, state: .ended)
            try await store.meetingLibrary.store.upsertSession(session)
            try await store.meetingLibrary.store.saveOutcome(.init(meetingID: session.id,
                meetingTitle: session.title, endedAt: start + 900, summary: summary), state: .ready)
        }
        await store.meetingLibrary.refresh()
        store.assistant.restorePersistedOutcomes(try await store.meetingLibrary.store.outcomes())
        let rendered = await present(AssistantOutcomesView(attention: AttentionCoordinator(store: store)),
            size: NSSize(width: 1100, height: 700), name: "repeated-room-day-order")
        try assertOutcomeDayOrder(rendered, expected: [
            (day, ["Afternoon occurrence", "Morning occurrence"]),
            (previousDay, ["Older day occurrence"])
        ])
    }

    func testOutcomeHistorySearchTemporarilyRevealsCollapsedDayAndPreservesSelectionOnRefresh() async throws {
        let store = store()
        await store.waitForMeetingLibrary()
        let library = store.meetingLibrary
        let day = Calendar.current.startOfDay(for: Date())
        let previousDay = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -1, to: day))
        let selectedTitle = "Selected history occurrence"
        let selected = MeetingSessionRecord(title: selectedTitle, startedAt: day + 14 * 3_600)
        let match = MeetingSessionRecord(title: "Matching release planning", startedAt: day + 9 * 3_600)
        let earlier = MeetingSessionRecord(title: "Previous day occurrence", startedAt: previousDay + 13 * 3_600)
        for session in [selected, match, earlier] { try await library.store.upsertSession(session) }
        await library.refresh()
        let attention = AttentionCoordinator(store: store)
        attention.requestedOutcomeSessionID = selected.id
        let rendered = await present(AssistantOutcomesView(attention: attention),
            size: NSSize(width: 1100, height: 700), name: "outcome-history-search")
        rendered.window.makeKeyAndOrderFront(nil)
        await settle()
        try assertOutcomeDayOrder(rendered, expected: [
            (day, [selectedTitle, match.title]), (previousDay, [earlier.title])
        ])
        let dayLabel = day.formatted(.dateTime.day().month(.wide).year().locale(.current))
        let disclosure = try XCTUnwrap(nodes(rendered).first {
            (attribute($0, kAXRoleAttribute) as? String) == kAXDisclosureTriangleRole &&
                strings($0).contains { $0.contains(dayLabel) }
        })
        XCTAssertEqual(AXUIElementPerformAction(disclosure, kAXPressAction as CFString), .success)
        await settle()
        try assertOutcomeDayOrder(rendered, expected: [(day, []), (previousDay, [earlier.title])],
                                  collapsedCounts: [day: 2])
        XCTAssertTrue(containsText(rendered, selectedTitle), "Collapsing a day must keep the selected detail open")

        let search = try XCTUnwrap(nodes(rendered).first {
            (attribute($0, kAXRoleAttribute) as? String) == kAXTextFieldRole &&
                strings($0).contains(L("Search meetings"))
        })
        XCTAssertEqual(AXUIElementSetAttributeValue(search, kAXFocusedAttribute as CFString, kCFBooleanTrue), .success)
        await settle()
        let fieldEditor = try XCTUnwrap(rendered.window.firstResponder as? NSTextView, "Search field should have an AppKit field editor")
        fieldEditor.insertText("release", replacementRange: fieldEditor.selectedRange())
        await settle()
        try assertOutcomeDayOrder(rendered, expected: [(day, [match.title])])
        XCTAssertTrue(containsText(rendered, selectedTitle), "Search must keep the selected detail open")

        let incoming = MeetingSessionRecord(title: "New release meeting", startedAt: day + 17 * 3_600,
            endedAt: day + 18 * 3_600, state: .ended)
        try await library.store.upsertSession(incoming)
        try await library.store.saveOutcome(.init(meetingID: incoming.id, meetingTitle: incoming.title,
            endedAt: day + 18 * 3_600, summary: "Newly published outcome"), state: .ready)
        await library.refresh()
        await settle()
        try assertOutcomeDayOrder(rendered, expected: [(day, [incoming.title, match.title])])
        XCTAssertTrue(containsText(rendered, selectedTitle), "Catalog refresh must keep the selected detail open")

        fieldEditor.selectAll(nil)
        fieldEditor.deleteBackward(nil)
        await settle()
        try assertOutcomeDayOrder(rendered, expected: [(day, []), (previousDay, [earlier.title])],
                                  collapsedCounts: [day: 3])
        XCTAssertTrue(containsText(rendered, selectedTitle), "Clearing search must restore collapse and keep the selected detail open")
    }

    func testMidnightOutcomeStaysInStartDayAfterLateGenerationRenameAndEdit() async throws {
        let store = store()
        await store.waitForMeetingLibrary()
        let library = store.meetingLibrary
        let midnight = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -2,
            to: Calendar.current.startOfDay(for: Date())))
        let dayBefore = Calendar.current.startOfDay(for: midnight - 300)
        let overnight = MeetingSessionRecord(title: "Overnight occurrence", startedAt: midnight - 300)
        let nextDay = MeetingSessionRecord(title: "Next-day meeting", startedAt: midnight + 600,
            endedAt: midnight + 1200, state: .ended)
        try await library.store.upsertSession(overnight)
        try await library.store.upsertSession(nextDay)
        try await library.store.saveNote(sessionID: overnight.id, markdown: "Before midnight")
        try await library.store.saveOutcome(.init(meetingID: nextDay.id,
            meetingTitle: nextDay.title, endedAt: midnight + 1200, summary: "Next-day summary"), state: .ready)
        await library.endSession(overnight.id, endedAt: midnight + 300, awaitingOutcome: true)
        store.assistant.restorePersistedOutcomes(try await library.store.outcomes())
        let attention = AttentionCoordinator(store: store)
        attention.requestedOutcomeSessionID = overnight.id
        let rendered = await present(AssistantOutcomesView(attention: attention),
            size: NSSize(width: 1100, height: 700), name: "overnight-outcome-day")
        try assertOutcomeDayOrder(rendered, expected: [
            (midnight, ["Next-day meeting"]), (dayBefore, ["Overnight occurrence"])
        ])

        var generated = try await startFixtureOutcome(store, session: overnight, endedAt: midnight + 300)
        generated.summary = "Late generation"
        let publication = try await library.store.finishOutcome(generated, owner: "fixture-writer", errorCode: nil)
        var edited = try XCTUnwrap(publication?.outcome)
        store.assistant.restorePersistedOutcomes([edited])
        try await library.renameSession(overnight.id, title: "Renamed overnight")
        edited.summary = "Edited after generation"
        store.assistant.updateOutcome(edited)
        await store.waitForOutcomeWrites()
        let editedOutcome = try await library.store.outcomeBySession(overnight.id)
        XCTAssertEqual(editedOutcome?.summary, "Edited after generation")
        XCTAssertEqual(editedOutcome?.meetingTitle, "Renamed overnight")
        try await library.store.saveNote(sessionID: overnight.id, markdown: "Edited days later")
        await library.refresh()
        await settle()
        let card = try XCTUnwrap(library.cards.first { $0.sessionID == overnight.id })
        XCTAssertEqual(card.effectiveDate, .init(date: midnight - 300, fromEnd: false))
        XCTAssertEqual(card.endedAt, midnight + 300)
        XCTAssertGreaterThan(card.updatedAt, midnight + 86_400)
        try assertOutcomeDayOrder(rendered, expected: [
            (midnight, ["Next-day meeting"]), (dayBefore, ["Renamed overnight"])
        ])
        XCTAssertTrue(containsText(rendered, "Edited after generation"))
    }

    private func startFixtureOutcome(_ store: AttentionStore, session: MeetingSessionRecord, endedAt: Date) async throws -> MeetingOutcome {
        let request = MeetingOutcomeRequest(meetingTitle: session.title, endedAt: endedAt,
            window: MeetingOutcomePrompt.window(title: session.title, transcript: [], chat: [],
                yourName: "Fixture", now: Date()), language: "en")
        return try await store.meetingLibrary.store.startOutcome(.init(meetingID: session.id,
            meetingTitle: session.title, invitation: session.invitation, seriesID: session.calendarSeriesID,
            endedAt: endedAt, summary: ""),
            input: .init(request: request, provider: store.effectiveWriter), owner: "fixture-writer")
    }

    private func assertOutcomeDayOrder(_ rendered: Rendered, expected: [(Date, [String])],
                                       collapsedCounts: [Date: Int] = [:],
                                       file: StaticString = #filePath, line: UInt = #line) throws {
        func isCard(_ node: AXUIElement) -> Bool {
            (attribute(node, kAXIdentifierAttribute) as? String) == "assistant.meeting-card"
        }
        let sidebar = try XCTUnwrap(nodes(rendered).first {
            (attribute($0, kAXRoleAttribute) as? String) == kAXScrollAreaRole && nodes($0).contains(where: isCard)
        }, "Missing meeting history sidebar", file: file, line: line)
        let list = try nodes(sidebar).compactMap { node -> (y: CGFloat, labels: [String], day: Bool)? in
            let isDay = (attribute(node, kAXRoleAttribute) as? String) == kAXDisclosureTriangleRole
            guard isDay || isCard(node) else { return nil }
            let position = try XCTUnwrap(attribute(node, kAXPositionAttribute), file: file, line: line)
            var point = CGPoint.zero
            XCTAssertTrue(AXValueGetValue(position as! AXValue, .cgPoint, &point), file: file, line: line)
            return (point.y, strings(node) + children(node).flatMap(strings), isDay)
        }.sorted { $0.y < $1.y }
        let values = list.map(\.labels)
        let expectedCount = expected.reduce(0) { $0 + $1.1.count + 1 }
        guard list.count == expectedCount else {
            return XCTFail("Expected \(expectedCount) rendered days and cards, got \(list.count): \(values)", file: file, line: line)
        }
        var index = 0
        for (day, titles) in expected {
            let label = day.formatted(.dateTime.day().month(.wide).year().locale(.current))
            XCTAssertTrue(list[index].day, "\(values)", file: file, line: line)
            XCTAssertTrue(list[index].labels.contains { $0.contains(label) }, "\(values)", file: file, line: line)
            let count = collapsedCounts[day] ?? titles.count
            XCTAssertTrue(list[index].labels.contains(count.formatted()), "\(values)", file: file, line: line)
            index += 1
            for title in titles {
                XCTAssertFalse(list[index].day, "\(values)", file: file, line: line)
                XCTAssertTrue(list[index].labels.contains { $0.contains(title) }, "\(values)", file: file, line: line)
                index += 1
            }
        }
    }

    /// The agent timeline shows the user message, one collapsed activity row, and the
    /// final answer; raw `rocknroll_*` names appear only behind Details.
    func testAgentTimelineCompactsToolNoiseBehindDetails() async throws {
        let items: [AssistantConversationItem] = [
            .init(kind: .user, text: "what did I miss?"),
            .init(kind: .tool, text: "Daily sync", toolName: "rocknroll_get_meeting"),
            .init(kind: .tool, text: "3 lines", toolName: "rocknroll_read_chat"),
            .init(kind: .assistant, text: "Anna asked about the build.",
                  sources: [.init(id: "e1", kind: "chat", title: "Chat", at: nil)]),
        ]
        let turns = items.assistantTurns
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].activity.count, 3)

        let view = ScrollView { AssistantAgentTurnView(turn: turns[0]) }.padding(16)
        let rendered = await present(view, size: NSSize(width: 520, height: 300), name: "agent-turn-compact")
        XCTAssertTrue(containsText(rendered, "what did I miss?"))
        XCTAssertTrue(containsText(rendered, "Anna asked about the build."))
        XCTAssertFalse(containsText(rendered, "rocknroll_"), "Raw tool identifiers stay hidden by default")
        XCTAssertTrue(containsText(rendered, L("%ld steps", 2)))
        try await press(rendered, L("Details"))
        XCTAssertTrue(containsText(rendered, "get_meeting"), "Details reveals the friendly step names")
        XCTAssertTrue(containsText(rendered, "read_chat"))
        try capture(rendered)
    }
}

private actor OutcomeFixtureCalendar: CalendarReading {
    private var event: CalendarMeeting?

    func replace(with event: CalendarMeeting) { self.event = event }
    func access() -> CalendarAccess { .allowed }
    func requestAccess() -> Bool { true }
    func read(selected: Set<String>, now: Date, knownOrigins: Set<String>, aliases: [String: URL]) -> CalendarSnapshot {
        .init(calendars: [.init(id: "fixture", name: "Work", source: "Fixture")],
              meetings: event.map { [$0] } ?? [])
    }
}

private final class OutcomeFixtureCalendarStorage: RoomHistoryStorage {
    private var data: Data?
    func read() -> Data? { data }
    func write(_ data: Data) throws { self.data = data }
}

private struct AssistantSettingsHarness: View {
    @ObservedObject var store: AttentionStore
    @ObservedObject var attention: AttentionCoordinator
    @State private var area: NativeDesktopAssistantSettingsArea = .overview
    var body: some View { NativeDesktopIntelligenceSettings(store: store, attention: attention, area: $area) }
}

private actor AssistantVoiceUIWorker: ClonedVoiceWorkerConnection {
    private(set) var requests: [ClonedVoiceWire.Request] = []
    func execute(_ request: ClonedVoiceWire.Request, timeout: TimeInterval) async throws -> ClonedVoiceWorkerOutput {
        requests.append(request)
        return .init(samples: nil, repairedAsset: request.repairAsset)
    }
    func stop() {}
}

private actor WorkspaceFixtureWriter: ReplyWriter {
    private(set) var lastRequest: ReplyRequest?

    func draft(_ request: ReplyRequest) async throws -> ReplyResult {
        lastRequest = request
        return .init(draft: .init(chat: "I’ll check the recovery test.", reaction: nil), latency: 0)
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
