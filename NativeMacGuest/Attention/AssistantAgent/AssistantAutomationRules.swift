import Foundation

/// A persisted automation rule. The model can only produce a proposal
/// (`AssistantAutomationRuleProposal`); every field here is set or changed by
/// native review, never by tool output. Material edits bump `revision` and
/// invalidate any unattended grant for the old revision.
struct AssistantAutomationRule: Codable, Equatable, Identifiable, Sendable {
    enum State: String, Codable, Sendable { case proposed, enabled, paused }

    var id: UUID
    var revision: Int
    var createdAt: Date
    var updatedAt: Date
    var state: State
    var trigger: AssistantAutomationRuleProposal.Trigger
    var scope: AssistantAutomationRuleProposal.Scope
    var action: AssistantAutomationRuleProposal.Action
    /// The exact outward payload, never a paraphrase.
    var text: String
    var voiceID: String
    var cooldownSeconds: TimeInterval
    var execution: AssistantAutomationRuleProposal.Execution
    /// A native grant to run unattended, bound to the exact revision and payload.
    var unattendedRevision: Int?

    init(proposal: AssistantAutomationRuleProposal) {
        id = proposal.id; revision = proposal.revision; createdAt = proposal.createdAt
        updatedAt = proposal.createdAt; state = .proposed
        trigger = proposal.trigger; scope = proposal.scope; action = proposal.action
        text = proposal.text; voiceID = proposal.voiceID; cooldownSeconds = proposal.cooldownSeconds
        execution = proposal.execution; unattendedRevision = nil
    }
}

struct AssistantRuleAuditEntry: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case proposed, enabled, paused, resumed, edited, grantUpdated, deleted, revokedGrant
        case mentionMatched, mentionSkipped, actionQueued, actionApproved, actionDenied, actionExecuted
        case actionFailed, actionExpired, capabilityUnsupported
    }
    var id = UUID()
    var at = Date()
    var kind: Kind
    var ruleID: UUID
    var revision: Int
    var meetingID: UUID?
    var detail: String
}

/// One mention event consumed by the deterministic evaluator. The coordinator
/// supplies these from the same native mention detection the judge uses; nothing
/// here is inferred by a model.
struct AssistantRuleMentionEvent: Equatable, Sendable {
    var id: String
    var meetingID: UUID
    var meetingTitle: String
    var at: Date
    var supportsVoiceReply: Bool
    var canSendChat: Bool
}

struct AssistantRuleEvaluation: Equatable, Sendable {
    enum Outcome: String, Sendable { case queuedAction, skipped }
    enum SkipReason: String, Sendable {
        case alreadyHandled, inCooldown, noMatchingEnabledRule, voiceUnsupported
    }
    var outcome: Outcome
    var reason: SkipReason?
    var pendingAction: AssistantRulePendingAction?
}

/// An outward action produced by a rule, awaiting the native approval path.
struct AssistantRulePendingAction: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var ruleID: UUID
    var ruleRevision: Int
    var ruleText: String
    var voiceID: String
    /// Deterministic dedupe key: rule + meeting + triggering event.
    var eventKey: String
    var meetingID: UUID
    var meetingTitle: String
    var action: AssistantCanonicalAction
    var createdAt = Date()
    var expiresAt: Date
}

/// The deterministic rule evaluator. Given rules, one mention event and persisted
/// dedupe/cooldown state, it decides at most one outcome. No model runs here.
enum AssistantRuleEvaluator {
    static func evaluate(rules: [AssistantAutomationRule], event: AssistantRuleMentionEvent,
                         handledEventKeys: Set<String>, lastHandledAt: [UUID: Date], now: Date) -> AssistantRuleEvaluation {
        let eventKey = event.id
        guard !handledEventKeys.contains(eventKey) else {
            return .init(outcome: .skipped, reason: .alreadyHandled, pendingAction: nil)
        }
        let matches = rules.filter { rule in
            rule.state == .enabled && rule.trigger == .mentionOfCurrentUser
            // Scope: all eligible current and future meetings; eligibility (voice-capable
            // or report-only) is checked per meeting at queue time, not by title matching.
        }
        guard let rule = matches.sorted(by: { $0.updatedAt < $1.updatedAt }).first else {
            return .init(outcome: .skipped, reason: .noMatchingEnabledRule, pendingAction: nil)
        }
        if let last = lastHandledAt[event.meetingID], now.timeIntervalSince(last) < rule.cooldownSeconds {
            return .init(outcome: .skipped, reason: .inCooldown, pendingAction: nil)
        }
        guard event.supportsVoiceReply else {
            return .init(outcome: .skipped, reason: .voiceUnsupported, pendingAction: nil)
        }
        let action = AssistantCanonicalAction(kind: .say, meetingID: event.meetingID, text: rule.text)
        let pending = AssistantRulePendingAction(ruleID: rule.id, ruleRevision: rule.revision,
                                                 ruleText: rule.text, voiceID: rule.voiceID,
                                                 eventKey: eventKey + "|" + rule.id.uuidString,
                                                 meetingID: event.meetingID, meetingTitle: event.meetingTitle,
                                                 action: action, expiresAt: now.addingTimeInterval(120))
        return .init(outcome: .queuedAction, reason: nil, pendingAction: pending)
    }
}

