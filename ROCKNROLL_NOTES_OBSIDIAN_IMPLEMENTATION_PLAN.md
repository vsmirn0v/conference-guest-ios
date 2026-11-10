# Rock’N’Roll for Mac: Meeting Notes and Obsidian — Implementation Plan

Date: 10 November 2026  
Source requirement: `ROCKNROLL_NOTES_OBSIDIAN_SPEC.md`  
Target: `NativeMacGuest`, macOS 13+, Swift/AppKit/SwiftUI  
Planning status: Stages 1–4 core and the MCP note tool implemented and shipped as native direct beta 0.3.0 (86) on 2026-11-10 (commits `101d15f`, merge `4f2033f`; validation record `docs/native-direct-0.3.0-86-validation.json`). Stages 5–7 (worklogs, Mode B/C, Runtime profile, UI polish, performance qualification) remain open.

## 1. Outcome and delivery strategy

Build one durable meeting library, then expose it through four surfaces:

1. Markdown notes during and after a meeting.
2. Assistant meeting cards, local search, grounded answers, and source navigation.
3. Manual Markdown export without Obsidian.
4. Automatic one-way export to Obsidian with a persistent outbox, conflict handling, and worklog layouts.

Deliver in independently testable stages. Do not begin with the Runtime parser and do not put Obsidian file writes on the editor path.

| Stage | Deliverable | User-visible gate | Size for one experienced macOS developer |
|---|---|---|---|
| 0 | Contracts and technical spikes | Storage, Markdown parser, and file-provider decisions proven | 3–5 days |
| 1 | Durable meeting library and migration | Notes/outcomes survive restart; legacy outcomes preserved | 8–12 days |
| 2 | Notes editor and autosave | Write during parallel meetings; local save and recovery work | 8–12 days |
| 3 | Assistant cards, search, and manual export | Notes-only meetings are visible, searchable, and exportable offline | 8–12 days |
| 4 | Obsidian Mode A and outbox | Separate meeting files update live and recover safely | 10–15 days |
| 5 | Assistant/MCP note tools and worklogs/indexes | Modes B/C, history export, and read-only note tools work | 15–22 days |
| 6 | Runtime compatibility and hardening | Existing Runtime-style files update without silent damage | 10–15 days |
| 7 | Full acceptance and release documentation | All 36 acceptance scenarios and performance gates pass | 8–12 days |

The estimates are planning ranges, not a committed calendar. They exclude design-review waits and qualification of unrelated meeting/media behavior. A useful early release is possible after Stage 4; the complete specification is done only after Stage 7.

## 2. Binding design decisions

These decisions close ambiguities in the source specification. Record any product-owner override in the specification before the corresponding stage begins.

### 2.1 Authority and storage

- Rock’N’Roll local storage is authoritative for notes and outcomes. Obsidian is an additional one-way export destination, never the only copy.
- Use the macOS system SQLite3 API behind an actor. Do not use SwiftData: the application deployment target is macOS 13.
- Do not add a database package by default. If SQLite ergonomics become a demonstrated blocker, propose GRDB separately with its compatibility and supply-chain impact; do not introduce it incidentally.
- Use WAL mode, foreign keys, a busy timeout, and `synchronous=FULL` for acknowledged local revisions. “Saved on device” is emitted only after the transaction commits successfully.
- Notes and outcomes no longer use the 90-day outcome pruning or the 200-outcome cap. Existing retention behavior remains only for data categories whose UI explicitly describes that behavior.
- Keep `MeetingOutcome`, `MeetingOutcomeTask`, and their Codable representation as domain DTOs initially. Store the structured outcome payload as JSON plus relational identity/revision/state columns; normalize tasks only if a later measured query requires it.
- Notes remain raw UTF-8 Markdown. A parser/renderer never becomes the stored representation.

### 2.2 Session identity and reconnects

- Create a persisted `MeetingSession` when a new `NativeDesktopMeetingModel` is created and shown, before a user can type notes.
- Reuse `model.sessionID` as the persisted session UUID. Do not derive identity from title, room, calendar series, or outcome ID.
- Transport reconnects inside the same model retain the session. An explicit Leave followed by a new model is a new session, even when the room and title match.
- A failed join leaves no user-visible historical session if it has no notes/outcome and never connected. If the user entered notes, retain the session and mark it `failed`; never delete user content as join cleanup.
- Cross-device continuation does not silently merge local sessions. Link records with the continuation identifier; preserve the same session only if the existing protocol explicitly transfers that exact identity.
- Store UTC instants plus the IANA time-zone identifier captured at session creation. Worklog grouping uses the destination’s configured time zone, not a numeric offset or the Mac’s later time-zone setting.
- Legacy outcomes with `meetingID` use that UUID as their session ID. A legacy outcome without `meetingID` receives one new synthetic session UUID per outcome; never merge such records by title or room.

### 2.3 Revisions and outcome state

Maintain independent note and outcome revisions plus an aggregate export revision:

- `notes.revision` increments for every committed content change, not for cursor/scroll changes.
- `outcomes.revision` increments for summary, decision, task, open-question, owner, due-date, and completion changes.
- `meeting_sessions.export_revision` increments in the same transaction as either content revision or relevant session metadata changes.
- An export snapshot carries the aggregate revision and both component revisions. A worker always loads the newest committed snapshot immediately before rendering.
- Outcome states are `notStarted`, `pending`, `draft`, `ready`, and `failed`. The current generator only has to emit `pending`, `ready`, and `failed`; streaming generation is not new scope.
- Persist `pending` before invoking the writer. On launch, an orphaned `pending`/`draft` generation becomes `failed(interrupted)` unless a live task still owns it. Do not automatically restart a paid/network model call; expose Retry.
- A task suggested by the assistant is not a saved task until the existing confirmation path commits it. A Markdown checklist remains independent of structured tasks.

