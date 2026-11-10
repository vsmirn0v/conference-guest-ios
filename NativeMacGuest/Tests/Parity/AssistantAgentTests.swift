import ConferenceCore
import Foundation
import XCTest
@testable import RockNativeDesktop

/// Scripted model: deterministic steps, records every request it receives.
@MainActor final class ScriptedModel: AssistantAgentModel {
    var steps: [AssistantAgentModelStep]
    var requests: [AssistantAgentModelRequest] = []
    init(steps: [AssistantAgentModelStep]) { self.steps = steps }

    func next(_ request: AssistantAgentModelRequest) async throws -> AssistantAgentModelStep {
        requests.append(request)
        guard !steps.isEmpty else { throw AssistantAgentError.budgetExhausted }
        return steps.removeFirst()
    }
}

@MainActor
final class AssistantAgentTests: XCTestCase {
    // MARK: Fixture

    nonisolated(unsafe) private var actions: [AssistantCanonicalAction] = []
    nonisolated(unsafe) private var proposals: [AssistantAutomationRuleProposal] = []

    private func hooks() -> AssistantNativeToolProvider.Hooks {
        .init(
            executeAction: { [weak self] action in
                self?.actions.append(action)
                return "executed"
            },
            createRuleProposal: { [weak self] proposal in
                self?.proposals.append(proposal)
                return proposal
            })
    }

    private func registry(snapshot: AssistantNativeSnapshot) -> AssistantAgentToolRegistry {
        AssistantNativeToolProvider.registry(snapshot: snapshot, hooks: hooks())
    }

    private func call(_ name: String, _ arguments: AssistantJSON = .object([:]), id: String = "c1") -> AssistantAgentToolCall {
        .init(id: id, name: name, arguments: arguments)
    }

    private func fixture(now: Date = Date(timeIntervalSince1970: 1_760_000_000)) -> AssistantNativeSnapshot {
        let activeID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
        let transcript = [
            AssistantTextLine(id: "l1", speaker: "Anna", text: "Can we test the new build today?", at: now.addingTimeInterval(-300)),
            AssistantTextLine(id: "l2", speaker: "You", text: "Not yet", at: now.addingTimeInterval(-240)),
            AssistantTextLine(id: "l3", speaker: "Boris", text: "The share-layout fix is ready for review.", at: now.addingTimeInterval(-120)),
        ]
        let chat = [
            AssistantTextLine(id: "k1", speaker: "Anna", text: "Build link?", at: now.addingTimeInterval(-200)),
            AssistantTextLine(id: "k2", speaker: "You", text: "Sending in a minute", at: now.addingTimeInterval(-180)),
        ]
        let meeting = AssistantMeetingRecord(
            id: activeID, title: "Daily sync", active: true, roomIdentity: "meet.example · daily",
            invitationSummary: "meet.example · daily", seriesID: nil, displayName: "You",
            participants: ["You", "Anna", "Boris"], transcript: transcript, chat: chat,
            transcriptCoverage: "Partial", canSendChat: true, canReact: true,
            supportsVoiceReply: true, microphoneOn: false, soundOn: true, outcomeID: nil)
        let outcomes = (1...3).map { index in
            AssistantOutcomeRecord(
                id: UUID(uuidString: "00000000-0000-0000-0000-00000000000\(index)")!,
                meetingID: nil, title: "Planning \(index)", roomIdentity: "meet.example · planning",
                seriesID: "series-1",
                endedAt: now.addingTimeInterval(TimeInterval(-index * 86_400)),
                summary: "Planning \(index): discussed Q\(index) budget and owner \(index).",
                decisions: ["Decision \(index): ship it"],
                tasks: [.init(text: "Task \(index) follow up", owner: "You", dueAt: nil, done: false)],
                openQuestions: index == 1 ? ["Is the budget approved?"] : [])
        }
        let calendar = [
            AssistantCalendarOccurrence(id: "occ-1", seriesID: "daily-series", calendarID: "cal-1",
                                       calendarTitle: "Work", title: "Daily standup",
                                       start: now.addingTimeInterval(3600), end: now.addingTimeInterval(3900),
                                       allDay: false, roomIdentity: "meet.example · standup"),
            AssistantCalendarOccurrence(id: "occ-2", seriesID: "daily-series", calendarID: "cal-1",
                                       calendarTitle: "Work", title: "Daily standup",
                                       start: now.addingTimeInterval(86_400), end: now.addingTimeInterval(86_400 + 300),
                                       allDay: false, roomIdentity: "meet.example · standup"),
        ]
        return AssistantNativeSnapshot(
            now: now, timeZoneIdentifier: "UTC", language: "en", contextMeetingID: activeID,
            profileNames: ["You"], meetings: [meeting], outcomes: outcomes, notes: [],
            moments: [], memories: [], calendar: calendar,
            actionTargets: [.init(id: activeID, title: "Daily sync", invitation: nil, active: true, meetingID: activeID)],
            settings: ["voice_engine": "system", "talk_back": "off", "provider_host": "local",
                       "outcomes_enabled": "on", "push_to_talk": "on"])
    }

