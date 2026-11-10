import CryptoKit
import ConferenceCore
import Foundation
import Network

// MARK: - Shared JSON helpers

typealias MCPJSON = [String: Any]

struct MCPToolFailure: Error {
    let code: String
    let message: String
    let retryable: Bool

    init(_ code: String, _ message: String, retryable: Bool = false) {
        self.code = code; self.message = message; self.retryable = retryable
    }

    var envelope: MCPJSON {
        ["code": code, "message": message, "retryable": retryable, "details": [:]]
    }
}

enum MCPValue {
    static func string(_ value: Any?, key: String) throws -> String {
        guard let value = value as? String, !value.isEmpty else { throw MCPToolFailure("INVALID_ARGUMENT", "\(key) is required.") }
        return value
    }

    static func optionalString(_ value: Any?, key: String) throws -> String? {
        guard let value else { return nil }
        guard let text = value as? String else { throw MCPToolFailure("INVALID_ARGUMENT", "\(key) must be a string.") }
        return text
    }

    static func bool(_ value: Any?, key: String) throws -> Bool {
        guard let value = value as? Bool else { throw MCPToolFailure("INVALID_ARGUMENT", "\(key) must be a boolean.") }
        return value
    }

    static func optionalBool(_ value: Any?, key: String) throws -> Bool? {
        guard let value else { return nil }
        return try bool(value, key: key)
    }

    static func integer(_ value: Any?, key: String, default fallback: Int, maximum: Int) throws -> Int {
        guard let value else { return fallback }
        guard let number = value as? Int, number > 0 else { throw MCPToolFailure("INVALID_ARGUMENT", "\(key) must be a positive integer.") }
        return min(maximum, number)
    }

    static func date(_ value: Any?, key: String) throws -> Date? {
        guard let value else { return nil }
        guard let text = value as? String else { throw MCPToolFailure("INVALID_ARGUMENT", "\(key) must be an RFC 3339 timestamp.") }
        let cleaned = text.hasSuffix("Z") ? String(text.dropLast()) + "+00:00" : text
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: cleaned) { return date }
        let flexible = DateFormatter(); flexible.locale = Locale(identifier: "en_US_POSIX"); flexible.calendar = Calendar(identifier: .gregorian)
        flexible.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        guard let date = flexible.date(from: cleaned) else { throw MCPToolFailure("INVALID_ARGUMENT", "\(key) must be an RFC 3339 timestamp.") }
        return date
    }
}

func mcpNow() -> String {
    ISO8601DateFormatter().string(from: Date())
}

func mcpDate(_ date: Date?) -> String? {
    date.map { ISO8601DateFormatter().string(from: $0) }
}

func mcpSHA256(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
}

func mcpOpaqueID(_ kind: String, _ stable: String) -> String {
    "\(kind):native:\(mcpSHA256(stable).prefix(24))"
}

func mcpRoomID(_ invitation: URL, engine: MeetingEngineKind?) -> String {
    if let identity = MeetingRoomIdentity(invitation, engine: engine) {
        return mcpOpaqueID("room", identity.origin + "|" + identity.room + "|" + identity.engine.rawValue)
    }
    return mcpOpaqueID("room", invitation.absoluteString)
}

func mcpSessionID(_ id: UUID) -> String { "session:native:\(id.uuidString)" }
func mcpOccurrenceID(_ id: String) -> String { "occurrence:native:\(id)" }
func mcpOutcomeID(_ id: UUID) -> String { "outcome:native:\(id.uuidString)" }
func mcpTaskID(_ outcome: UUID, _ task: MeetingOutcomeTask) -> String { "task:native:\(outcome.uuidString):\(task.id.uuidString)" }

// MARK: - Auth, actions and audit

struct MCPClientIdentity {
    let tokenHash: String
    let scopes: Set<String>
    let label: String
}

struct MCPActionRecord {
    let id: String
    let payloadHash: String
    var status: String
    var result: MCPJSON?
}

struct MCPAuditEvent {
    let at = Date()
    let client: String
    let actionID: String
    let type: String
    let target: String
    let status: String
    let failure: String?
}

