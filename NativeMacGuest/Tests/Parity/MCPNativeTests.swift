import AppKit
import ConferenceCore
import Foundation
import LiveKitWebRTC
import XCTest
@testable import RockNativeDesktop

/// Minimal stand-in engine for session-scoped MCP tests (mirrors AttentionTests' fixture).
@MainActor private final class MCPTestEngine: NativeDesktopMeetingEngine {
    var onState: ((NativeDesktopExternalSnapshot) -> Void)?
    var onVideo: (([NativeDesktopExternalVideo]) -> Void)?
    var onLocalCamera: ((LKRTCVideoTrack?) -> Void)?
    var onTitle: ((String) -> Void)?
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

/// Rock'N'Roll native MCP: pairing and scopes, idempotent actions with audit,
/// the JSON-RPC surface, the loopback HTTP transport, settings confidentiality
/// and revision checks, and the safe in-app assistant path.
@MainActor final class MCPNativeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = Self.disableBuggyMemoryChecker
    }

    // Xcode 26's memory checker re-invokes each completed test body inside its
    // error-observation machinery, which trips a Swift 6.3/6.4 concurrency
    // runtime assertion ("freed pointer was not the last allocation",
    // swiftlang/swift#87481) and aborts the test host. Shadowing the hook on
    // this class only (the original stays intact for every other test class)
    // keeps the suite runnable; these tests own no Objective-C fixtures, so
    // the checker buys nothing here.
    private static let disableBuggyMemoryChecker: Void = {
        let selector = NSSelectorFromString("assertInvalidObjectsDeallocatedAfterScope:")
        let block: @convention(block) (XCTestCase, AnyObject?) -> Void = { _, _ in }
        let imp = imp_implementationWithBlock(block)
        class_addMethod(MCPNativeTests.self, selector, imp, "v@:@")
    }()

    private func tempFile(_ name: String = "endpoint.json") -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-native-\(UUID().uuidString)/\(name)", isDirectory: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        return url
    }

    private func defaults() -> UserDefaults { UserDefaults(suiteName: "mcp-native-\(UUID().uuidString)")! }

    private func folder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-attention-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func store() -> AttentionStore {
        let defaults = UserDefaults(suiteName: "mcp-attention-\(UUID().uuidString)")!
        let keychain = AttentionKeychain(service: "dev.vsmirn0v.conferenceguest.mcp.tests.\(UUID().uuidString)")
        addTeardownBlock { keychain.deleteAll() }
        return AttentionStore(root: folder(), defaults: defaults, keychain: keychain)
    }

    private func spin(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 where !predicate() { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(predicate())
    }

    /// `XCTAssertThrowsError` cannot carry `async` expressions; MCP failures are asserted here instead.
    private func assertFailure(_ code: String, _ expression: () async throws -> MCPJSON,
                               file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await expression()
            XCTFail("Expected MCPToolFailure(\(code))", file: file, line: line)
        } catch let failure as MCPToolFailure {
            XCTAssertEqual(failure.code, code, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    private func client(_ scopes: Set<String> = ["meetings:read", "settings:read"], label: String = "test") -> MCPClientIdentity {
        MCPClientIdentity(tokenHash: "hash", scopes: scopes, label: label)
    }

    // MARK: Async-body runner
    //
    // XCTest's asynchronous test invocation on Swift 6.3/6.4 (Xcode 26) trips a
    // concurrency-runtime assertion ("freed pointer was not the last allocation",
    // swiftlang/swift#87481) whenever the test body touches the attention store.
    // Running the async body via a plain Task + XCTWaiter sidesteps the buggy
    // error-observation path; fixtures stay local to the closure so the test case
    // never retains MainActor-isolated objects.

    private func runAsyncTest(file: StaticString = #filePath, line: UInt = #line, _ body: @escaping @MainActor () async -> Void) {
        let done = expectation(description: "async body")
        Task { await body(); done.fulfill() }
        // XCTWaiter instead of XCTestCase.wait(for:) — macOS 26 shadows the name with a Foundation `wait` symbol.
        let result = XCTWaiter().wait(for: [done], timeout: 120)
        XCTAssertEqual(result, .completed, "Async test body timed out", file: file, line: line)
    }

    // MARK: Pairing and scopes

    func testPairingRejectsBadTokenAndDefaultsToReadScopes() throws {
        let tokens = MCPTokenStore()
        XCTAssertThrowsError(try tokens.pair(token: "not-the-token", label: "x", requestedScopes: nil)) {
            XCTAssertEqual(($0 as? MCPToolFailure)?.code, "ACCESS_DENIED")
        }
        let pairing = tokens.endpoint(host: "127.0.0.1", port: 9, path: "/mcp").pairingToken
        let paired = try tokens.pair(token: pairing, label: "codex", requestedScopes: nil)
        XCTAssertEqual(paired.scopes, ["meetings:read", "settings:read"], "Default grants are read-only")
        let write = try tokens.pair(token: tokens.endpoint(host: "127.0.0.1", port: 9, path: "/mcp").pairingToken, label: "codex", requestedScopes: ["settings:write", "evil:admin"])
        XCTAssertEqual(write.scopes, ["settings:write"], "Write scopes are granted explicitly; unknown scopes are dropped")
        // A consumed pairing token rotates: the same token must not pair twice.
        XCTAssertNotEqual(tokens.endpoint(host: "127.0.0.1", port: 9, path: "/mcp").pairingToken, pairing)
        XCTAssertThrowsError(try tokens.pair(token: pairing, label: "codex", requestedScopes: nil))
    }

    func testAuthenticateEnforcesScopeAndBearerPrefix() throws {
        let tokens = MCPTokenStore()
        let paired = try tokens.pair(token: tokens.endpoint(host: "h", port: 1, path: "/mcp").pairingToken, label: "c", requestedScopes: nil)
        XCTAssertThrowsError(try tokens.authenticate(authorization: nil, requiredScope: "meetings:read")) {
            XCTAssertEqual(($0 as? MCPToolFailure)?.code, "ACCESS_DENIED")
        }
        XCTAssertThrowsError(try tokens.authenticate(authorization: "Token \(paired.token)", requiredScope: "meetings:read"))
        let identity = try tokens.authenticate(authorization: "Bearer \(paired.token)", requiredScope: "settings:read")
        XCTAssertEqual(identity.scopes, ["meetings:read", "settings:read"])
        XCTAssertThrowsError(try tokens.authenticate(authorization: "Bearer \(paired.token)", requiredScope: "meetings:control")) {
            XCTAssertEqual(($0 as? MCPToolFailure)?.code, "SCOPE_DENIED")
        }
    }

    // MARK: Action center: idempotency and audit

    func testActionCenterReplaysSamePayloadAndRejectsMismatchedReuse() throws {
        let center = MCPActionCenter()
        let payload: MCPJSON = ["favorite": true, "room_id": "room:native:x"]
        let first = try center.begin(client: client(), actionID: UUID().uuidString, payload: payload)
        XCTAssertNotNil(first)
        // Same action_id + same payload: a replay, no new record.
        XCTAssertNil(try center.begin(client: client(), actionID: first!.id, payload: payload))
        // Same action_id + different payload: an auditable error.
        XCTAssertThrowsError(try center.begin(client: client(), actionID: first!.id, payload: ["favorite": false])) {
            XCTAssertEqual(($0 as? MCPToolFailure)?.code, "ACTION_ID_REUSED")
        }
        _ = center.finish(first!.id, client: client(), type: "favorite", target: "room:native:x", status: "applied", result: ["ok": true])
        XCTAssertEqual(center.recordedActions[first!.id]?.status, "applied")
        let rejected = MCPActionCenter()
        let denied = try XCTUnwrap(rejected.begin(client: client(), actionID: UUID().uuidString, payload: [:]))
        _ = rejected.finish(denied.id, client: client(), type: "meeting_control", target: "session:native:x", status: "rejected", failure: "APPROVAL_DENIED")
        XCTAssertEqual(rejected.audit.last?.status, "rejected")
        XCTAssertEqual(rejected.audit.last?.failure, "APPROVAL_DENIED")
        XCTAssertEqual(rejected.audit.last?.client, "test")
    }

    // MARK: JSON-RPC surface

    @MainActor private struct StubBackend: MCPBackend {
        func status() async throws -> MCPJSON { ["backend": "stub"] }
        func listMeetings(_: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON { [:] }
        func getMeeting(_: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON { [:] }
        func getTranscript(_: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON { [:] }
        func getOutcome(_: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON { [:] }
        func listTasks(_: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON { [:] }
        func search(_: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON { [:] }
        func getSettings(_: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON { [:] }
        func controlMeeting(_: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON { [:] }
        func setFavorite(_: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON { [:] }
        func updateTask(_: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON { [:] }
        func updateSettings(_: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON { [:] }
        func runAssistant(_: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON { [:] }
    }

    func testToolsListExposesTwelveToolsWithHonestAnnotations() async throws {
        let server = MCPJSONRPCServer(backend: StubBackend())
        let listResponse = await server.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/list"], client: client())
        let result = try XCTUnwrap(listResponse)?["result"] as? MCPJSON
        let tools = try XCTUnwrap(result?["tools"] as? [MCPJSON])
        XCTAssertEqual(tools.count, nativeMCPToolDefinitions().count)
        let byName = Dictionary(uniqueKeysWithValues: tools.compactMap { tool -> (String, MCPJSON)? in
            guard let name = tool["name"] as? String else { return nil }
            return (name, tool)
        })
        XCTAssertEqual(byName.count, nativeMCPToolDefinitions().count)
        for definition in nativeMCPToolDefinitions() {
            let tool = try XCTUnwrap(byName[definition.name])
            let annotations = try XCTUnwrap(tool["annotations"] as? MCPJSON)
            XCTAssertEqual(annotations["readOnlyHint"] as? Bool, definition.readOnly, definition.name)
            XCTAssertEqual(annotations["destructiveHint"] as? Bool, false, definition.name)
            XCTAssertFalse((tool["description"] as? String ?? "").isEmpty, definition.name)
        }
        let initResponse = await server.handle(["jsonrpc": "2.0", "id": 2, "method": "initialize"], client: client())
        let initialize = try XCTUnwrap(initResponse)
        XCTAssertEqual((initialize["result"] as? MCPJSON)?["serverInfo"] as? NSDictionary, ["name": "rocknroll-native", "version": "0.1.0"] as NSDictionary)
        let unknownResponse = await server.handle(["jsonrpc": "2.0", "id": 3, "method": "bogus/method"], client: client())
        let unknown = try XCTUnwrap(unknownResponse)
        XCTAssertEqual((unknown["error"] as? MCPJSON)?["code"] as? Int, -32601)
        let notification = await server.handle(["jsonrpc": "2.0", "method": "notifications/initialized"], client: client())
        XCTAssertNil(notification)
    }

    // MARK: Loopback HTTP transport

    func testTransportPairsAndServesScopedRpc() async throws {
        let tokens = MCPTokenStore()
        let server = MCPJSONRPCServer(backend: StubBackend())
        let transport = MCPHTTPTransport(server: server, tokens: tokens, endpointFile: tempFile())
        try await transport.start()
        addTeardownBlock { transport.stop() }
        let endpoint = try XCTUnwrap(tokens.endpoint(host: "127.0.0.1", port: transport.port ?? 0, path: "/mcp"))
        let endpointData = try Data(contentsOf: transport.endpointFile)
        let endpointObject = try XCTUnwrap(JSONSerialization.jsonObject(with: endpointData) as? MCPJSON)
        XCTAssertEqual(endpointObject["port"] as? Int, Int(endpoint.port))
        let permissions = try FileManager.default.attributesOfItem(atPath: transport.endpointFile.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600, "The endpoint file carries the pairing secret")

        let url = URL(string: "http://127.0.0.1:\(endpoint.port)")!
        // Bad pairing token.
        let (badPair, badStatus) = try await post(url.appendingPathComponent("pair"), object: ["pairing_token": "wrong"], token: nil)
        XCTAssertEqual(badStatus, 401); _ = badPair
        // Good pairing token: default read scopes.
        let (pairBody, pairStatus) = try await post(url.appendingPathComponent("pair"), object: ["pairing_token": endpoint.pairingToken, "client": "codex"], token: nil)
        XCTAssertEqual(pairStatus, 200)
        let clientToken = try XCTUnwrap(pairBody?["client_token"] as? String)
        XCTAssertEqual(pairBody?["scopes"] as? [String], ["meetings:read", "settings:read"])

        // Unauthenticated tool call.
        let (unauth, unauthStatus) = try await post(url.appendingPathComponent("mcp"), object: rpc("tools/call", name: "rocknroll_status"), token: nil)
        XCTAssertEqual(unauthStatus, 401); _ = unauth
        // Authorized read.
        let (statusBody, statusCode) = try await post(url.appendingPathComponent("mcp"), object: rpc("tools/call", name: "rocknroll_status"), token: clientToken)
        XCTAssertEqual(statusCode, 200)
        let result = statusBody?["result"] as? MCPJSON
        let content = (result?["content"] as? [MCPJSON])?.first
        XCTAssertEqual(result?["isError"] as? Bool, false)
        XCTAssertTrue((content?["text"] as? String ?? "").contains("stub"))
        // Read-only token cannot call a write tool: the transport rejects before dispatch.
        let (denied, deniedStatus) = try await post(url.appendingPathComponent("mcp"), object: rpc("tools/call", name: "rocknroll_update_settings"), token: clientToken)
        XCTAssertEqual(deniedStatus, 401); _ = denied
        // Unknown path.
        let (_, notFound) = try await post(url.appendingPathComponent("nope"), object: [:], token: clientToken)
        XCTAssertEqual(notFound, 404)
    }

    private func rpc(_ method: String, name: String? = nil, arguments: MCPJSON = [:]) -> MCPJSON {
        var params: MCPJSON = [:]
        if let name { params = ["name": name, "arguments": arguments] }
        return ["jsonrpc": "2.0", "id": UUID().uuidString, "method": method, "params": params]
    }

    private func post(_ url: URL, object: MCPJSON, token: String?) async throws -> (MCPJSON?, Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: object)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let body = try JSONSerialization.jsonObject(with: data) as? MCPJSON
        return (body, status)
    }

    // MARK: Backend reads without a workspace

    func testBackendReadsAreSafeWithNoWorkspace() async throws {
        let backend = NativeDesktopMCPBackend(defaults: defaults())
        let status = try await backend.status()
        XCTAssertEqual(status["backend"] as? String, "native")
        XCTAssertEqual((status["app"] as? MCPJSON)?["active_meetings"] as? Int, 0)
        let listed = try await backend.listMeetings([:], client: client())
        XCTAssertEqual((listed["items"] as? [MCPJSON])?.count, 0)
        XCTAssertEqual(listed["coverage"] as? String, "complete")
        let searched = try await backend.search(["query": "anything"], client: client())
        XCTAssertEqual((searched["items"] as? [MCPJSON])?.count, 0)
        await assertFailure("MEETING_NOT_FOUND") {
            try await backend.getMeeting(["meeting_id": "session:native:\(UUID().uuidString)"], client: client())
        }
        await assertFailure("MEETING_NOT_FOUND") {
            try await backend.controlMeeting(["action_id": UUID().uuidString, "meeting_id": "session:native:\(UUID().uuidString)", "desired_state": ["leave": true]], client: client())
        }
        await assertFailure("APP_NOT_RUNNING") {
            try await backend.runAssistant(["action_id": UUID().uuidString, "prompt": "hi"], client: client())
        }
    }

    func testMutationsRequireExpectedRevisionBeforeAnyLookup() async throws {
        let backend = NativeDesktopMCPBackend(defaults: defaults())
        // No expected_revision: refused before the room lookup, so nothing is touched.
        await assertFailure("INVALID_ARGUMENT") {
            try await backend.setFavorite(["action_id": UUID().uuidString, "room_id": "room:native:\(UUID().uuidString)", "favorite": true], client: client())
        }
        XCTAssertTrue(backend.actions.recordedActions.isEmpty, "A refused action leaves no pending record")
        await assertFailure("APP_NOT_RUNNING") {
            try await backend.updateSettings(["action_id": UUID().uuidString, "sections": [:]], client: client())
        }
    }

    // MARK: Settings with a real attention store
    //
    // These tests build a live AttentionStore, which trips the Swift 6.3/6.4
    // XCTest async-invocation bug noted above; they therefore run through the
    // synchronous `runAsyncTest` wrapper.

    private func makeSettingsBackend(allow: NSMutableArray? = nil, approvals: NSMutableArray? = nil)
        -> (backend: NativeDesktopMCPBackend, store: AttentionStore, coordinator: AttentionCoordinator, injected: UserDefaults) {
        let store = store()
        store.provider = .init(kind: .custom, baseURL: "https://judge.example/v1", model: "m")
        XCTAssertTrue(store.setAPIKey("sk-test-secret-key-123", for: store.provider))
        let coordinator = AttentionCoordinator(store: store)
        let injected = defaults()
        let gate = allow ?? NSMutableArray(object: false)
        let log = approvals ?? NSMutableArray()
        let backend = NativeDesktopMCPBackend(defaults: injected,
                                              approval: { title, _ in log.add(title); return (gate[0] as? Bool) ?? false },
                                              attention: { [weak coordinator] in coordinator })
        return (backend, store, coordinator, injected)
    }

    private func drain(_ store: AttentionStore, _ coordinator: AttentionCoordinator) async {
        await store.assistant.waitForLoad()
        await store.waitForMoments()
        coordinator.stop()
    }

    func testSettingsReadExposesNoAPIKey() {
        runAsyncTest { @MainActor in
            let fixtures = self.makeSettingsBackend()
            guard let read = try? await fixtures.backend.getSettings([:], client: self.client()) else {
                XCTFail("getSettings should succeed"); return
            }
            let sections = read["sections"] as? MCPJSON
            XCTAssertNotNil(sections?["app"]); XCTAssertNotNil(sections?["attention"])
            guard let encoded = try? JSONSerialization.data(withJSONObject: read, options: [.sortedKeys]) else {
                XCTFail("settings must be serializable"); return
            }
            let text = String(data: encoded, encoding: .utf8) ?? ""
            XCTAssertFalse(text.contains("sk-test-secret-key-123"), "API keys never leave the keychain")
            XCTAssertTrue(text.contains("\"has_key\":true"))
            XCTAssertNotNil(read["revision"] as? String)
            await self.drain(fixtures.store, fixtures.coordinator)
        }
    }

    func testSettingsUpdateRequiresRevisionAndApproval() {
        runAsyncTest { @MainActor in
            let approvals = NSMutableArray()
            let fixtures = self.makeSettingsBackend(approvals: approvals)
            guard let read = try? await fixtures.backend.getSettings([:], client: self.client()),
                  let revision = read["revision"] as? String else {
                XCTFail("getSettings should succeed"); return
            }
            let wasEnabled = fixtures.store.enabled
            let patch: MCPJSON = ["sections": ["attention": ["judge_enabled": !wasEnabled]]]
            // Wrong revision: retryable conflict, no approval asked, nothing changed.
            var args = patch; args["action_id"] = UUID().uuidString; args["expected_revision"] = "stale"
            do {
                _ = try await fixtures.backend.updateSettings(args, client: self.client())
                XCTFail("Expected REVISION_CONFLICT")
            } catch let failure as MCPToolFailure {
                XCTAssertEqual(failure.code, "REVISION_CONFLICT"); XCTAssertEqual(failure.retryable, true)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(approvals.count, 0)
            XCTAssertEqual(fixtures.store.enabled, wasEnabled, "A conflicted update never touches the store")

            // Correct revision but approval denied: an auditable rejected action.
            args["expected_revision"] = revision
            guard let denied = try? await fixtures.backend.updateSettings(args, client: self.client()) else {
                XCTFail("updateSettings should return a rejected result"); return
            }
            XCTAssertEqual(denied["status"] as? String, "rejected")
            XCTAssertEqual(approvals.count, 1)
            XCTAssertEqual(approvals[0] as? String, "Settings update")
            XCTAssertEqual(fixtures.store.enabled, wasEnabled)
            XCTAssertEqual(fixtures.backend.actions.audit.last?.status, "rejected")
            XCTAssertEqual(fixtures.backend.actions.audit.last?.failure, "APPROVAL_DENIED")
            await self.drain(fixtures.store, fixtures.coordinator)
        }
    }

    func testSettingsUpdateAppliesReplaysAndDetectsReuse() {
        runAsyncTest { @MainActor in
            let allow = NSMutableArray(object: true)
            let fixtures = self.makeSettingsBackend(allow: allow)
            guard let read = try? await fixtures.backend.getSettings([:], client: self.client()),
                  let revision = read["revision"] as? String else {
                XCTFail("getSettings should succeed"); return
            }
            let wasEnabled = fixtures.store.enabled
            var args: MCPJSON = ["action_id": UUID().uuidString, "expected_revision": revision,
                                 "sections": ["attention": ["judge_enabled": !wasEnabled], "app": ["multiple_meetings": false]]]
            guard let first = try? await fixtures.backend.updateSettings(args, client: self.client()) else {
                XCTFail("updateSettings should succeed"); return
            }
            XCTAssertEqual(first["status"] as? String, "applied")
            XCTAssertEqual(fixtures.store.enabled, !wasEnabled)
            XCTAssertFalse(fixtures.injected.bool(forKey: "nativeDesktop.multipleMeetings"))
            // An exact replay returns the stored result without asking again.
            guard let replay = try? await fixtures.backend.updateSettings(args, client: self.client()) else {
                XCTFail("the replay should succeed"); return
            }
            XCTAssertEqual(replay["status"] as? String, "applied", "Same action_id + same payload replays the recorded result")
            // The same action_id with a different payload is refused.
            args["sections"] = ["attention": ["judge_enabled": wasEnabled]]
            await self.assertFailure("ACTION_ID_REUSED") {
                try await fixtures.backend.updateSettings(args, client: self.client())
            }
            await self.drain(fixtures.store, fixtures.coordinator)
        }
    }

    // MARK: In-app assistant safety

    private func meeting(_ name: String) async throws -> NativeDesktopMeetingModel {
        let engine = MCPTestEngine()
        let model = NativeDesktopMeetingModel(destination: try .verified(URL(string: "https://example.test/calls/\(name)")!, engine: .guest),
                                              name: "Vitalii", title: name, engine: engine)
        try await model.connect()
        addTeardownBlock { _ = await model.leave() }
        return model
    }

    func testRunExternalNeverUsesSendBypassAndCancelsPending() {
        runAsyncTest { @MainActor in
            let store = self.store(); store.provider = .init(kind: .local, baseURL: "http://127.0.0.1:1/v1", model: "m")
            guard let infra = try? await self.meeting("mcp-infra") else {
                XCTFail("the fixture meeting should connect"); return
            }
            infra.chat.canSend = true
            let coordinator = AttentionCoordinator(store: store); coordinator.meetings = { [infra] }
            var sent: [String] = []
            coordinator.deliverChat = { _, text in sent.append(text); return true }
            let talk = coordinator.talk
            talk.setDirectSend(true, for: infra.sessionID)

            talk.interpretOverride = { _ in .init(action: .sendChat, meetingID: infra.sessionID, text: "on my way") }
            let external = await talk.runExternal("tell them I'm on my way")
            XCTAssertTrue(external.needsNativeConfirmation, "External MCP callers can never use the send-without-asking bypass")
            XCTAssertNil(external.answer)
            XCTAssertTrue(sent.isEmpty, "Nothing was sent")
            XCTAssertNil(talk.pending, "The pending command was cancelled, not left for a later confirm")

            await talk.run("tell them I'm on my way")
            try! await self.spin { sent.count == 1 }
            XCTAssertEqual(sent, ["on my way"], "The internal path still honors the bypass, proving the override itself works")

            talk.interpretOverride = { _ in .init(action: .mute, meetingID: infra.sessionID) }
            let muted = await talk.runExternal("mute me")
            XCTAssertFalse(muted.needsNativeConfirmation)
            XCTAssertNotNil(muted.answer)
            XCTAssertNil(talk.pending)

            // Drain background loading so no in-flight child tasks outlive the test.
            await store.assistant.waitForLoad()
            await store.waitForMoments()
            coordinator.stop()
        }
    }
}