    // MARK: Validation

    func testRegistryRejectsUnknownToolAndBadArguments() async throws {
        let registry = registry(snapshot: fixture())
        XCTAssertThrowsError(try registry.validate(call("rocknroll_nope"))) {
            XCTAssertEqual($0 as? AssistantAgentError, .unknownTool("rocknroll_nope"))
        }
        XCTAssertThrowsError(try registry.validate(call("rocknroll_get_outcome"))) {
            XCTAssertEqual($0 as? AssistantAgentError, .missingArgument("rocknroll_get_outcome", "outcome_id"))
        }
        XCTAssertThrowsError(try registry.validate(call("rocknroll_get_meeting",
            .object(["meeting_id": .int(5), "extra": .string("x")])))) { error in
            guard case .invalidArguments(let tool, _) = error as? AssistantAgentError else {
                return XCTFail("expected invalidArguments, got \(error)")
            }
            XCTAssertEqual(tool, "rocknroll_get_meeting")
        }
        // Wrong type for an existing argument.
        XCTAssertThrowsError(try registry.validate(call("rocknroll_list_meetings",
            .object(["limit": .string("ten")]))))
        // Allowed-value violation.
        XCTAssertThrowsError(try registry.validate(call("rocknroll_list_meetings",
            .object(["kind": .string("bogus")]))))
        // Settings allowlist: keys outside the whitelist are rejected at execution.
        let settings = call("rocknroll_get_settings", .object(["keys": .array([.string("api_key")])]))
        let validatedSettings = try registry.validate(settings)
        let settingsResult = try await registry.tool(named: "rocknroll_get_settings")!
            .execute(validatedSettings, arguments: validatedSettings.arguments)
        XCTAssertTrue(settingsResult.isError, "Disallowed settings keys must fail closed")
    }

    // MARK: Read tools and provenance

    func testSearchReturnsProvenanceEvidence() async throws {
        let snapshot = fixture()
        let registry = registry(snapshot: snapshot)
        let validated = try registry.validate(call("rocknroll_search", .object(["query": .string("budget")]), id: "s1"))
        let result = try await registry.tool(named: "rocknroll_search")!.execute(validated, arguments: validated.arguments)
        XCTAssertFalse(result.isError)
        XCTAssertFalse(result.evidence.isEmpty, "Search must carry evidence provenance")
        let matches = result.json["matches"]?.arrayValue ?? []
        XCTAssertTrue(matches.contains { $0["kind"]?.stringValue == "outcome" })
    }

    func testCalendarOccurrencesAreOrderedAndBounded() async throws {
        let snapshot = fixture()
        let registry = registry(snapshot: snapshot)
        let after = ISO8601DateFormatter().string(from: snapshot.now)
        let validated = try registry.validate(call("rocknroll_list_calendar_occurrences",
            .object(["after": .string(after), "limit": .int(10)]), id: "cal1"))
        let result = try await registry.tool(named: "rocknroll_list_calendar_occurrences")!
            .execute(validated, arguments: validated.arguments)
        let occurrences = result.json["occurrences"]?.arrayValue ?? []
        XCTAssertEqual(occurrences.count, 2)
        XCTAssertEqual(occurrences[0]["occurrence_id"]?.stringValue, "occ-1")
        XCTAssertEqual(occurrences[0]["series_id"]?.stringValue, "daily-series")
    }