### 2.4 Empty content and deletion

- The first non-empty note creates the export job. Later emptying the note does not delete the exported file or section.
- If notes are empty but an outcome exists, render an explicit empty-notes state according to the fixed template. If neither notes nor outcome content exists after an earlier export, preserve the managed file/block with an explicit empty state; never auto-delete user files.
- Deleting a meeting locally never deletes Obsidian files or blocks. A separate, explicitly confirmed export-deletion action may be added later; it is not implicit in this work.
- Manual export to another folder never changes automatic bindings or outbox state.

### 2.5 Backups and data clearing

- Before modifying an existing shared file, save a byte-exact backup in the app container under `MeetingLibrary/ExportBackups`, not inside the vault.
- Keep the latest 20 backups per target file for at least 30 days. Prune only older excess backups, never the sole recovery copy; backup failures block a destructive conflict resolution and produce a visible error for ordinary shared-file updates.
- Backups and logs have separate retention rules. Technical logs contain IDs, paths redacted to safe relative components, revisions, error classes, and timings—but no note/outcome/file content.
- Update “delete all Assistant data” UX to state whether sessions, notes, outcomes, search indexes, and recovery backups are included. No existing broad-delete action may leave the user believing notes were deleted when they were not.

### 2.6 Markdown dependency boundary

Use two deliberately separate components:

- A maintained CommonMark/GFM parser for preview only, selected in Stage 0. It must support headings, emphasis, strikethrough, lists, task lists, links, quotes, inline/fenced code, tables, and horizontal rules. Raw HTML/scripts are not executed, and remote images are not loaded automatically.
- An app-owned, byte-oriented Markdown structure scanner for export patching. It recognizes frontmatter only at file start, fenced/indented code, block quotes, ATX headings, comments, and exact managed markers with source byte ranges. It fails closed on ambiguity and never round-trips the whole document through a preview AST.

Do not hand-build a second full Markdown renderer. Do not use global regular-expression replacement for document updates.

## 3. Target architecture

```text
NSTextView notes editor
        │ latest buffer, per-session editor state
        ▼
MeetingNotesController ───────► MeetingLibraryController (MainActor snapshots/status)
                                      │
                                      ▼
                           MeetingLibraryStore (actor)
                    SQLite transaction: content + FTS + outbox
                                      │
                 ┌────────────────────┼─────────────────────┐
                 ▼                    ▼                     ▼
       Assistant/search/tools   Manual exporter      ObsidianExportCoordinator
                                                        │
                                                        ▼
                                               ObsidianExportWorker (actor)
                                                        │
                                  snapshot → template → structure patcher
                                                        │
                                  vault access → conflict check → atomic write
                                                        │
                                               binding/status transaction
```

Rules:

- The editor never waits for Obsidian and never performs file I/O on the main actor.
- A local revision and its required export outbox row commit atomically.
- One outbox row per `(destination_id, session_id)` coalesces to the latest aggregate revision.
- Writes are serialized per canonical target file, not merely per meeting. Different meetings sharing a worklog cannot overwrite one another.
- Mode C may update meeting file and index independently; multi-file atomicity is not claimed. Each binding records its own saved revision, and aggregate success requires both at the same current revision.
- A worker never applies an older snapshot over a newer local revision. It may export an older snapshot only if no newer revision exists at commit time; otherwise it discards the stale render and retries the latest.

## 4. SQLite schema and migration

Create `Application Support/Attention/MeetingLibrary/meetings.sqlite3` through the existing `AttentionStore` root injection so tests remain isolated.

### 4.1 Tables

`schema_migrations`

- `version INTEGER PRIMARY KEY`
- `applied_at INTEGER NOT NULL`

`meeting_sessions`

- `session_id TEXT PRIMARY KEY` — UUID string
- `title TEXT NOT NULL`
- `invitation TEXT` — existing local meeting metadata; never emitted automatically into export metadata
- `room_identity TEXT`
- `calendar_series_id TEXT`
- `continuation_id TEXT`
- `started_at INTEGER NOT NULL`
- `ended_at INTEGER`
- `time_zone_id TEXT NOT NULL`
- `state TEXT NOT NULL` — joining, active, reconnecting, ended, failed
- `export_revision INTEGER NOT NULL DEFAULT 0`
- `created_at INTEGER NOT NULL`
- `updated_at INTEGER NOT NULL`

Indexes on `(started_at, session_id)`, `calendar_series_id`, and `room_identity`.

`meeting_notes`

- `note_id TEXT PRIMARY KEY`
- `session_id TEXT NOT NULL UNIQUE REFERENCES meeting_sessions ON DELETE CASCADE`
- `markdown TEXT NOT NULL`
- `revision INTEGER NOT NULL`
- `created_at INTEGER NOT NULL`
- `updated_at INTEGER NOT NULL`

`meeting_outcomes`

- `outcome_id TEXT PRIMARY KEY`
- `session_id TEXT NOT NULL UNIQUE REFERENCES meeting_sessions ON DELETE CASCADE`
- `state TEXT NOT NULL`
- `payload_json TEXT NOT NULL`
- `revision INTEGER NOT NULL`
- `generation_owner TEXT`
- `error_code TEXT`
- `created_at INTEGER NOT NULL`
- `updated_at INTEGER NOT NULL`

`meeting_search`

- FTS5 table over note Markdown and meeting title, keyed by session ID, if the Stage 0 probe confirms FTS5 on the supported runtime.
- Rebuildable from source tables and therefore never authoritative.
- If FTS5 is unavailable, use a relational `note_chunks` table with deterministic case/diacritic folding; do not disable offline search.

`export_destinations`

