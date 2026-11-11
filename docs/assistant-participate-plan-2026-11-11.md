# Participate — implementation plan

11 November 2026 · Proposal, not implemented

Design and behavior contract: [assistant-participate-design-2026-11-11.md](assistant-participate-design-2026-11-11.md). Start on the native Mac app. Keep core policy/evidence types portable, but do not promise an iOS background executor until its lifecycle and ownership design is validated.

## Current source and the gaps

Inspection baseline: local `440a7e6` plus existing uncommitted work. No branch switch, production edit, installation or publication is part of this design task. Reconcile current notes/task work before implementation; do not overwrite it or treat a design-era snapshot as current code.

| Existing source | What can be reused | What must change or be verified |
| --- | --- | --- |
| `NativeMacGuest/Attention/AttentionModel.swift`, `AttentionModeViews.swift` | Off / Mentions / Watch, per-meeting selection, situation defaults | Participation is separately authorized; no automatic grant through an enum cycle or situation default. Preserve serialized `watch`. |
| `AttentionCoordinator.swift` | Meeting windows, attention evaluation, private moments, reply generation | Emit normalized observations into a dedicated participation coordinator. Avoid making this already large coordinator own another full state machine. |
| `AssistantAgent/AssistantAgentRuntime.swift` | Bounded model/tool loop, approval states, canonical actions | The inspected action ledger is in memory. Add durable, fail-closed delivery receipts for autonomous effects. Payload-only identity is insufficient for repeated legitimate events. |
| `AssistantAgent/AssistantAgentContracts.swift` | Typed tools, evidence handles, current send gate | Add explicit execution principal and a separate participation grant. Current evidence has title/time but lacks revision, span and disclosure policy. |
| `AssistantAgent/AssistantNativeTools.swift` | Native read tools and domain gateway | Build a restricted meeting/public registry; never inject its broad snapshot into an autonomous public run. |
| `AssistantAgent/AssistantAutomationRules.swift` | Revision-bound grants, event dedupe, audit pattern | Existing rules are fixed voice payloads on mention events. They are not a general conversational scheduler. Persistence errors must not be swallowed for autonomy authorization or dispatch. |
| `DesktopMeetingModel.swift` | Transcript/chat events, provider capability flags, microphone arbitration, native sends | Current actions use the user's connection. Add attribution capability checks and asynchronous observed delivery results. A successful enqueue is not confirmed remote delivery. |
| `MeetingLibrary/*`, `Attention/AssistantData.swift` | Outcomes, notes, tasks and memory | Add source provenance, audience/processor policy and generated-export dedupe. Existing private storage is not automatically public knowledge. |
| `Obsidian/ObsidianVaultAccess.swift`, `ObsidianSettingsView.swift` | Folder selection and bookmark patterns | Existing access is for one-way export. Add a separate read grant and a reader that validates every discovered file and transclusion. Do not blindly reuse write-path validation as a read sandbox. |
| `Tests/Parity/AssistantAgentTests.swift`, `AssistantNotesTests.swift`, `AssistantUIAcceptanceTests.swift` | Test seams and UI fixtures | Add policy, replay, recovery and provider-contract fixtures listed below. |

Provider behavior is a preflight experiment. Existing code exposes chat/reaction availability, not a verified separate assistant sender. Older README provider tables are not sufficient proof of current wire behavior. Test Guest/Rock, Telemost and TrueConf separately with two observer clients.

## Architecture and invariants

```text
Transcript / chat / roster / lifecycle events
                  |
          MeetingEventNormalizer
                  |
       ParticipationCoordinator (per session)
          |                       |
   MeetingContextReducer     Private insight lane
          |
   CandidatePlanner ---- public-scoped KnowledgeRetriever
          |
   EvidenceVerifier + native ParticipationPolicy
          |
   TurnScheduler ---- cancel/supersede/expire
          |
   Atomic preflight + durable action reservation
          |
   Domain delivery adapter -> observed receipt -> Activity UI
```