    func testListMeetingsDeduplicatesSeriesProjections() async throws {
        let registry = registry(snapshot: fixture())
        let validated = try registry.validate(call("rocknroll_list_meetings", .object(["kind": .string("all"), "limit": .int(20)])))
        let result = try await registry.tool(named: "rocknroll_list_meetings")!.execute(validated, arguments: validated.arguments)
        let meetings = result.json["meetings"]?.arrayValue ?? []
        XCTAssertEqual(meetings.count, 4, "3 distinct outcomes + 1 active meeting")
        XCTAssertTrue(meetings.contains { $0["active"]?.boolValue == true })
    }

    // MARK: Runtime budget and flow

    private func environment(snapshot: AssistantNativeSnapshot,
                             model: any AssistantAgentModel,
                             policy: (@Sendable (AssistantAgentToolCall, AssistantCanonicalAction) -> AssistantApprovalDecision)? = nil,
                             coordinator: AssistantActionCoordinator? = nil) -> AssistantAgentEnvironment {
        AssistantAgentEnvironment(
            registry: registry(snapshot: snapshot), model: model,
            context: AssistantNativeToolProvider.context(snapshot: snapshot),
            approvalPolicy: policy ?? { _, _ in .ask },
            actionCoordinator: coordinator ?? AssistantActionCoordinator())
    }

    func testBudgetExhaustsWithoutSideEffects() async throws {
        let snapshot = fixture()
        let call = self.call("rocknroll_status", id: "loop")
        let looping = ScriptedModel(steps: (0..<20).map { _ in .toolCalls([call]) })
        let runtime = AssistantRuntime()
        let result = await runtime.submit("loop", environment: environment(snapshot: snapshot, model: looping))
        guard case .failure(let error) = result, case .budgetExhausted = error as? AssistantAgentError else {
            return XCTFail("expected budgetExhausted, got \(result)")
        }
        XCTAssertEqual(looping.requests.count, 8, "Model steps are bounded at 8")
        XCTAssertTrue(actions.isEmpty)
    }

    func testSelectedMeetingIDIsResolvedForReadCalls() async throws {
        let snapshot = fixture()
        let model = ScriptedModel(steps: [
            .toolCalls([call("rocknroll_get_meeting", id: "missing-id")]),
            .toolCalls([call("rocknroll_get_meeting", .object(["meeting_id": .string("Daily sync")]), id: "title-id")]),
            .response("Done", []),
        ])
        let runtime = AssistantRuntime()
        let result = await runtime.submit("inspect this meeting",
                                          environment: environment(snapshot: snapshot, model: model))

        guard case .success(.completed) = result else { return XCTFail("got \(result)") }
        XCTAssertEqual(model.requests.count, 3)
        XCTAssertEqual(runtime.conversation.filter {
            $0.kind == .tool && $0.toolName == "rocknroll_get_meeting" && !$0.isError
        }.count, 2)
        XCTAssertFalse(runtime.conversation.contains { $0.isError })
    }

    func testInvalidReadCallIsReturnedForBoundedRecovery() async throws {
        let snapshot = fixture()
        let say = call("rocknroll_say", .object(["meeting_id": .string("Daily sync"),
                                                  "text": .string("Hello colleagues")]), id: "say-after-repair")
        let model = ScriptedModel(steps: [
            .toolCalls([call("rocknroll_get_meeting", .object(["meeting_id": .int(5)]), id: "wrong-type")]),
            .toolCalls([say]),
            .response("Said it", []),
        ])
        let runtime = AssistantRuntime()
        let result = await runtime.submit("say hello colleagues in the meeting",
                                          environment: environment(snapshot: snapshot, model: model))

        guard case .success(.approvalRequired(let approval)) = result else { return XCTFail("got \(result)") }
        XCTAssertEqual(approval.action.text, "Hello colleagues")
        XCTAssertEqual(model.requests.count, 2)
        XCTAssertTrue(model.requests[1].messages.contains {
            $0["content"]?.contains("meeting_id must be string") == true
        }, "The validation error must be visible to the next model step")
        XCTAssertEqual(runtime.conversation.filter(\.isError).count, 1)
        XCTAssertFalse(runtime.conversation.contains { $0.kind == .system && $0.isError })
        XCTAssertTrue(actions.isEmpty, "Recovery of a read call must not execute the later action")

        let finished = await runtime.resumePendingApproval(approved: true)
        guard case .success(.completed) = finished else { return XCTFail("got \(finished)") }
        XCTAssertEqual(actions.map(\.text), ["Hello colleagues"])
    }

