# Rock’N’Roll MCP Integration — Revised Technical Specification

**Status:** Proposed consolidated design  
**Date:** 9 November 2026  
**Supersedes:** the read-only `ROCKNROLL_MCP_SPEC.md` where requirements conflict  
**Implementation language:** Not prescribed; use the native application’s stack for in-app components and choose a suitable maintained MCP SDK for the standalone adapter

This document combines two complementary directions:

1. A standalone, offline, read-only MCP server for Codex and other MCP clients.
2. An authoritative adapter inside the native Mac application for live meetings, settings, controls, and the in-app assistant.

The offline adapter is the first deliverable, not a replacement for the native integration.

## 1. Purpose

Provide AI agents with safe, predictable access to Rock’N’Roll meeting information and, when the native application is available, controlled interaction with the application.

The complete integration covers:

- all active meetings and their effective live state;
- favorite, recent, and calendar meetings;
- available transcript fragments and complete transcripts when an authoritative source exists;
- outcomes, summaries, decisions, open questions, and tasks;
- mention/follow configuration and resolved attention state;
- explicitly exposed non-secret application settings;
- meeting controls and reversible library mutations;
- controlled invocation of the in-app assistant.

The first release intentionally supports only persisted, read-only data.

## 2. Delivery Profiles

### 2.1 Offline profile

Executable: `rocknroll-local`

- Standalone MCP server using stdio.
- Reads an allowlisted set of persisted application files.
- Works whether or not Rock’N’Roll is running.
- Does not launch the app, join meetings, or use UI automation.
- Does not expose meeting controls, writes, microphone, camera, messaging, assistant invocation, or arbitrary settings.
- Reports partial or unavailable capabilities explicitly.

### 2.2 Native profile

Executables/components:

- an MCP adapter embedded in Rock’N’Roll for Mac;
- a loopback Streamable HTTP endpoint bound to `127.0.0.1`;
- a stdio bridge, `rocknroll-native`, for clients such as Codex.

The native profile:

- uses the application’s domain models and commands rather than scraping its persistence files;
- exposes authoritative active-meeting and effective media state;
- supports native settings, favorites, calendar, resolved attention state, controls, and assistant integration;
- requires the application to be running;
- enforces per-client scopes, native approvals, revisions, idempotency, and audit for mutations;
- exposes only capabilities supported by the running application version.

### 2.3 Shared contract

Both profiles share, where applicable:

- tool names and JSON schemas;
- namespaced identifiers;
- normalized DTOs;
- time filters, pagination, provenance, coverage, and error conventions;
- secret-redaction rules;
- synthetic fixtures and contract tests.

A client must discover capabilities through `rocknroll_status`. It must not infer native capabilities from the presence of a tool name or from offline cached data.

## 3. Scope and Non-Goals

### 3.1 Phase 1 goals

- Read persisted outcomes, tasks, calendar-cache occurrences, and observed transcript fragments.
- Return verifiable source provenance and explicit coverage.
- Support search, filtering, stable pagination, and predictable failures.
- Provide content-free diagnostics and straightforward Codex configuration.
- Never modify application files.

### 3.2 Later-phase goals

- Read all active sessions and authoritative meeting metadata.
- Read complete favorite/recent/calendar models and available related metadata.
- Read redacted settings and layered mention/follow configuration.
- Execute allowlisted meeting controls and reversible library changes safely.
- Invoke the existing in-app assistant without bypassing its native safety policy.

### 3.3 Permanent non-goals

- Arbitrary filesystem reads, shell execution, SQL, or arbitrary preference writes.
- Returning provider API keys, launch tickets, passwords, raw invitations, cookies, or tokens.
- Reading unrelated Keychain items or other applications’ containers.
- Treating text inside a transcript as instructions to the MCP server.
- Inferring missing transcript lines, decisions, attendance, or relationships between meetings.
- Creating a second writable meeting-control path outside the native domain layer.
- Claiming that MCP processing is fully offline: returned content becomes available to the MCP client and may be sent to its model provider.