Use the current model gateway and native domain services. Do not introduce a second agent framework or route native calls through the app's own MCP server. The autonomous runtime has a restricted tool registry and an immutable meeting binding. External MCP principals cannot inherit participation grants.

Invariants:

1. A model proposes content and reasons; native code authorizes effects.
2. Public-generation context contains only room-authorized information. Private and public lanes cannot share conversation history or caches without policy partitioning.
3. Session ID, room identity, roster epoch, policy revision, source revisions and event watermark are explicit; UI selection is irrelevant to execution authority.
4. One action owner serializes dispatch per meeting. Private user commands take priority; user activity can cancel an outdated candidate.
5. No persistence success, no autonomous send. No dispatch while disconnected, revoked, expired or incompletely revalidated.
6. A receipt reflects observed provider state. “Accepted for send,” “confirmed,” “failed” and “unknown” are different.
7. Files, transcripts, chat and tool results are untrusted content. They cannot change grants, add tools or override these invariants.

### Proposed contracts

Names below are proposed types, not claims about existing definitions.

| Type | Required fields / purpose |
| --- | --- |
| `AssistantExecutionPrincipal` | `interactiveUser`, `meetingParticipant(grantID)`, `externalMCP`; native origin, never model supplied. |
| `ParticipationGrant` | Session/room IDs, roster epoch, revision, allowed channels and action categories, source-policy IDs, allowed processors, expiry, stop generation, attribution method and budgets. |
| `ParticipationTemplate` | Remembered preferences, independent of a live grant. Cannot authorize by itself. |
| `KnowledgeGrant` | Read scope, public audience scope, approved revisions, processor permissions, exclusions, retention and revocation epoch. |
| `KnowledgeDocument` / `KnowledgeChunk` | Stable source ID, content hash, section/span, title, timestamps, source kind, origin session, authoritative/derived status and permission references. |
| `MeetingContext` | Ordered event watermark, coverage gaps, topic, question/answer links, decisions versus proposals, unresolved constraints, roster and source provenance. |
| `ContributionCandidate` | Trigger event IDs, semantic intent, audience/channel, exact draft, claim-to-evidence links, unresolved-question ID, context/grant versions, expiry and abstention alternatives. |
| `ParticipationReceipt` | Candidate ID, dispatch ID, payload hash, grant/source/context versions, durable state, provider message/ack ID when present, times, cancellation or abstention reason. |

Policy storage may use SQLite alongside the existing local library or a dedicated versioned store. Keep content-bearing indexes separate from minimal action receipts so revocation can purge source material without destroying deduplication. Use app-container protection and existing local data conventions; do not log vault contents or whole prompts by default.

### State, races and recovery

Session states: `inactive -> preparing -> observing -> paused/reviewRequired -> observing -> ended`. Candidate states: `proposed -> grounded -> queued -> reserved -> dispatching -> confirmed/failed/unknown`, with `cancelled/superseded/expired` terminal before dispatch.

The final preflight and dispatch reservation are serialized against pause, revocation and meeting-end events. Revalidate the current source and permission revisions before reserving; cancel queued work when those revisions change. If Pause wins the barrier, no new dispatch starts. If dispatch wins, show the in-flight result honestly; stopping cannot recall already transmitted bytes.

Deduplication key: session + trigger event set + contribution kind + draft revision. Store the exact payload hash separately. Identical wording for two genuinely separate human events is not automatically a duplicate. Store reservation durably before sending. Use provider idempotency keys or message IDs when supported. If a crash occurs after dispatch but before acknowledgement and the provider cannot reconcile it, mark unknown and never automatically resend. Exactly-once delivery cannot be promised over an adapter without the necessary semantics.

On restart, live grants are inactive, old queued candidates expire, and unknown sends are reconciled only through read-only provider evidence. On transient reconnect, obtain fresh coverage/roster state and generate new candidates only from still-relevant events. If two clients can participate in the same session later, require a shared executor lease with fencing; v1 is Mac-only and explicitly single-owner, with no auto-resume on device handoff.

