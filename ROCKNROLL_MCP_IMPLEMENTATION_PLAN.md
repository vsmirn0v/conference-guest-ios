# Rock’N’Roll MCP — Implementation Plan and Backlog

**Status:** Proposed implementation backlog  
**Date:** 9 November 2026  
**Normative product reference:** `ROCKNROLL_MCP_SPEC_REVISED.md`  
**Scope:** Phases 0–4, from discovery through the native in-app assistant

This plan converts the revised specification into implementation-ready work items. Each task can become one issue. Large tasks may be split after discovery, but their acceptance conditions and security gates must remain intact.

## 1. Execution Rules

### 1.1 Relative task sizes

- **S:** isolated change with focused tests.
- **M:** multiple components or substantial test coverage.
- **L:** cross-cutting architecture, native integration, or security-sensitive behavior.

Sizes indicate complexity, not a calendar commitment.

### 1.2 Global definition of done

A task is complete only when:

- its implementation and automated tests are merged;
- its output JSON conforms to the shared schemas where applicable;
- errors are structured and do not expose secrets or meeting content;
- relevant unit, integration, and negative-path tests pass;
- documentation and supported-capability matrices are updated;
- no unresolved requirement is hidden behind a fabricated empty result;
- real user meeting content is not added to fixtures, tests, logs, or examples.

### 1.3 Cross-phase invariants

- Offline remains read-only in every release.
- The native domain layer is the only meeting-control authority.
- No UI automation is used as a substitute for domain commands.
- IDs remain typed and namespaced; titles are never identity.
- Partial coverage and unavailable capabilities are always explicit.
- Raw invitations, provider secrets, launch tickets, arbitrary preferences, and Keychain values never enter responses.
- Sensitive actions require payload-bound native approval and revision revalidation.
- MCP callers never inherit an assistant “send without asking” bypass.
- Synthetic stores or test copies are used for mutation testing.

### 1.4 Recommended work streams

After Phase 0, these tracks can proceed in parallel where dependencies permit:

1. Offline file adapter and read tools.
2. Packaging, diagnostics, and client configuration.
3. Native transport, pairing, and app lifecycle.
4. Native read projectors and domain integration.

Phase 3 mutation infrastructure starts only after the native read model and revisions are reliable. Phase 4 starts only after the native assistant contract and the Phase 3 approval framework are available.

---

## 2. Phase 0 — Discovery and Shared Foundations

**Objective:** eliminate guessed semantics and establish contracts, threat boundaries, protocol feasibility, and test data.

### MCP-0.1 — Verify persisted source schemas and semantics

- **Size / depends on:** M / none.
- **Work:** Inspect representative synthetic or consented samples of `Attention/assistant.json`, `MeetingReminders/state.json`, and `Attention/decisions/YYYY-MM-DD.jsonl`. Record field optionality, actual date meaning, ID stability, source modifications, schema versions, and observed limitations. Verify that journal windows are fragments rather than complete transcripts.
- **Output:** The persistence section of `discovery.md`, plus a source-support matrix.
- **Done when:** Every field used by Phase 1 has documented provenance and semantics; unknown fields are explicitly excluded rather than guessed.

### MCP-0.2 — Map native domain authorities and command behavior

- **Size / depends on:** L / none.
- **Work:** Map `NativeDesktopWorkspace`, `NativeDesktopMeetingModel`, calendar/reminder stores, favorites/recents and room-history storage, attention/outcome models, settings ownership, Keychain boundaries, and the in-app assistant. Distinguish configured, inherited, effective, and persisted state. Inventory native meeting controls and existing approval behavior.
- **Output:** Native source-of-truth map, supported-control inventory, assistant integration notes, and unresolved-behavior list.
- **Done when:** Each full-product capability has an identified native authority or is marked unsupported; no direct persistence write is proposed.

### MCP-0.3 — Define shared versioned contracts and identity rules

- **Size / depends on:** L / MCP-0.1, MCP-0.2.
- **Work:** Specify normalized DTOs, opaque typed IDs, related-entity links, `coverage`, `sources`, `observed_at`, revisions, capabilities, error envelopes, filter semantics, cursor rules, and safe metadata. Define `meeting_id`, `outcome_id`, `task_id`, and other accepted entity types for every tool.
- **Output:** Versioned schemas, JSON examples, compatibility policy, and identity/relationship decision table.
- **Done when:** Fixtures can be validated mechanically; same-title, recurring-room, multi-outcome, and ambiguous-link cases have explicit expected representations.

### MCP-0.4 — Select the MCP SDK and prove client interoperability