- `destination_id TEXT PRIMARY KEY`
- `enabled INTEGER NOT NULL`
- `mode TEXT NOT NULL`
- `config_json TEXT NOT NULL`
- `config_revision INTEGER NOT NULL`
- `vault_bookmark BLOB`
- `created_at`, `updated_at`

`export_bindings`

- `(destination_id, session_id, component)` primary key; component is `meeting`, `worklog`, or `index`
- `relative_path TEXT NOT NULL`
- `marker_id TEXT`
- `day_key TEXT`
- `month_key TEXT`
- `layout_map_json TEXT`
- `last_exported_revision INTEGER NOT NULL DEFAULT 0`
- `last_block_sha256 TEXT`
- `last_file_sha256 TEXT`
- `last_file_identity TEXT`
- `state TEXT NOT NULL`
- `error_code TEXT`
- `conflict_json TEXT`
- `last_success_at INTEGER`
- `updated_at INTEGER NOT NULL`

`export_outbox`

- `(destination_id, session_id)` primary key
- `desired_revision INTEGER NOT NULL`
- `desired_config_revision INTEGER NOT NULL`
- `attempt_count INTEGER NOT NULL DEFAULT 0`
- `next_attempt_at INTEGER NOT NULL DEFAULT 0`
- `paused INTEGER NOT NULL DEFAULT 0`
- `last_error_code TEXT`
- `updated_at INTEGER NOT NULL`

`note_chunks`

- Stable chunk ID, session ID, note revision, ordinal, start/end UTF-8 offsets, start/end lines, and text.
- Rebuilt in the same transaction as a note revision; used for bounded Assistant context and explicit coverage.

### 4.2 Legacy migration

1. Open/migrate SQLite in a transaction before changing `assistant.json`.
2. Read every decodable legacy outcome, including records beyond the limits that would have been pruned by a later save.
3. Create one session per outcome as described in §2.2. Preserve outcome UUID, title, invitation, series, ended time, task IDs, and content exactly.
4. Set migrated outcome revision to 1 and state to `ready`. Use `endedAt` for the session end; use a documented migrated-start value only when no start exists—do not pretend it is an observed start.
5. Verify imported outcome IDs and counts against the decoded source before committing migration bookkeeping.
6. Keep a byte-exact `assistant.pre-meeting-library-backup.json`. Do not prune it as a diagnostic log.
7. Only after successful import, remove `outcomes` from subsequent `assistant.json` writes. A failed migration leaves the legacy file authoritative and blocks dual writes with a visible persistence error.
8. Buffer user edits during migration in memory and flush them only after the repository is ready. Never overwrite the only legacy copy with a partial decode.
9. Previously pruned data cannot be recovered by this migration; release notes must not claim otherwise.

## 5. File-by-file implementation

### 5.1 New meeting-library modules

| New file | Responsibility |
|---|---|
| `NativeMacGuest/MeetingLibrary/MeetingLibraryModels.swift` | `MeetingSession`, `MeetingNote`, revision/state enums, composed meeting card, bounded note chunk, typed errors. Keep DTOs Sendable and independent of SwiftUI. |
| `NativeMacGuest/MeetingLibrary/MeetingLibraryStore.swift` | Actor-owned SQLite connection, prepared statements, transactions, CRUD, revision checks, search queries, and snapshot loading. No UI imports. |
| `NativeMacGuest/MeetingLibrary/MeetingLibrarySchema.swift` | Schema DDL, migrations, integrity checks, FTS capability probe/fallback, and database recovery errors. |
| `NativeMacGuest/MeetingLibrary/MeetingLibraryMigration.swift` | Legacy outcome import, verification, backup, and migration status. |
| `NativeMacGuest/MeetingLibrary/MeetingLibraryController.swift` | MainActor observable catalog of sessions/outcomes/cards, selected historical session, asynchronous repository calls, save/export status projection. |
| `NativeMacGuest/MeetingLibrary/MeetingNotesController.swift` | Per-session draft buffers, 500 ms debounce plus 1 s max-interval throttle, generation fencing, flush-all, disk-full draft retention, and per-session cursor/scroll state. |
| `NativeMacGuest/MeetingLibrary/MeetingNoteSearch.swift` | Query parsing, date/title filters, bounded snippets, note chunk selection, explicit complete/partial coverage. |

Implementation invariants:

- `updateNotes` takes the session ID, exact raw string, and controller generation. The database assigns the content revision. A late completion for generation N must not mark generation N+1 saved.
- `flush(sessionID:)` bypasses debounce and awaits the latest buffer at invocation time. `flushAll()` is called on ordinary Quit before termination is allowed to finish.
- A failed local commit leaves the draft in `MeetingNotesController`, exposes an error, and enables manual draft export. It never displays “Saved on device.”
- Search index updates and note chunks are committed with their source revision. A search result from an older revision is discarded before display if the selected note changed.

### 5.2 Existing persistence and meeting lifecycle files

| Existing file | Required changes |
|---|---|
| `NativeMacGuest/Attention/AttentionStore.swift` | Own one `MeetingLibraryController` and its repository. Inject the same test root. Start migration/load before advertising the library as ready. Keep provider/model behavior unchanged. |
| `NativeMacGuest/Attention/AssistantData.swift` | Keep memories/suggestions JSON persistence. Make `outcomes` a compatibility projection backed by `MeetingLibraryController`; route add/update/remove through the meeting repository. Remove outcome pruning and outcome encoding after migration. Preserve corrupt-file safeguards for remaining data. |
| `NativeMacGuest/Attention/AttentionCoordinator.swift` | Persist outcome pending/ready/failed states. Register generation ownership, write received outcomes through the repository, and emit export revisions from the same commits. Keep model calls off leave-critical media teardown. |
| `NativeMacGuest/DesktopMeetingModel.swift` | Add `.notes` to `Panel`, expose the stable persisted session reference and session timestamps, and do not couple notes lifecycle to microphone/camera/transcription state. |
| `NativeMacGuest/DesktopWorkspace.swift` | Create/close session records at the same commit points as meeting models. Flush notes on meeting switch, panel close, window close, leave, and Quit. Route historical note sources to Assistant cards. Preserve exact reconnect/new-model semantics. |
| `NativeMacGuest/App.swift` | Initialize the meeting library with the workspace. In `applicationShouldTerminate`, await note flush and required local outcome edits before final termination. Keep media cleanup behavior; a local-save failure must be visible and must not be converted into false success. |