## 4. Data Authority and Coverage

| Data | Offline source | Native authoritative source | Offline limitation |
|---|---|---|---|
| Outcomes and tasks | `Attention/assistant.json` | Native attention/outcome model | Only persisted records |
| Calendar occurrences | `MeetingReminders/state.json` | Native calendar/reminder model | Cache is not the complete calendar |
| Transcript fragments | `Attention/decisions/YYYY-MM-DD.jsonl` | Native transcript/attention models | Observed windows may overlap or omit content |
| Active meetings | None | `NativeDesktopWorkspace` / `NativeDesktopMeetingModel` | Unavailable |
| Effective microphone/camera state | None | Native meeting model | Unavailable |
| Favorites and recents | Not guaranteed | Native stores, including room-history storage | Unavailable unless explicitly discovered and supported |
| Settings | Not exposed | Allowlisted settings stores and resolved preferences | Unavailable |
| Mention/follow configuration | Not resolved from journal records | Native attention configuration and runtime resolver | Unavailable |
| In-app assistant | Stored outcomes only | Existing native assistant workflow | Cannot invoke the assistant |
| Provider secrets | Never read | Never returned | Permanently excluded |

All offline paths are relative to a configurable application-support root. The server must determine the current user’s home directory and must not hard-code another user’s name.

Confirmed sampled fields, not guaranteed public schemas:

```text
Attention/assistant.json
  outcomes[]:
    id, meetingID, meetingTitle, invitation, endedAt,
    summary, decisions[], openQuestions[], tasks[]
  tasks[]:
    id, text, owner, done

MeetingReminders/state.json
  schema: 2
  occurrences[]:
    id, eventID, calendarID, title, start, end,
    reference, invitation, engine, eligible, tentative
  scheduled[]

Attention/decisions/YYYY-MM-DD.jsonl
  at, id, meetingTitle, window
  window.lines[]:
    id, at, ref, source, speaker, text, isYou, mentionsYou
```

Interpretation rules:

- `outcomes[].decisions` are meeting decisions.
- `Attention/decisions/` is an assistant journal; its operational decisions are not participant decisions.
- Calendar-cache entries do not prove attendance or an active session.
- `messages`, service instructions, model memory, and model settings are excluded.
- Unknown or unverified fields must not be assigned guessed semantics.
- Schema discovery must verify optionality, date semantics, ID stability, and relationships before transformations are finalized.

## 5. Identity Model

Never conflate a reusable room, a scheduled occurrence, an active session, an outcome, or a transcript fragment.

Use opaque, stable, namespaced adapter IDs with distinct conceptual types:

```text
room:<source>:<opaque-id>
occurrence:<source>:<opaque-id>
session:<source>:<opaque-id>
outcome:<source>:<opaque-id>
fragment:<source>:<opaque-id>
task:<source>:<opaque-id>
```

The exact serialization is an implementation detail, but the namespace and entity type must be unambiguous to the server.

Requirements:

- Prefer stable source identifiers.
- Do not include secrets or raw invitation URLs in IDs.
- Do not merge records by title alone.
- Do not automatically combine repeated sessions in one room.
- When a relationship is uncertain, return separate records and a warning.
- Preserve source type, source record ID, and, when applicable, JSONL filename and line number as internal provenance.
- A source reference must permit retrieval of the same record while the source remains available and unchanged.
- A `meeting_id` parameter accepts only the meeting-like types documented by that tool. Other entities use explicit parameters such as `outcome_id`.

A meeting card may contain typed links to related rooms, occurrences, sessions, outcomes, and transcript fragments. A link represents verified identity only; possible but unconfirmed relationships belong in warnings, not merged entities.

## 6. Common API Contract

### 6.1 Dates and filtering

- API timestamps use RFC 3339 with an explicit offset.
- Time ranges are half-open: `[from, to)`.
- Each tool schema documents the date used for filtering: occurrence start, outcome end, utterance time, or another verified field.
- Do not invent missing task dates.
- Preserve source timestamps separately from adapter observation timestamps.