- **Size / depends on:** M / none.
- **Work:** Select maintained SDKs and pinned dependencies without prescribing an unnecessary application-stack migration. Implement a disposable stdio spike with initialization, version negotiation, tool discovery, one typed tool call, structured failure, and clean shutdown. Validate a minimal native HTTP transport spike separately if needed.
- **Output:** SDK decision record, protocol spike, supported client/version matrix, and reproducible launch commands.
- **Done when:** The installed target Codex version discovers and calls the spike successfully; stdout remains protocol-only and logs go to stderr.

### MCP-0.5 — Establish the security and privacy threat model

- **Size / depends on:** L / MCP-0.2; MCP-0.1 for offline paths.
- **Work:** Document trust boundaries for meeting text, agent prompts, MCP clients, loopback transport, native pairing, file paths, approvals, assistant actions, and logs. Define scope names, sensitive-action classifications, credential handling, redaction, retention, audit, and denial behavior.
- **Output:** Security decision record and abuse-case matrix covering traversal, symlink escape, stolen client credentials, confused deputy, replay, approval tampering, stale revisions, prompt injection, and outward contributions.
- **Done when:** Every mutating capability has an authorization rule, and every data source has an explicit expose/redact/exclude classification.

### MCP-0.6 — Build the synthetic fixture corpus

- **Size / depends on:** M / MCP-0.1, MCP-0.3.
- **Work:** Create versioned fixtures for empty sources, optional fields, same-title meetings, recurring rooms, multiple active sessions, multiple outcomes per room, overlapping journal windows, duplicate utterance IDs, incomplete/malformed JSONL, unknown schemas, ambiguous relationships, secrets/invitations, and Unicode/date boundaries. Add native fake-store counterparts.
- **Output:** Synthetic file repository, native fixture models, expected normalized outputs, and fixture-generation instructions.
- **Done when:** Fixtures contain no real user data and exercise every identity, redaction, and coverage rule needed by Phases 1–4.

### MCP-0.7 — Build shared contract and transport test harnesses

- **Size / depends on:** M / MCP-0.3, MCP-0.4, MCP-0.6.
- **Work:** Implement schema validation, golden DTO tests, RFC 3339 and `[from, to)` cases, deterministic-order checks, cursor filter binding, provenance/coverage assertions, safe error serialization, and an MCP client harness usable against both backends.
- **Output:** Reusable contract-test package and CI invocation.
- **Done when:** The same contract suite can run against a fake backend and the protocol spike, and deliberately invalid DTOs fail CI.

### MCP-0.8 — Establish repository layout, CI, and release provenance

- **Size / depends on:** M / MCP-0.4; shared-contract location informed by MCP-0.3.
- **Work:** Create logical modules for shared contracts, offline adapter, native adapter, bridge, fixtures, and tests. Add formatting, static checks, unit tests, dependency locking, reproducible build metadata, and a verification-report template. Keep native app and standalone adapter build responsibilities clear.
- **Output:** Buildable skeleton and CI pipeline with documented commands.
- **Done when:** A clean checkout builds and tests without interactive shell setup, private paths, or user meeting data.

### Phase 0 release gate

- `discovery.md` covers both persistence and native authorities.
- Shared schemas and identity rules are executable and versioned.
- Security decisions cover all planned write and assistant capabilities.
- Codex interoperability is demonstrated.
- Synthetic fixtures and shared tests run in CI.
- No remaining implementation decision depends on guessed field semantics.

---

## 3. Phase 1 — Offline Read-Only MVP

**Objective:** ship `rocknroll-local` with seven safe read tools and Codex installation, without changing application data.

### MCP-1.1 — Implement the standalone server and CLI skeleton

- **Size / depends on:** M / MCP-0.4, MCP-0.8.
- **Work:** Implement `rocknroll-local`, stdio lifecycle, protocol-only stdout, redacted stderr logging, graceful shutdown, startup configuration, explicit data-root override, and bounded request handling. Add the `doctor` subcommand entry point.
- **Output:** Runnable server with a health/configuration unit-test surface.
- **Done when:** Codex starts and stops the process reliably; invalid configuration fails safely; no HTTP service or provider key is required.

### MCP-1.2 — Implement secure source discovery and path enforcement

- **Size / depends on:** M / MCP-0.1, MCP-0.5, MCP-1.1.
- **Work:** Resolve the per-user application-support root, allow explicit test/alternative roots, canonicalize allowed files, reject traversal and symlink escapes, and distinguish absent roots, absent sources, denied access, and unsupported layouts. Never search unrelated containers or Keychain.
- **Output:** Read-only source locator with structured diagnostics.
- **Done when:** Path and symlink attacks are rejected, errors identify the precise safe path/action, and no arbitrary path parameter reaches file reads.

### MCP-1.3 — Implement snapshot-aware JSON source reads

- **Size / depends on:** M / MCP-1.2, MCP-0.6.
- **Work:** Add read-only file opening, source identity/modification metadata, schema detection, bounded retries for changing JSON, consistent snapshot handles, and behavior for replacement/truncation. Do not create locks or caches in the app container.
- **Output:** JSON adapter used by outcomes and calendar-cache projections.
- **Done when:** Concurrent-write fixtures either yield one valid snapshot or a structured retryable failure; source bytes remain unchanged.

