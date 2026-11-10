import ConferenceCore
import CryptoKit
import Foundation

enum AssistantConversationItemKind: String, Codable, Equatable, Sendable {
    case user, assistant, tool, clarification, approval, system
}

struct AssistantConversationItem: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var kind: AssistantConversationItemKind
    var text: String
    var toolName: String?
    var sources: [AssistantEvidenceSource] = []
    var isError = false
    var at = Date()
}

struct AssistantConversationStore: Codable, Equatable, Sendable {
    var items: [AssistantConversationItem] = []
    var limit = 80

    mutating func append(_ item: AssistantConversationItem) {
        items.append(item)
        if items.count > limit { items.removeFirst(items.count - limit) }
    }

    mutating func clear() { items.removeAll() }

    func transcript(limit: Int = 40) -> [[String: String]] {
        items.suffix(limit).map { item in
            var text = item.text
            if item.kind == .tool, let name = item.toolName { text = "[tool \(name)] " + text }
            return ["role": item.kind == .user ? "user" : "assistant", "content": String(text.prefix(3000))]
        }
    }
}

enum AssistantApprovalDecision: Equatable, Sendable {
    case allow, ask, deny(reason: String)
}

enum AssistantAgentRunState: String, Equatable, Sendable {
    case idle, preparingContext, waitingForModel, executingReadTools, waitingForApproval,
         executingApprovedAction, waitingForUserInput, completed, failed, cancelled
}

enum AssistantAgentRunOutcome: Equatable, Sendable {
    case completed(String, sources: [AssistantEvidenceSource], ruleProposal: AssistantAutomationRuleProposal?)
    case needsUserInput(String)
    case approvalRequired(AssistantAgentApproval)
}

/// Native side-effecting tools expose a canonical exact payload for policy and approval.
protocol AssistantAgentActionTool: AssistantAgentTool {
    func canonicalAction(for call: AssistantAgentToolCall, arguments: AssistantJSON) throws -> AssistantCanonicalAction
}