### 6.2 Pagination and limits

- `limit` defaults to 20 and has a maximum of 100.
- Cursors are opaque and bound to the query filters and backend snapshot/revision.
- Within a stable snapshot, pagination must not omit or duplicate records.
- If a consistent continuation cannot be provided, return `CURSOR_EXPIRED`.
- Transcript responses are additionally bounded to approximately 64 KiB; continuation uses a cursor.
- Search results use deterministic ordering with a stable tie-breaker.

### 6.3 Response envelope

List responses use:

```json
{
  "items": [],
  "next_cursor": null,
  "observed_at": "2026-11-09T18:00:00+03:00",
  "coverage": "partial",
  "sources": [],
  "warnings": []
}
```

Single-object responses include the object plus the same applicable metadata.

- `observed_at`: when the MCP backend read the data, not when the app updated it.
- `source_modified_at`: optional per-source modification time.
- `coverage`: `complete`, `partial`, or `unknown` with respect to the requested representation.
- `sources`: safe source type and revision/modification metadata, without secrets.
- `warnings`: structured, non-sensitive diagnostics.

Journal-derived transcripts must use `coverage: "partial"` unless completeness is proven by an authoritative source. `coverage` describes data completeness, not request success.

### 6.4 Provenance and text fidelity

- Return stored summaries, decisions, open questions, and task text without generative rewriting.
- Preserve utterance speaker, timestamp, source, and stable identity where available.
- Deduplicate overlapping windows only by verified utterance identity.
- Do not merge identical phrases spoken by different people or at different times.
- Do not reconstruct omitted speech.
- Do not attach a journal record to a meeting when the relationship is ambiguous.

### 6.5 Tool annotations and schemas

- Every tool has explicit input and output JSON schemas.
- Read-only tools use `readOnlyHint: true` and `destructiveHint: false`.
- Mutating tools must not claim to be read-only; destructive behavior must be annotated accurately.
- Unsupported capabilities return a structured error rather than a fabricated empty success.

## 7. Phase 1 Read Tools

The initial public surface contains seven tools.

| Tool | Parameters | Result |
|---|---|---|
| `rocknroll_status` | None | Backend, sources, schema versions, capabilities, coverage, and limitations |
| `rocknroll_list_meetings` | `from`, `to`, `query`, `kind`, `cursor`, `limit` | Meeting-like records for the requested filters |
| `rocknroll_get_meeting` | `meeting_id` | Canonical meeting card and typed related-data links |
| `rocknroll_get_transcript` | `meeting_id`, `from`, `to`, `cursor`, `limit` | Available utterances with provenance and coverage |
| `rocknroll_get_outcome` | `outcome_id` | Stored summary, decisions, open questions, and task links |
| `rocknroll_list_tasks` | `meeting_id`, `done`, `owner`, `cursor`, `limit` | Tasks with verified meeting/outcome relationships |
| `rocknroll_search` | `query`, `types`, `from`, `to`, `cursor`, `limit` | Search across supported meetings, outcomes, tasks, and utterances |

Required parameters:

- `meeting_id` for `rocknroll_get_meeting` and `rocknroll_get_transcript`;
- `outcome_id` for `rocknroll_get_outcome`;
- `query` for `rocknroll_search`.

Other listed parameters are optional filters or pagination controls.

Outcome IDs are discovered through `rocknroll_list_meetings` with `kind: "outcome"` or through typed links in `rocknroll_get_meeting`. This avoids the ambiguity of requesting one outcome for a room or series that may have many outcomes.

Initial offline `kind` values:

```text
calendar
outcome
transcript_fragment
```

Native profile adds:

```text
active
favorite
recent
```

`types` for search is a subset of:

```text
meeting
outcome
task
transcript
```

An omitted `kind` searches only the meeting-like categories supported by the active backend and identifies each item’s actual kind.