### MCP-1.4 — Implement robust JSONL journal reads

- **Size / depends on:** M / MCP-1.3.
- **Work:** Read completed lines only, defer incomplete tails, surface malformed completed lines as warnings, handle rotation/replacement/truncation, and preserve filename/line provenance. Bound memory and input size.
- **Output:** Streaming or bounded journal iterator with snapshot metadata.
- **Done when:** All JSONL fixture cases behave predictably, no partial tail is parsed, and a damaged record cannot be mistaken for an empty meeting history.

### MCP-1.5 — Project outcomes, summaries, decisions, and tasks

- **Size / depends on:** M / MCP-0.3, MCP-1.3.
- **Work:** Normalize verified outcome/task fields, preserve original text, generate typed outcome/task IDs, retain safe provenance, exclude `invitation`, and represent multiple outcomes for one room without collapsing them. Implement missing-field behavior.
- **Output:** Outcome and task projection services with golden tests.
- **Done when:** Stored text is returned without rewriting, all output is secret-free, and ambiguous parent links produce warnings or separate records as specified.

### MCP-1.6 — Project cached calendar occurrences

- **Size / depends on:** M / MCP-0.3, MCP-1.3.
- **Work:** Normalize supported `occurrences`, validate schema `2` or explicitly supported versions, preserve start/end and tentative/eligible metadata where verified, generate occurrence IDs, and exclude invitations/references classified as sensitive. Label data as calendar cache, not attendance.
- **Output:** Calendar-cache projection service.
- **Done when:** Filtering and output match fixtures, and responses never claim the user attended or that the cache is the full calendar.

### MCP-1.7 — Extract and deduplicate transcript fragments

- **Size / depends on:** L / MCP-1.4, MCP-1.5 where outcome linking is reused.
- **Work:** Extract verified `window.lines`, preserve speaker/time/source, deduplicate only by proven utterance identity, retain repeated phrases from distinct speakers/times, expose fragment relationships, and mark journal-derived output `coverage: "partial"`.
- **Output:** Transcript-fragment projection with ambiguous-meeting handling.
- **Done when:** Overlap fixtures produce no proven duplicates, uncertain records are not assigned to meetings, and omitted content is never reconstructed.

### MCP-1.8 — Assemble meeting cards and typed relationships

- **Size / depends on:** L / MCP-1.5, MCP-1.6, MCP-1.7.
- **Work:** Build canonical meeting-like records for `calendar`, `outcome`, and `transcript_fragment`; attach only verified typed links; expose available related data and warnings; prevent title-based merging and automatic recurring-session consolidation.
- **Output:** Offline meeting repository used by query and detail tools.
- **Done when:** Complex identity fixtures match the MCP-0.3 decision table, and `get_meeting` never returns a synthetic composite presented as authoritative fact.

### MCP-1.9 — Implement filtering, search, ordering, and snapshots

- **Size / depends on:** L / MCP-0.7, MCP-1.8.
- **Work:** Implement `[from, to)` filters by entity-specific dates, query/title search, outcome/task/transcript search, owner/done filters, stable ordering, limit 20/max 100, opaque cursors, approximately 64 KiB transcript bounds, consistent snapshots, and `CURSOR_EXPIRED`.
- **Output:** Query service shared by list and search endpoints.
- **Done when:** Pagination has no snapshot-internal gaps/duplicates, altered filters invalidate cursors, and absent task dates are not invented.

### MCP-1.10 — Expose the seven Phase 1 MCP tools

- **Size / depends on:** L / MCP-1.9.
- **Work:** Implement `rocknroll_status`, `rocknroll_list_meetings`, `rocknroll_get_meeting`, `rocknroll_get_transcript`, `rocknroll_get_outcome(outcome_id)`, `rocknroll_list_tasks`, and `rocknroll_search`. Add schemas, read-only annotations, response envelopes, typed validation, and safe error mapping.
- **Output:** Complete offline MCP tool surface.
- **Done when:** The shared contract suite passes, outcome lookup cannot be confused with room lookup, and unsupported native-only categories return explicit capability errors.

### MCP-1.11 — Complete status, error taxonomy, and `doctor`

- **Size / depends on:** M / MCP-1.2, MCP-1.10.
- **Work:** Report backend, source availability, schema versions, category coverage, and limitations. Implement all Phase 1 error codes and content-free `doctor` checks for app version when detectable, root access, source presence/readability, schemas, and category availability.
- **Output:** User-actionable diagnostics without meeting content.
- **Done when:** Missing, denied, busy, corrupt, unsupported, ambiguous, unavailable, and expired-cursor states are distinguishable; access failures do not automatically recommend Full Disk Access.

