import ConferenceCore
import Foundation

extension AssistantCommandScope: Codable {}

/// A small, serializable JSON value. Tool arguments and results cross provider, storage,
/// MCP and test boundaries without `Any` or provider-specific encoders.
enum AssistantJSON: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([AssistantJSON])
    case object([String: AssistantJSON])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Int.self) { self = .int(value); return }
        if let value = try? container.decode(Double.self) { self = .double(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([AssistantJSON].self) { self = .array(value); return }
        if let value = try? container.decode([String: AssistantJSON].self) { self = .object(value); return }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported assistant JSON value")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var intValue: Int? {
        switch self {
        case .int(let value): value
        case .double(let value) where value.rounded() == value: Int(value)
        default: nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .double(let value): value
        case .int(let value): Double(value)
        default: nil
        }
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    var arrayValue: [AssistantJSON]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var objectValue: [String: AssistantJSON]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    subscript(key: String) -> AssistantJSON? { objectValue?[key] }

    static func object(_ pairs: (String, AssistantJSON?)...) -> AssistantJSON {
        .object(Dictionary(uniqueKeysWithValues: pairs.compactMap { key, value in value.map { (key, $0) } }))
    }

    static func strings(_ values: [String]) -> AssistantJSON { .array(values.map { .string($0) }) }
    static func date(_ value: Date) -> AssistantJSON { .string(ISO8601DateFormatter().string(from: value)) }
    static func optionalString(_ value: String?) -> AssistantJSON? { value.map { .string($0) } }
    static func optionalDate(_ value: Date?) -> AssistantJSON? { value.map { .date($0) } }
    static func optionalInt(_ value: Int?) -> AssistantJSON? { value.map { .int($0) } }

    var compactDescription: String {
        switch self {
        case .null: "null"
        case .bool(let value): String(value)
        case .int(let value): String(value)
        case .double(let value): String(value)
        case .string(let value): value
        case .array(let values): "[" + values.map(\.compactDescription).joined(separator: ", ") + "]"
        case .object(let object):
            "{" + object.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value.compactDescription)" }.joined(separator: ", ") + "}"
        }
    }
}

enum AssistantValueKind: String, Codable, Equatable, Sendable {
    case string, integer, number, boolean, array, object
}

/// A provider-neutral, allowlisted argument contract. Runtime validation is deterministic
/// and happens before a model-selected tool can touch a native domain service.
struct AssistantArgumentSpec: Codable, Equatable, Sendable {
    var name: String
    var type: AssistantValueKind
    var required = false
    var description = ""
    var allowedValues: [String] = []
}

struct AssistantAgentToolDescriptor: Codable, Equatable, Identifiable, Sendable {
    var name: String
    var description: String
    var arguments: [AssistantArgumentSpec] = []
    /// True for a native domain action. The model never authorizes these; the app policy does.
    var requiresApproval = false
    /// True when the tool may create a reviewable proposal without itself executing it.
    var createsReview = false
    var id: String { name }
}

struct AssistantAgentToolCall: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var arguments: AssistantJSON
}

struct AssistantEvidenceSource: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var kind: String
    var title: String
    var at: Date?
}

struct AssistantAutomationRuleProposal: Codable, Equatable, Identifiable, Sendable {
    enum Trigger: String, Codable, CaseIterable, Sendable { case mentionOfCurrentUser }
    enum Scope: String, Codable, CaseIterable, Sendable { case allEligibleCurrentAndFutureMeetings }
    enum Action: String, Codable, CaseIterable, Sendable { case voiceReply }
    enum Execution: String, Codable, CaseIterable, Sendable { case askEachTime, unattendedWhenApproved }

    var id = UUID()
    var revision = 1
    var createdAt = Date()
    var trigger: Trigger
    var scope: Scope
    var action: Action
    /// The exact outward payload, never a paraphrase.
    var text: String
    var voiceID: String
    /// Per-meeting cooldown after one handled mention.
    var cooldownSeconds: TimeInterval
    var execution: Execution
}

struct AssistantAgentToolResult: Equatable, Sendable {
    var callID: String
    var toolName: String
    var json: AssistantJSON
    var summary: String
    var isError = false
    var evidence: [AssistantEvidenceSource] = []
    /// A reviewable internal proposal created by a tool. It is not enabled or executed here.
    var ruleProposal: AssistantAutomationRuleProposal? = nil

    static func error(_ call: AssistantAgentToolCall, _ message: String) -> AssistantAgentToolResult {
        .init(callID: call.id, toolName: call.name, json: .object(["error": .string(message)]), summary: message, isError: true)
    }
}

enum AssistantCanonicalActionKind: String, Codable, CaseIterable, Sendable {
    case setAttention, join, leave, mute, sendChat, say, react, readChat, remind, remember
}

