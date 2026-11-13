# Rock'N'Roll MCP — tool contracts

Version 0.3.0 · Protocol `2025-03-26` · Companion to `ROCKNROLL_MCP_INPUT_SCHEMA_FIX_SPEC.md`.

This is the single source of truth for what each tool accepts. Published `inputSchema`
values and server-side validation are generated from the declarations behind this table;
contract tests fail on drift. Corrections belong here first, then in code.

Conventions used below: `*` = unconditionally required. `?` = optional. Explicit `null`
is **never** accepted for any parameter — it fails with `INVALID_ARGUMENT`. Dates are
RFC 3339 with a numeric offset or `Z`; a missing time-zone offset is rejected. When both
`from` and `to` are present, `from` must be earlier than `to`. Pagination: `limit`
(integer, default 20) accepts values in 1…100; out-of-range values are rejected at the
MCP boundary with `reason: range` (the internal paging helpers still clamp for callers
that bypass JSON-RPC). `cursor` is an opaque string taken verbatim from a previous
response's `next_cursor`; reusing it after changing the other filters fails with
`CURSOR_EXPIRED`. Meeting/room/outcome/task IDs are opaque strings — clients must not
assume UUID format (only `action_id` is a UUID).

## Native profile (14 tools)

### rocknroll_status — no arguments

### rocknroll_list_meetings
Reads: active, favorite, recent, calendar and outcome meetings, sorted by date (undated
cards last among equals, then by id).

| Field | Type | Req | Default | Notes |
|-|-|-|-|-|
| `from` | string, `date-time` | | | lower bound on start/ended_at/last_joined_at |
| `to` | string, `date-time` | | | exclusive upper bound |
| `query` | string | | | trimmed; whitespace-only = no filter; case-insensitive substring over title + summary |
| `kind` | string enum `active\|favorite\|recent\|calendar\|outcome` | | all kinds | |
| `limit` | integer 1…100 | | 20 | out-of-range values rejected (`reason: range`) |
| `cursor` | string | | | see pagination conventions |

### rocknroll_get_meeting
| Field | Type | Req | Notes |
|-|-|-|
| `meeting_id` | string, minLength 1 | * | opaque item `id` from `rocknroll_list_meetings` or `rocknroll_search`. Prefix selects the record: `session:` active meeting, `room:` favorite/recent room, `occurrence:` calendar event, `outcome:` stored outcome (with decisions, open questions, task ids). Other prefixes → `INVALID_ARGUMENT`. |

### rocknroll_get_transcript
Authoritative transcript of an **active session** (service transcript plus local
transcription, de-duplicated, chronological). Coverage is reported per response
(`complete` only when the service proves a full stream).

| Field | Type | Req | Notes |
|-|-|-|-|
| `meeting_id` | string, minLength 1 | * | must be a `session:` id; otherwise `TRANSCRIPT_UNAVAILABLE` |
| `from`, `to` | string, `date-time` | | utterance time range |
| `limit`, `cursor` | | | pagination (see conventions) |

### rocknroll_get_outcome
| Field | Type | Req | Notes |
|-|-|-|
| `outcome_id` | string, minLength 1 | * | the `id` of a `kind:"outcome"` item from `rocknroll_list_meetings` / `rocknroll_search`, or the `meeting_id` field of task items. **Not** a `meeting_id`. |

### rocknroll_get_notes
Raw Markdown of the user's personal note for one meeting. Notes are user-authored
records attributed separately from outcomes and transcripts; the tool never writes.

| Field | Type | Req | Notes |
|-|-|-|
| `meeting_id` | string, minLength 1 | * | an id returned by `rocknroll_list_meetings` or `rocknroll_search`; must identify a persisted session (`session:` prefix) or an outcome-backed historical session |

Response: `meeting_id`, `note_id`, `has_notes`, `revision`, `updated_at`,
`provenance: {type: "personal_note", …}`, `coverage` (`complete`, or `partial` with a
truncation warning when the Markdown exceeds the 12 KB inline cap), `markdown`,
`meeting_title`, `observed_at`. A persisted session without a note returns
`has_notes: false` with a warning, not an error.

### rocknroll_list_tasks
Tasks collected from stored outcomes.