### MCP-1.12 — Package installation, upgrades, and Codex configuration

- **Size / depends on:** M / MCP-1.10, MCP-1.11.
- **Work:** Produce a reproducible executable or launcher with absolute-path configuration, pinned dependencies, install/upgrade/uninstall instructions, and a targeted `config.toml` update that preserves unrelated settings. Document limitations and local-model data-flow implications.
- **Output:** Release bundle, README, example configuration, and verification report template.
- **Done when:** Clean install/upgrade/uninstall tests pass, existing Codex settings survive, startup needs no current-directory or interactive-shell assumptions, and the real installed command is documented.

### MCP-1.13 — Run offline end-to-end acceptance and release review

- **Size / depends on:** M / MCP-1.12 and all earlier Phase 1 tasks.
- **Work:** Exercise Codex prompts for today’s meetings, outcomes, incomplete tasks, and transcript search. Verify partial coverage, recurring/same-title separation, pagination, source errors, source immutability, invitation/secret redaction, `doctor`, and configuration preservation.
- **Output:** Phase 1 acceptance report and actual supported-capability matrix.
- **Done when:** Every specification §16.1 criterion has recorded evidence, known limitations are documented, and no complete-transcript claim is made without an authoritative source.

### Phase 1 release gate

Ship only when MCP-1.13 passes. The offline release remains read-only even if later native phases are not yet scheduled.

---

## 4. Phase 2 — Native Authoritative Reads

**Objective:** expose authoritative live and native library data through an authenticated in-app adapter and stdio bridge.

### MCP-2.1 — Embed the native adapter and define its lifecycle

- **Size / depends on:** L / MCP-0.2, MCP-0.3, MCP-0.8; shared read behavior from MCP-1.10.
- **Work:** Add an explicitly enabled native integration lifecycle to the Mac app, including startup/shutdown, app-state handling, adapter versioning, dependency isolation, and domain-service access. Avoid reading native state through offline file projections.
- **Output:** Native adapter host with fake domain-service tests.
- **Done when:** Enabling/disabling is deterministic, app shutdown invalidates requests cleanly, and native responses identify `backend: native` or its schema equivalent.

### MCP-2.2 — Implement client pairing, identity, credentials, and scopes

- **Size / depends on:** L / MCP-0.5, MCP-2.1.
- **Work:** Add user-initiated client pairing, distinct client identities, least-privilege read scopes, revocation, protected credential storage, safe rotation, and redacted diagnostics. Do not put credentials in arguments or logs.
- **Output:** Native pairing UI/domain flow and authenticated client registry.
- **Done when:** Unknown, revoked, wrongly scoped, and malformed credentials are denied; users can inspect/revoke clients; secrets are absent from logs and responses.

### MCP-2.3 — Implement authenticated loopback Streamable HTTP

- **Size / depends on:** L / MCP-2.1, MCP-2.2.
- **Work:** Bind to `127.0.0.1`, select an available port, provide explicit endpoint discovery, enforce loopback/origin/authentication checks, negotiate MCP versions, bound request sizes/timeouts, and stop cleanly with the app/adapter.
- **Output:** Native MCP endpoint using shared schemas and errors.
- **Done when:** LAN/non-loopback and unauthorized requests fail, port collisions recover predictably, and no native request silently falls back to offline files.

### MCP-2.4 — Implement and package `rocknroll-native`

- **Size / depends on:** M / MCP-2.3; packaging patterns from MCP-1.12.
- **Work:** Build the stdio-to-loopback bridge, endpoint/credential discovery, app-unavailable errors, reconnect/shutdown behavior, protocol-only stdout, safe stderr, and Codex configuration. Keep native and offline profile names distinct.
- **Output:** Installable bridge with client setup/revocation documentation.
- **Done when:** Codex discovers native tools through the bridge, app-not-running is explicit, and credentials/content never appear in process arguments or technical logs.

### MCP-2.5 — Project all active meetings and effective media state

- **Size / depends on:** L / MCP-0.2, MCP-2.3.
- **Work:** Project every active session from native workspace/meeting models, including typed session/room/occurrence links, joined/connection state, effective microphone/camera state, safe live metadata, native revisions, and per-session supported controls.
- **Output:** Authoritative active-meeting repository and `kind: "active"` support.
- **Done when:** Multiple simultaneous meetings remain independently addressable, values agree with the native UI/domain models, and a stopped session disappears or transitions according to documented native semantics.

### MCP-2.6 — Project favorites, recents, and complete native calendar data

- **Size / depends on:** L / MCP-2.3.
- **Work:** Integrate native favorite/room-history and calendar/reminder authorities, expose `favorite` and `recent` kinds, return complete supported calendar metadata, resolve typed relationships only when verified, and redact raw invitations/references.
- **Output:** Native meeting-library repository.
- **Done when:** Native UI/store parity tests pass, cached reminders are not substituted for the complete native model, and secrets remain excluded even when stored beside room metadata.