Do not block ordinary Quit indefinitely on an unavailable Obsidian destination. Only local durable flushes are on the Quit path; automatic export remains durable and resumes later.

### 5.3 Notes UI and manual export

| New file | Responsibility |
|---|---|
| `NativeMacGuest/Notes/MeetingNotesEditor.swift` | `NSViewRepresentable` around `NSTextView`; per-session undo manager, selection, scroll, find, paste, and formatting shortcuts. Raw string is canonical. |
| `NativeMacGuest/Notes/MeetingNotesView.swift` | Source/preview modes, meeting title, local/export status, and empty/error states. Opening updates never steal focus. |
| `NativeMacGuest/Notes/MarkdownPreviewView.swift` | Safe preview adapter; no script/HTML execution or automatic remote image fetch. Unsupported Obsidian syntax remains visible as source text. |
| `NativeMacGuest/Notes/NoteFormattingCommands.swift` | Heading, bold, italic, strikethrough, lists, checklist, link, quote, code, table, and divider actions operating on raw selections. |
| `NativeMacGuest/ManualExport/MeetingManualExportController.swift` | MainActor panel flow, composition/date selection, collision preview, cancellation, progress, and partial-failure report. |
| `NativeMacGuest/ManualExport/MeetingManualExport.swift` | Consistent local snapshot capture, single/batch/worklog rendering, unique naming, and per-file results. |

Modify:

- `NativeMacGuest/DesktopMeetingView.swift`: add Notes to the inspector switch, toolbar, narrow-window sheet, and accessibility identifiers. The panel remains usable during live transcription updates.
- `NativeMacGuest/DesktopHomeView.swift`: add toolbar access and an Integrations settings tab without reusing existing numeric tags.
- `NativeMacGuest/Attention/AssistantOutcomeViews.swift`: evolve the outcome-only list into session cards keyed by session ID. Show Notes independently of outcome readiness; keep existing outcome editing, reminder, and chat-confirmation behavior. Add Export Markdown actions.
- `RockNRoll/en.lproj` and `RockNRoll/ru.lproj`: add all user-facing strings in both locales; do not hard-code Russian export headings when the UI language is English.

Manual export rules:

- Flush and snapshot the selected sessions first. If local persistence failed, mark the output as an unsaved draft rather than hiding that fact.
- Default to notes, summary, decisions, tasks, and open questions; expose composition selection before saving.
- One meeting may export during an active meeting with an explicit pending-outcome state.
- Batch export uses one file per session or an in-memory combined worklog with stable chronological/insertion ordering and session-ID tie breakers.
- Precompute sanitized names and collisions. `NSSavePanel` replacement is explicit; folder batch collisions require a visible rule before writing.
- Return saved/failed/cancelled meeting lists and allow retry of failures only. Never mutate outbox or Obsidian binding state.

### 5.4 Assistant integration

| Existing/new file | Required changes |
|---|---|
| `NativeMacGuest/Attention/AssistantAgent/AssistantNativeTools.swift` | Add note metadata to `AssistantNativeSnapshot`, `rocknroll_get_notes`, and note search results. Read full notes through async repository hooks rather than embedding the entire library in each turn. Return note ID, session ID, Markdown, revision, updated time, and coverage. |
| `NativeMacGuest/Attention/AssistantAgent/AssistantTalkAgent.swift` | Load the current saved note revision for the selected meeting when building a turn. Include short notes directly; use query-relevant chunks for long notes and state partial coverage. Route note source selection to the meeting card. |
| `NativeMacGuest/Attention/AssistantTalk.swift` | Include note-backed historical meetings in references. For the legacy interpreter path, provide bounded saved-note context where applicable; do not silently enable the agent runtime or a network provider. |
| `NativeMacGuest/Attention/AssistantAgent/AssistantAgentModels.swift` | Add `note` to source kinds and strengthen grounding instructions: personal notes are user-authored claims, not participant agreements; notes/outcomes/transcript remain separately attributed. |
| `NativeMacGuest/Attention/AssistantAgent/AssistantAgentRuntime.swift` | Preserve note evidence through tool calls and completed responses. No automatic model request is triggered by note edits or indexing. |
| `NativeMacGuest/Attention/AssistantData.swift` | Extend deterministic retrieval to note snippets while keeping memory/outcome provenance distinct. |
| `NativeMacGuest/Attention/AssistantAgent/AssistantTalkAgent.swift` source-chip UI | Add a note icon and an enabled source action. A chip is not merely decorative: it opens the correct historical/active meeting and Notes section. |
| `NativeMacGuest/DesktopWorkspace.swift` | Implement the historical source router and selected-card handoff. |

Privacy requirement: the existing provider host/settings UI must state that notes are included only when the user asks the Assistant and the selected provider is remote. Indexing and local search remain offline and make no model call.

### 5.5 Export templates and byte-preserving patching