/// The exact action payload shown to the user and sent to the native executor.
struct AssistantCanonicalAction: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var revision = 1
    var kind: AssistantCanonicalActionKind
    var meetingID: UUID?
    var momentID: UUID?
    var mode: AttentionMode?
    var scope: AssistantCommandScope = .untilLeave
    var text = ""
    var reaction: MeetingReaction?
    var minutes = 10
    var at: Date?
    /// Stable idempotency/hash data for the shared action framework.
    var payloadHash: String
}

struct AssistantAgentApproval: Equatable, Identifiable, Sendable {
    var id: UUID { action.id }
    var action: AssistantCanonicalAction
    var toolCallID: String
    var toolName: String
    var title: String
    var detail: String
    var expiresAt: Date
}

enum AssistantAgentModelStep: Equatable, Sendable {
    case toolCalls([AssistantAgentToolCall])
    case response(String, [AssistantEvidenceSource])
    case needsUserInput(String)
}

struct AssistantAgentModelRequest: Equatable, Sendable {
    var messages: [[String: String]]
    var tools: [AssistantAgentToolDescriptor]
    var context: [String: String]
}

protocol AssistantAgentModel: Sendable {
    func next(_ request: AssistantAgentModelRequest) async throws -> AssistantAgentModelStep
}

enum AssistantAgentError: LocalizedError, Equatable {
    case malformedToolCall(String), unknownTool(String), invalidArguments(String, String),
         missingArgument(String, String), unknownMeeting(String), unsupported, budgetExhausted,
         approvalExpired, staleApproval, duplicateAction, providerUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .malformedToolCall(let name): L("The model returned a malformed tool call for %@.", name)
        case .unknownTool(let name): L("The assistant does not have a tool named %@.", name)
        case .invalidArguments(let tool, let detail): L("The arguments for %@ are invalid: %@", tool, detail)
        case .missingArgument(let tool, let argument): L("%@ needs %@.", tool, argument)
        case .unknownMeeting(let id): L("Meeting %@ is not available now.", id)
        case .unsupported: L("The model provider cannot do that now.")
        case .budgetExhausted: L("The assistant ran out of time before it could finish. Nothing else was done.")
        case .approvalExpired: L("That approval expired. Nothing was sent.")
        case .staleApproval: L("The meeting or action changed. Review it again.")
        case .duplicateAction: L("That action was already handled.")
        case .providerUnavailable(let reason): L("The assistant is unavailable: %@", reason)
        }
    }
}

/// A validated native tool. `validate` canonicalizes a model argument; `execute` is called
/// only after runtime validation and, when required, native approval.
protocol AssistantAgentTool: Sendable {
    var descriptor: AssistantAgentToolDescriptor { get }
    func validate(_ arguments: AssistantJSON) throws -> AssistantJSON
    func execute(_ call: AssistantAgentToolCall, arguments: AssistantJSON) async throws -> AssistantAgentToolResult
}

final class AssistantAgentToolRegistry: @unchecked Sendable {
    private var tools: [String: any AssistantAgentTool] = [:]

    var descriptors: [AssistantAgentToolDescriptor] { tools.values.map(\.descriptor).sorted { $0.name < $1.name } }

    func register(_ tool: any AssistantAgentTool) { tools[tool.descriptor.name] = tool }
    func register(external tool: any AssistantAgentTool, trusted: Bool) {
        // External tools arrive with a namespaced name from the MCP adapter and remain
        // unable to widen native action scopes. Trust still controls exposure.
        guard trusted, !tool.descriptor.name.hasPrefix("rocknroll_") else { return }
        register(tool)
    }
    func tool(named name: String) -> (any AssistantAgentTool)? { tools[name] }

    func validate(_ call: AssistantAgentToolCall) throws -> AssistantAgentToolCall {
        guard let tool = tools[call.name] else { throw AssistantAgentError.unknownTool(call.name) }
        guard case .object(let object) = call.arguments else { throw AssistantAgentError.invalidArguments(call.name, "object expected") }
        for argument in tool.descriptor.arguments where argument.required && object[argument.name] == nil {
            throw AssistantAgentError.missingArgument(call.name, argument.name)
        }
        for (key, value) in object {
            guard let argument = tool.descriptor.arguments.first(where: { $0.name == key }) else {
                throw AssistantAgentError.invalidArguments(call.name, "unknown argument \(key)")
            }
            let valid: Bool
            switch argument.type {
            case .string: valid = value.stringValue != nil
            case .integer: valid = value.intValue != nil
            case .number: valid = value.doubleValue != nil
            case .boolean: valid = value.boolValue != nil
            case .array: valid = value.arrayValue != nil
            case .object: valid = value.objectValue != nil
            }
            guard valid else { throw AssistantAgentError.invalidArguments(call.name, "\(key) must be \(argument.type.rawValue)") }
            if !argument.allowedValues.isEmpty, let string = value.stringValue, !argument.allowedValues.contains(string) {
                throw AssistantAgentError.invalidArguments(call.name, "\(key) must be one of the listed values")
            }
        }
        var validated = call
        validated.arguments = try tool.validate(call.arguments)
        return validated
    }
}