extension AssistantCanonicalAction {
    init(id: UUID? = nil, kind: AssistantCanonicalActionKind, meetingID: UUID? = nil, momentID: UUID? = nil,
         mode: AttentionMode? = nil, scope: AssistantCommandScope = .untilLeave, text: String = "",
         reaction: MeetingReaction? = nil, minutes: Int = 10, at: Date? = nil) {
        self.kind = kind; self.meetingID = meetingID; self.momentID = momentID
        self.mode = mode; self.scope = scope; self.text = text; self.reaction = reaction
        self.minutes = minutes; self.at = at
        var hasher = SHA256()
        hasher.update(data: Data(kind.rawValue.utf8))
        hasher.update(data: Data((meetingID?.uuidString ?? "").utf8))
        hasher.update(data: Data((momentID?.uuidString ?? "").utf8))
        hasher.update(data: Data((mode?.rawValue ?? "").utf8))
        hasher.update(data: Data(scope.rawValue.utf8))
        hasher.update(data: Data(text.utf8))
        hasher.update(data: Data((reaction?.rawValue ?? "").utf8))
        hasher.update(data: Data(String(minutes).utf8))
        hasher.update(data: Data((at.map(ISO8601DateFormatter().string(from:)) ?? "").utf8))
        let digest = hasher.finalize()
        payloadHash = digest.map { String(format: "%02x", $0) }.joined()
        // The id is deterministic per payload: an approval and its execution construct
        // the same action identity, and identical retries dedupe naturally.
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        self.id = id ?? UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                                     bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

/// A tiny action coordinator gives every outward action a stable identity and makes
/// retries observe the applied state instead of executing twice.
@MainActor final class AssistantActionCoordinator {
    enum State: String, Equatable, Sendable { case proposed, approved, applied, denied, failed }

    struct Record: Equatable, Sendable {
        var actionID: UUID
        var revision: Int
        var payloadHash: String
        var state: State
    }

    private(set) var records: [UUID: Record] = [:]

    func begin(_ action: AssistantCanonicalAction) throws {
        if let existing = records[action.id] {
            guard existing.revision == action.revision, existing.payloadHash == action.payloadHash else {
                throw AssistantAgentError.staleApproval
            }
            guard existing.state != .applied else { throw AssistantAgentError.duplicateAction }
            return
        }
        records[action.id] = .init(actionID: action.id, revision: action.revision,
                                   payloadHash: action.payloadHash, state: .proposed)
    }

    func approved(_ action: AssistantCanonicalAction) throws {
        try begin(action)
        records[action.id]?.state = .approved
    }

    func applied(_ action: AssistantCanonicalAction) {
        records[action.id] = .init(actionID: action.id, revision: action.revision,
                                   payloadHash: action.payloadHash, state: .applied)
    }

    func failed(_ action: AssistantCanonicalAction) {
        records[action.id] = .init(actionID: action.id, revision: action.revision,
                                   payloadHash: action.payloadHash, state: .failed)
    }

    func markDenied(_ action: AssistantCanonicalAction) {
        records[action.id]?.state = .denied
    }

    func state(of action: AssistantCanonicalAction) -> State? { records[action.id]?.state }
}

struct AssistantAgentEnvironment: Sendable {
    var registry: AssistantAgentToolRegistry
    var model: any AssistantAgentModel
    var context: [String: String]
    /// The app owns this policy. A model-generated annotation can never widen it.
    var approvalPolicy: @Sendable (AssistantAgentToolCall, AssistantCanonicalAction) -> AssistantApprovalDecision = { _, _ in .ask }
    var actionCoordinator: AssistantActionCoordinator?
    var approvalTitle: @Sendable (AssistantAgentToolCall, AssistantCanonicalAction) -> String = { call, _ in call.name }
    var approvalDetail: @Sendable (AssistantAgentToolCall, AssistantCanonicalAction) -> String = { _, action in action.text }
}

/// The bounded native runtime. One run owns one user turn; model steps, tool calls,
/// approvals, cancellation and recovery are explicit states rather than prompt branches.
@MainActor final class AssistantRuntime: ObservableObject {
    @Published private(set) var state: AssistantAgentRunState = .idle
    @Published private(set) var items: [AssistantConversationItem] = []
    @Published private(set) var pendingApproval: AssistantAgentApproval?

    private var store = AssistantConversationStore()
    private var runGeneration = UUID()
    /// Injectable clock; the coordinator owns the wall clock in production.
    var now: () -> Date = Date.init
    private var pendingCall: AssistantAgentToolCall?
    private var pendingEnvironment: AssistantAgentEnvironment?
    private var lastRuleProposal: AssistantAutomationRuleProposal?

    var conversation: [AssistantConversationItem] { items }
    var canResumeApproval: Bool { pendingApproval != nil }

    /// Surface an out-of-run error (for example an environment build failure) in the
    /// conversation without changing the run state machine.
    func appendSystemForUI(_ text: String) {
        appendSystem(text, isError: true)
    }

    func newConversation() {
        cancel()
        store.clear(); items = []; lastRuleProposal = nil
    }

    func cancel() {
        runGeneration = UUID(); pendingApproval = nil; pendingCall = nil; pendingEnvironment = nil
        if state != .idle { state = .cancelled }
    }

    func submit(_ text: String, environment: AssistantAgentEnvironment) async -> Result<AssistantAgentRunOutcome, Error> {
        let clean = String(text.trimmed.prefix(2000))
        guard !clean.isEmpty else { return .failure(AssistantAgentError.missingArgument("assistant", "text")) }
        guard state == .idle || state == .completed || state == .failed || state == .cancelled || state == .waitingForUserInput else {
            return .failure(AssistantAgentError.unsupported)
        }
        let generation = UUID(); runGeneration = generation
        store.append(.init(kind: .user, text: clean)); syncItems()
        state = .preparingContext
        do {
            let result = try await runLoop(generation: generation, environment: environment)
            return .success(result)
        } catch is CancellationError {
            state = .cancelled; return .failure(CancellationError())
        } catch {
            state = .failed
            appendSystem(error.localizedDescription, isError: true)
            return .failure(error)
        }
    }

    /// Continues a paused approval. Denial is a real observed result and has no side effect.
    func resumePendingApproval(approved: Bool) async -> Result<AssistantAgentRunOutcome, Error> {
        guard let approval = pendingApproval, let call = pendingCall, let environment = pendingEnvironment else {
            return .failure(AssistantAgentError.approvalExpired)
        }
        guard approval.expiresAt > now() else {
            clearPending(); appendSystem(AssistantAgentError.approvalExpired.localizedDescription ?? "", isError: true)
            state = .failed
            return .failure(AssistantAgentError.approvalExpired)
        }
        let generation = runGeneration
        clearPending()
        guard approved else {
            let result = AssistantAgentToolResult(callID: call.id, toolName: call.name,
                json: .object(["denied": .bool(true)]), summary: L("Denied. Nothing was sent."), isError: false)
            store.append(.init(kind: .approval, text: result.summary)); syncItems()
            return await continueAfterToolResult(result, generation: generation, environment: environment)
        }
        state = .executingApprovedAction
        do {
            guard let tool = environment.registry.tool(named: call.name) else { throw AssistantAgentError.unknownTool(call.name) }
            let validated = try environment.registry.validate(call)
            try environment.actionCoordinator?.approved(approval.action)
            let result = try await tool.execute(validated, arguments: validated.arguments)
            if result.isError { environment.actionCoordinator?.failed(approval.action) }
            else { environment.actionCoordinator?.applied(approval.action) }
            appendTool(result)
            return await continueAfterToolResult(result, generation: generation, environment: environment)
        } catch {
            environment.actionCoordinator?.failed(approval.action)
            state = .failed
            appendSystem(error.localizedDescription, isError: true)
            return .failure(error)
        }
    }

    private func runLoop(generation: UUID, environment: AssistantAgentEnvironment) async throws -> AssistantAgentRunOutcome {
        var modelSteps = 0, toolCalls = 0
        while modelSteps < 8, toolCalls < 16 {
            try Task.checkCancellation()
            guard generation == runGeneration else { throw CancellationError() }
            state = .waitingForModel
            let request = AssistantAgentModelRequest(messages: store.transcript(), tools: environment.registry.descriptors,
                                                     context: environment.context)
            let step = try await environment.model.next(request)
            guard generation == runGeneration else { throw CancellationError() }
            modelSteps += 1

            switch step {
            case .response(let text, let sources):
                let proposal = lastRuleProposal
                store.append(.init(kind: .assistant, text: text, sources: sources)); syncItems()
                state = .completed
                return .completed(text, sources: sources, ruleProposal: proposal)

            case .needsUserInput(let question):
                store.append(.init(kind: .clarification, text: question)); syncItems()
                state = .waitingForUserInput
                return .needsUserInput(question)

            case .toolCalls(let rawCalls):
                state = .executingReadTools
                var lastResult: AssistantAgentToolResult?
                for raw in rawCalls {
                    try Task.checkCancellation()
                    guard generation == runGeneration else { throw CancellationError() }
                    let call = try environment.registry.validate(raw)
                    toolCalls += 1
                    let tool = environment.registry.tool(named: call.name)
                    let requiresApproval = tool?.descriptor.requiresApproval == true
                    if requiresApproval, let actionTool = tool as? any AssistantAgentActionTool {
                        let action = try actionTool.canonicalAction(for: call, arguments: call.arguments)
                        switch environment.approvalPolicy(call, action) {
                        case .deny(let reason):
                            let result = AssistantAgentToolResult(callID: call.id, toolName: call.name,
                                json: .object(["denied": .bool(true)]), summary: reason, isError: true)
                            appendTool(result); lastResult = result; continue
                        case .ask:
                            try environment.actionCoordinator?.begin(action)
                            let approval = AssistantAgentApproval(action: action, toolCallID: call.id, toolName: call.name,
                                title: environment.approvalTitle(call, action), detail: environment.approvalDetail(call, action),
                                expiresAt: now().addingTimeInterval(120))
                            pendingApproval = approval; pendingCall = call; pendingEnvironment = environment
                            store.append(.init(kind: .approval, text: approval.title)); syncItems()
                            state = .waitingForApproval
                            return .approvalRequired(approval)
                        case .allow:
                            try environment.actionCoordinator?.begin(action)
                            try environment.actionCoordinator?.approved(action)
                            let result = try await actionTool.execute(call, arguments: call.arguments)
                            if result.isError { environment.actionCoordinator?.failed(action) }
                            else { environment.actionCoordinator?.applied(action) }
                            appendTool(result); lastResult = result
                        }
                    } else {
                        guard let tool else { throw AssistantAgentError.unknownTool(call.name) }
                        let result: AssistantAgentToolResult
                        do {
                            result = try await tool.execute(call, arguments: call.arguments)
                        } catch let error as AssistantAgentError {
                            // Domain failures are observable tool results, not turn aborts.
                            result = .error(call, error.localizedDescription ?? call.name)
                        }
                        appendTool(result); lastResult = result
                    }
                }
                if let result = lastResult, toolCalls >= 16, result.isError {
                    throw AssistantAgentError.budgetExhausted
                }
            }
        }
        throw AssistantAgentError.budgetExhausted
    }

    private func continueAfterToolResult(_ result: AssistantAgentToolResult, generation: UUID,
                                         environment: AssistantAgentEnvironment) async -> Result<AssistantAgentRunOutcome, Error> {
        if let proposal = result.ruleProposal { lastRuleProposal = proposal }
        do {
            return .success(try await runLoop(generation: generation, environment: environment))
        } catch {
            state = .failed
            appendSystem(error.localizedDescription, isError: true)
            return .failure(error)
        }
    }

    private func appendTool(_ result: AssistantAgentToolResult) {
        if let proposal = result.ruleProposal { lastRuleProposal = proposal }
        store.append(.init(kind: .tool, text: result.summary, toolName: result.toolName,
                           sources: result.evidence, isError: result.isError)); syncItems()
    }

    private func appendSystem(_ text: String, isError: Bool) {
        store.append(.init(kind: .system, text: text, isError: isError)); syncItems()
    }

    private func syncItems() { items = store.items }
    private func clearPending() { pendingApproval = nil; pendingCall = nil; pendingEnvironment = nil }
}