### Knowledge implementation

Introduce `KnowledgeSource` adapters for live meeting events, approved library records and selected Markdown files. Build a local permission-filtered lexical index first, then add local embeddings/reranking as benchmarked enhancements. Lexical retrieval matches data; semantic intent and intervention decisions remain structured model outputs, never language-specific hardcoded routing.

The reader enumerates only explicit roots/files under a separate read-only bookmark. Validate resolved file identity/containment at open time, with size limits and regular-file checks. Do not follow links, aliases or embeds outside the grant. Observe file changes, hash on read, and periodically reconcile missed filesystem events. New or changed public-source revisions require review in the first release. Revocation synchronously blocks retrieval and dispatch; asynchronous cleanup removes all derived content and invalidates public/private model sessions that contained it.

The public retrieval API returns only authorized titles, snippets and evidence IDs. Do not retrieve all private notes and filter after the model sees them. Partition caches by audience, source-policy epoch and processor. Chunk evidence must be resolvable at verification time. Test stale revisions, contradictory documents, large notes, Unicode filenames, moved files and malformed Markdown. No plugin execution or arbitrary MCP access in v1.

## Delivery sequence

Estimates are engineering effort ranges for one experienced engineer familiar with the app, excluding external provider access/admission delays. These are planning assumptions, not commitments.

| Phase | Work and reviewable deliverable | Exit condition | Effort |
| --- | --- | --- | --- |
| 0 — Provider and UX feasibility | Two-client capability matrix; actual chat attribution; reaction sender identity; delivery acknowledgement behavior; review interactive drafts with users | Know which services can truthfully support each channel; settle recommended layout and scope copy | 2–3 days |
| 1 — Permission and delivery foundation | Principals, templates/grants, durable receipts, cancellation barrier, kill switch, scoped tool registry, migrations | Deterministic lifecycle/revocation/recovery tests pass; interactive commands retain their existing behavior | 4–6 days |
| 2 — Useful private intelligence | Event normalization, question/decision state, candidate planner, evidence verification, timing simulation; shadow mode emits no public actions | Replay review demonstrates grounded value and useful abstention on held-out sessions | 5–7 days |
| 3 — Knowledge pilot | Current meeting + explicitly selected outcomes and Markdown files; independent read/share/processor grants; source inspector, revision review and revocation | No cross-scope content in public prompts; stale/revoked/injected content fixtures pass; retrieval benchmark is useful | 6–9 days |
| 4 — Autonomous chat pilot | Meeting setup, persistent Pause, public attribution, cancellable queue, actual receipts and private insight lane | Opted-in live pilot meets usefulness/noise goals and hard policy gates | 5–7 days |
| 5 — Release hardening | Narrow-window/accessibility/appearance QA; media/resource stress; multilingual evaluation; review and retention UI; rollout flag and rollback exercise | Sign-off against acceptance matrix and observed provider support | 4–6 days |

Total first-release estimate: **26–38 engineering days**, roughly **6–8 working weeks**, plus participant feedback and any provider-dependent delay. Phase 3 can be developed independently after Phase 1 contracts settle, but no parallel staffing is assumed.

Follow-on releases: scoped section grants and maintained-folder policies; automatic attributable reactions for supported providers; voice participation with turn-taking and audio interruption. Allow another 2–4 weeks of engineering for voice after feasibility, with real-meeting evaluation. A separate bot identity may be a larger provider integration, not a small UI task. iOS initially shows status and controls only after a secure ownership/control protocol exists; do not rely on background timers to run an unattended meeting agent.

### Suggested changes by location