| Field | Type | Req | Default | Notes |
|-|-|-|-|
| `meeting_id` | string | | | filter by outcome id (`outcome:…`), matching the `meeting_id` field of task items |
| `done` | boolean | | | completion filter |
| `owner` | string | | | case-insensitive substring match |
| `limit`, `cursor` | | | | pagination |

### rocknroll_search
| Field | Type | Req | Default | Notes |
|-|-|-|-|
| `query` | string, minLength 1 | * | | trimmed before matching; must be non-empty after trimming; case-insensitive substring |
| `types` | array of string enum `meeting\|outcome\|task\|transcript\|note` | | all five | unknown values rejected |
| `limit`, `cursor` | | | | pagination. No date filters on this tool. |

### rocknroll_get_settings
| Field | Type | Req | Default | Notes |
|-|-|-|
| `sections` | array of string enum `app\|attention\|meeting` | | all three | unknown values rejected |
| `meeting_id` | string | | | consulted only when `sections` includes `meeting`; must be a `session:` id |

Response carries `revision` (opaque; required by `rocknroll_update_settings` as
`expected_revision`) and `sections.app.favorite_revision` (required by
`rocknroll_set_favorite`). Secrets are never returned — providers report `has_key`.

### rocknroll_control_meeting
Every call shows a native approval dialog; a denied call is recorded as
`rejected` / `APPROVAL_DENIED` and changes nothing.

| Field | Type | Req | Notes |
|-|-|-|-|
| `action_id` | string (UUID) | * | idempotency key; retrying an identical call replays the recorded result |
| `meeting_id` | string, minLength 1 | * | `session:` / `room:` / `occurrence:` id from `rocknroll_list_meetings` |
| `desired_state` | object | | empty object allowed; keys: `leave` boolean (sessions only), `microphone` boolean (sessions: set state; rooms/occurrences: `false` joins muted), `camera` boolean (sessions only) |

Join behavior: a `room:` or `occurrence:` target joins the meeting; a `session:` target
applies device state / leaves.

### rocknroll_set_favorite
| Field | Type | Req | Notes |
|-|-|-|-|
| `action_id` | string (UUID) | * | idempotency key |
| `room_id` | string, minLength 1 | * | id of a `favorite`/`recent` item from `rocknroll_list_meetings` |
| `favorite` | boolean | * | `true` star, `false` unstar |
| `expected_revision` | string | | **required unless `action_id` replays a recorded call**; current value from `rocknroll_get_settings` → `sections.app.favorite_revision` |

### rocknroll_update_task
| Field | Type | Req | Notes |
|-|-|-|-|
| `task_id` | string, minLength 1 | * | task item `id` (`task:native:<outcomeUUID>:<taskUUID>`) from `rocknroll_list_tasks`, `rocknroll_search` or `rocknroll_get_outcome` |
| `action_id` | string (UUID) | * | idempotency key |
| `expected_revision` | string | | **required unless replaying**; equals the outcome UUID — the middle component of `task_id` |
| `text`, `owner` | string | | new value; omitted = unchanged |
| `done` | boolean | | omitted = unchanged |

An empty patch (none of `text`/`owner`/`done`) is structurally valid and applies no
changes; it still requires approval and a fresh `expected_revision`.

### rocknroll_update_settings
Shows a native approval dialog; denied calls are recorded as `rejected`.

| Field | Type | Req | Notes |
|-|-|-|-|
| `action_id` | string (UUID) | * | idempotency key |
| `expected_revision` | string | | **required unless replaying**; current value from `rocknroll_get_settings` → `revision` |
| `sections` | object | `{}` | patch; omitting it applies no changes. Keys: `attention` — object with exactly the boolean fields `judge_enabled`, `pause_on_battery`, `draft_replies`, `local_drafts`, `push_to_talk`, `talk_back`, `generate_outcomes`, `remote_outcomes`. Unknown keys (including other section names) are rejected. |

### rocknroll_run_assistant
Runs a prompt through the in-app assistant. Actions that would need native confirmation
(sending chat, …) are **not** executed: the call is recorded as `rejected` /
`APPROVAL_REQUIRED` and the human can confirm in the app.