| New file | Responsibility |
|---|---|
| `NativeMacGuest/MarkdownExport/MeetingMarkdownTemplate.swift` | Fixed templates for meeting file, full worklog entry, and index entry. Flat YAML encoding, explicit pending/empty/draft states, selected components, schema version, aggregate revision. |
| `NativeMacGuest/MarkdownExport/MarkdownStructureScanner.swift` | Byte ranges for frontmatter, headings, code, quotes, comments, day sections, and exact markers. Ambiguity returns a typed conflict, never a guessed patch. |
| `NativeMacGuest/MarkdownExport/ManagedBlock.swift` | Marker grammar with full session UUID, component, schema version, and a per-binding nonce. Parse exact pairs and compute base hashes. |
| `NativeMacGuest/MarkdownExport/MarkdownFilePatcher.swift` | Replace only owned ranges and owned YAML keys while preserving all other bytes. Reject missing, duplicated, nested, or damaged ownership boundaries. |
| `NativeMacGuest/MarkdownExport/WorklogLayout.swift` | Monthly/permanent targets, intro/work-area/outro map, start/end insertion, day grouping, within-day ordering, late historical insertion, stable batch order. |
| `NativeMacGuest/MarkdownExport/ObsidianLinks.swift` | Relative Obsidian links for spaces, Cyrillic, nested paths, aliases, and reserved characters. |
| `NativeMacGuest/MarkdownExport/RuntimeWorklogProfile.swift` | “Like Runtime” defaults, historical year-assignment model, short-date parsing, explicit year separators, synthetic onboarding preview. |

Marker handling:

- Marker syntax in the specification is illustrative; include a stored nonce so a note containing marker-like text cannot forge ownership.
- Scanner-recognized markers inside fenced code or quotes are not structural. Marker-like lines inside an existing managed block are content unless they exactly match its active terminal marker; such a collision on creation regenerates the nonce or raises a conflict.
- Raw local notes are never normalized. Export may add headings/wrappers but cannot drop unsupported syntax.
- Separate meeting files use one frontmatter block. Shared worklogs never receive per-meeting YAML islands or forced frontmatter.

Patch algorithm for every update:

1. Resolve the persisted binding and security-scoped vault access.
2. Read bytes and record file identity, size, modification time, and SHA-256.
3. Parse structure. Verify session ID, component, marker nonce, and last managed-block hash against the binding.
4. If the managed block differs from its base, report `managedBlockConflict`. If only bytes outside owned ranges differ, allow a splice that preserves those exact bytes.
5. Render the new owned block from the latest local snapshot. Produce a candidate by replacing byte ranges only.
6. Re-read/fingerprint immediately before commit and coordinate through `NSFileCoordinator` where supported. If the file changed, discard the candidate and re-evaluate; never overwrite from the stale read.
7. For shared files, write the required recovery backup. Write a temporary regular file in the same directory, flush it, atomically replace the target, and preserve expected permissions/metadata where supported.
8. Verify the resulting file and then commit binding success. A crash before the state commit is safe because retry compares actual managed content/base and remains idempotent.
9. Document the remaining third-party race window honestly. Atomic replacement prevents partial files; it is not an unconditional lock against every external process.

### 5.6 Vault access, queue, conflicts, and settings

| New file | Responsibility |
|---|---|
| `NativeMacGuest/Obsidian/ObsidianModels.swift` | Destination mode, layout/components configuration, outbox/binding states, typed transient/conflict errors, user status projection. |
| `NativeMacGuest/Obsidian/ObsidianVaultAccess.swift` | `NSOpenPanel`, security-scoped bookmark create/resolve/stale handling, scope lifetime, path validation, regular-file/symlink/hardlink checks, file-provider errors. |
| `NativeMacGuest/Obsidian/ObsidianExportCoordinator.swift` | MainActor settings/status projection, start/stop/resume, manual retry, mode switch preview, conflict actions, and history-export selection. |
| `NativeMacGuest/Obsidian/ObsidianExportWorker.swift` | Actor loop, revision coalescing, per-target serialization, exponential retry capped at 60 seconds, restart recovery, and destination enable/disable behavior. |
| `NativeMacGuest/Obsidian/ObsidianFileWriter.swift` | Coordinated read/check/backup/temp/replace/verify operations with injectable fault points. |
| `NativeMacGuest/Obsidian/ObsidianConflictView.swift` | Two-version diff and exact actions: apply latest Rock’N’Roll with backup, save a separate copy, or pause this meeting. |
| `NativeMacGuest/Obsidian/ObsidianSettingsView.swift` | Integrations UI, vault/mode/layout/components/time-zone settings, path/template preview, access check, last success, pending/conflict counts, Open File and Retry. |
| `NativeMacGuest/Obsidian/ObsidianStatusView.swift` | Local versus Obsidian statuses in editor/cards; aggregate Mode C success only when both bindings are current. |

Path and destination rules:

- A `.obsidian` directory is not required. Never write to it.
- Permanent worklogs/indexes must resolve inside the selected vault. Reject absolute relative-path inputs, `..`, normalized escapes, symlink escapes, non-regular targets, and unsafe generated names.
- Store paths relative to the vault after creation. Meeting-title changes update document content, not the fixed filename.
- Handle stale bookmarks, revoked access, missing volumes, dataless/file-provider materialization failures, full disks, and permission errors as visible states. Retry only transient errors automatically.
- Disabling integration stops new attempts and retries but leaves queue/bindings/local originals intact. A write already in flight may finish and is reported accurately. Re-enabling offers to resume.
- Changing mode/folder shows creations first and deactivates the previous destination. It does not delete old files or silently export all history. Active meetings and subsequently changed meetings use the new destination; historical migration is a separate period-selected, previewed, idempotent action.
- “Save a separate copy” does not mark the original binding current. “Apply Rock’N’Roll” always uses the latest local revision and creates a backup first.

### 5.7 Worklog placement and Runtime onboarding

Implement placement as a pure function:

```text
(existing bytes, persisted layout map, ordered new managed entries, configuration)
    -> either patched bytes + updated layout map or PlacementConflict
```