- Add `NativeMacGuest/Attention/Participation/` for contracts, coordinator, event reducer, planner, scheduler, policy, delivery adapter and activity views.
- Add `NativeMacGuest/Knowledge/` for grants, source adapters, index, retriever, evidence resolution and scope views.
- Extend the existing mode popover and meeting toolbar; add a presentation-level Participate choice backed by its own grant. Keep the old attention enum readable and preserve existing defaults. Explicitly update exhaustive switches, command schemas, localization and accessibility identifiers if the enum is expanded later.
- Refactor native sends to expose an async result containing observed delivery semantics; keep ordinary chat UI behavior compatible. Never mark autonomous actions confirmed solely because `chat.send` accepted a draft.
- Extend the native tool registry with `searchApprovedKnowledge` and `readApprovedEvidence` bound to a host-created context. The model cannot supply or widen its audience principal.
- Add separate source/participation settings beside Obsidian export. Explain the two permissions; keep export jobs independent.
- Append Assistant activity to existing outcomes rather than making another competing meeting-history product.

## Acceptance matrix

| Area | Required scenarios and evidence |
| --- | --- |
| Permission isolation | Private-note canary never appears in public prompt, candidate, citation, receipt text or room message; no filename/count leaks; external MCP cannot inherit a grant; processor restriction enforced before embedding/generation. |
| Audience and session | New attendee, participant ID ambiguity, same room URL in a new occurrence, two simultaneous meetings, UI selection change and handoff cannot redirect authority or knowledge. |
| Revocation and interruption | Revoke during retrieval/generation/queue/dispatch; pause during every state; restart and reconnect. Verify barriers and accurate in-flight/unknown status. |
| Knowledge | Deleted/moved/changed notes, escaped symlinks, path prefix collisions, transclusions, malicious note instructions, private linked notes, duplicated exports, stale decision dates and contradictory sources. |
| Conversational usefulness | Human answers first; incomplete sentence; sarcasm; ambiguous address; overlapping speakers; false transcript; topic changes; owner is speaking; direct follow-up; another bot starts a loop; decision versus proposal. |
| Channels and delivery | Public attribution visible on observer clients; reaction attribution unavailable; unsupported chat; acknowledgement timeout; duplicate transport event; crash on both sides of durable reservation; no voice fallback. |
| Resource behavior | Transcription and call quality under indexing/generation load; bounded queues; old work dropped; wake/reconnect bursts; thermal pressure; cancelled network requests; provider latency and cost ceilings. |
| UX | Keyboard and VoiceOver activation/pause/source inspection; both appearances; large text and narrow window; no hover-only action; source status understandable; hidden meeting still has accessible global pause. |
| Compatibility | Existing Off/Mentions/Watch defaults, user-initiated send settings, legacy fixed-payload rules, notes/export and MCP remain independent; database migrations do not grant access. |

Replay corpus: begin with approximately 50 consented or synthetic sessions covering direct answers, unnecessary interventions, contradictory evidence, private knowledge, poor transcripts and multilingual discussion. Keep a held-out slice, include intentionally negative cases and have two reviewers label contested contributions. Synthetic replay does not establish live social usefulness or audio performance.

Track supported claims, participant-rated usefulness, avoidable interruptions, missed useful opportunities, duplicate contributions, time to a relevant answer, correction rate, provider latency, cost per meeting hour and audio/transcription regressions. Measure with the configured models and real target hardware. Use a staged feature flag: shadow -> private preview -> opt-in attributed chat -> wider beta. Any disclosure, cross-room action or cancellation-barrier failure disables unattended dispatch until understood.

## Decisions to settle during implementation

Recommended defaults are already specified; these are investigations, not reasons to postpone the design.

1. Which services support a separate assistant participant and reliable send receipts? Gate reactions and voice on the answer.
2. Which configured local/cloud models meet the structured-output, evidence and latency bar on the user's hardware? Benchmark; do not assume a provider name guarantees quality.
3. Does “Follow” replace the present English “Watch” label? Preserve the stored value either way.
4. Which trustworthy audience identifiers can each service expose? Where insufficient, use explicit current-roster grants and re-review changes.
5. Do pilot users prefer the quiet meeting rail or a chat-first layout? Use the same policy engine and validate both with real tasks.