## 8. Native Read Extensions

The native profile adds the following tools and richer responses to the shared read tools.

### 8.1 `rocknroll_get_settings`

Parameters:

- optional `sections`;
- optional `meeting_id` when resolved meeting-specific values are requested.

Returns an allowlisted, versioned representation of:

- general meeting preferences;
- audio/video preferences;
- attention and assistant preferences;
- mention/follow configuration;
- defaults, configured overrides, and effective values where distinguishable;
- a settings revision for optimistic concurrency.

Never return provider credentials, Keychain values, raw invitations, arbitrary `UserDefaults`, or internal model instructions. Unknown settings are omitted rather than exposed through an unrestricted key/value API.

### 8.2 Meeting cards

Native meeting cards extend the common DTO with applicable fields:

- entity kind and typed related IDs;
- title, schedule, room/reference metadata, favorite state, and safe source metadata;
- active/joined state and effective media state for active sessions;
- available summaries, outcomes, tasks, and transcript coverage;
- configured and effective mention/follow state;
- supported controls and current entity revision.

“All metadata” means all fields defined by the normalized public contract plus explicitly allowlisted safe source metadata. It does not mean dumping raw persistence objects or secrets.

### 8.3 Attention representation

When supported by the app, expose both configuration and resolution:

```json
{
  "configured": {},
  "effective": {},
  "inherited_from": [],
  "revision": "native-revision"
}
```

Enums and fields must match the native attention model. Do not invent a separate MCP-only attention policy language. Offline journal entries are not sufficient to reconstruct this state.

## 9. Native Mutations and Assistant

All mutation tools accept:

```text
action_id          client-generated unique ID, preferably UUID
expected_revision  required when modifying an existing revisioned entity
```

Additional fields are tool-specific. Commands are validated, canonicalized, and authorized by the native adapter before presentation for approval.

### 9.1 `rocknroll_control_meeting`

Controls a native meeting through desired state rather than UI automation.

Input includes:

- `meeting_id` identifying an active session, or a valid room/occurrence for a join request;
- `desired_state` containing only controls advertised by `rocknroll_status` and the meeting card;
- `action_id`;
- `expected_revision` when required.

Potential controls include connection state, microphone, camera, and other explicitly supported native controls. Unsupported controls return `UNSUPPORTED_CONTROL`; they must not be simulated through UI scripting.

Joining, leaving, microphone activation, camera activation, and outward contributions always require explicit native user approval. The app resolves any stored invitation internally; the MCP caller does not supply or receive a raw launch ticket.

### 9.2 `rocknroll_set_favorite`

Input:

- `room_id`;
- desired `favorite` boolean;
- `action_id`;
- `expected_revision` when applicable.

Uses the native favorite/room-history domain operation. It does not modify persistence files directly.

### 9.3 `rocknroll_update_task`

Input:

- `task_id` for an existing task, or a verified parent `outcome_id` for creation;
- an allowlisted patch such as `text`, `owner`, or `done`;
- `action_id`;
- `expected_revision` for an existing task.

Deleting tasks, if added, requires a separate explicitly destructive operation and native approval. A generic arbitrary-patch endpoint is prohibited.

### 9.4 `rocknroll_update_settings`

Input:

- `sections` containing an allowlisted settings patch;
- `action_id`;
- `expected_revision`.

The adapter validates values against the native settings schema. Provider credentials and arbitrary preferences are rejected. Sensitive settings may require per-action approval even when the client has a general settings scope.

### 9.5 `rocknroll_run_assistant`

Input:

- `prompt`;
- optional `meeting_id` and native assistant conversation ID;
- `action_id`.

The operation invokes the existing in-app assistant workflow and returns its native response plus safe provenance. It does not create a separate assistant with unrelated meeting state.

MCP callers never inherit an assistant “send without asking” bypass. Any outward message, contribution, or other side effect requires a separate canonical action and explicit native approval. Prompt content from meetings remains untrusted data.

