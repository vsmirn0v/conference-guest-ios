import AppKit
import ConferenceCore
import Foundation
import XCTest
@testable import RockNativeDesktop

/// Contract tests for the published inputSchemas and the pre-dispatch validator:
/// catalog shape, schema/handler drift guard, the per-tool behavior matrix, and
/// side-effect safety (invalid calls never reach the backend or the action log).
///
/// Every async test body runs through `runAsyncTest`: XCTest's native async
/// invocation on Swift 6.3/6.4 (Xcode 26) silently skips bodies (they report
/// "passed" in ~0 ms without executing) whenever the concurrency-runtime bug
/// swiftlang/swift#87481 would trip, so `async` test methods are not trustworthy
/// on this toolchain.
@MainActor final class MCPSchemaContractTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = Self.disableBuggyMemoryChecker
    }

    // Swift 6.3/6.4 (Xcode 26) XCTest wraps every test body in a private memory
    // checker, `assertInvalidObjectsDeallocatedAfterScope:`, whose post-scope
    // assertion trips a concurrency-runtime bug ("freed pointer was not the
    // last allocation", swiftlang/swift#87481) whenever the body touched the
    // attention store — aborting the test host. The checker takes the body as
    // its scope block, so the safe neutralization is to KEEP running the block
    // and skip only the assertion. Do NOT replace the implementation with a
    // plain no-op (or class_addMethod it onto a subclass): XCTest runs the test
    // body inside this method, so swallowing it produces tests that report
    // "passed" in ~0 ms while their bodies never execute.
    private static let disableBuggyMemoryChecker: Void = {
        let selector = NSSelectorFromString("assertInvalidObjectsDeallocatedAfterScope:")
        guard let method = class_getInstanceMethod(XCTestCase.self, selector) else { return }
        let block: @convention(block) (AnyObject?, AnyObject?) -> Void = { _, scope in
            guard let scope else { return }
            unsafeBitCast(scope, to: (@convention(block) () -> Void).self)()
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }()

    /// Runs an async body on the main actor and fails the test if it throws or
    /// times out. See the class doc comment: native `async` test methods are
    /// silently hollow on this toolchain.
    private func runAsyncTest(file: StaticString = #filePath, line: UInt = #line,
                              _ body: @escaping @MainActor () async throws -> Void) {
        let done = expectation(description: "async body")
        Task {
            do { try await body() }
            catch { XCTFail("Async body threw: \(error)", file: file, line: line) }
            done.fulfill()
        }
        let result = XCTWaiter().wait(for: [done], timeout: 120)
        XCTAssertEqual(result, .completed, "Async test body timed out", file: file, line: line)
    }

    private func client(_ scopes: Set<String> = ["meetings:read", "settings:read"], label: String = "test") -> MCPClientIdentity {
        MCPClientIdentity(tokenHash: "hash", scopes: scopes, label: label)
    }

    /// Every scope a write tool can need.
    private let allScopes: Set<String> = ["meetings:read", "settings:read", "meetings:control",
                                          "favorites:write", "tasks:write", "settings:write", "assistant:run"]

    /// Records handler invocations so tests can prove validation precedes dispatch.
    private final class CountingBackend: MCPBackend {
        var calls: [String] = []
        func record(_ name: String) -> MCPJSON { calls.append(name); return ["ok": true] }
        func status() async throws -> MCPJSON { record("status") }
        func listMeetings(_: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON { record("listMeetings") }
        func getMeeting(_: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON { record("getMeeting") }
        func getTranscript(_: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON { record("getTranscript") }
        func getOutcome(_: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON { record("getOutcome") }
        func getNotes(_: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON { record("getNotes") }
        func listTasks(_: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON { record("listTasks") }
        func search(_: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON { record("search") }
        func getSettings(_: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON { record("getSettings") }
        func controlMeeting(_: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON { record("controlMeeting") }
        func setFavorite(_: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON { record("setFavorite") }
        func updateTask(_: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON { record("updateTask") }
        func updateSettings(_: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON { record("updateSettings") }
        func runAssistant(_: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON { record("runAssistant") }
    }

    private func call(_ server: MCPJSONRPCServer, _ name: String, _ arguments: Any? = [:],
                      scopes: Set<String> = ["meetings:read", "settings:read"]) async -> MCPJSON {
        var params: MCPJSON = ["name": name]
        if let arguments { params["arguments"] = arguments }
        let request: MCPJSON = ["jsonrpc": "2.0", "id": UUID().uuidString, "method": "tools/call", "params": params]
        let response = await server.handle(request, client: client(scopes))
        return (response?["result"] as? MCPJSON) ?? ["isError": true, "transportError": response?["error"] as Any]
    }

    /// Decodes the structured tool error from an isError result.
    private func toolError(_ response: MCPJSON) -> MCPJSON? {
        guard response["isError"] as? Bool == true,
              let content = (response["content"] as? [MCPJSON])?.first,
              let text = content["text"] as? String,
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? MCPJSON else { return nil }
        return object["error"] as? MCPJSON
    }

    private func assertToolError(_ response: MCPJSON, _ code: String, field: String? = nil, reason: String? = nil,
                                 file: StaticString = #filePath, line: UInt = #line) {
        guard let error = toolError(response) else {
            XCTFail("Expected an isError tool result, got \(response)", file: file, line: line); return
        }
        XCTAssertEqual(error["code"] as? String, code, file: file, line: line)
        let details = error["details"] as? MCPJSON
        if let field { XCTAssertEqual(details?["field"] as? String, field, "error details should name the field", file: file, line: line) }
        if let reason { XCTAssertEqual(details?["reason"] as? String, reason, file: file, line: line) }
    }

    // MARK: Catalog shape

    func testCatalogPublishesSchemasForAllFourteenTools() {
        runAsyncTest { @MainActor in
            let server = MCPJSONRPCServer(backend: CountingBackend())
            let list = await server.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/list"], client: self.client())
            let tools = try XCTUnwrap((list?["result"] as? MCPJSON)?["tools"] as? [MCPJSON])
            XCTAssertEqual(tools.count, 14)
            for tool in tools {
                let label = (tool["name"] as? String) ?? "?"
                let schema = try XCTUnwrap(tool["inputSchema"] as? MCPJSON, label)
                XCTAssertEqual(schema["type"] as? String, "object")
                XCTAssertEqual(schema["additionalProperties"] as? Bool, false, label)
                let properties = try XCTUnwrap(schema["properties"] as? MCPJSON, label)
                let required = (schema["required"] as? [String]) ?? []
                XCTAssertTrue(required.allSatisfy { properties[$0] != nil }, "required must be a subset of properties for \(label)")
                // Every published property (including nested) carries a description.
                try self.assertDescribed(properties, tool: (tool["name"] as? String) ?? "?")
                // Self-contained: no $ref anywhere in the encoded schema.
                let encoded = try JSONSerialization.data(withJSONObject: schema)
                XCTAssertFalse(String(data: encoded, encoding: .utf8)?.contains("$ref") ?? true)
            }
            let status = try XCTUnwrap(tools.first(where: { $0["name"] as? String == "rocknroll_status" })?["inputSchema"] as? MCPJSON)
            XCTAssertEqual((status["properties"] as? MCPJSON)?.isEmpty, true)
            XCTAssertEqual((status["required"] as? [String])?.isEmpty, true)
            // The only tool allowed an empty schema is status.
            let emptyOthers = tools.filter { $0["name"] as? String != "rocknroll_status" }
                .filter { (($0["inputSchema"] as? MCPJSON)?["properties"] as? MCPJSON)?.isEmpty != false }
            XCTAssertEqual(emptyOthers.map { $0["name"] as? String }, [], "empty schemas only where the handler reads nothing")
            let initialize = await server.handle(["jsonrpc": "2.0", "id": 2, "method": "initialize"], client: self.client())
            let info = (initialize?["result"] as? MCPJSON)?["serverInfo"] as? MCPJSON
            XCTAssertEqual(info?["version"] as? String, "0.3.0")
            XCTAssertEqual(info?["name"] as? String, "rocknroll-native")
        }
    }

    private func assertDescribed(_ properties: MCPJSON, tool: String, path: String = "") throws {
        for (key, value) in properties {
            guard let property = value as? MCPJSON else { throw XCTSkip("non-object property in \(tool)") }
            XCTAssertFalse((property["description"] as? String ?? "").isEmpty, "\(tool).\(path)\(key) needs a description")
            if let nested = property["properties"] as? MCPJSON {
                try assertDescribed(nested, tool: tool, path: "\(path)\(key).")
            }
            if let items = property["items"] as? MCPJSON, let itemProperties = items["properties"] as? MCPJSON {
                try assertDescribed(itemProperties, tool: tool, path: "\(path)\(key)[].")
            }
        }
    }

    // MARK: Drift guard: published fields must equal the fields handlers read

    func testPublishedSchemasMatchHandlerContracts() {
        // Expected readable fields per tool, independently maintained from the
        // handler audit in mcp/CONTRACTS.md. A mismatch here means schema or
        // handler drifted — fix the code, not this table, after updating CONTRACTS.md.
        let expected: [String: (fields: Set<String>, required: Set<String>)] = [
            "rocknroll_status": ([], []),
            "rocknroll_list_meetings": (["from", "to", "query", "kind", "limit", "cursor"], []),
            "rocknroll_get_meeting": (["meeting_id"], ["meeting_id"]),
            "rocknroll_get_transcript": (["meeting_id", "from", "to", "limit", "cursor"], ["meeting_id"]),
            "rocknroll_get_outcome": (["outcome_id"], ["outcome_id"]),
            "rocknroll_get_notes": (["meeting_id"], ["meeting_id"]),
            "rocknroll_list_tasks": (["meeting_id", "done", "owner", "limit", "cursor"], []),
            "rocknroll_search": (["query", "types", "limit", "cursor"], ["query"]),
            "rocknroll_get_settings": (["sections", "meeting_id"], []),
            "rocknroll_control_meeting": (["action_id", "meeting_id", "desired_state"], ["action_id", "meeting_id"]),
            "rocknroll_set_favorite": (["action_id", "room_id", "favorite", "expected_revision"], ["action_id", "room_id", "favorite"]),
            "rocknroll_update_task": (["action_id", "task_id", "expected_revision", "text", "owner", "done"], ["action_id", "task_id"]),
            "rocknroll_update_settings": (["action_id", "expected_revision", "sections"], ["action_id"]),
            "rocknroll_run_assistant": (["action_id", "prompt", "meeting_id", "conversation_id"], ["action_id", "prompt"]),
        ]
        XCTAssertEqual(nativeMCPToolDefinitions().count, expected.count)
        for definition in nativeMCPToolDefinitions() {
            guard let want = expected[definition.name] else { XCTFail("missing expectation for \(definition.name)"); continue }
            XCTAssertEqual(Set(definition.schema.properties.keys), want.fields, "\(definition.name) fields")
            XCTAssertEqual(Set(definition.schema.required), want.required, "\(definition.name) required")
        }
    }

    // MARK: Structural validation behavior matrix

    func testUnknownFieldsAreRejectedBeforeDispatch() {
        runAsyncTest { @MainActor in
            let backend = CountingBackend()
            let server = MCPJSONRPCServer(backend: backend)
            let response = await self.call(server, "rocknroll_get_meeting", ["meeting_id": "session:native:x", "bogus": 1])
            self.assertToolError(response, "INVALID_ARGUMENT", field: "bogus", reason: "unknown_field")
            XCTAssertTrue(backend.calls.isEmpty, "A rejected call must never reach the backend")
            let list = await self.call(server, "rocknroll_list_meetings", ["surprise": true])
            self.assertToolError(list, "INVALID_ARGUMENT", field: "surprise", reason: "unknown_field")
            XCTAssertTrue(backend.calls.isEmpty)
        }
    }

    func testRequiredFieldsAreEnforced() {
        runAsyncTest { @MainActor in
            let server = MCPJSONRPCServer(backend: CountingBackend())
            self.assertToolError(await self.call(server, "rocknroll_get_meeting", [:]), "INVALID_ARGUMENT", field: "meeting_id", reason: "required")
            self.assertToolError(await self.call(server, "rocknroll_get_transcript", [:]), "INVALID_ARGUMENT", field: "meeting_id", reason: "required")
            self.assertToolError(await self.call(server, "rocknroll_get_outcome", [:]), "INVALID_ARGUMENT", field: "outcome_id", reason: "required")
            self.assertToolError(await self.call(server, "rocknroll_search", [:]), "INVALID_ARGUMENT", field: "query", reason: "required")
            self.assertToolError(await self.call(server, "rocknroll_search", ["query": NSNull()]), "INVALID_ARGUMENT", field: "query", reason: "null")
            self.assertToolError(await self.call(server, "rocknroll_control_meeting", ["action_id": UUID().uuidString], scopes: self.allScopes), "INVALID_ARGUMENT", field: "meeting_id", reason: "required")
            // No-argument tools still accept an empty object.
            let status = await self.call(server, "rocknroll_status", [:])
            XCTAssertEqual(status["isError"] as? Bool, false)
        }
    }

    func testTypesAreStrictAndNeverCoerced() {
        runAsyncTest { @MainActor in
            let backend = CountingBackend()
            let server = MCPJSONRPCServer(backend: backend)
            self.assertToolError(await self.call(server, "rocknroll_get_meeting", ["meeting_id": 7]), "INVALID_ARGUMENT", field: "meeting_id", reason: "type")
            self.assertToolError(await self.call(server, "rocknroll_get_meeting", ["meeting_id": NSNull()]), "INVALID_ARGUMENT", field: "meeting_id", reason: "null")
            self.assertToolError(await self.call(server, "rocknroll_get_meeting", ["meeting_id": ""]), "INVALID_ARGUMENT", field: "meeting_id", reason: "empty")
            self.assertToolError(await self.call(server, "rocknroll_search", ["query": "x", "limit": "20"]), "INVALID_ARGUMENT", field: "limit", reason: "type")
            self.assertToolError(await self.call(server, "rocknroll_search", ["query": "x", "limit": true]), "INVALID_ARGUMENT", field: "limit", reason: "type")
            self.assertToolError(await self.call(server, "rocknroll_list_tasks", ["done": "true"]), "INVALID_ARGUMENT", field: "done", reason: "type")
            self.assertToolError(await self.call(server, "rocknroll_list_tasks", ["done": 1]), "INVALID_ARGUMENT", field: "done", reason: "type")
            self.assertToolError(await self.call(server, "rocknroll_list_tasks", ["done": NSNull()]), "INVALID_ARGUMENT", field: "done", reason: "null")
            // Non-object arguments are rejected outright.
            self.assertToolError(await self.call(server, "rocknroll_status", "nope"), "INVALID_ARGUMENT", field: "arguments", reason: "type")
            XCTAssertTrue(backend.calls.isEmpty)
        }
    }

    func testEnumsAreEnforced() {
        runAsyncTest { @MainActor in
            let server = MCPJSONRPCServer(backend: CountingBackend())
            self.assertToolError(await self.call(server, "rocknroll_list_meetings", ["kind": "bogus"]), "INVALID_ARGUMENT", field: "kind", reason: "enum")
            self.assertToolError(await self.call(server, "rocknroll_search", ["query": "x", "types": ["bogus"]]), "INVALID_ARGUMENT", field: "types[0]", reason: "enum")
            self.assertToolError(await self.call(server, "rocknroll_search", ["query": "x", "types": [7]]), "INVALID_ARGUMENT", field: "types[0]", reason: "type")
            self.assertToolError(await self.call(server, "rocknroll_get_settings", ["sections": ["bogus"]]), "INVALID_ARGUMENT", field: "sections[0]", reason: "enum")
            // Empty arrays are structurally fine.
            let empty = await self.call(server, "rocknroll_search", ["query": "x", "types": []])
            XCTAssertEqual(empty["isError"] as? Bool, false)
        }
    }

    func testLimitBoundsAreEnforced() {
        runAsyncTest { @MainActor in
            let backend = CountingBackend()
            let server = MCPJSONRPCServer(backend: backend)
            self.assertToolError(await self.call(server, "rocknroll_search", ["query": "x", "limit": 0]), "INVALID_ARGUMENT", field: "limit", reason: "range")
            self.assertToolError(await self.call(server, "rocknroll_search", ["query": "x", "limit": 101]), "INVALID_ARGUMENT", field: "limit", reason: "range")
            let atMax = await self.call(server, "rocknroll_search", ["query": "x", "limit": 100])
            XCTAssertEqual(atMax["isError"] as? Bool, false)
            let atMin = await self.call(server, "rocknroll_search", ["query": "x", "limit": 1])
            XCTAssertEqual(atMin["isError"] as? Bool, false)
            XCTAssertEqual(backend.calls.filter { $0 == "search" }.count, 2)
        }
    }

    func testDatesRequireOffsetsAndOrdering() {
        runAsyncTest { @MainActor in
            // The real backend is used so MCPValue.date runs in the handler.
            let server = MCPJSONRPCServer(backend: NativeDesktopMCPBackend(defaults: UserDefaults(suiteName: "mcp-schema-\(UUID().uuidString)")!))
            let noOffset = await self.call(server, "rocknroll_list_meetings", ["from": "2026-01-01T09:00:00"])
            self.assertToolError(noOffset, "INVALID_ARGUMENT", field: "from", reason: "format")
            let badDate = await self.call(server, "rocknroll_list_meetings", ["from": "2026-13-40T09:00:00+03:00"])
            self.assertToolError(badDate, "INVALID_ARGUMENT", field: "from", reason: "format")
            let reversed = await self.call(server, "rocknroll_list_meetings",
                                           ["from": "2026-02-01T09:00:00+03:00", "to": "2026-01-01T09:00:00+03:00"])
            self.assertToolError(reversed, "INVALID_ARGUMENT", field: "from", reason: "range")
            let transcriptReversed = await self.call(server, "rocknroll_get_transcript",
                                                     ["meeting_id": "session:native:\(UUID().uuidString)",
                                                      "from": "2026-02-01T09:00:00Z", "to": "2026-02-01T09:00:00Z"])
            self.assertToolError(transcriptReversed, "INVALID_ARGUMENT", field: "from", reason: "range")
            // Valid bounds reach the handler and return an empty page.
            let valid = await self.call(server, "rocknroll_list_meetings", ["from": "2026-01-01T00:00:00Z", "to": "2026-03-01T00:00:00+03:00"])
            XCTAssertEqual(valid["isError"] as? Bool, false)
        }
    }

    func testQueryTrimmingPolicy() {
        runAsyncTest { @MainActor in
            let server = MCPJSONRPCServer(backend: NativeDesktopMCPBackend(defaults: UserDefaults(suiteName: "mcp-schema-\(UUID().uuidString)")!))
            self.assertToolError(await self.call(server, "rocknroll_search", ["query": "   "]), "INVALID_ARGUMENT", field: "query", reason: "empty")
            let padded = await self.call(server, "rocknroll_search", ["query": "  anything  "])
            XCTAssertEqual(padded["isError"] as? Bool, false)
            // A whitespace-only optional filter is ignored, not an error.
            let list = await self.call(server, "rocknroll_list_meetings", ["query": "   "])
            XCTAssertEqual(list["isError"] as? Bool, false)
        }
    }

    func testNestedSettingsPatchValidation() {
        runAsyncTest { @MainActor in
            let server = MCPJSONRPCServer(backend: NativeDesktopMCPBackend(defaults: UserDefaults(suiteName: "mcp-schema-\(UUID().uuidString)")!))
            let action = UUID().uuidString
            self.assertToolError(await self.call(server, "rocknroll_update_settings", ["action_id": action, "sections": ["attention": ["bogus": true]]], scopes: self.allScopes),
                                 "INVALID_ARGUMENT", field: "sections.attention.bogus", reason: "unknown_field")
            self.assertToolError(await self.call(server, "rocknroll_update_settings", ["action_id": action, "sections": ["attention": ["judge_enabled": "yes"]]], scopes: self.allScopes),
                                 "INVALID_ARGUMENT", field: "sections.attention.judge_enabled", reason: "type")
            self.assertToolError(await self.call(server, "rocknroll_update_settings", ["action_id": action, "sections": ["app": ["multiple_meetings": "true"]]], scopes: self.allScopes),
                                 "INVALID_ARGUMENT", field: "sections.app.multiple_meetings", reason: "type")
            self.assertToolError(await self.call(server, "rocknroll_update_settings", ["action_id": action, "sections": ["meeting": [:]]], scopes: self.allScopes),
                                 "INVALID_ARGUMENT", field: "sections.meeting", reason: "unknown_field")
            // A structurally valid call passes validation and fails later at the domain layer.
            let passes = await self.call(server, "rocknroll_update_settings", ["action_id": action], scopes: self.allScopes)
            self.assertToolError(passes, "APP_NOT_RUNNING")
        }
    }

    func testScopeCheckPrecedesValidation() {
        runAsyncTest { @MainActor in
            let backend = CountingBackend()
            let server = MCPJSONRPCServer(backend: backend)
            // A read-only client gets SCOPE_DENIED even for structurally invalid writes.
            let denied = await self.call(server, "rocknroll_set_favorite", ["bogus": 1], scopes: ["meetings:read", "settings:read"])
            self.assertToolError(denied, "SCOPE_DENIED")
            XCTAssertTrue(backend.calls.isEmpty)
        }
    }

    func testInvalidWritesRecordNoActionAndAskNoApproval() {
        runAsyncTest { @MainActor in
            let backend = NativeDesktopMCPBackend(defaults: UserDefaults(suiteName: "mcp-schema-\(UUID().uuidString)")!)
            let server = MCPJSONRPCServer(backend: backend)
            self.assertToolError(await self.call(server, "rocknroll_control_meeting",
                                                 ["action_id": "not-a-uuid", "meeting_id": "session:native:x"], scopes: self.allScopes),
                                 "INVALID_ARGUMENT", field: "action_id", reason: "format")
            self.assertToolError(await self.call(server, "rocknroll_set_favorite",
                                                 ["action_id": UUID().uuidString, "room_id": "room:native:x", "favorite": true], scopes: self.allScopes),
                                 "INVALID_ARGUMENT", field: "expected_revision", reason: "required")
            XCTAssertTrue(backend.actions.recordedActions.isEmpty, "Refused actions leave no audit record")
            XCTAssertTrue(backend.actions.audit.isEmpty)
        }
    }

    func testConversationIdStaysACapabilityError() {
        runAsyncTest { @MainActor in
            let server = MCPJSONRPCServer(backend: NativeDesktopMCPBackend(defaults: UserDefaults(suiteName: "mcp-schema-\(UUID().uuidString)")!))
            // Recognized field, explicit rejection — even without a running workspace.
            let rejected = await self.call(server, "rocknroll_run_assistant",
                                           ["action_id": UUID().uuidString, "prompt": "hi", "conversation_id": "ext-1"], scopes: self.allScopes)
            self.assertToolError(rejected, "CAPABILITY_UNAVAILABLE")
            // Wrong-typed values still fail as plain validation errors.
            self.assertToolError(await self.call(server, "rocknroll_run_assistant",
                                                 ["action_id": UUID().uuidString, "prompt": "hi", "conversation_id": 5], scopes: self.allScopes),
                                 "INVALID_ARGUMENT", field: "conversation_id", reason: "type")
            // A whitespace-only prompt is rejected before reaching the assistant.
            self.assertToolError(await self.call(server, "rocknroll_run_assistant",
                                                 ["action_id": UUID().uuidString, "prompt": "   "], scopes: self.allScopes),
                                 "INVALID_ARGUMENT", field: "prompt", reason: "empty")
        }
    }

    func testReplayedActionPassesValidationAndReplays() {
        runAsyncTest { @MainActor in
            let defaults = UserDefaults(suiteName: "mcp-schema-\(UUID().uuidString)")!
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-schema-\(UUID().uuidString)", isDirectory: true)
            let keychain = AttentionKeychain(service: "dev.vsmirn0v.conferenceguest.mcp.schema.\(UUID().uuidString)")
            self.addTeardownBlock { keychain.deleteAll(); try? FileManager.default.removeItem(at: folder) }
            let store = AttentionStore(root: folder, defaults: UserDefaults(suiteName: "mcp-schema-store-\(UUID().uuidString)")!, keychain: keychain)
            self.closeLibraryAtTeardown(store)
            store.provider = .init(kind: .custom, baseURL: "https://judge.example/v1", model: "m")
            let coordinator = AttentionCoordinator(store: store)
            let backend = NativeDesktopMCPBackend(defaults: defaults,
                                                  approval: { _, _ in true },
                                                  attention: { [weak coordinator] in coordinator })
            let server = MCPJSONRPCServer(backend: backend)
            let identity = self.client(self.allScopes, label: "schema-test")
            var arguments: MCPJSON = ["action_id": UUID().uuidString, "sections": ["attention": ["judge_enabled": true]]]
            // Read the revision through the published surface, then apply and replay.
            // Read the revision through the published surface, then apply and replay.
            let read = await server.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                            "params": ["name": "rocknroll_get_settings", "arguments": ["sections": ["app", "attention"]]]],
                                           client: identity)
            let readResult = (read?["result"] as? MCPJSON)?["content"] as? [MCPJSON]
            let readText = readResult?.first?["text"] as? String ?? "{}"
            let readObject = (try? JSONSerialization.jsonObject(with: Data(readText.utf8)) as? MCPJSON) ?? [:]
            let revision = readObject["revision"] as? String
            XCTAssertNotNil(revision)
            let appSection = (readObject["sections"] as? MCPJSON)?["app"] as? MCPJSON
            XCTAssertNotNil(appSection?["favorite_revision"], "set_favorite's expected_revision must be discoverable")
            arguments["expected_revision"] = revision ?? ""
            let request: MCPJSON = ["jsonrpc": "2.0", "id": UUID().uuidString, "method": "tools/call",
                                    "params": ["name": "rocknroll_update_settings", "arguments": arguments]]
            let first = await server.handle(request, client: identity)
            XCTAssertEqual((first?["result"] as? MCPJSON)?["isError"] as? Bool, false)
            let replay = await server.handle(request, client: identity)
            XCTAssertEqual((replay?["result"] as? MCPJSON)?["isError"] as? Bool, false)
            await store.assistant.waitForLoad()
            await store.waitForMoments()
            coordinator.stop()
        }
    }

    // MARK: Living example: mcp/examples/tools-list.native.json mirrors the live catalog

    /// The example file checked into mcp/examples must equal the catalog the live
    /// server publishes. Regenerate it after any schema change with
    /// WRITE_TOOLS_LIST_EXAMPLE=1; this test fails on drift either way.
    func testToolsListExampleFileMatchesLiveCatalog() {
        runAsyncTest { @MainActor in
            let server = MCPJSONRPCServer(backend: CountingBackend())
            let response = await server.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/list"], client: self.client())
            let live = try XCTUnwrap(response?["result"] as? MCPJSON)

            // Repo root: NativeMacGuest/Tests/Parity/<this file> -> up four directories.
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent() // Parity
                .deletingLastPathComponent() // Tests
                .deletingLastPathComponent() // NativeMacGuest
                .deletingLastPathComponent() // repo root
            let url = root.appendingPathComponent("mcp/examples/tools-list.native.json")

            // Write when the example is missing (first run after checkout) or when
            // explicitly asked; an existing file is only ever compared, so schema
            // drift always fails here until regenerated.
            let exists = FileManager.default.fileExists(atPath: url.path)
            if !exists || ProcessInfo.processInfo.environment["WRITE_TOOLS_LIST_EXAMPLE"] != nil {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try JSONSerialization.data(withJSONObject: live, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: url, options: .atomic)
            }

            let sampleData = try Data(contentsOf: url)
            let sample = try XCTUnwrap(JSONSerialization.jsonObject(with: sampleData) as? MCPJSON)
            XCTAssertEqual((sample["tools"] as? NSArray), (live["tools"] as? NSArray),
                           "mcp/examples/tools-list.native.json is stale — regenerate with WRITE_TOOLS_LIST_EXAMPLE=1")
        }
    }
}