### MCP-2.7 — Connect native outcomes, tasks, and transcript authorities

- **Size / depends on:** M / MCP-2.3, MCP-2.5, MCP-2.6.
- **Work:** Reuse shared DTOs while sourcing outcomes/tasks/transcripts from authoritative native models where available. Preserve multiple outcomes, source provenance, transcript coverage, and typed session/occurrence links; retain partial coverage where completeness is still unproven.
- **Output:** Native implementations of meeting, outcome, task, transcript, and search reads.
- **Done when:** Shared contract fixtures pass against native fakes, and native responses do not inherit offline assumptions about files or coverage.

### MCP-2.8 — Expose allowlisted redacted settings

- **Size / depends on:** L / MCP-0.2, MCP-0.5, MCP-2.3.
- **Work:** Implement `rocknroll_get_settings` for explicitly supported sections, distinguish defaults/overrides/effective values where possible, expose revisions, support meeting-specific resolution when requested, and reject unknown/arbitrary keys. Exclude Keychain values, provider credentials, model instructions, and raw preferences.
- **Output:** Versioned settings read service and redaction tests.
- **Done when:** Settings match native resolution, revisions change with effective updates, unknown keys fail closed, and secret-bearing fields never appear in output or diagnostics.

### MCP-2.9 — Expose configured and effective mention/follow state

- **Size / depends on:** L / MCP-0.2, MCP-2.3, MCP-2.5.
- **Work:** Project native attention enums without inventing an MCP policy language. Return configured layers, effective state, inheritance sources, and revision for global/room/occurrence/session scopes supported by the app.
- **Output:** Attention projection included in applicable meeting cards and settings responses.
- **Done when:** Layer-precedence fixtures match the native resolver, and unavailable runtime inputs yield explicit partial/unknown coverage rather than a guessed policy.

### MCP-2.10 — Unify native tools, capability reporting, and pagination

- **Size / depends on:** L / MCP-2.5, MCP-2.6, MCP-2.7, MCP-2.8, MCP-2.9.
- **Work:** Route shared tools to native repositories, add native kinds, implement native snapshot/revision cursor behavior, expose app/adapter state and per-meeting capabilities in `rocknroll_status`, and retain common provenance/error conventions.
- **Output:** Complete native read-only tool surface.
- **Done when:** Offline and native responses are distinguishable, native cursors are stable or expire explicitly, and clients cannot infer unavailable features from static tool lists.

### MCP-2.11 — Validate native parity, transport security, and release setup

- **Size / depends on:** L / MCP-2.4, MCP-2.10 and all native security/read tasks.
- **Work:** Test multiple active meetings, live-state changes, library/settings/attention parity, schema contracts, cursor behavior, pairing/revocation, loopback/origin restrictions, app restarts, disabled adapter, and offline/native coexistence. Update `doctor`, README, upgrade/uninstall, and capability documentation.
- **Output:** Phase 2 verification report and release candidate.
- **Done when:** Native reads agree with domain/UI state, unauthorized transport tests fail closed, offline limitations remain explicit, and clean installation/revocation workflows succeed.

### Phase 2 release gate

Ship native reads only when MCP-2.11 passes and no mutation endpoint is exposed unintentionally. Pairing and authentication cannot be deferred to Phase 3.

---

## 5. Phase 3 — Controlled Meeting and Library Writes

**Objective:** add allowlisted native commands with per-client authorization, native approvals, optimistic concurrency, idempotency, and audit.

### MCP-3.1 — Implement the canonical action and idempotency framework

- **Size / depends on:** L / MCP-2.10, MCP-0.5.
- **Work:** Define canonical action payloads/hashes, `action_id`, per-client idempotency records, action statuses, bounded pending lifecycle, replay behavior, and `ACTION_ID_REUSED`. Decide and document bounded waiting versus `pending_approval`; an identical retry must retrieve the action result without executing twice.
- **Output:** Shared native command dispatcher and persistent or crash-safe action-result store appropriate to product requirements.
- **Done when:** Concurrent/sequential retries execute at most once, same-ID different-payload requests fail, restarts cannot duplicate an applied action, and pending actions expire safely.

### MCP-3.2 — Add domain revisions and precondition evaluation

- **Size / depends on:** L / MCP-2.5 through MCP-2.9.
- **Work:** Expose stable revisions for mutable sessions, favorites, tasks, and settings; define join/create semantics where no entity revision exists; validate `expected_revision`; return `REVISION_CONFLICT`; re-read effective state immediately before applying approved actions.
- **Output:** Native revision service integrated with every future command target.
- **Done when:** Stale revisions never overwrite newer state, revision opacity is preserved for clients, and unsupported preconditions cannot be bypassed by omitting a field.