    func testInvalidActionCallIsReturnedForCorrectionWithoutSideEffects() async throws {
        let snapshot = fixture()
        let missingText = call("rocknroll_say", .object(["meeting_id": .string("Daily sync")]), id: "missing-text")
        let corrected = call("rocknroll_say", .object(["text": .string("Hello colleagues")]), id: "corrected")
        let model = ScriptedModel(steps: [.toolCalls([missingText]), .toolCalls([corrected]), .response("Said it", [])])
        let runtime = AssistantRuntime()
        let result = await runtime.submit("say hello colleagues in the meeting",
                                          environment: environment(snapshot: snapshot, model: model))

        guard case .success(.approvalRequired(let approval)) = result else { return XCTFail("got \(result)") }
        XCTAssertEqual(approval.action.text, "Hello colleagues")
        XCTAssertEqual(approval.action.meetingID, snapshot.contextMeetingID)
        XCTAssertTrue(model.requests[1].messages.contains {
            $0["content"]?.contains("rocknroll_say needs text") == true
        })
        XCTAssertEqual(runtime.conversation.filter(\.isError).count, 1)
        XCTAssertFalse(runtime.conversation.contains { $0.kind == .system && $0.isError })
        XCTAssertTrue(actions.isEmpty)

        let finished = await runtime.resumePendingApproval(approved: true)
        guard case .success(.completed) = finished else { return XCTFail("got \(finished)") }
        XCTAssertEqual(actions.map(\.text), ["Hello colleagues"])
    }

    func testUnknownActionTargetIsNotReportedAsMissingText() throws {
        let registry = registry(snapshot: fixture())
        let unknown = call("rocknroll_say", .object([
            "meeting_id": .string(UUID().uuidString), "text": .string("Hello colleagues")]))
        let validated = try registry.validate(unknown)
        let tool = try XCTUnwrap(registry.tool(named: "rocknroll_say") as? any AssistantAgentActionTool)
        XCTAssertThrowsError(try tool.canonicalAction(for: validated, arguments: validated.arguments)) {
            guard case .unknownMeeting = $0 as? AssistantAgentError else {
                return XCTFail("expected unknownMeeting, got \($0)")
            }
        }
    }

    func testFailureErrorIsNotDuplicated() async throws {
        let model = ScriptedModel(steps: [])
        let runtime = AssistantRuntime()
        let result = await runtime.submit("fail", environment: environment(snapshot: fixture(), model: model))
        guard case .failure(let error) = result else { return XCTFail("got \(result)") }
        XCTAssertEqual(runtime.conversation.filter { $0.kind == .system && $0.isError }.count, 1)

        // AssistantTalkController observes the same Result failure after the runtime records it.
        runtime.appendSystemForUI(error.localizedDescription)
        XCTAssertEqual(runtime.conversation.filter { $0.kind == .system && $0.isError }.count, 1)
    }

    func testClarificationPausesWithoutToolCalls() async throws {
        let model = ScriptedModel(steps: [.needsUserInput("Which meeting do you mean?")])
        let runtime = AssistantRuntime()
        let result = await runtime.submit("summary please", environment: environment(snapshot: fixture(), model: model))
        guard case .success(.needsUserInput(let question)) = result else { return XCTFail("got \(result)") }
        XCTAssertEqual(question, "Which meeting do you mean?")
        XCTAssertTrue(actions.isEmpty)
    }