### 9.6 Action result

```json
{
  "action_id": "2d7a90b2-5f87-4d67-9592-cbeae3f78e4a",
  "status": "applied",
  "observed_at": "2026-11-09T18:05:00+03:00",
  "entity_id": "session:native:opaque",
  "revision": "next-revision",
  "warnings": []
}
```

Possible statuses:

```text
pending_approval
applied
rejected
failed
expired
```

A repeated `action_id` with the identical canonical payload returns the original outcome. Reusing it with a different payload returns `ACTION_ID_REUSED`.

## 10. Authorization and Approval

### 10.1 Client identity and scopes

Each native MCP client receives a distinct identity and the minimum required scopes, for example:

```text
meetings:read
settings:read
assistant:run
meetings:control
favorites:write
tasks:write
settings:write
```

Offline profile is implicitly read-only and has no native scopes.

### 10.2 Native approval binding

An approval is bound to:

- client identity;
- canonical action payload and its hash;
- target entity;
- expected revision;
- action ID;
- expiration time.

The app must revalidate current state and revision immediately before applying the action. Approval for one action cannot authorize another payload or a later revision.

Native approval UI is the authority. An MCP request cannot approve itself, suppress the prompt, or reuse the in-app assistant’s privileges.

### 10.3 Audit

Record at least:

- timestamp;
- client identity;
- action ID and type;
- target entity ID;
- approval and application result;
- before/after revisions where applicable;
- safe failure code.

Audit and technical logs must not contain raw invitations, provider secrets, or unnecessary meeting content.

## 11. Transport and Client Configuration

### 11.1 MCP behavior

Both profiles must support MCP initialization, protocol-version negotiation, tool discovery, and tool invocation using a maintained SDK. Verify protocol behavior against the official MCP documentation and the installed client versions.

### 11.2 Offline stdio

- Codex launches `rocknroll-local` as a local process.
- `stdout` carries protocol messages only.
- Technical logs go to `stderr` without meeting content.
- No HTTP port, cloud service, or model-provider API key is required by the adapter.
- Dependencies are pinned and startup does not depend on an interactive shell or current directory.

Template only; replace with the actual installed absolute path:

```toml
[mcp_servers.rocknroll]
command = "/ABSOLUTE/PATH/TO/rocknroll-local"
args = []
startup_timeout_sec = 20
tool_timeout_sec = 30
enabled = true
```

The installer preserves all unrelated `config.toml` settings and never overwrites the whole file. Validate the final example against the installed Codex version.

### 11.3 Native HTTP and stdio bridge

- Bind Streamable HTTP to loopback only; never expose it on a LAN interface by default.
- Use an application-selected available port and explicit endpoint discovery.
- Authenticate every native client; do not put credentials in command-line arguments or logs.
- Store native credentials using a user-approved protected mechanism with restrictive file permissions where a file is unavoidable.
- Restrict origins and reject non-loopback connections.
- `rocknroll-native` translates client stdio to the authenticated local HTTP transport.
- If the app is unavailable, return `APP_NOT_RUNNING` or `CAPABILITY_UNAVAILABLE`; do not silently fall back to stale file data under the native profile.

A client may explicitly configure both profiles under different MCP server names. Responses must identify their backend so cached/offline data cannot be mistaken for live state.

## 12. Offline File Safety and Concurrency

The file adapter:

- opens sources read-only;
- reads only allowlisted paths under the configured root;
- rejects path traversal and symlink escapes;
- performs bounded retries when JSON changes during reading;
- reads only completed JSONL lines and defers an incomplete tail;
- reports a malformed completed JSONL line in warnings;
- handles replacement, truncation, and rotation;
- uses a consistent snapshot for pagination or returns `CURSOR_EXPIRED`;
- creates no locks, indexes, caches, or other files inside the app container;
- never promises live active-meeting state from a persisted journal.

An in-memory cache is sufficient for Phase 1. A persistent search index is a later optimization and, if implemented, belongs in the adapter’s own user-approved storage with appropriate redaction and retention controls.