| Field | Type | Req | Notes |
|-|-|-|-|
| `action_id` | string (UUID) | * | idempotency key |
| `prompt` | string, minLength 1 | * | trimmed; must be non-empty after trimming |
| `meeting_id` | string | | must be a `session:` id; scopes the assistant to that meeting |
| `conversation_id` | string | | recognized for compatibility but **always rejected** with `CAPABILITY_UNAVAILABLE` — this assistant exposes no external conversation IDs |

## Offline profile (7 read-only tools)

Same pagination/date/null conventions. The offline profile reads cached fixtures and
never mutates; all tools are read-only.

- `rocknroll_status` — no arguments.
- `rocknroll_list_meetings` — `from?`, `to?`, `query?` (trimmed; whitespace-only = no
  filter), `kind?` enum `calendar|outcome|transcript_fragment` (default: all three;
  unknown kinds rejected), `limit?`, `cursor?`.
- `rocknroll_get_meeting` — `meeting_id*` (cached record id).
- `rocknroll_get_transcript` — `meeting_id*`, `from?`, `to?`, `limit?`, `cursor?`;
  coverage is always partial and marked as such.
- `rocknroll_get_outcome` — `outcome_id*` (outcome item `id`).
- `rocknroll_list_tasks` — `meeting_id?`, `done?`, `owner?` (case-insensitive
  substring), `limit?`, `cursor?`.
- `rocknroll_search` — `query*` (trimmed, non-empty), `types?` array of string enum
  `meeting|outcome|task|transcript` (default all; unknown rejected), `from?`, `to?`
  (offline search filters by date; the native equivalent does not), `limit?`, `cursor?`.

## Error model (both profiles)

Structural problems fail before any handler or side effect with `INVALID_ARGUMENT` and
`details: {"field": …, "reason": …}` where reason ∈ `required`, `type`, `null`, `enum`,
`range`, `unknown_field`, `empty`, `format`. Domain problems keep their existing codes:
`MEETING_NOT_FOUND`, `OUTCOME_NOT_FOUND`, `TASK_NOT_FOUND`, `TRANSCRIPT_UNAVAILABLE`,
`CURSOR_EXPIRED` (retryable), `REVISION_CONFLICT` (retryable), `CAPABILITY_UNAVAILABLE`,
`APP_NOT_RUNNING`, `SCOPE_DENIED` / `ACCESS_DENIED` (checked before validation).
`ACTION_ID_REUSED` guards idempotency-key reuse with a different payload.

## Documented behavior changes introduced with 0.3.0

- `rocknroll_get_notes(meeting_id)` joins the read-only catalog: raw personal-note
  Markdown with revision, provenance `personal_note` and a 12 KB partial-coverage flag.
- `rocknroll_search` `types` gains `note` (note Markdown matches; defaults to all five).
- Offline profile: `MeetingLibrary/notes.json` is an allowlisted read-only source;
  `rocknroll_list_meetings` gains kind `note` (`session:file:<uuid>` ids), and
  `rocknroll_get_meeting` resolves note-session ids. Server version 0.2.0 → 0.3.0;
  the MCP protocol version is unchanged.

## Documented behavior changes introduced with 0.2.0

- `tools/list` publishes real schemas (this fix).
- Explicit `null` arguments are rejected instead of behaving like missing keys
  (offline previously treated `null` as absent).
- Dates without a time-zone offset are rejected (previously accepted by a lenient
  fallback in the native profile).
- `from` ≥ `to` is rejected (previously returned empty results).
- `query` / `prompt` are trimmed; a whitespace-only required `query`/`prompt` is
  rejected; a whitespace-only optional `query` filter is ignored.
- Unknown `types`/`sections`/`kind` enum values are rejected at validation (previously
  silently ignored by `search`/`get_settings`; `kind` already errored).
- Unknown keys inside `update_settings.sections` are rejected (previously silently
  ignored); unknown top-level arguments are rejected for all tools.
- `rocknroll_get_settings` response adds `sections.app.favorite_revision` so
  `rocknroll_set_favorite` is callable (its `expected_revision` was never exposed before,
  making the tool unusable by a fresh client).
- `sections.attention.situation_modes` is now a plain string-keyed object. It was keyed
  by the internal `AttentionSituation` enum, which `JSONSerialization` cannot encode —
  serializing a settings response (as the MCP server does for every tool result) was
  unreliable and could abort the host on Swift 6.3/6.4 (swiftlang/swift#87481).