    func testApprovalAskAllowDenyExpiry() async throws {
        let snapshot = fixture()
        let meetingID = snapshot.meetings[0].id
        let say = call("rocknroll_say", .object(["meeting_id": .string(meetingID.uuidString),
                                                  "text": .string("On my way")]), id: "say1")

        // Deny: nothing executes, the tool result feeds the next model step.
        let denyModel = ScriptedModel(steps: [.toolCalls([say]), .response("Denied then answered", [])])
        let runtime = AssistantRuntime()
        let denied = await runtime.submit("say on my way", environment: environment(snapshot: snapshot, model: denyModel))
        guard case .success(.approvalRequired(let approval)) = denied else { return XCTFail("got \(denied)") }
        XCTAssertEqual(approval.action.text, "On my way")
        let afterDeny = await runtime.resumePendingApproval(approved: false)
        guard case .success(.completed(let text, _, _)) = afterDeny else { return XCTFail("got \(afterDeny)") }
        XCTAssertEqual(text, "Denied then answered")
        XCTAssertTrue(actions.isEmpty)

        // Allow: executes exactly once through the hook.
        let allowModel = ScriptedModel(steps: [.toolCalls([say]), .response("Said it", [])])
        let runtime2 = AssistantRuntime()
        let coordinator = AssistantActionCoordinator()
        _ = await runtime2.submit("say on my way",
                                  environment: environment(snapshot: snapshot, model: allowModel, coordinator: coordinator))
        let afterAllow = await runtime2.resumePendingApproval(approved: true)
        guard case .success(.completed) = afterAllow else { return XCTFail("got \(afterAllow)") }
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(coordinator.state(of: actions[0]), .applied)

        // Expiry: a stale approval fails closed.
        let expiredModel = ScriptedModel(steps: [.toolCalls([say])])
        let runtime3 = AssistantRuntime()
        _ = await runtime3.submit("say on my way", environment: environment(snapshot: snapshot, model: expiredModel))
        XCTAssertNotNil(runtime3.pendingApproval)
        runtime3.now = { Date().addingTimeInterval(500) }
        let expired = await runtime3.resumePendingApproval(approved: true)
        guard case .failure(let error) = expired, case .approvalExpired = error as? AssistantAgentError else {
            return XCTFail("expected approvalExpired, got \(expired)")
        }
        XCTAssertEqual(actions.count, 1, "Expired approval must not execute")
    }

    func testActionCoordinatorDeduplicatesAndDetectsStale() throws {
        let coordinator = AssistantActionCoordinator()
        var first = AssistantCanonicalAction(kind: .say, meetingID: UUID(), text: "hello")
        try coordinator.begin(first)
        try coordinator.approved(first)
        coordinator.applied(first)
        XCTAssertThrowsError(try coordinator.approved(first)) {
            XCTAssertEqual($0 as? AssistantAgentError, .duplicateAction)
        }
        var revised = AssistantCanonicalAction(id: first.id, kind: .say, meetingID: first.meetingID, text: "hello?")
        revised.revision = 2
        XCTAssertThrowsError(try coordinator.approved(revised)) {
            XCTAssertEqual($0 as? AssistantAgentError, .staleApproval)
        }
    }

    // MARK: Screenshot scenarios

    /// S1 + S5 shape: a read/synthesis turn never touches action tools or approvals.
    func testReadOnlyTurnsNeverProduceActionsOrApprovals() async throws {
        let snapshot = fixture()
        let meetingID = snapshot.meetings[0].id
        let outcomeIDs = snapshot.outcomes.map { $0.id.uuidString }
        let script: [AssistantAgentModelStep] = [
            .toolCalls([call("rocknroll_list_meetings", .object(["kind": .string("outcome"), "limit": .int(3)]), id: "m1")]),
            .toolCalls(outcomeIDs.map { call("rocknroll_get_outcome", .object(["outcome_id": .string($0)]), id: "o\($0)") }),
            .response("Three meetings: Planning 3, 2, 1 with dated summaries.", [.init(id: "e1", kind: "outcome", title: "Planning 3", at: nil)]),
        ]
        let model = ScriptedModel(steps: script)
        let runtime = AssistantRuntime()
        let coordinator = AssistantActionCoordinator()
        let result = await runtime.submit("latest three meetings summary please",
                                          environment: environment(snapshot: snapshot, model: model,
                                                                   coordinator: coordinator))
        guard case .success(.completed(let text, let sources, _)) = result else { return XCTFail("got \(result)") }
        XCTAssertTrue(text.contains("Planning"))
        XCTAssertFalse(sources.isEmpty)
        XCTAssertTrue(actions.isEmpty, "S1/S5: zero outward actions")
        XCTAssertNil(runtime.pendingApproval, "S1/S5: zero approval cards")
        XCTAssertEqual(model.requests.count, 3)
    }