Private persistence formats may change without notice. Detect supported schema versions, return `UNSUPPORTED_SCHEMA` for unrecognized incompatible structures, and fail closed rather than guessing.

Sandbox/container access is not guaranteed. Diagnostics must identify the precise unavailable path and minimum required user action; not every access failure implies a need for Full Disk Access.

## 13. Diagnostics and Errors

### 13.1 `doctor`

Both executables provide a `doctor` command appropriate to their profile. It checks, without printing meeting content:

Offline:

- app presence/version when detectable;
- configured data-root access;
- allowlisted source presence and readability;
- schema compatibility;
- category availability.

Native:

- app and adapter availability;
- endpoint discovery and loopback connectivity;
- client authentication and granted scopes;
- protocol compatibility;
- capability availability.

### 13.2 Error envelope

Tool failures return a safe structured error containing:

```json
{
  "code": "SOURCE_NOT_FOUND",
  "message": "The configured outcome source is unavailable.",
  "retryable": false,
  "details": {}
}
```

Do not include secrets or meeting content in error details.

Common error codes:

```text
INVALID_ARGUMENT
SOURCE_NOT_FOUND
ACCESS_DENIED
UNSUPPORTED_SCHEMA
SOURCE_BUSY
CORRUPT_SOURCE
MEETING_NOT_FOUND
OUTCOME_NOT_FOUND
TASK_NOT_FOUND
TRANSCRIPT_UNAVAILABLE
AMBIGUOUS_MEETING
CURSOR_EXPIRED
APP_NOT_RUNNING
CAPABILITY_UNAVAILABLE
UNSUPPORTED_CONTROL
SCOPE_DENIED
APPROVAL_REQUIRED
APPROVAL_DENIED
APPROVAL_EXPIRED
REVISION_CONFLICT
ACTION_ID_REUSED
RATE_LIMITED
INTERNAL_ERROR
```

Absence of data, denied access, incompatible schema, corruption, and ambiguity are distinct states. Do not convert every failure into an empty list.

## 14. Implementation Sequence and Gates

### Phase 0 — Discovery and shared foundations

- Inspect native models, stores, commands, and existing attention/assistant behavior.
- Produce `discovery.md` with verified schemas, date semantics, IDs, relationships, settings ownership, and limitations.
- Define versioned shared DTOs, identity rules, error envelope, provenance, and capability model.
- Build synthetic fixtures without real user meeting content.
- Validate the MCP protocol and Codex configuration with a minimal spike.

**Gate:** identity and relationship rules are documented; no implementation depends on guessed fields.

### Phase 1 — Offline read-only MVP

- Implement allowlisted JSON/JSONL adapters and file safety.
- Implement outcomes, tasks, and calendar-cache reads.
- Add transcript-fragment extraction and verified deduplication.
- Implement the seven read tools, search, pagination, status, and `doctor`.
- Add installation, uninstallation, Codex configuration, tests, and a capability report.

**Gate:** all Phase 1 acceptance criteria pass without modifying app files.

### Phase 2 — Native authoritative reads

- Embed the adapter in the native app and add authenticated loopback transport plus stdio bridge.
- Reuse shared contracts and fixtures.
- Add all active meetings, effective media state, favorites/recents, complete native calendar data, and available related metadata.
- Add redacted settings and configured/effective mention-follow state.
- Report backend and capabilities dynamically.

**Gate:** native reads agree with native UI/domain state, and offline-only limitations remain explicit.

### Phase 3 — Controlled meeting and library writes

- Add native desired-state meeting commands.
- Add favorite, task, and allowlisted settings mutations.
- Enforce scopes, per-client identity, expected revisions, idempotency, native approvals, and audit.
- Add conflict, repeated-action, denied-approval, expiry, and app-state tests.

**Gate:** no unapproved sensitive action is possible, and direct persistence writes are not used.

### Phase 4 — In-app assistant integration

