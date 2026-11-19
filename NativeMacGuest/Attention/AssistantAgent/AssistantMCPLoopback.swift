import Foundation

/// The server id the app's own MCP backend is known by in the agent's trust policy.
/// Loopback tools are namespaced `mcp__<native name>`, so the id is `mcp`.
let assistantMCPLoopbackServerID = "mcp"

extension AssistantAgentToolRegistry {
    func registerMeetingMCPTools(_ provider: any AssistantExternalToolProviding, includeAdditionalReads: Bool) async {
        let trust = AssistantExternalToolTrust(disabled: false, enabledServers: [assistantMCPLoopbackServerID],
                                               readOnlyServers: [assistantMCPLoopbackServerID])
        let tools = await AssistantExternalToolPolicy.exposedTools(provider, serverID: assistantMCPLoopbackServerID,
                                                                    trust: trust)
        let meetingTools: Set = ["mcp__rocknroll_list_meetings", "mcp__rocknroll_get_meeting", "mcp__rocknroll_get_outcome",
                                 "mcp__rocknroll_get_notes", "mcp__rocknroll_get_transcript"]
        register(externalTools: tools.filter { includeAdditionalReads || meetingTools.contains($0.descriptor.name) })
    }
}

/// Adapts the app's own MCP backend to the agent runtime's external-tool seam.
/// This is a loopback: the assistant runs natively under the user's own approvals,
/// so it receives an internal identity with read scopes. Outward MCP actions stay
/// server-side only; they are never exposed to the agent's tool registry.
@MainActor final class AssistantMCPLoopbackProvider: AssistantExternalToolProviding {
    private let backend: any MCPBackend
    private let client: MCPClientIdentity

    init(backend: any MCPBackend) {
        self.backend = backend
        client = MCPClientIdentity(
            tokenHash: mcpSHA256("rocknroll-internal-assistant"),
            scopes: Set(nativeMCPToolDefinitions().map(\.scope)),
            label: "Rock'N'Roll Assistant")
    }

    /// Read-only tools only; `run_assistant` is excluded (the agent is the assistant;
    /// recursing would loop). Names are namespaced `mcp__*` so they can never shadow
    /// or spoof native `rocknroll_*` agent tools.
    func tools() async throws -> [AssistantAgentToolDescriptor] {
        nativeMCPToolDefinitions().filter { $0.readOnly && $0.name != "rocknroll_run_assistant" }.map { definition in
            .init(name: "mcp__" + definition.name,
                  description: definition.description + " (via the app's MCP server)",
                  inputSchema: AssistantJSON.make(definition.schema.json))
        }
    }

    func call(_ name: String, arguments: AssistantJSON) async throws -> AssistantJSON {
        guard let definition = nativeMCPToolDefinitions().first(where: { "mcp__" + $0.name == name }),
              definition.readOnly, definition.name != "rocknroll_run_assistant" else {
            throw AssistantAgentError.unknownTool(name)
        }
        guard let args = arguments.foundationValue as? MCPJSON else {
            throw MCPToolFailure("INVALID_ARGUMENT", "arguments must be an object.",
                                 details: ["field": "arguments", "reason": "type"])
        }
        try MCPSchemaValidator.validate(args, schema: definition.schema)
        let value: MCPJSON
        switch definition.name {
        case "rocknroll_status": value = try await backend.status()
        case "rocknroll_list_meetings": value = try await backend.listMeetings(args, client: client)
        case "rocknroll_get_meeting": value = try await backend.getMeeting(args, client: client)
        case "rocknroll_get_transcript": value = try await backend.getTranscript(args, client: client)
        case "rocknroll_get_outcome": value = try await backend.getOutcome(args, client: client)
        case "rocknroll_get_notes": value = try await backend.getNotes(args, client: client)
        case "rocknroll_list_tasks": value = try await backend.listTasks(args, client: client)
        case "rocknroll_search": value = try await backend.search(args, client: client)
        case "rocknroll_get_settings": value = try await backend.getSettings(args, client: client)
        default: throw AssistantAgentError.unknownTool(name)
        }
        return AssistantJSON.make(value)
    }
}