@MainActor final class MCPActionCenter {
    private var records: [String: MCPActionRecord] = [:]
    private(set) var audit: [MCPAuditEvent] = []
    var recordedActions: [String: MCPActionRecord] { records }
    var approval: (String, MCPJSON) async -> Bool = { _, _ in false }

    func begin(client: MCPClientIdentity, actionID: String, payload: MCPJSON) throws -> MCPActionRecord? {
        guard UUID(uuidString: actionID) != nil else { throw MCPToolFailure("INVALID_ARGUMENT", "action_id must be a UUID.") }
        let canonical = canonicalPayload(payload)
        let hash = mcpSHA256(canonical)
        if let existing = records[actionID] {
            guard existing.payloadHash == hash else { throw MCPToolFailure("ACTION_ID_REUSED", "action_id was already used for a different payload.") }
            return nil
        }
        let record = MCPActionRecord(id: actionID, payloadHash: hash, status: "pending_approval", result: nil)
        records[actionID] = record
        return record
    }

    func finish(_ actionID: String, client: MCPClientIdentity, type: String, target: String, status: String, result: MCPJSON? = nil, failure: String? = nil) -> MCPJSON {
        var record = records[actionID] ?? MCPActionRecord(id: actionID, payloadHash: "", status: status, result: nil)
        record.status = status; record.result = result
        records[actionID] = record
        audit.append(MCPAuditEvent(client: client.label, actionID: actionID, type: type, target: target, status: status, failure: failure))
        return result ?? [
            "action_id": actionID, "status": status, "observed_at": mcpNow(), "warnings": [],
        ]
    }

    private func canonicalPayload(_ payload: MCPJSON) -> String {
        (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "\(payload)"
    }
}

@MainActor final class MCPTokenStore {
    struct Endpoint {
        let host: String
        let port: UInt16
        let path: String
        let pairingToken: String
    }

    private(set) var pairingToken = UUID().uuidString + UUID().uuidString
    private var clients: [String: MCPClientIdentity] = [:]
    var writeScopesByDefault = false

    func resetPairingToken() { pairingToken = UUID().uuidString + UUID().uuidString }

    func pair(token: String, label: String, requestedScopes: [String]?) throws -> (token: String, scopes: [String]) {
        guard token == pairingToken else { throw MCPToolFailure("ACCESS_DENIED", "The pairing token was rejected.") }
        let defaults = ["meetings:read", "settings:read"]
        let allowed: Set<String> = [
            "meetings:read", "settings:read", "assistant:run", "meetings:control",
            "favorites:write", "tasks:write", "settings:write",
        ]
        let requested = Set(requestedScopes ?? (writeScopesByDefault ? Array(allowed) : defaults))
        let scopes = requested.intersection(allowed)
        let token = UUID().uuidString + UUID().uuidString
        clients[mcpSHA256(token)] = MCPClientIdentity(tokenHash: mcpSHA256(token), scopes: scopes, label: label)
        // A pairing token is single-use: rotate it so a copied token dies after pairing.
        resetPairingToken()
        return (token, scopes.sorted())
    }

    func authenticate(authorization: String?, requiredScope: String) throws -> MCPClientIdentity {
        guard let authorization, authorization.hasPrefix("Bearer ") else { throw MCPToolFailure("ACCESS_DENIED", "A bearer token is required.") }
        let token = String(authorization.dropFirst("Bearer ".count))
        guard let client = clients[mcpSHA256(token)] else { throw MCPToolFailure("ACCESS_DENIED", "The client token was rejected.") }
        guard client.scopes.contains(requiredScope) else { throw MCPToolFailure("SCOPE_DENIED", "The client lacks the \(requiredScope) scope.") }
        return client
    }

