import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

public struct TaskContextEnrichmentResult: Sendable {
    public var enrichedSnapshots: [SyncedTaskSnapshot]
    public var followUpsByExtractedID: [UUID: TaskTranscriptFollowUp]
    public var standaloneFollowUps: [TaskTranscriptFollowUp]

    public init(
        enrichedSnapshots: [SyncedTaskSnapshot],
        followUpsByExtractedID: [UUID: TaskTranscriptFollowUp] = [:],
        standaloneFollowUps: [TaskTranscriptFollowUp] = []
    ) {
        self.enrichedSnapshots = enrichedSnapshots
        self.followUpsByExtractedID = followUpsByExtractedID
        self.standaloneFollowUps = standaloneFollowUps
    }
}

public enum TaskContextLLMService {
    /// Enriches newly extracted tasks and matches meeting updates against prior open tasks.
    /// Completely non-fatal: falls back to deterministic context enrichment whenever offline or unconfigured.
    public static func enrichAndMatch(
        sessionID: UUID,
        meetingTitle: String,
        endedAt: Date,
        events: [SyncedTranscriptEvent],
        notes: String,
        decisions: [String],
        extractedTasks: [SyncedTaskSnapshot],
        existingOpenTasks: [TaskReconciliationCandidateInput],
        configuration: PortableOutcomeConfiguration,
        keychain: WorkspaceAPIKeychain = .init(),
        session: URLSession = .shared
    ) async -> TaskContextEnrichmentResult {
        let deterministicSnapshots = extractedTasks.map {
            CrossMeetingTaskReconciler.enrichExtractedTaskContext(
                snapshot: $0,
                meetingTitle: meetingTitle,
                endedAt: endedAt,
                sessionID: sessionID,
                events: events,
                decisions: decisions
            )
        }
        let deterministicFollowUps = CrossMeetingTaskReconciler.analyzeTranscriptUpdates(
            meetingTitle: meetingTitle,
            endedAt: endedAt,
            events: events,
            notes: notes,
            decisions: decisions,
            existingTasks: existingOpenTasks
        )

        guard !extractedTasks.isEmpty || !existingOpenTasks.isEmpty else {
            return TaskContextEnrichmentResult(
                enrichedSnapshots: deterministicSnapshots,
                standaloneFollowUps: deterministicFollowUps
            )
        }

        let promptPayload = buildMessages(
            meetingTitle: meetingTitle,
            endedAt: endedAt,
            events: events,
            notes: notes,
            decisions: decisions,
            extractedTasks: deterministicSnapshots,
            existingOpenTasks: existingOpenTasks
        )
        guard let promptPayload else {
            return TaskContextEnrichmentResult(
                enrichedSnapshots: deterministicSnapshots,
                standaloneFollowUps: deterministicFollowUps
            )
        }

        do {
            let rawJSON: String
            switch configuration.providerKind {
            case .preferMac, .appleOnDevice:
                #if canImport(FoundationModels)
                if #available(iOS 26.0, macOS 26.0, *),
                   SystemLanguageModel.default.availability == .available {
                    let lm = LanguageModelSession(instructions: promptPayload.system)
                    let resp = try await lm.respond(to: promptPayload.user)
                    rawJSON = resp.content
                } else {
                    return TaskContextEnrichmentResult(
                        enrichedSnapshots: deterministicSnapshots,
                        standaloneFollowUps: deterministicFollowUps
                    )
                }
                #else
                return TaskContextEnrichmentResult(
                    enrichedSnapshots: deterministicSnapshots,
                    standaloneFollowUps: deterministicFollowUps
                )
                #endif

            case .openAI, .openRouter, .custom:
                guard let endpoint = configuration.endpoint else {
                    return TaskContextEnrichmentResult(
                        enrichedSnapshots: deterministicSnapshots,
                        standaloneFollowUps: deterministicFollowUps
                    )
                }
                let model = configuration.resolvedModel
                let key = keychain.read(kind: configuration.providerKind)
                guard !model.isEmpty, !(configuration.providerKind.needsKey && (key?.isEmpty != false)) else {
                    return TaskContextEnrichmentResult(
                        enrichedSnapshots: deterministicSnapshots,
                        standaloneFollowUps: deterministicFollowUps
                    )
                }
                let body = PortableOutcomeService.requestBody(
                    messages: [
                        ["role": "system", "content": promptPayload.system],
                        ["role": "user", "content": promptPayload.user]
                    ],
                    model: model,
                    provider: configuration.providerKind,
                    tokenLimit: 1800,
                    temperature: 0
                )
                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"
                request.timeoutInterval = 35
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                if let key, !key.isEmpty {
                    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                }
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                let (data, response) = try await MeetingAITransfer.send(request, using: session)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = root["choices"] as? [[String: Any]],
                      let message = choices.first?["message"] as? [String: Any],
                      let content = message["content"] as? String else {
                    return TaskContextEnrichmentResult(
                        enrichedSnapshots: deterministicSnapshots,
                        standaloneFollowUps: deterministicFollowUps
                    )
                }
                rawJSON = content
            }

            if let parsed = parseLLMResult(
                rawJSON,
                extractedSnapshots: deterministicSnapshots,
                existingTasks: existingOpenTasks,
                meetingTitle: meetingTitle,
                sessionID: sessionID,
                endedAt: endedAt,
                deterministicFollowUps: deterministicFollowUps
            ) {
                return parsed
            }
        } catch {
            // Non-fatal fallback to deterministic analysis.
        }

        return TaskContextEnrichmentResult(
            enrichedSnapshots: deterministicSnapshots,
            standaloneFollowUps: deterministicFollowUps
        )
    }