/// Persisted rules, dedupe/cooldown state, pending actions and the audit trail.
/// Pure state transitions; execution of queued actions stays in the coordinator.
@MainActor final class AssistantRuleStore: ObservableObject {
    @Published private(set) var rules: [AssistantAutomationRule] = []
    @Published private(set) var pendingActions: [AssistantRulePendingAction] = []
    @Published private(set) var audit: [AssistantRuleAuditEntry] = []

    private var handledEventKeys: Set<String> = []
    private var lastHandledAt: [UUID: Date] = [:]
    private let root: URL
    private var loading = false

    init(root: URL) {
        self.root = root
        load()
    }

    private var documentURL: URL { root.appendingPathComponent("automation-rules.json") }

    private struct Document: Codable {
        var rules: [AssistantAutomationRule] = []
        var pendingActions: [AssistantRulePendingAction] = []
        var audit: [AssistantRuleAuditEntry] = []
        var handledEventKeys: [String] = []
        var lastHandledAt: [UUID: Date] = [:]
    }

    private func load() {
        loading = true; defer { loading = false }
        guard let data = try? Data(contentsOf: documentURL) else { return }
        guard let document = try? JSONDecoder.attention.decode(Document.self, from: data) else { return }
        rules = document.rules; pendingActions = document.pendingActions; audit = document.audit
        handledEventKeys = Set(document.handledEventKeys); lastHandledAt = document.lastHandledAt
    }