### MCP-3.3 — Implement payload-bound native approval UI and policy

- **Size / depends on:** L / MCP-3.1, MCP-3.2.
- **Work:** Present understandable native approval for canonical client/action/target/state changes. Bind approval to client, payload hash, target, expected revision, action ID, and expiration. Implement deny, cancel, timeout, app shutdown, and revalidation. Require explicit approval every time for join, leave, microphone/camera activation, and outward contributions.
- **Output:** Native approval coordinator and UI with scope/policy enforcement.
- **Done when:** Modified payloads/revisions invalidate approval, MCP cannot self-approve, and all sensitive-action negative tests prove that denial/timeout produces no side effect.

### MCP-3.4 — Implement privacy-safe action audit

- **Size / depends on:** M / MCP-3.1.
- **Work:** Record time, client, action ID/type, target, approval/result, safe failure code, and before/after revisions where applicable. Add retention/access behavior consistent with product policy and exclude raw content, credentials, and invitations.
- **Output:** Queryable internal audit trail plus redacted diagnostics.
- **Done when:** Applied, denied, failed, conflicted, and expired actions are attributable, and log/audit inspection reveals no prohibited content.

### MCP-3.5 — Implement join and leave through desired-state commands

- **Size / depends on:** L / MCP-3.3, MCP-2.5, MCP-2.6.
- **Work:** Add `rocknroll_control_meeting` connection-state support for valid room/occurrence/session targets. Resolve stored invitations entirely inside the app, validate current state/capabilities, request approval, and return observed native state/revision. Never accept a raw launch ticket from an agent.
- **Output:** Native join/leave command path with `SCOPE_DENIED`, `APPROVAL_*`, conflict, unavailable, and unsupported behavior.
- **Done when:** Join/leave uses native domain operations, exact targeting works with repeated rooms/multiple sessions, denial causes no connection change, and raw invitations never cross MCP.

### MCP-3.6 — Implement microphone, camera, and advertised meeting controls

- **Size / depends on:** L / MCP-3.3, MCP-2.5.
- **Work:** Add desired-state mutations only for controls advertised by the active native session. Return actual effective state after execution, handle device/policy failures, and require explicit approval for activation. Return `UNSUPPORTED_CONTROL` rather than scripting the UI.
- **Output:** Native media/control commands and per-meeting capability updates.
- **Done when:** Simultaneous meetings cannot cross-control each other, hardware denial is distinguishable from approval denial, retries are idempotent, and reported state matches the native model rather than requested intent.

### MCP-3.7 — Implement favorite mutations

- **Size / depends on:** M / MCP-3.3, MCP-2.6.
- **Work:** Add `rocknroll_set_favorite` with typed `room_id`, desired boolean, scopes, action ID, revision where applicable, and native favorite/room-history operations. Define approval behavior for this reversible low-risk class without weakening sensitive-action policy.
- **Output:** Favorite command and updated native meeting-card revision/state.
- **Done when:** Native storage and UI agree, retries do not toggle state, invalid IDs cannot affect arbitrary Keychain/history entries, and conflicts are handled explicitly.

### MCP-3.8 — Implement allowlisted task creation and updates

- **Size / depends on:** L / MCP-3.3, MCP-2.7.
- **Work:** Add `rocknroll_update_task` for verified parent outcome creation and allowlisted patches to `text`, `owner`, and `done`. Enforce typed IDs, expected revisions, scopes, idempotency, native validation, and approved authorization policy. Do not add generic patches or hidden deletion.
- **Output:** Native task command path and related outcome/task projections.
- **Done when:** Created/updated tasks match native models, ambiguous parents fail, stale updates do not overwrite newer text, and deletion remains unavailable unless separately specified.

### MCP-3.9 — Implement allowlisted settings updates

- **Size / depends on:** L / MCP-3.3, MCP-2.8.
- **Work:** Add `rocknroll_update_settings` with per-section schemas, expected revision, native validation, scope checks, and sensitive-setting approval rules. Reject unknown keys, provider credentials, arbitrary `UserDefaults`, and model-instruction changes.
- **Output:** Settings command path with effective-value re-read and revision result.
- **Done when:** Invalid and secret-bearing patches fail closed, conflicts preserve newer settings, native effective values match the response, and unrelated preferences remain unchanged.

### MCP-3.10 — Run adversarial authorization and failure testing

- **Size / depends on:** L / MCP-3.4 through MCP-3.9.
- **Work:** Test unauthenticated/wrong-scope clients, self-approval attempts, payload substitution, stale approval, expired approval, denial/timeout, revision races, app shutdown, target disappearance, duplicate/reordered requests, reused action IDs, cross-client replay, device failure, and log redaction.
- **Output:** Security test suite, abuse-case evidence, and resolved-findings record.
- **Done when:** No unauthorized or unapproved sensitive side effect is reproducible; all races fail closed or apply exactly once to the approved revision.