    private static func buildMessages(
        meetingTitle: String,
        endedAt: Date,
        events: [SyncedTranscriptEvent],
        notes: String,
        decisions: [String],
        extractedTasks: [SyncedTaskSnapshot],
        existingOpenTasks: [TaskReconciliationCandidateInput]
    ) -> (system: String, user: String)? {
        let lines = events
            .filter { ($0.kind == "transcript" || $0.kind == "chat") && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .suffix(220)
            .map { event -> String in
                let speaker = event.speaker?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return (speaker.isEmpty ? "" : "\(speaker): ") + event.text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        guard !lines.isEmpty || !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        var budget = 18_000
        var transcriptSlice: [String] = []
        for line in lines.reversed() {
            if budget - line.count < 0 { break }
            transcriptSlice.append(line)
            budget -= line.count
        }
        transcriptSlice.reverse()

        let existingJSON = existingOpenTasks.prefix(35).map { task -> String in
            let keys = task.extended.externalBindings.compactMap(\.externalKey).joined(separator: ",")
            return "{\"id\":\"\(task.id.uuidString)\",\"jira_key\":\"\(keys)\",\"owner\":\"\(escapeJSON(task.owner))\",\"status\":\"\(task.extended.workflowStatus.rawValue)\",\"text\":\"\(escapeJSON(task.text))\"}"
        }.joined(separator: ",")

        let extractedJSON = extractedTasks.prefix(25).map { task -> String in
            "{\"id\":\"\(task.id.uuidString)\",\"owner\":\"\(escapeJSON(task.owner))\",\"text\":\"\(escapeJSON(task.text))\"}"
        }.joined(separator: ",")

        let system = """
        Analyze this meeting to enrich tasks with extended context and match tasks across meetings.
        Use only explicit facts from the transcript, chat, decisions, and notes.
        Allowed statuses: "todo", "in_progress", "blocked", "in_review", "done", "cancelled".
        Allowed priorities: "low", "medium", "high", "critical", or "".
        Return ONE JSON object and nothing else:
        {
          "enriched_new": [{"extracted_id": string, "context_notes": string, "status": string, "priority": string}],
          "existing_updates": [{"existing_id": string, "extracted_id": string, "new_status": string, "context_addition": string, "evidence_quote": string}]
        }
        Only include entries in "existing_updates" when the meeting clearly refers to the same deliverable/task from existing_tasks. If extracted_id matches an existing task, include its UUID in "extracted_id"; if discovered directly in conversation without a new extracted row, leave "extracted_id" empty "".
        """

        let clock = ISO8601DateFormatter()
        let user = """
        Meeting: \(meetingTitle)
        Ended: \(clock.string(from: endedAt))
        Decisions: \(decisions.joined(separator: " | "))
        Notes: \(String(notes.prefix(3_000)))
        existing_tasks: [\(existingJSON)]
        new_tasks: [\(extractedJSON)]

        Transcript:
        \(transcriptSlice.joined(separator: "\n"))
        """
        return (system, user)
    }

    private static func parseLLMResult(
        _ rawText: String,
        extractedSnapshots: [SyncedTaskSnapshot],
        existingTasks: [TaskReconciliationCandidateInput],
        meetingTitle: String,
        sessionID: UUID,
        endedAt: Date,
        deterministicFollowUps: [TaskTranscriptFollowUp]
    ) -> TaskContextEnrichmentResult? {
        struct EnrichedRow: Decodable {
            var extracted_id: String?
            var context_notes: String?
            var status: String?
            var priority: String?
        }
        struct ExistingUpdateRow: Decodable {
            var existing_id: String?
            var extracted_id: String?
            var new_status: String?
            var context_addition: String?
            var evidence_quote: String?
        }
        struct ResponsePayload: Decodable {
            var enriched_new: [EnrichedRow]?
            var existing_updates: [ExistingUpdateRow]?
        }
        let clean = extractJSONObject(rawText)
        guard let data = clean.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ResponsePayload.self, from: data) else {
            return nil
        }

        let existingIDs = Set(existingTasks.map(\.id))
        var snapshots = extractedSnapshots
        for row in decoded.enriched_new ?? [] {
            guard let idStr = row.extracted_id, let eid = UUID(uuidString: idStr),
                  let idx = snapshots.firstIndex(where: { $0.id == eid }) else { continue }
            if let notes = row.context_notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
                snapshots[idx].extended.appendContextNote(notes)
            }
            if let statusRaw = row.status, let status = TaskWorkflowStatus(rawValue: statusRaw) {
                snapshots[idx].extended.workflowStatus = status
                if status.isTerminalDone {
                    snapshots[idx].done = true
                    snapshots[idx].completedAt = endedAt
                }
            }
            if let prioRaw = row.priority, let prio = TaskPriorityLevel(rawValue: prioRaw) {
                snapshots[idx].extended.priority = prio
            }
            snapshots[idx].extended.contextHistory = [
                TaskMeetingContextEntry(
                    sessionID: sessionID,
                    meetingTitle: meetingTitle,
                    observedAt: endedAt,
                    previousStatus: nil,
                    updatedStatus: snapshots[idx].extended.workflowStatus,
                    note: snapshots[idx].extended.contextNotes.isEmpty
                        ? L("Created from meeting outcome")
                        : String(snapshots[idx].extended.contextNotes.prefix(320)),
                    source: .meetingExtraction
                )
            ]
        }

        var followUpsByExtracted: [UUID: TaskTranscriptFollowUp] = [:]
        var standaloneByExisting: [UUID: TaskTranscriptFollowUp] = Dictionary(
            deterministicFollowUps.map { ($0.existingTaskID, $0) },
            uniquingKeysWith: { a, _ in a }
        )

        for row in decoded.existing_updates ?? [] {
            guard let existingStr = row.existing_id,
                  let existingID = UUID(uuidString: existingStr),
                  existingIDs.contains(existingID) else { continue }
            let parsedStatus = row.new_status.flatMap(TaskWorkflowStatus.init(rawValue:))
            let addition = (row.context_addition ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let quote = row.evidence_quote?.trimmingCharacters(in: .whitespacesAndNewlines)
            let followUp = TaskTranscriptFollowUp(
                existingTaskID: existingID,
                newStatus: parsedStatus,
                contextAddition: addition,
                evidenceQuote: quote?.isEmpty == false ? quote : nil,
                dueDay: nil,
                dueAt: nil
            )
            if let extractedStr = row.extracted_id,
               let extractedID = UUID(uuidString: extractedStr),
               snapshots.contains(where: { $0.id == extractedID }) {
                followUpsByExtracted[extractedID] = followUp
            } else if parsedStatus != nil || !addition.isEmpty {
                standaloneByExisting[existingID] = followUp
            }
        }

        return TaskContextEnrichmentResult(
            enrichedSnapshots: snapshots,
            followUpsByExtractedID: followUpsByExtracted,
            standaloneFollowUps: Array(standaloneByExisting.values)
        )
    }

    private static func escapeJSON(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    private static func extractJSONObject(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            if let newline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: newline)...])
            }
            if let close = text.range(of: "```", options: .backwards) {
                text = String(text[..<close.lowerBound])
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !text.hasPrefix("{"), let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") {
            text = String(text[start...end])
        }
        return text
    }
}