    private func save() {
        guard !loading else { return }
        let document = Document(rules: rules, pendingActions: pendingActions, audit: Array(audit.suffix(500)),
                                handledEventKeys: Array(handledEventKeys.prefix(2000)), lastHandledAt: lastHandledAt)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try JSONEncoder.attention.encode(document).write(to: documentURL, options: .atomic)
        } catch { /* Keep in-memory state; the next save retries. */ }
    }

    // MARK: Rule lifecycle (native review only)

    /// Store a tool-created proposal for review. Proposing never executes anything.
    @discardableResult func propose(_ proposal: AssistantAutomationRuleProposal) -> AssistantAutomationRule {
        let rule = AssistantAutomationRule(proposal: proposal)
        rules.append(rule)
        appendAudit(.proposed, rule: rule, detail: proposal.text)
        save()
        return rule
    }

    func enable(id: UUID) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[index].state = .enabled
        rules[index].updatedAt = Date()
        appendAudit(.enabled, rule: rules[index], detail: rules[index].text)
        save()
    }

    func pause(id: UUID) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[index].state = .paused
        rules[index].updatedAt = Date()
        appendAudit(.paused, rule: rules[index], detail: "")
        save()
    }

    func resume(id: UUID) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[index].state = .enabled
        rules[index].updatedAt = Date()
        appendAudit(.resumed, rule: rules[index], detail: "")
        save()
    }

    /// A material edit creates a new revision and revokes any unattended grant.
    func edit(id: UUID, text: String, voiceID: String, cooldownSeconds: TimeInterval,
              execution: AssistantAutomationRuleProposal.Execution) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[index].revision += 1
        rules[index].updatedAt = Date()
        rules[index].text = text
        rules[index].voiceID = voiceID
        rules[index].cooldownSeconds = cooldownSeconds
        rules[index].execution = execution
        if rules[index].unattendedRevision != nil {
            rules[index].unattendedRevision = nil
            appendAudit(.revokedGrant, rule: rules[index], detail: "edit invalidated the grant")
        }
        appendAudit(.edited, rule: rules[index], detail: text)
        save()
    }

    /// Bind or revoke the unattended grant for the exact current revision.
    func setUnattendedGrant(id: UUID, granted: Bool) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[index].unattendedRevision = granted ? rules[index].revision : nil
        rules[index].updatedAt = Date()
        appendAudit(granted ? .grantUpdated : .revokedGrant, rule: rules[index],
                    detail: granted ? "unattended for revision \(rules[index].revision)" : "grant revoked")
        save()
    }

    func delete(id: UUID) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        let rule = rules[index]
        rules.remove(at: index)
        pendingActions.removeAll { $0.ruleID == id }
        appendAudit(.deleted, rule: rule, detail: rule.text)
        save()
    }

    // MARK: Evaluation and pending actions

    /// Consume one mention event. Returns the evaluation; a queued action waits
    /// for the native approval path and is never executed here.
    @discardableResult
    func handleMention(_ event: AssistantRuleMentionEvent, now: Date = Date()) -> AssistantRuleEvaluation {
        let evaluation = AssistantRuleEvaluator.evaluate(rules: rules, event: event,
                                                         handledEventKeys: handledEventKeys,
                                                         lastHandledAt: lastHandledAt, now: now)
        recordHandled(event, rule: evaluation.pendingAction?.ruleID, at: now)
        if let pending = evaluation.pendingAction {
            guard !pendingActions.contains(where: { $0.eventKey == pending.eventKey }) else {
                return .init(outcome: .skipped, reason: .alreadyHandled, pendingAction: nil)
            }
            pendingActions.append(pending)
            appendAudit(.mentionMatched, rule: rule(id: pending.ruleID), revision: pending.ruleRevision,
                        meetingID: event.meetingID, detail: event.meetingTitle)
            appendAudit(.actionQueued, rule: rule(id: pending.ruleID), revision: pending.ruleRevision,
                        meetingID: event.meetingID, detail: pending.ruleText)
        } else if let rule = rules.first(where: { $0.state == .enabled && $0.trigger == .mentionOfCurrentUser }) {
            let kind: AssistantRuleAuditEntry.Kind = evaluation.reason == .voiceUnsupported ? .capabilityUnsupported : .mentionSkipped
            appendAudit(kind, rule: rule, meetingID: event.meetingID,
                        detail: evaluation.reason?.rawValue ?? "")
        }
        save()
        return evaluation
    }

    private func recordHandled(_ event: AssistantRuleMentionEvent, rule: UUID?, at: Date) {
        handledEventKeys.insert(event.id)
        if rule != nil { lastHandledAt[event.meetingID] = at }
    }

    func pendingAction(id: UUID) -> AssistantRulePendingAction? { pendingActions.first { $0.id == id } }

    /// Called by the approval UI/executor with the observed result.
    func actionApproved(_ id: UUID) {
        guard let pending = pendingAction(id: id) else { return }
        appendAudit(.actionApproved, rule: rule(id: pending.ruleID), revision: pending.ruleRevision,
                    meetingID: pending.meetingID, detail: pending.ruleText)
        save()
    }

    func actionExecuted(_ id: UUID) {
        guard let index = pendingActions.firstIndex(where: { $0.id == id }) else { return }
        let pending = pendingActions[index]
        pendingActions.remove(at: index)
        appendAudit(.actionExecuted, rule: rule(id: pending.ruleID), revision: pending.ruleRevision,
                    meetingID: pending.meetingID, detail: pending.ruleText)
        save()
    }

    func actionDenied(_ id: UUID) {
        guard let index = pendingActions.firstIndex(where: { $0.id == id }) else { return }
        let pending = pendingActions[index]
        pendingActions.remove(at: index)
        appendAudit(.actionDenied, rule: rule(id: pending.ruleID), revision: pending.ruleRevision,
                    meetingID: pending.meetingID, detail: pending.ruleText)
        save()
    }

    /// Expiry is observed state: the action simply never runs.
    func expirePendingActions(now: Date = Date()) -> Int {
        let expired = pendingActions.filter { $0.expiresAt <= now }
        for pending in expired {
            appendAudit(.actionExpired, rule: rule(id: pending.ruleID), revision: pending.ruleRevision,
                        meetingID: pending.meetingID, detail: pending.ruleText)
        }
        if !expired.isEmpty {
            pendingActions.removeAll { $0.expiresAt <= now }
            save()
        }
        return expired.count
    }

    func rule(id: UUID) -> AssistantAutomationRule? { rules.first { $0.id == id } }

    private func appendAudit(_ kind: AssistantRuleAuditEntry.Kind, rule: AssistantAutomationRule?, revision: Int? = nil,
                             meetingID: UUID? = nil, detail: String) {
        guard let rule else { return }
        appendAudit(kind, ruleID: rule.id, revision: revision ?? rule.revision, meetingID: meetingID, detail: detail)
    }

    private func appendAudit(_ kind: AssistantRuleAuditEntry.Kind, ruleID: UUID, revision: Int,
                             meetingID: UUID? = nil, detail: String) {
        audit.append(.init(kind: kind, ruleID: ruleID, revision: revision, meetingID: meetingID, detail: detail))
        if audit.count > 500 { audit.removeFirst(audit.count - 500) }
    }
}