    /// S5: interim summary uses transcript/chat tools only.
    func testInterimSummaryStaysReadOnly() async throws {
        let snapshot = fixture()
        let meetingID = snapshot.meetings[0].id
        let script: [AssistantAgentModelStep] = [
            .toolCalls([call("rocknroll_get_transcript", .object(["meeting_id": .string(meetingID.uuidString)]), id: "t1")]),
            .toolCalls([call("rocknroll_read_chat", .object(["meeting_id": .string(meetingID.uuidString)]), id: "c1")]),
            .response("Anna asked about testing the build; the rest was the share-layout fix.", []),
        ]
        let model = ScriptedModel(steps: script)
        let runtime = AssistantRuntime()
        let result = await runtime.submit("what did I miss?", environment: environment(snapshot: snapshot, model: model))
        guard case .success(.completed) = result else { return XCTFail("got \(result)") }
        XCTAssertTrue(actions.isEmpty)
        XCTAssertNil(runtime.pendingApproval)
    }

    /// S4: a standing instruction becomes a reviewable proposal only — no immediate action.
    func testRuleProposalFlowAndDeterministicMentionHandling() async throws {
        let snapshot = fixture()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("assistant-rule-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ruleStore = AssistantRuleStore(root: root)
        let now = snapshot.now

        // 1. Tool proposes; runtime surfaces the proposal; nothing executes.
        let propose = call("rocknroll_propose_automation_rule", .object([
            "trigger": .string("mentionOfCurrentUser"), "scope": .string("allEligibleCurrentAndFutureMeetings"),
            "action": .string("voiceReply"), "text": .string("Busy, back in a few minutes"),
            "voice_id": .string("my-voice"), "cooldown_seconds": .int(300)]), id: "r1")
        let model = ScriptedModel(steps: [.toolCalls([propose]), .response("Rule proposed for review.", [])])
        let runtime = AssistantRuntime()
        let result = await runtime.submit("when mentioned, reply with my voice",
            environment: environment(snapshot: snapshot, model: model))
        guard case .success(.completed(_, _, let proposal)) = result, let proposal else {
            return XCTFail("expected a rule proposal, got \(result)")
        }
        XCTAssertEqual(proposals.count, 1)
        XCTAssertTrue(actions.isEmpty, "Proposing must not execute a voice reply")

        // 2. Native review enables the rule; still no action.
        let rule = ruleStore.propose(proposal)
        ruleStore.enable(id: rule.id)
        XCTAssertTrue(actions.isEmpty)

        // 3. Mention queues a pending action exactly once; duplicates and cooldown skip.
        let meetingID = snapshot.meetings[0].id
        let event = AssistantRuleMentionEvent(id: "line-42", meetingID: meetingID, meetingTitle: "Daily sync",
                                            at: now, supportsVoiceReply: true, canSendChat: true)
        let first = ruleStore.handleMention(event, now: now)
        XCTAssertEqual(first.outcome, .queuedAction)
        XCTAssertEqual(ruleStore.pendingActions.count, 1)
        let duplicate = ruleStore.handleMention(event, now: now)
        XCTAssertEqual(duplicate.reason, .alreadyHandled)
        XCTAssertEqual(ruleStore.pendingActions.count, 1, "Duplicate events never replay a reply")
        let cooled = ruleStore.handleMention(.init(id: "line-43", meetingID: meetingID, meetingTitle: "Daily sync",
                                                     at: now.addingTimeInterval(30), supportsVoiceReply: true, canSendChat: true),
                                               now: now.addingTimeInterval(30))
        XCTAssertEqual(cooled.reason, .inCooldown)

        // 4. Capability mismatch: no silent chat fallback, audit records the skip.
        let noVoiceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("assistant-rule-novoice-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: noVoiceRoot) }
        let noVoiceStore = AssistantRuleStore(root: noVoiceRoot)
        let noVoice = AssistantRuleMentionEvent(id: "line-44", meetingID: meetingID, meetingTitle: "Daily sync",
                                                at: now.addingTimeInterval(400), supportsVoiceReply: false, canSendChat: true)
        // First store already consumed cooldown; a fresh root shows the unsupported path on enable.
        noVoiceStore.propose(proposal); noVoiceStore.enable(id: noVoiceStore.rules[0].id)
        let unsupported = noVoiceStore.handleMention(noVoice, now: now.addingTimeInterval(400))
        XCTAssertEqual(unsupported.reason, .voiceUnsupported)
        XCTAssertTrue(noVoiceStore.pendingActions.isEmpty)
        XCTAssertTrue(noVoiceStore.audit.contains { $0.kind == .capabilityUnsupported })

        // 5. Restart: handled event keys persist, so no replay after relaunch.
        let reloaded = AssistantRuleStore(root: root)
        let replay = reloaded.handleMention(event, now: now.addingTimeInterval(500))
        XCTAssertEqual(replay.reason, .alreadyHandled, "Restart must not replay a handled mention")
        XCTAssertEqual(reloaded.pendingActions.count, 1)

        // 6. Audit trail is complete.
        let kinds = Set(ruleStore.audit.map(\.kind))
        XCTAssertTrue(kinds.contains(.proposed) && kinds.contains(.enabled)
                      && kinds.contains(.mentionMatched) && kinds.contains(.actionQueued))
    }

    func testRuleLifecycleEditsRevokeGrants() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("assistant-rule-lifecycle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AssistantRuleStore(root: root)
        let proposal = AssistantAutomationRuleProposal(trigger: .mentionOfCurrentUser,
                                                       scope: .allEligibleCurrentAndFutureMeetings, action: .voiceReply,
                                                       text: "Busy", voiceID: "v", cooldownSeconds: 60, execution: .askEachTime)
        let rule = store.propose(proposal)
        store.enable(id: rule.id)
        store.setUnattendedGrant(id: rule.id, granted: true)
        XCTAssertEqual(store.rule(id: rule.id)?.unattendedRevision, 1)
        store.edit(id: rule.id, text: "Busy, back soon", voiceID: "v", cooldownSeconds: 90, execution: .askEachTime)
        XCTAssertEqual(store.rule(id: rule.id)?.revision, 2)
        XCTAssertNil(store.rule(id: rule.id)?.unattendedRevision, "Editing revokes the old unattended grant")
        XCTAssertTrue(store.audit.contains { $0.kind == .revokedGrant })
        store.pause(id: rule.id)
        XCTAssertEqual(store.rule(id: rule.id)?.state, .paused)
        store.delete(id: rule.id)
        XCTAssertTrue(store.rules.isEmpty)
        XCTAssertTrue(store.audit.contains { $0.kind == .deleted })
    }

    func testPendingActionExpiryIsObserved() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("assistant-rule-expiry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AssistantRuleStore(root: root)
        let proposal = AssistantAutomationRuleProposal(trigger: .mentionOfCurrentUser,
                                                       scope: .allEligibleCurrentAndFutureMeetings, action: .voiceReply,
                                                       text: "Busy", voiceID: "v", cooldownSeconds: 60, execution: .askEachTime)
        let rule = store.propose(proposal)
        store.enable(id: rule.id)
        let event = AssistantRuleMentionEvent(id: "e1", meetingID: UUID(), meetingTitle: "M", at: Date(),
                                              supportsVoiceReply: true, canSendChat: true)
        _ = store.handleMention(event)
        XCTAssertEqual(store.pendingActions.count, 1)
        let expired = store.expirePendingActions(now: Date().addingTimeInterval(200))
        XCTAssertEqual(expired, 1)
        XCTAssertTrue(store.pendingActions.isEmpty)
        XCTAssertTrue(store.audit.contains { $0.kind == .actionExpired })
    }

    /// External tools never widen native scopes: namespacing and trust gates.
    func testExternalToolPolicyGates() async {
        struct Provider: AssistantExternalToolProviding {
            var exposed: [AssistantAgentToolDescriptor]
            func tools() async throws -> [AssistantAgentToolDescriptor] { exposed }
            func call(_ name: String, arguments: AssistantJSON) async throws -> AssistantJSON { .object(["ok": .bool(true)]) }
        }
        let readOnly = AssistantAgentToolDescriptor(name: "notes__search", description: "Search notes")
        let nativeName = AssistantAgentToolDescriptor(name: "rocknroll_status", description: "spoofed native")
        let approvalTool = AssistantAgentToolDescriptor(name: "notes__send", description: "Send",
                                                        requiresApproval: true)
        let trust = AssistantExternalToolTrust(disabled: false, enabledServers: ["notes"], readOnlyServers: ["notes"])
        let exposed = await AssistantExternalToolPolicy.exposedTools(Provider(exposed: [readOnly, nativeName, approvalTool]),
                                                                     serverID: "notes", trust: trust)
        XCTAssertEqual(exposed.map { $0.descriptor.name }, ["notes__search"])
        // Disabled trust exposes nothing.
        let none = await AssistantExternalToolPolicy.exposedTools(Provider(exposed: [readOnly]),
                                                                  serverID: "notes", trust: .init(disabled: true))
        XCTAssertTrue(none.isEmpty)
    }

    // MARK: MCP loopback

    @MainActor private final class StubMCPBackend: MCPBackend {
        var lastClient: MCPClientIdentity?
        func status() async throws -> MCPJSON { ["backend": "stub"] }
        func listMeetings(_: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON {
            lastClient = client; return ["items": []]
        }
        func getMeeting(_: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON { [:] }
        func getTranscript(_: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON { [:] }
        func getOutcome(_: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON { [:] }
        func getNotes(_: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON { [:] }
        func listTasks(_: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON { [:] }
        func search(_: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON {
            lastClient = client; return ["items": [["title": "Kickoff"]]]
        }
        func getSettings(_: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON { [:] }
        func controlMeeting(_: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON { [:] }
        func setFavorite(_: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON { [:] }
        func updateTask(_: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON { [:] }
        func updateSettings(_: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON { [:] }
        func runAssistant(_: MCPJSON, client: MCPClientIdentity) async throws -> MCPJSON { [:] }
    }

    /// Read-only tools only, `run_assistant` excluded, all namespaced `mcp__*`.
    func testMCPLoopbackExposesOnlyReadOnlyTools() async throws {
        let provider = await AssistantMCPLoopbackProvider(backend: StubMCPBackend())
        let descriptors = try await provider.tools()
        let readOnlyNames = Set(nativeMCPToolDefinitions().filter(\.readOnly).map(\.name))
            .subtracting(["rocknroll_run_assistant"])
        XCTAssertEqual(Set(descriptors.map { String($0.name.dropFirst("mcp__".count)) }), readOnlyNames)
        XCTAssertFalse(descriptors.contains { $0.name.contains("run_assistant") })
        XCTAssertTrue(descriptors.allSatisfy { $0.name.hasPrefix("mcp__") && !$0.requiresApproval && $0.allowsArbitraryArguments })
        // Full policy round-trip: loopback passes its own server id and trust gates.
        let exposed = await AssistantExternalToolPolicy.exposedTools(
            provider, serverID: assistantMCPLoopbackServerID,
            trust: .init(disabled: false, enabledServers: [assistantMCPLoopbackServerID],
                         readOnlyServers: [assistantMCPLoopbackServerID]))
        XCTAssertEqual(exposed.count, descriptors.count)
        let disabled = await AssistantExternalToolPolicy.exposedTools(
            provider, serverID: assistantMCPLoopbackServerID, trust: .init(disabled: true))
        XCTAssertTrue(disabled.isEmpty)
    }

    /// Dispatch reaches the backend with the internal identity and converts values both ways.
    func testMCPLoopbackDispatchUsesInternalIdentity() async throws {
        let backend = StubMCPBackend()
        let provider = await AssistantMCPLoopbackProvider(backend: backend)
        let result = try await provider.call("mcp__rocknroll_search", arguments: .object(["query": .string("kickoff")]))
        guard case .object(let object) = result else { return XCTFail("expected object") }
        guard case .array(let items)? = object["items"] else { return XCTFail("expected items") }
        guard case .object(let first)? = items.first, case .string(let title)? = first["title"] else {
            return XCTFail("expected first item title")
        }
        XCTAssertEqual(title, "Kickoff")
        let client = await backend.lastClient
        XCTAssertEqual(client?.label, "Rock'N'Roll Assistant")
        XCTAssertEqual(client?.tokenHash, mcpSHA256("rocknroll-internal-assistant"))
        // The recursion guard and write tools are not callable even by name.
        await XCTAssertThrowsErrorAsync({ try await provider.call("mcp__rocknroll_run_assistant", arguments: .object([:])) })
        await XCTAssertThrowsErrorAsync({ try await provider.call("mcp__rocknroll_update_settings", arguments: .object([:])) })
        await XCTAssertThrowsErrorAsync({ try await provider.call("rocknroll_status", arguments: .object([:])) })
    }

    private func XCTAssertThrowsErrorAsync(_ expression: () async throws -> AssistantJSON,
                                           _ message: String = "",
                                           file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await expression(); XCTFail("Expected error. \(message)", file: file, line: line) }
        catch {}
    }
}