- Start/end and day grouping are independent. Existing entries never move because their content or the setting changed.
- Batch export determines order once using start time and session UUID; retries reuse persisted placement.
- With grouping, match only unambiguous full internal day keys. Do not create empty days.
- Missing historical days are inserted among recognized dates without reordering unrelated content. Ambiguous boundaries produce a placement conflict and location picker.
- Meetings crossing midnight/month boundaries use session start in the destination time zone. Late outcomes patch the original binding.
- Permanent files do not rotate at month boundaries.
- Runtime onboarding detects candidate day headings outside code/quotes, shows inferred year ranges and intro/work/outro boundaries, and requires correction where ambiguous.
- `9.11` and `09.11` may share a full day key only within an agreed year; duplicate physical sections are never silently merged.
- Rock’N’Roll owns only its marked meeting blocks within an existing day, never the whole day or a same-named manual “Daily.”
- Short dates across years receive an explicit year separator plus full internal metadata; old headings are not rewritten.
- Reordering/regrouping old content is a separate previewed action with backup, not a side effect of settings changes.

All Runtime fixtures are synthetic. Never use the referenced personal `Runtime.md` in tests, previews committed to the repository, or destructive validation.

### 5.8 MCP and offline profile

Current baseline is 13 native tools/eight native read-only tools and seven offline tools. Add one read-only tool to each profile; do not describe the seven-tool offline allowlist as the whole native surface.

Modify:

| File | Changes |
|---|---|
| `mcp/CONTRACTS.md` | Define `rocknroll_get_notes(meeting_id)` first. Accept a persisted/active `session:` ID; optionally accept `outcome:` only by an explicitly documented mapping. Return raw Markdown, note/session IDs, revision, updated time, provenance, coverage, and warnings. Extend search enum with `note`. |
| `NativeMacGuest/MCP/MCPToolSchemas.swift` | Add the declarative schema under `meetings:read`, read-only annotation, `note` search enum, and note capability. Bump the app’s MCP implementation version to 0.3.0 without changing the MCP protocol version. |
| `NativeMacGuest/MCP/MCPCore.swift` | Add backend protocol requirement and dispatch. Scope check and structural validation remain before handler execution. |
| `NativeMacGuest/MCP/NativeDesktopMCPBackend.swift` | Resolve active and persisted sessions, expose `has_notes`/note ID on cards, read exact committed revisions, and search notes with source provenance. Historical `session:` cards no longer require an active media model; transcript restrictions remain unchanged. |
| `NativeMacGuest/Attention/AssistantAgent/AssistantMCPLoopback.swift` | Expose and dispatch the new read-only tool without widening write scopes. |
| `mcp/rocknroll_local.py` | Add equivalent offline handler/schema/search type and allowlisted synthetic note fixture loading. |
| `mcp/rocknroll_native.py` | Update only if its transport/catalog assumptions require it; do not duplicate a hard-coded tool list unnecessarily. |
| `mcp/examples/tools-list.native.json` | Regenerate from live declarations; contract test must prove exact parity. |
| `mcp/fixtures/MeetingLibrary/notes.json` | New synthetic persisted-note fixture with revisions and session links; no business/personal content. |
| `mcp/README.md` | Update tool counts, scope, examples, reconnect/catalog refresh instructions, and read-only guarantees. |
| Client connection documentation | Refresh cached catalogs/allowlists. No write scope or filesystem-control tool is introduced. |

## 6. Test plan and new files

### 6.1 Unit and integration tests

Add under `NativeMacGuest/Tests/Parity` so the existing `NativeDesktopTests` target includes them:

| Test file | Coverage |
|---|---|
| `MeetingLibraryTests.swift` | Schema migration, CRUD, independent/aggregate revisions, atomic content+outbox commits, legacy identity, no retention pruning, corrupt migration rollback, restart recovery. |
| `MeetingNotesControllerTests.swift` | Debounce, continuous-input throttle, latest-generation fencing, switch/panel/Quit flush, disk-full buffer, per-session editor state. |
| `MeetingNoteSearchTests.swift` | Cyrillic, title/date filters, snippets, revision invalidation, chunk limits, explicit partial coverage, no model invocation. |
| `MeetingMarkdownTemplateTests.swift` | All components, empty/pending/draft outcomes, YAML escaping, UTF-8, unsupported syntax preservation, fixed paths and title changes. |
| `MarkdownStructureScannerTests.swift` | Frontmatter, headings, fenced/indented code, quotes, comments, marker lookalikes, malformed/nested/duplicate markers, byte-range exactness. |
| `MarkdownFilePatcherTests.swift` | External-only edits, managed-block conflicts, idempotent retries, unrelated-byte preservation, owned YAML keys only. |
| `WorklogLayoutTests.swift` | Every start/end/grouping combination, same-day meetings, late history, month/midnight/DST boundaries, permanent files, setting changes without reorder. |
| `RuntimeWorklogProfileTests.swift` | Synthetic short/long dates, duplicate sections, year inference/conflicts, non-date headings, pinned intro/outro, manual Daily preservation. |
| `ObsidianVaultAccessTests.swift` | Bookmark staleness, revoked/missing access, normalized escape, symlink/non-regular targets, safe Unicode filenames, no `.obsidian` writes. |
| `ObsidianExportWorkerTests.swift` | Coalescing, per-file serialization, retry backoff, pause/disable/resume, crash/restart, stale revision prevention, Mode C partial success and convergence. |
| `ObsidianFileWriterTests.swift` | Injected failures before/after temp write/replace/state commit, external write races, backup success/failure, atomicity and recovery. |
| `MeetingManualExportTests.swift` | Offline single/batch/worklog export, active meeting, collision rules, cancellation, partial success, independent outbox state. |
| `AssistantNotesTests.swift` | Note-only cards, saved-revision context, source distinction/navigation, no automatic network calls, no task/checklist conflation. |
| Existing `MCPSchemaContractTests.swift` and `MCPNativeTests.swift` | New tool schema, scope denial, validation, catalog parity, active/historical reads, note search/provenance, no write behavior. |
| Existing `AssistantAgentTests.swift` | Snapshot/tool fixtures, note evidence, long-note coverage, stale IDs, source routing. |
| Existing `AssistantUIAcceptanceTests.swift` | Live meeting notes, parallel meeting switching, notes-without-outcome, export statuses, conflict UI, keyboard accessibility. |