- Invoke the existing assistant with native context.
- Preserve native conversation identity and safe provenance.
- Separate outward side effects from assistant responses.
- Test prompt-injection handling and verify that MCP never inherits a send-without-asking bypass.

**Gate:** assistant behavior and approvals match the native product’s security policy.

## 15. Testing Requirements

### 15.1 Shared contract tests

- RFC 3339 parsing and `[from, to)` boundaries.
- Typed identity and ambiguous relationships.
- Stable ordering and cursor filter binding.
- Coverage and provenance propagation.
- Secret redaction and safe error serialization.
- Offline/native capability reporting.

### 15.2 Offline adapter tests

- Optional/missing fields and supported/unsupported schemas.
- Same-title and recurring meetings remain separate.
- Overlapping transcript windows and verified deduplication.
- Incomplete, malformed, rotated, truncated, and replaced JSONL/JSON inputs.
- Concurrent file writes and bounded retries.
- Snapshot pagination without omissions or duplicates.
- Path traversal and symlink escape rejection.
- Source files remain byte-for-byte unchanged.
- No adapter artifacts appear inside the app container.

### 15.3 Native adapter tests

- Multiple simultaneous active meetings and correct session targeting.
- Effective microphone/camera and connection state.
- Favorite/calendar/recent coverage and related metadata.
- Layered mention/follow resolution.
- Settings redaction and revisions.
- Client authentication, scope enforcement, loopback/origin restrictions.
- Approval payload binding and approval expiration.
- Revision conflicts and process/state changes between approval and execution.
- Idempotent retries and action-ID payload mismatch.
- Audit completeness without sensitive content.

### 15.4 Assistant tests

- Correct meeting context and native conversation use.
- Transcript instructions treated as untrusted content.
- No implicit outward message or contribution.
- Explicit native approval required for every outward action.
- Clear failure when the assistant or requested capability is unavailable.

Write-mutation tests use synthetic stores or test copies. Do not attribute the running app’s own changes to MCP, and do not test destructive behavior against a user’s real data.

## 16. Acceptance Criteria

### 16.1 Phase 1 acceptance

The offline MVP is accepted when:

- Codex discovers the tools and reads real persisted data successfully.
- “Show today’s meetings,” “show the meeting outcome,” and “find incomplete tasks” return results consistent with their sources.
- Transcript search returns verifiable fragments with speaker and timestamp when present.
- Partial transcripts are explicitly marked partial.
- Same-title and recurring meetings are not merged.
- Pagination does not omit or duplicate records within a snapshot.
- Missing access, corruption, and unsupported schemas fail predictably.
- Source files are unchanged and invitations/secrets are not disclosed.
- `doctor` diagnoses availability without exposing meeting content.
- Installation preserves unrelated Codex configuration.
- A full transcript is not claimed when only journal fragments exist.

### 16.2 Full native acceptance

The complete integration is accepted when, in addition:

- every active native meeting is visible with its authoritative effective state;
- favorites, recents, calendar meetings, settings, and available metadata match the native models;
- configured and effective mention/follow state is distinguishable;
- only advertised controls and settings are exposed;
- sensitive actions require bound native approval and pass revision checks;
- retries are idempotent and conflicts never overwrite newer state blindly;
- assistant calls use the existing native workflow and cannot bypass outward-action approval;
- offline and native responses are distinguishable by backend, provenance, coverage, and capabilities.

## 17. Deliverables

For each implemented phase, deliver:

- source code and pinned dependencies;
- reproducible build/run instructions;
- automated tests and a verification report;
- `discovery.md` and an actual supported-capability matrix;
- JSON schemas and example responses without real user content;
- README with installation, configuration, upgrade, and uninstallation;
- `doctor` diagnostics and troubleshooting guidance;
- documented limitations and security behavior.

Phase 1 completion requires working meeting, outcome, and task reads. If only transcript fragments are available, deliver them with explicit partial coverage; do not fabricate a complete transcript or claim full support.
