import Foundation

/// A neutral seam for externally supplied tools. The app's own MCP transport (a
/// separate workstream) adapts its server tools to this protocol; the agent
/// runtime never speaks MCP itself. Everything a tool can do is bounded by the
/// same descriptor/validation/approval pipeline as native tools.
protocol AssistantExternalToolProviding: Sendable {
    /// Tools the provider currently exposes. Names must already be namespaced
    /// (`<server>__<tool>`); native `rocknroll_*` names are never accepted.
    func tools() async throws -> [AssistantAgentToolDescriptor]
    /// Invoke one exposed tool with validated arguments. The provider executes
    /// on its own principal; the app-side trust policy decided exposure earlier.
    func call(_ name: String, arguments: AssistantJSON) async throws -> AssistantJSON
}

/// How far an external server may reach into the assistant. The policy is set
/// natively (settings UI); nothing in a prompt, tool output or MCP payload can
/// widen it. Grants never apply to native `rocknroll_*` action tools.
struct AssistantExternalToolTrust: Equatable, Sendable {
    /// External tools are not exposed to the model at all.
    var disabled = true
    /// Servers the user explicitly enabled, by exact server id.
    var enabledServers: Set<String> = []
    /// Servers allowed to expose read-only tools. Outward/external write tools
    /// from MCP are never bound to native approvals and stay unavailable.
    var readOnlyServers: Set<String> = []
}

/// Wraps one external tool as an agent tool. Execution delegates to the
/// provider; validation follows the shared descriptor contract. External tools
/// can never satisfy a native approval: `requiresApproval` is forced off and
/// the tool is registered only when inert (read-style) exposure is granted.
struct AssistantExternalTool: AssistantAgentTool {
    let descriptor: AssistantAgentToolDescriptor
    let provider: any AssistantExternalToolProviding

    func validate(_ arguments: AssistantJSON) throws -> AssistantJSON { arguments }

    func execute(_ call: AssistantAgentToolCall, arguments: AssistantJSON) async throws -> AssistantAgentToolResult {
        do {
            let json = try await provider.call(descriptor.name, arguments: arguments)
            return .init(callID: call.id, toolName: call.name, json: json,
                         summary: L("External tool %@ finished.", descriptor.name))
        } catch let error as AssistantAgentError {
            return .error(call, error.localizedDescription)
        } catch {
            return .error(call, error.localizedDescription)
        }
    }
}

enum AssistantExternalToolPolicy {
    /// Decide which tools from a provider may be registered, applying the trust
    /// policy and the namespacing rules. Native names and approval-demanding
    /// external tools are always rejected. Tool names must be namespaced with
    /// the provider's server id prefix (`<serverID>__<tool>`).
    static func exposedTools(_ provider: any AssistantExternalToolProviding, serverID: String,
                             trust: AssistantExternalToolTrust) async -> [any AssistantAgentTool] {
        guard !trust.disabled else { return [] }
        guard trust.enabledServers.contains(serverID) else { return [] }
        guard let descriptors = try? await provider.tools() else { return [] }
        return descriptors.compactMap { descriptor in
            guard descriptor.name.hasPrefix(serverID + "__"), !descriptor.name.hasPrefix("rocknroll_"),
                  !descriptor.name.contains("..") else { return nil }
            guard !descriptor.requiresApproval else { return nil }
            guard trust.readOnlyServers.contains(serverID) || descriptor.createsReview == false else { return nil }
            return AssistantExternalTool(descriptor: descriptor, provider: provider)
        }
    }
}

/// Host-side registry hook: the app adds the MCP adapter's provider here when
/// its transport lands; until then the registry stays native-only.
extension AssistantAgentToolRegistry {
    func register(externalTools: [any AssistantAgentTool]) {
        for tool in externalTools { register(tool) }
    }
}