Add synthetic fixture resources to `NativeMacGuest/Tests/Fixtures` and include them in the test target in `NativeMacGuest/project.yml`. Production Swift files under `NativeMacGuest` are already discovered by the target; only a new package dependency or non-Swift fixture resources should require project-spec changes.

Extend `mcp/tests/test_rocknroll_local.py` for eight offline tools, schema parity, malformed arguments, note reads, note search, pagination, and source provenance.

### 6.2 Randomized and fault-injection tests

- Property-test patch idempotence: applying the same desired snapshot twice produces identical bytes and no new entry.
- Property-test unrelated-byte preservation for arbitrary valid UTF-8 prefix/infix/suffix content around managed blocks.
- Generate nested fences, quotes, CRLF/LF samples, Cyrillic, combining characters, large tables, and marker-like user content. Unsupported/ambiguous structures fail closed.
- Interleave two meetings writing one worklog; verify both final blocks and all manual text.
- Inject crashes after local content commit, after outbox commit, before file replace, after file replace, between meeting/index writes, and before binding success commit.
- Fault-inject full local disk separately from full vault disk. The former keeps an unsaved memory buffer and never claims local success; the latter keeps locally saved data queued.

### 6.3 Performance evidence

Use notes of 100 KiB and worklogs of 5 MiB on the supported local-disk baseline:

- Record local-save latency after 500 ms idle and during at least 60 seconds of continuous input; confirmed writes occur at least once per second.
- Record enqueue-to-vault latency and verify the two-second normal-operation target.
- Measure main-thread stalls, CPU, memory, temp-file growth, and repeated full-file updates.
- Publish p50/p95/max over a documented run count and hardware/macOS configuration. A synthetic unit test alone is not performance qualification.
- Test process crash separately from power loss. Only committed-revision recovery is claimed for process crash; power-loss guarantees are limited to what the measured SQLite/filesystem configuration actually demonstrates.

### 6.4 Build and regression gates

Run after each stage:

```sh
python3 NativeMacGuest/build.py --compile-only \
  --output-dir .build/native-notes-obsidian-build
python3 -m unittest discover -s mcp/tests -v
bash NativeMacGuest/test-standalone.sh
bash NativeMacGuest/test-rock.sh \
  --framework-root .build/webrtc-m156-desktop-audio/native-framework-r4
```

Run the generated `RockNRollNativeGuest` scheme’s `NativeDesktopTests` through Xcode/xcodebuild with the same pinned dependency root. Add a focused `-only-testing:NativeDesktopTests/<suite>` invocation for each new suite and then run the full target. Do not substitute a lightweight standalone Swift compile for the application target when UI, SQLite, bookmarks, or MCP integration changed.

At final acceptance, rerun existing Assistant, MCP schema, UI accessibility, update-safety, and media regression suites. No note/export change may alter microphone/camera ownership, leave-critical media teardown, update admission, or existing write-scope approvals.

## 7. Acceptance traceability

The source specification’s numbered scenarios are release gates, not optional examples.

| Spec scenario | Primary implementation/test owner | Stage |
|---|---|---|
| 1. Notes during active meeting | `MeetingNotesView`, `MeetingNotesControllerTests`, UI acceptance | 2 |
| 2. Continuous input then crash | SQLite commit tests + process-crash integration | 1–2, 7 |
| 3. Parallel meetings | Per-session buffers/editor state and UI acceptance | 2 |
| 4. Same room/title and reconnect | `DesktopWorkspace`, `MeetingLibraryTests` | 1 |
| 5. Markdown/tables/code/Cyrillic/wikilinks | Editor raw preservation, preview, template tests | 2–4 |
| 6. No transcript/outcome failure | Independent notes repository and UI/export tests | 1–4 |
| 7. Assistant notes/outcomes/sources | `AssistantNotesTests`, source router | 3, 5 |
| 8. First note creates file during meeting | Outbox + Mode A integration | 4 |
| 9. Outcome arrives with UI closed | Repository outcome handler + worker integration | 4 |
| 10. Repeated updates without duplicates | Revision coalescing/idempotence tests | 4 |
| 11. Multiple meetings in monthly worklog | Per-file gate + `WorklogLayoutTests` | 5 |
| 12. Month boundary and late outcome | Binding/month-key tests | 5 |
| 13. Mode C crash between file and index | Fault-injection worker tests | 5 |
| 14. Obsidian closed | Direct file integration test | 4 |
| 15. Revoked/missing/full vault destination | Vault/worker faults and local durability | 4 |
| 16. Edit outside managed block | Byte-preserving patcher test | 4 |
| 17. Edit managed block/remove markers | Conflict UI and no-overwrite tests | 4 |
| 18. Concurrent third-party writer | Coordinated writer race tests + documented limitation | 4, 7 |
| 19. Rename meeting/retry/restart | Fixed binding path tests | 4 |
| 20. Change mode/folder | Destination preview and migration tests | 5 |
| 21. MCP read/search | Native/offline schema and backend tests | 5 |
| 22. Obsidian never installed/configured | Local library/manual export tests | 1–3 |
| 23. Delete/move vault or disable integration | Local original/binding/queue tests | 4 |
| 24. Offline single Markdown export | Manual export integration | 3 |
| 25. Batch separate files and worklog | Manual batch/template tests | 3, 5 |
| 26. Cancel/collision/partial failure | Manual export controller tests | 3 |
| 27. Active meeting before outcome | Pending template + independent outbox | 3–4 |
| 28. Local application disk full | Controller buffer/draft-export test | 2–3 |
| 29. Ungrouped start/end and fixed intro/outro | `WorklogLayoutTests` | 5 |
| 30. Grouped days and both directions | `WorklogLayoutTests` | 5 |
| 31. Existing Runtime day | Synthetic Runtime fixture | 6 |
| 32. Late update stays in old block/day | Binding and no-move tests | 5–6 |
| 33. Mixed date formats/code/non-date headings | Scanner/Runtime ambiguity fixtures | 6 |
| 34. Same day/month in different years | Full day keys/year separators | 6 |
| 35. Permanent worklog across month | Permanent-target tests | 5 |
| 36. Change ordering on populated worklog | Existing-block/no-resort tests | 5 |