    func endpoint(host: String, port: UInt16, path: String) -> Endpoint {
        Endpoint(host: host, port: port, path: path, pairingToken: pairingToken)
    }
}

// MARK: - Native backend protocol

@MainActor protocol MCPBackend {
    func status() async throws -> MCPJSON
    func listMeetings(_ args: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON
    func getMeeting(_ args: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON
    func getTranscript(_ args: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON
    func getOutcome(_ args: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON
    func listTasks(_ args: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON
    func search(_ args: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON
    func getSettings(_ args: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON
    func controlMeeting(_ args: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON
    func setFavorite(_ args: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON
    func updateTask(_ args: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON
    func updateSettings(_ args: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON
    func runAssistant(_ args: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON
}

// MARK: - JSON-RPC server

struct MCPToolDefinition {
    let name: String
    let description: String
    let readOnly: Bool
    let scope: String
}

func nativeMCPToolDefinitions() -> [MCPToolDefinition] {
    [
        .init(name: "rocknroll_status", description: "Report native backend, capabilities and app state.", readOnly: true, scope: "meetings:read"),
        .init(name: "rocknroll_list_meetings", description: "List active, favorite, recent, calendar and outcome meetings.", readOnly: true, scope: "meetings:read"),
        .init(name: "rocknroll_get_meeting", description: "Get one native meeting record.", readOnly: true, scope: "meetings:read"),
        .init(name: "rocknroll_get_transcript", description: "Get the authoritative transcript available to the native meeting.", readOnly: true, scope: "meetings:read"),
        .init(name: "rocknroll_get_outcome", description: "Get one stored outcome by outcome ID.", readOnly: true, scope: "meetings:read"),
        .init(name: "rocknroll_list_tasks", description: "List tasks from native meeting outcomes.", readOnly: true, scope: "meetings:read"),
        .init(name: "rocknroll_search", description: "Search native meetings, outcomes, tasks and transcripts.", readOnly: true, scope: "meetings:read"),
        .init(name: "rocknroll_get_settings", description: "Read allowlisted native settings and resolved attention configuration.", readOnly: true, scope: "settings:read"),
        .init(name: "rocknroll_control_meeting", description: "Request a bound native meeting control.", readOnly: false, scope: "meetings:control"),
        .init(name: "rocknroll_set_favorite", description: "Set a favorite room through the native library.", readOnly: false, scope: "favorites:write"),
        .init(name: "rocknroll_update_task", description: "Update an allowlisted task field.", readOnly: false, scope: "tasks:write"),
        .init(name: "rocknroll_update_settings", description: "Update an allowlisted native setting.", readOnly: false, scope: "settings:write"),
        .init(name: "rocknroll_run_assistant", description: "Run a safe in-app assistant prompt.", readOnly: false, scope: "assistant:run"),
    ]
}

@MainActor final class MCPJSONRPCServer {
    let backend: any MCPBackend
    init(backend: any MCPBackend) { self.backend = backend }

    func handle(_ request: MCPJSON, client: MCPClientIdentity) async -> MCPJSON? {
        guard let method = request["method"] as? String else {
            return rpcError(id: request["id"], code: -32600, message: "Invalid request", data: [:])
        }
        if method.hasPrefix("notifications/") { return nil }
        do {
            switch method {
            case "initialize":
                return rpcResult(id: request["id"], value: [
                    "protocolVersion": "2025-03-26",
                    "capabilities": ["tools": ["listChanged": false]],
                    "serverInfo": ["name": "rocknroll-native", "version": "0.1.0"],
                ])
            case "ping": return rpcResult(id: request["id"], value: [:])
            case "tools/list":
                let tools: [MCPJSON] = nativeMCPToolDefinitions().map {
                    [
                        "name": $0.name, "description": $0.description,
                        "annotations": ["readOnlyHint": $0.readOnly, "destructiveHint": false],
                        "inputSchema": ["type": "object", "properties": [:], "required": []],
                    ]
                }
                return rpcResult(id: request["id"], value: ["tools": tools])
            case "tools/call":
                guard let params = request["params"] as? MCPJSON, let name = params["name"] as? String,
                      let definition = nativeMCPToolDefinitions().first(where: { $0.name == name }) else {
                    throw MCPToolFailure("INVALID_ARGUMENT", "A supported tool name is required.")
                }
                guard client.scopes.contains(definition.scope) else { throw MCPToolFailure("SCOPE_DENIED", "The client lacks the \(definition.scope) scope.") }
                let args = params["arguments"] as? MCPJSON ?? [:]
                let value: MCPJSON
                switch name {
                case "rocknroll_status": value = try await backend.status()
                case "rocknroll_list_meetings": value = try await backend.listMeetings(args, client: client)
                case "rocknroll_get_meeting": value = try await backend.getMeeting(args, client: client)
                case "rocknroll_get_transcript": value = try await backend.getTranscript(args, client: client)
                case "rocknroll_get_outcome": value = try await backend.getOutcome(args, client: client)
                case "rocknroll_list_tasks": value = try await backend.listTasks(args, client: client)
                case "rocknroll_search": value = try await backend.search(args, client: client)
                case "rocknroll_get_settings": value = try await backend.getSettings(args, client: client)
                case "rocknroll_control_meeting": value = try await backend.controlMeeting(args, client: client)
                case "rocknroll_set_favorite": value = try await backend.setFavorite(args, client: client)
                case "rocknroll_update_task": value = try await backend.updateTask(args, client: client)
                case "rocknroll_update_settings": value = try await backend.updateSettings(args, client: client)
                case "rocknroll_run_assistant": value = try await backend.runAssistant(args, client: client)
                default: throw MCPToolFailure("CAPABILITY_UNAVAILABLE", "Unsupported tool: \(name)")
                }
                return rpcResult(id: request["id"], value: toolResult(value))
            default:
                return rpcError(id: request["id"], code: -32601, message: "Method not found", data: [:])
            }
        } catch let failure as MCPToolFailure {
            if method == "tools/call" { return rpcResult(id: request["id"], value: toolError(failure)) }
            return rpcError(id: request["id"], code: -32602, message: failure.message, data: failure.envelope)
        } catch {
            return rpcError(id: request["id"], code: -32603, message: "Internal error", data: ["code": "INTERNAL_ERROR", "message": String(describing: error), "retryable": false, "details": [:]])
        }
    }

    private func toolResult(_ value: MCPJSON) -> MCPJSON {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data()
        return ["content": [["type": "text", "text": String(data: data, encoding: .utf8) ?? "{}"]], "isError": false]
    }

    private func toolError(_ failure: MCPToolFailure) -> MCPJSON {
        let data = (try? JSONSerialization.data(withJSONObject: ["error": failure.envelope], options: [.sortedKeys])) ?? Data()
        return ["content": [["type": "text", "text": String(data: data, encoding: .utf8) ?? "{}"]], "isError": true]
    }

    private func rpcResult(id: Any?, value: MCPJSON) -> MCPJSON {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": value]
    }

    private func rpcError(id: Any?, code: Int, message: String, data: MCPJSON) -> MCPJSON {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message, "data": data]]
    }
}

// MARK: - Loopback HTTP transport

final class MCPHTTPTransport: @unchecked Sendable {
    private let server: MCPJSONRPCServer
    private let tokens: MCPTokenStore
    private(set) var endpointFile: URL

    /// Allows the owning service to relocate the endpoint file (e.g. fallback dir).
    func updateEndpointFile(_ url: URL) { endpointFile = url }
    private var listener: NWListener?
    private let path = "/mcp"
    var onError: (String) -> Void = { _ in }

    init(server: MCPJSONRPCServer, tokens: MCPTokenStore, endpointFile: URL) {
        self.server = server; self.tokens = tokens; self.endpointFile = endpointFile
    }

    var port: UInt16? { listener?.port?.rawValue }

    @MainActor func start() async throws {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .main)
            self?.receive(connection: connection, accumulated: Data())
        }
        self.listener = listener
        // The port is published only in the .ready state; never read it synchronously.
        try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            listener.stateUpdateHandler = { [weak self] state in
                let finish: () -> Void = {
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume()
                }
                switch state {
                case .ready: finish()
                case .failed(let error):
                    if !resumed { resumed = true; continuation.resume(throwing: error) }
                    self?.onError("MCP listener failed: \(error)")
                default: break
                }
            }
            listener.start(queue: .main)
        }
        guard let port = listener.port?.rawValue, port > 0 else {
            throw MCPToolFailure("INTERNAL_ERROR", "The MCP listener did not publish a port.")
        }
        try writeEndpoint(port: port)
    }

    func stop() {
        listener?.cancel(); listener = nil
        try? FileManager.default.removeItem(at: endpointFile)
    }

    @MainActor private func writeEndpoint(port: UInt16) throws {
        let endpoint = tokens.endpoint(host: "127.0.0.1", port: port, path: path)
        let object: MCPJSON = ["host": endpoint.host, "port": Int(endpoint.port), "path": endpoint.path, "pairing_token": endpoint.pairingToken]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
        try FileManager.default.createDirectory(at: endpointFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: endpointFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: endpointFile.path)
    }

    private func receive(connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var body = accumulated; if let data { body.append(data) }
            if let request = HTTPRequest.parse(body), request.isComplete {
                Task { @MainActor in await self.respond(connection: connection, request: request) }
                return
            }
            if isComplete || error != nil {
                self.send(connection: connection, status: 400, object: ["error": "Invalid HTTP request"]); return
            }
            self.receive(connection: connection, accumulated: body)
        }
    }

    @MainActor private func respond(connection: NWConnection, request: HTTPRequest) async {
        do {
            if request.path == "/pair" {
                let object = request.jsonObject ?? [:]
                guard let pairing = object["pairing_token"] as? String else { throw MCPToolFailure("INVALID_ARGUMENT", "pairing_token is required.") }
                let label = object["client"] as? String ?? "MCP client"
                let scopes = object["scopes"] as? [String]
                let paired = try tokens.pair(token: pairing, label: label, requestedScopes: scopes)
                send(connection: connection, status: 200, object: ["client_token": paired.token, "scopes": paired.scopes])
                // Persist the rotated pairing token so the on-disk secret stays current.
                if let port = listener?.port?.rawValue { try? writeEndpoint(port: port) }
                return
            }
            guard request.path == path else { throw MCPToolFailure("NOT_FOUND", "Unknown MCP endpoint.") }
            let authorization = request.headers["authorization"]
            let firstScope = (request.jsonObject?["method"] as? String) == "tools/call" ? scope(for: request) : "meetings:read"
            let client = try tokens.authenticate(authorization: authorization, requiredScope: firstScope)
            guard let rpc = request.jsonObject else { throw MCPToolFailure("INVALID_ARGUMENT", "The request body must be a JSON-RPC object.") }
            guard let response = await server.handle(rpc, client: client) else {
                send(connection: connection, status: 202, object: [:]); return
            }
            send(connection: connection, status: 200, object: response)
        } catch let failure as MCPToolFailure {
            let status = failure.code == "ACCESS_DENIED" || failure.code == "SCOPE_DENIED" ? 401 : failure.code == "NOT_FOUND" ? 404 : 400
            send(connection: connection, status: status, object: ["error": failure.envelope])
        } catch {
            send(connection: connection, status: 500, object: ["error": ["code": "INTERNAL_ERROR", "message": String(describing: error), "retryable": false, "details": [:]]])
        }
    }

    private func scope(for request: HTTPRequest) -> String {
        guard let rpc = request.jsonObject, let params = rpc["params"] as? MCPJSON, let name = params["name"] as? String,
              let definition = nativeMCPToolDefinitions().first(where: { $0.name == name }) else { return "meetings:read" }
        return definition.scope
    }

    private func send(connection: NWConnection, status: Int, object: MCPJSON) {
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        let reason = status == 200 ? "OK" : status == 202 ? "Accepted" : status == 401 ? "Unauthorized" : status == 404 ? "Not Found" : status == 400 ? "Bad Request" : "Internal Server Error"
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }
}

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
    let expectedBodyLength: Int

    var isComplete: Bool { body.count >= expectedBodyLength }

    var jsonObject: MCPJSON? {
        guard !body.isEmpty, let object = try? JSONSerialization.jsonObject(with: body) as? MCPJSON else { return nil }
        return object
    }

    static func parse(_ data: Data) -> HTTPRequest? {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = data[..<separator.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ").map(String.init) ?? []
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let pieces = line.split(separator: ":", maxSplits: 1).map(String.init)
            if pieces.count == 2 { headers[pieces[0].trimmingCharacters(in: .whitespaces).lowercased()] = pieces[1].trimmingCharacters(in: .whitespaces) }
        }
        let length = Int(headers["content-length"] ?? "") ?? 0
        let body = data[separator.upperBound...]
        return HTTPRequest(method: requestLine[0], path: requestLine[1], headers: headers, body: Data(body), expectedBodyLength: length)
    }
}