### MCP-3.11 — Run multi-client and multi-meeting end-to-end validation

- **Size / depends on:** L / MCP-3.10.
- **Work:** Exercise Codex through the bridge with two clients and multiple simultaneous meetings. Validate pending/applied results, retry after timeout/restart, concurrent favorites/tasks/settings edits, approval UX, native UI parity, audit records, and non-interference with app-originated changes.
- **Output:** Phase 3 interoperability and concurrency report.
- **Done when:** Every action is attributable to the correct client/target, MCP changes are distinguishable from app-originated changes, and no real user data is used by destructive tests.

### MCP-3.12 — Finalize mutation documentation and controlled rollout

- **Size / depends on:** M / MCP-3.11.
- **Work:** Document every command, scope, approval requirement, action lifecycle, revision rule, error, example, rollback/disable procedure, and supported limitation. Add explicit feature rollout so write scopes default off until granted by the user.
- **Output:** Updated README/security guide/capability matrix and Phase 3 release candidate.
- **Done when:** Documentation matches runtime capabilities, fresh clients receive no write scope by default, disabling writes leaves native reads functional, and the Phase 3 gate has auditable evidence.

### Phase 3 release gate

No sensitive action can execute without bound native approval and revision revalidation. All writes use native domain commands, not persistence files. Security and concurrency evidence from MCP-3.10 and MCP-3.11 is mandatory.

---

## 6. Phase 4 — In-App Assistant Integration

**Objective:** expose the existing native assistant with correct context and conversation identity while preserving native trust and outward-action approvals.

### MCP-4.1 — Specify the native assistant invocation contract

- **Size / depends on:** L / MCP-0.2, MCP-2.11.
- **Work:** Verify the assistant’s actual entry points, accepted context, conversation identity, response model, cancellation, timeout, progress, model/provider errors, cost/user-consent behavior, and existing side-effect paths. Distinguish stored outcomes from assistant invocation.
- **Output:** Assistant integration decision record and native service protocol.
- **Done when:** No parallel assistant state machine is proposed, all side effects are enumerated, and unsupported behavior is documented rather than simulated.

### MCP-4.2 — Implement native assistant request orchestration

- **Size / depends on:** L / MCP-4.1, MCP-2.5, MCP-2.7.
- **Work:** Invoke the existing in-app assistant with verified optional meeting/session context and native conversation ID. Preserve safe provenance, handle app/meeting changes during execution, support bounded waiting and cancellation, and avoid duplicating prompts/responses on retry.
- **Output:** Native assistant service adapter with fake-assistant tests.
- **Done when:** Context and conversation match native behavior, unavailable/cancelled/failed states are structured, and responses contain no hidden credentials or service instructions.

### MCP-4.3 — Expose `rocknroll_run_assistant` with scoped action semantics

- **Size / depends on:** L / MCP-4.2, MCP-3.1.
- **Work:** Add the MCP schema for `prompt`, optional `meeting_id`/conversation ID, and `action_id`; enforce `assistant:run`, input bounds, idempotent retries, native capability discovery, and response provenance. Define whether invocation itself needs confirmation based on native cost/privacy policy.
- **Output:** Assistant tool integrated with native action tracking.
- **Done when:** Codex can invoke the assistant through the bridge, retries do not create duplicate conversations/runs, wrong meeting types fail, and scopes are denied by default until granted.

### MCP-4.4 — Enforce untrusted-content and prompt-injection boundaries

- **Size / depends on:** L / MCP-4.3, MCP-0.5.
- **Work:** Treat transcripts, summaries, tasks, and user prompts as data rather than MCP/server instructions. Preserve source labels, isolate meeting text from adapter control inputs, test malicious transcript instructions, and prevent tool/schema fields from being overridden by content.
- **Output:** Prompt-injection fixtures and trust-boundary enforcement in the assistant adapter.
- **Done when:** Malicious meeting text cannot alter client scopes, target IDs, approval payloads, tool selection policy, or server configuration, and failures remain content-safe.

### MCP-4.5 — Separate outward effects from assistant responses

- **Size / depends on:** L / MCP-4.3, MCP-3.3, MCP-3.5, MCP-3.6.
- **Work:** Represent any proposed outward message/contribution as a separate canonical native action with target and payload. Require explicit bound approval regardless of native assistant “send without asking” settings. Ensure text-only assistant answers have no hidden side effects.
- **Output:** Outward-action mediation path and explicit denial behavior.
- **Done when:** Every outward action has its own approval and audit record; disabling or bypassing assistant autonomy settings cannot weaken MCP policy; text-only calls perform zero outward actions.