## 8. Stage execution checklist

### Stage 0 — contracts and spikes

- [ ] Review §2 decisions and fold any overrides into the specification.
- [ ] Probe SQLite FTS5 and commit latency on macOS 13 baseline.
- [ ] Select/pin the preview Markdown parser only after the required GFM/security matrix passes.
- [ ] Prove `NSTextView` source/preview editing with a 100 KiB document.
- [ ] Prove bookmark restore, atomic replacement, and file identity checks on local storage and one supported file provider.
- [ ] Write synthetic Runtime and adversarial Markdown fixtures before parser code.

Exit: no unresolved storage/parser dependency choice; no real user document used.

### Stage 1 — durable library

- [ ] Add schema, actor store, controller, migration, and revision/outbox transaction.
- [ ] Wire meeting session creation/end and legacy outcome projection.
- [ ] Remove outcome retention/cap behavior without changing memory retention inadvertently.
- [ ] Persist outcome state and orphaned-generation recovery.
- [ ] Pass migration, reconnect, crash, and existing Assistant outcome regression tests.

Exit: all existing outcomes plus new notes/outcomes are durable and independently addressable.

### Stage 2 — editor and autosave

- [ ] Add raw source editor, preview, formatting, status, and panel integration.
- [ ] Implement debounce/throttle/flush/generation fencing and editor-state caching.
- [ ] Handle disk failure without false saved state.
- [ ] Verify parallel meetings, no focus theft, no media-state coupling, and ordinary Quit flush.

Exit: local notes alone provide useful value without Obsidian or a model.

### Stage 3 — cards, search, manual export

- [ ] Convert outcome list to meeting cards with notes-only/pending/failed states.
- [ ] Add local note search/chunks and source navigation.
- [ ] Add single/batch/worklog manual export and collision/partial-failure UI.
- [ ] Add local disk-full draft export and offline acceptance.

Exit: every locally available note/outcome is viewable and manually exportable without network/Obsidian.

### Stage 4 — Mode A automatic export

- [ ] Add vault access, destination configuration, worker, writer, marker/template/patcher, backups, conflicts, and settings/status UI.
- [ ] Generate separate files on first non-empty note and on every later relevant revision.
- [ ] Prove retry/restart/idempotence/conflict/no-duplicate behavior and Obsidian-closed operation.
- [ ] Measure save/export latency and external-editor races.

Exit: an early release may be considered with only Mode A explicitly exposed; incomplete modes must not appear selectable.

### Stage 5 — complete Assistant/MCP and Modes B/C

- [ ] Finish Assistant context/evidence in both agent and legacy paths.
- [ ] Add native/offline `rocknroll_get_notes`, note search, contracts/catalog/docs.
- [ ] Add full worklog, meeting+index, monthly/permanent targets, grouping, placement, mode switching, and history migration.
- [ ] Make Mode C the default only after both components pass convergence tests.

Exit: all standard Obsidian modes and read-only integrations work without Runtime-specific legacy ingestion.

### Stage 6 — Runtime profile

- [ ] Add onboarding preview, historical year mapping, pinned regions, and synthetic Runtime fixtures.
- [ ] Resolve duplicates/ambiguities through UI, never silent merges.
- [ ] Add year separators and preserve existing formatting byte-for-byte outside owned ranges.

Exit: the complete Runtime acceptance matrix passes on synthetic copies.

### Stage 7 — full qualification

- [ ] Automate and record all 36 scenarios with explicit evidence.
- [ ] Run performance, crash, power-loss-scope, file-provider, accessibility, localization, and full regression gates.
- [ ] Update `NativeMacGuest/README.md`, add `docs/meeting-notes-obsidian.md`, and document supported destinations, one-way semantics, backups, conflicts, retention, manual export, and limitations.
- [ ] Confirm no personal/business reference content, invitation secrets, tokens, or file contents entered logs/fixtures.

## 9. Release blockers and non-goals

Hard blockers:

- Any silent loss of a committed local revision.
- Any automatic overwrite of a changed managed block or ambiguous worklog region.
- Any outcome pruning under the old retention rules after migration.
- Any new note export dependent on an open meeting/Assistant screen.
- Any duplicate file/section after retry or restart.
- Any “Saved” status before the corresponding durable commit.
- Any automatic model request caused merely by editing/indexing notes.
- Any write through MCP or expansion of write scopes.
- Any test against the real referenced Runtime document.

Unchanged non-goals for this work:

- Full two-way Obsidian synchronization or collaborative editing.
- A mandatory Obsidian plugin or a running Obsidian process.
- A new cloud service, audio recording system, or streaming outcome generator.
- Automatic transcript export.
- Executable user-defined templates.
- Daily/weekly/project layouts beyond the architecture’s future extensibility.

The feature is complete only when local notes/outcomes are permanent and independently usable, automatic exports converge after failures, and every automatic Markdown modification is bounded, explainable, and recoverable.