### MCP-4.6 — Add assistant UX, diagnostics, and privacy-safe observability

- **Size / depends on:** M / MCP-4.3, MCP-4.5.
- **Work:** Surface pending/running/completed/cancelled/failed states, app or meeting unavailability, native approval status, and safe run identity. Extend `rocknroll_status` and `doctor`; log metadata only, with explicit retention/redaction for prompts and responses.
- **Output:** User-visible progress/error handling and content-free diagnostics.
- **Done when:** Users can understand and cancel an active request, diagnostics identify the failing native stage without exposing prompt/transcript content, and stuck runs time out or remain explicitly recoverable.

### MCP-4.7 — Run assistant security and native-parity acceptance tests

- **Size / depends on:** L / MCP-4.4, MCP-4.5, MCP-4.6.
- **Work:** Test correct multi-meeting context, conversation continuity, native response parity, retries, cancellation, provider/app errors, malicious transcripts/prompts, scope denial, side-effect separation, approval denial/expiry, and the send-without-asking bypass case.
- **Output:** Assistant verification report with traced abuse cases.
- **Done when:** All specification §15.4 cases pass, no implicit outward action is observed, and native approval policy holds under every MCP assistant configuration.

### MCP-4.8 — Complete full-product acceptance and release documentation

- **Size / depends on:** L / MCP-4.7 plus all prior phase gates.
- **Work:** Re-run shared, offline, native, mutation, and assistant suites. Verify all active meetings, native library/settings/attention parity, capability reporting, revisions, approvals, idempotency, audit, assistant context, and outward-action controls. Document installation, migration, revocation, disable/rollback, limitations, and support diagnostics for both profiles.
- **Output:** Full acceptance report, final capability matrix, release notes, and production candidate.
- **Done when:** Every specification §16.2 criterion has evidence, all phase gates remain green, and no unimplemented capability is advertised as supported.

### Phase 4 release gate

The assistant must use the existing native workflow and context. Text-only responses must be side-effect free. Every outward contribution requires separate explicit native approval, independent of assistant autonomy settings.

---

## 7. Cross-Phase Traceability Matrix

| Requested capability | Primary tasks | Release |
|---|---|---|
| Outcomes, summaries, decisions, open questions | 0.1, 0.3, 1.5, 1.10 | Phase 1 |
| Tasks and task search | 0.1, 1.5, 1.9, 1.10 | Phase 1 |
| Cached calendar meetings | 0.1, 1.6, 1.10 | Phase 1 |
| Available transcript fragments | 0.1, 1.4, 1.7, 1.10 | Phase 1 |
| Stable IDs, provenance, partial coverage | 0.3, 0.6, 0.7, 1.8–1.11 | Phase 1 |
| Codex stdio integration | 0.4, 1.1, 1.12, 1.13 | Phase 1 |
| All active meetings and effective media state | 0.2, 2.5, 2.10, 2.11 | Phase 2 |
| Favorites, recents, complete native calendar | 0.2, 2.6, 2.10 | Phase 2 |
| Redacted settings | 0.2, 0.5, 2.8 | Phase 2 |
| Configured/effective mention-follow state | 0.2, 2.9 | Phase 2 |
| Native authenticated transport and bridge | 0.5, 2.2–2.4 | Phase 2 |
| Join/leave and meeting controls | 3.1–3.6 | Phase 3 |
| Favorite/task/settings mutations | 3.1–3.4, 3.7–3.9 | Phase 3 |
| Approvals, revisions, idempotency, audit | 0.5, 3.1–3.4, 3.10–3.12 | Phase 3 |
| In-app assistant invocation | 4.1–4.4, 4.6 | Phase 4 |
| Safe outward assistant actions | 4.5, 4.7 | Phase 4 |
| Full-product acceptance | 4.8 | Phase 4 |

## 8. Release Evidence Checklist

Each phase release must include:

- [ ] Source changes and pinned dependency/build metadata.
- [ ] Automated test results and a written verification report.
- [ ] Updated supported-capability matrix with explicit unavailable/partial features.
- [ ] Schema and example-response updates using synthetic content only.
- [ ] Security and privacy results, including negative-path tests.
- [ ] Installation, upgrade, uninstall, revocation/disable, and rollback instructions appropriate to the phase.
- [ ] `doctor` and troubleshooting verification.
- [ ] Product acceptance against the corresponding release gate.
- [ ] A list of known limitations and follow-up issues; no silent scope reductions.

## 9. Suggested Issue Labels

Use repository-native equivalents for:

```text
area:contracts
area:offline
area:native
area:transport
area:controls
area:assistant
type:discovery
type:implementation
type:security
type:testing
type:docs
phase:0 through phase:4
gate:blocker
```

Link every issue to its task ID and normative specification section. Keep security-gate failures open until resolved; do not move a release gate by silently narrowing the acceptance criteria.
