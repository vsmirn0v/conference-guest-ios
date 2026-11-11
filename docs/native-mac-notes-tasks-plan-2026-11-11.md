# Native Mac notes, tasks and Obsidian implementation plan

Date: 11 November 2026. Status: implementation proposal; product code has not been changed by this task.

Implement the seven requested features by extending `NativeMacGuest` and the existing `MeetingLibrary` SQLite database. First establish document, title, task and export revision ownership; then build the UI and automatic delivery on those contracts. The two highest-risk workstreams are lossless Live Preview and safe export/recovery under concurrent edits.

Inputs: [feature specification](/Users/v.smirnov/Downloads/ROCKNROLL_NOTES_TASKS_AUTOSYNC_SPEC.md), [design draft](native-mac-notes-tasks-design-2026-11-11.md). Source baseline inspected: local `main`, commit `440a7e6797da967a0b3c4a00efbb1b797359365a`. Findings below are source observations, not runtime test results. Recheck the checkout before implementation; avoid unrelated iOS/media work and existing untracked files.

## Existing components and concrete gaps

Paths below are relative to `NativeMacGuest`.

| Area | Reuse | Gap to close |
| --- | --- | --- |
| Session identity and storage | [MeetingLibraryModels.swift](../NativeMacGuest/MeetingLibrary/MeetingLibraryModels.swift), [MeetingLibrarySchema.swift](../NativeMacGuest/MeetingLibrary/MeetingLibrarySchema.swift), [MeetingLibraryStore.swift](../NativeMacGuest/MeetingLibrary/MeetingLibraryStore.swift) | Schema v2 has one notes row and one outcome row per session. Title has no separate user override; start date is mandatory. Legacy import copies end time into start time. Historical outcome versions need a head/history relationship. |
| Autosave | [MeetingNotesController.swift](../NativeMacGuest/MeetingLibrary/MeetingNotesController.swift) | Debounce and generation fencing exist, but the first continuous edit never reaches the one-second deadline because it depends on a previous attempt. Drafts do not publish changes; there is no editor lease or durable-revision conflict contract. |
| Editor | [MeetingNotesEditor.swift](../NativeMacGuest/Notes/MeetingNotesEditor.swift), [MeetingNotesView.swift](../NativeMacGuest/Notes/MeetingNotesView.swift), formatting commands | Raw `NSTextView`, per-view text state and whole-string external replacement; no Live Preview. Refactor away from required active `NativeDesktopMeetingModel`. |
| Outcomes | [AssistantOutcomeViews.swift](../NativeMacGuest/Attention/AssistantOutcomeViews.swift) | Flat list. Ready-outcome detail omits notes; other paths show read-only raw notes. No session rename or day grouping. |
| Assistant navigation | [AttentionMomentsView.swift](../NativeMacGuest/Attention/AttentionMomentsView.swift) | Moments / Outcomes / Talk only. Add a stable section identity and My Tasks. |
| Tasks and generation | [AssistantData.swift](../NativeMacGuest/Attention/AssistantData.swift), [AttentionCoordinator.swift](../NativeMacGuest/Attention/AttentionCoordinator.swift) | Tasks have UUID, owner string, due/reminder time and done. No profile archive, completion timestamp or date precision. Generation directly replaces the tasks array. |
| Personal selection | [AssistantNativeTools.swift](../NativeMacGuest/Attention/AssistantAgent/AssistantNativeTools.swift), `AssistantData.absorbOutcome` | Current “mine” logic includes unassigned tasks; native tool output takes 50. Neither is suitable as the My Tasks query. |
| Export queue | [ObsidianExportCoordinator.swift](../NativeMacGuest/Obsidian/ObsidianExportCoordinator.swift), [ObsidianExportWorker.swift](../NativeMacGuest/Obsidian/ObsidianExportWorker.swift) | One enabled flag, only separate files. Note/outcome commits queue enabled destinations immediately; no end/first-ready distinction or frozen initial snapshots. Worker polls every two seconds and reads latest fields separately. |
| Binding and ordering | `ObsidianExportWorker.export`, `MeetingLibraryStore.completeOutbox` | Worker derives the target from the current title even with an existing binding. It checks the same captured revision after writing and deletes outbox by session/destination, risking loss of work queued during delivery. |
| File protection | [MarkdownStructureScanner.swift](../NativeMacGuest/MarkdownExport/MarkdownStructureScanner.swift), [MarkdownFilePatcher.swift](../NativeMacGuest/MarkdownExport/MarkdownFilePatcher.swift), [ObsidianFileWriter.swift](../NativeMacGuest/Obsidian/ObsidianFileWriter.swift) | Reuse fence-aware scanning, managed blocks, hashes, backups and replacement. Fingerprint is obtained after the earlier content read; recheck/replace still has a race. No complete multi-file convergence or conflict comparison UI. Verify first-file creation separately. |
| Manual export | [MeetingManualExportController.swift](../NativeMacGuest/ManualExport/MeetingManualExportController.swift) | Single and batch export exist. A failed flush flags an unsaved draft but snapshots the stored note rather than the current buffer. Add consistent snapshots, worklog export, selection/period UI and per-file result presentation. |
| Quit | [App.swift](../NativeMacGuest/App.swift) | Flush is awaited, but errors are not returned and termination proceeds. Add a last-editor/quit decision before allowing buffer loss. |
| MCP and assistant context | [NativeDesktopMCPBackend.swift](../NativeMacGuest/MCP/NativeDesktopMCPBackend.swift), [MCPToolSchemas.swift](../NativeMacGuest/MCP/MCPToolSchemas.swift), native tool/context records | Preserve outcome/task IDs and permissions. Add effective titles and archive semantics to all projections; the MCP owner substring filter is not personal identity matching. |

The existing library already keeps migrated outcomes outside the legacy Assistant retention cap. Preserve that separation; export success must never become a condition for deleting originals.

## Domain model and ownership

### One session, one notes document

Evolve `MeetingNotesController` into a registry of observable session documents. Each document owns the current Markdown buffer, edit generation, committed revision/text, save state, pending persistence and one editing lease. Views keep only selection/scroll/layout state. Key all lookup and window creation by `sessionID`.

Send text-range edits against a document generation, not independent full view snapshots. The initial lease policy rejects stale senders and transfers editor ownership explicitly. Async hydration must not overwrite typing or populate a newly selected session with an old response. Keep undo history with the editing document/session; a source/preview toggle only changes rendering. Preserve input method composition during formatting and lease changes.

Track `firstDirtyAt` independently of last save attempt. Schedule at the earlier of last edit + 500 ms and dirty interval start + 1 s. Subsequent continuous commits keep a one-second maximum interval. A completed commit only marks its captured generation saved; further edits remain dirty. Lifecycle flush returns a structured result per document. Store failures preserve the buffer and feed close/quit recovery.

### Session title and dates

Add nullable `userTitle`, retained `originalTitle`, title revision and a single `effectiveTitle` projection. Validate/trim a rename and atomically commit the override, search keys, export revision and eligible export intent. Provider/calendar/generator updates cannot overwrite it. Update source links in tasks and MCP through the projection, not copied view labels.

Represent trustworthy start and end timestamps independently, with provenance for imported end-time fallbacks and unknown values. Do not reinterpret an arbitrary equal start/end pair as proof of migration: use migration metadata or the original legacy record when available. Preserve uncertain values and record their provenance rather than guessing. Group by start, else end, else Unknown; never by generation/update time. Store display time zone separately from each export destination's fixed grouping zone.

### Stable tasks and historical outcomes

Keep `MeetingOutcomeTask` as the public model and move mutable task ownership into canonical task rows in the **same** SQLite library, through one transactional migration. This is normalization of the existing store, not a second writable task database. Existing JSON payloads become historical snapshots; current DTOs compose their structured task section from canonical rows. All edit paths, including already-authorized MCP writes, call the same task mutation service.

Proposed additions:

| Record | Key and purpose |
| --- | --- |
| `meeting_tasks` | Existing task UUID plus session ID; owner text/stable assignee ID, due value and precision, reminder, done, nullable completedAt, revision |
| `outcome_task_links` | Existing outcome ID + original task ID → canonical task; preserves old MCP addressability |
| `task_profile_state` | Profile ID + canonical task ID; archivedAt nullable; archive is independent of done |
| `task_owner_aliases` | Profile ID + confirmed normalized full alias, with original display value |
| `meeting_outcome_heads` | Session → current outcome/version, permitting history without duplicate meeting cards |
| `task_reconciliation_candidates` | Proposed changes awaiting user resolution; excluded from operational task queries |

Remove the schema's one-outcome-per-session uniqueness only as part of the head/history migration. Preserve every old outcome ID. Never combine historical sessions by title. Missing task IDs are assigned and written once during migration; repeated decoding cannot mint a different identity. Preserve explicit IDs, owners, due/reminder values and done. Legacy completedAt remains unknown; do not invent completion timestamps. Legacy due instants retain current interpretation unless original precision is available.

Generation output is a proposal, applied transactionally. Reuse explicit stable references when present. On first generation, assign stable task IDs once. On regeneration without trustworthy references, keep canonical tasks and stage candidates for review; no text-only deduplication or automatic removal. Link/Add/Dismiss choices establish explicit identity. Outcome generation itself is unchanged.

Use one `PersonalTaskQuery`/visibility policy for My Tasks, meeting operational task rows, badges, search, recommendations, reminders and MCP personal lists. Stable assignee ID wins; otherwise compare confirmed full aliases after case/whitespace normalization only. Unassigned tasks are not personal by default. Ownership transfer must not inherit another profile's archive.

Archive commits persist the profile flag and a reminder-cancellation intent together. The existing producer is `AttentionCoordinator.scheduleOutcomeReminder`, using notification IDs `meeting-task-<task UUID>`; `remind(_:in:)` records the reminder after scheduling. Add profile-aware ownership, cancellation and restart reconciliation to that path, including cancellation of legacy IDs. Check eligibility immediately before scheduling and again on foreground delivery where possible. Persist cancellation intents so interrupted cancellation is retried; account for the OS delivery race explicitly. Restore does not send overdue notifications in a burst. Calendar meeting reminders remain separate.

## Live Preview implementation direction

Keep an AppKit editor hosted in SwiftUI. Prototype a source-preserving TextKit rendering layer and a formal CommonMark/GFM parser before choosing the final layout implementation. Apple exposes content/layout APIs suitable for native text rendering; this does not establish that our Markdown behavior or performance is already solved. [Apple TextKit 2 overview](https://developer.apple.com/videos/play/wwdc2021/10061/).

Evaluate a pinned compatible revision of `swift-markdown` as the parser behind a small adapter; the project supplies Markdown parsing and tree APIs. Preserve original source independently of any AST serialization. Verify source-range behavior, tables, strikeout and checkbox representation with the selected version. [Swift Markdown repository](https://github.com/swiftlang/swift-markdown).

The parser emits spans tied to a buffer generation. Convert UTF-8/parser offsets to AppKit UTF-16 ranges deliberately. Apply attributes and layout only to invalidated blocks; discard stale parse results. Nested structures and opening/closing fences can expand the invalidation region. Never parse Markdown with domain-specific keyword lists or use display HTML as the canonical document.

For inactive syntax, render formatting and table/rule layout in the same editor; expose editable source around the caret. No HTML execution or automatic network resource loads. Keep code ranges opaque to inline formatting. An attachment-based table experiment is acceptable only if selection, source mapping, copy/paste and undo round-trip remain lossless. Failure of that experiment means revise the rendering approach, not ship a separate preview as completion of the requirement.

Gate: ordinary editing in a 100 KiB fixture has p95 edit-to-formatted-paint ≤150 ms on a recorded supported Mac. Measure first open and bulk paste separately. Include emoji, Cyrillic, combining characters, bidirectional text, IME, long code and nested lists in correctness checks. Fix the Mac model, macOS version, build mode, sample count and measurement method before judging the target.

## Export state machine

### Policy and immutable snapshots

Extend the destination config with master enabled, after-end A, sync B, format, relative paths, content selection, ordering and a pinned grouping time zone. Persist preferences even without vault access. Separate **permission**, **transport availability**, and **conflict**: reconnecting a vault resumes eligible access retries; re-enabling preferences does not replay paused work.

Replace the generic “queue every enabled destination” rule with typed intents:

- `initialEnd`: one idempotent final-participation event per session/destination.
- `initialFirstReady`: the first complete outcome snapshot, part of A even when B is off.
- `linkedUpdate`: new exportable revisions under B, only for a successfully linked session.
- `manualSave`: explicit save into Obsidian; creates a link only after required components succeed.
- `manualAccumulated`: explicit selection of held work after a preview.

Persist an immutable export snapshot and its intent in the same transaction as the relevant local revision, or use a recovery journal with equivalent guarantees. Snapshot title, notes, outcome status/content and canonical tasks together. Initial end/first-ready snapshots remain frozen under A on/B off. A transport retry cannot absorb later edits. With B on, an eligible newer snapshot can supersede pending content; an older revision can never overwrite a newer successful manual or automatic delivery.

The ordinary `.md` export reads a consistent local snapshot with the current in-memory note buffer overlaid when needed, labels an unsaved recovery draft, and never creates a vault binding or acknowledges the Obsidian queue.

### Initial-export lifecycle

```text
Final end + A allowed → end snapshot → delivered or waiting for access
                                   ├─ outcome ready → initial complete
                                   ├─ disabled/declined → notes-only complete
                                   └─ pending/failed → awaiting first ready outcome
First ready + open initial operation → frozen full snapshot → initial complete
```

A failed generation leaves the operation awaiting a first successful outcome without initiating generation. Reconnect, crash or hiding a meeting window is not an end event. Define a durable, idempotent final-end event in the meeting lifecycle and record generation disabled/declined explicitly.

Turning A off holds both undelivered initial snapshots and future automatic completion of that operation. B can still update a previously successful binding. Turning B off holds ordinary updates but not a currently allowed initial delivery. The master toggle holds all automatic intents. Re-enable applies to future qualifying events; held jobs require explicit Send accumulated. A normal access outage leaves intent eligible, so restoring access retries it automatically.

### Worker, acknowledgment and path rules

Wake the worker on commit with bounded coalescing, rather than relying only on the two-second poll. While edits continue under B, deliver an intermediate current revision at least every two seconds on an available local disk. The measurable bound is commit-to-required-components-written, for ≤100 KiB notes and ≤5 MiB worklog, without conflicts. Use a timer as recovery, not the only trigger.

Serialize by physical destination file, including multiple sessions sharing a worklog. Read current permission/config immediately before each component write. A write already in its atomic replacement may finish; show the actual result and stop subsequent unauthorized writes.

Use the stored binding path once allocated. Renaming edits the managed title, owned metadata and index label, never the physical file name. New bindings resolve collisions once. Destination changes retire previous bindings for updates and preserve old files; history relocation is explicit.

After delivery, commit the component receipt and conditionally acknowledge **the delivered job/snapshot revision**. Never delete a newer outbox request. Preserve a monotonic successful revision, per-component receipts and partial state. Recovery checks receipts plus actual blocks so a crash after file replacement but before database acknowledgment does not create duplicate entries.

For files + index, retain the complete target snapshot until both components converge. Show partial delivery until then. This is recoverable multi-file delivery, not an atomic multi-file transaction.

### File safety and worklog layout

Reuse managed-block parsing and patching. Capture bytes and fingerprint from the same read, validate the managed region against the last exported base, then coordinate revalidation, a unique durable backup, staged write, replacement and readback. Distinguish missing file from unreadable file. Treat unknown relocation, marker damage and edited managed text as conflicts rather than transient access failures.

Use file coordination/presentation for cooperating processes. Apple describes this as a mechanism for coordinating participating readers/writers; do not infer immunity to arbitrary external writers. [Apple file coordination guide](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/FileCoordinators/FileCoordinators.html). Test external uncoordinated writes before backup, between recheck and replace, and after replace. Preserve recoverable originals and report conflicts; document residual platform limits rather than claiming a filesystem-wide compare-and-swap guarantee.

Validate root-relative paths, symlink traversal, file type, collisions and destination changes at use time. Keep invitation secrets out of metadata/logs. Ensure both new-file creation and replacement have valid paths; use collision-safe backup names even for several writes per second.

Add worklog and index renderers to the existing Markdown export module. Own only per-session blocks and specifically owned metadata/link labels. Preserve foreign frontmatter, introduction, conclusion, manual entries and formatting. Do not inject per-meeting frontmatter into a worklog or force frontmatter into an existing file.

Placement uses full date/year in the destination time zone. UI zone changes cannot move existing exports. Match an existing day only when unambiguous; preview/confirm old `D.MM` years. Support beginning/end without grouping, day direction with grouping, and independent within-day placement. Late outcomes update in place. Changing order affects future insertions; no automatic history reorder. Runtime style is a preset of these rules, not a separate parser. The index counts all structurally open tasks, including personally archived tasks; archive-only changes do not change export revisions.

## Implementation sequence and gates

Use reviewable, dependency-ordered changes. No phase alone is full feature acceptance.

| Phase | Implementation scope | Exit gate |
| --- | --- | --- |
| 0. Prove risky boundaries | Capture baseline fixtures; editor source-mapping/table spike; external-write race harness; inspect notification ownership and old Obsidian config semantics | Parser/layout approach and migration policy documented; recoverability limitations explicit |
| 1. Migrate domain ownership | Session title/date provenance; outcome head/history; canonical task rows, compatibility links and profile state; immutable snapshot/intent schema | Copy-based, restartable migrations preserve old IDs, done, dates, owners, notes and disabled integration |
| 2. Shared notes and safe lifecycle | Observable document registry, first-dirty timer, lease, close/quit flush, recovery export, session-scoped detached windows | No stale overwrite, false Saved or silent loss; notes UI independent of active media |
| 3. Outcomes and editor | Editable notes beside all outcome states; rename; grouped history; Live Preview/source view; accessibility | Required Markdown round trips; grouping/rename behavior; latency target on recorded Mac |
| 4. Personal tasks | Full-history query, aliases, filters, sort/precision, completion, archive/Undo/restore, regeneration review | UI, reminders, assistant context and MCP agree within one second of commit |
| 5. Export policy and delivery | A/B settings, final-end/first-ready events, frozen snapshots, pause reasons, conditional ACKs, stable bindings, conflict UI | Full switch matrix and crash/retry cases; no wrong-revision delivery or automatic backlog replay |
| 6. Formats and independent export | Worklog, files + index, placement preview, Runtime preset, content choices, batch/period export and results | Placement/conflict/partial-delivery fixtures pass; draft export includes current buffer |
| 7. Acceptance and release preparation | All 41 scenarios, mixed workflow testing, help/localization, diagnostics and migration/recovery report | Reviewable evidence ledger; native build and existing relevant suites pass; performance gates met |

Phase 2 precedes editor UI; phase 1 precedes task mutations and new export semantics. Task and export work must converge on the same snapshot contract. Use `test-library.sh` and relevant existing parity suites as starting points; inspect their current test selection and extend it instead of treating a passing narrow script as full acceptance. Distribution, installation and publication are later execution tasks, not part of this planning request.

## Migration and rollout policy

1. Back up the SQLite database using a WAL-safe mechanism and retain the legacy source files. Run schema/data migration transactionally; record version/provenance and validate referential links before success.
2. Migrate note and outcome IDs unchanged. Expand multiple known versions into history under one session head. Assign a durable session association for each unlinked legacy outcome; never match by room name.
3. Migrate canonical tasks and compatibility addresses once; prove reopening does not reassign IDs or duplicate tasks. Disable writes through old payload-only code paths in the same change.
4. Add unknown completion times and explicit legacy due semantics rather than guessing. Default archive off; owner aliases require confirmation. Use `Дмитрий Максимов` and `Дмитрий Максимов (СДБ)` only as acceptance fixtures, alongside a different person sharing the first name; do not hardcode these names in production.
5. Preserve disabled Obsidian integration and existing destinations. An enabled legacy mode currently exports during editing; expose that as a clearly labeled compatibility trigger if verified. Do not silently translate it into permission for broader after-end or backlog writes. Ambiguous cases get a migration explanation before new automation activates.
6. Preserve queue/binding evidence and old physical paths. Held, access-retry and conflict jobs remain distinct. Never auto-clear conflicts during settings migration.
7. On migration failure, keep originals and recoverable backup, show a local-library error, and allow recovery export where data can be read. Prevent older binaries from opening a newer incompatible schema writable. Rollback uses the pre-migration backup with an explicit accounting of any later edits.
8. Verify retention never removes notes/outcomes/tasks due to export success or disconnected/deleted vault. Explicit local deletion does not delete vault files; orphaned UI references are handled deliberately.

## Acceptance coverage

Numbers correspond to section 9 of the supplied specification. These are planned checks, not completed results.

| # | Check and required evidence | Main phase |
| --- | --- | --- |
| 1 | Edit formatted notes next to a ready outcome | 3 |
| 2 | Add notes to old/no-outcome session without generation | 2–3 |
| 3 | Formatting appears while typing in the meeting editor | 3 |
| 4 | Incomplete syntax, code/table paste, undo/redo preserve text and caret | 3 |
| 5 | Mode switch preserves raw bytes, caret and editing history | 3 |
| 6 | Detached editing with main window minimized leaves devices/call unchanged | 2 |
| 7 | Same session focuses existing window; different session stays isolated | 2 |
| 8 | Alternate three views; stale generation rejected and lease state visible | 2 |
| 9 | Close saves notes without ending meeting; end keeps notes available | 2 |
| 10 | Exercise all four A/B combinations, plus master-off override | 5 |
| 11 | Pending outcome at final end exports notes within target without opening UI | 5 |
| 12 | A on/B off permits first ready outcome only, then freezes later edits | 5 |
| 13 | Note/outcome/done changes update same managed path and preserve manual text | 5–6 |
| 14 | Short disconnect produces no end event, export or extra session | 5 |
| 15 | Restart with unavailable vault preserves data and eligible queue | 5 |
| 16 | Full personal history beyond a page includes completed tasks | 4 |
| 17 | Exact confirmed Russian full aliases match; same first name does not | 4 |
| 18 | Filter, completion and reopen mutate original and survive restart | 4 |
| 19 | Archive open/completed tasks hides all operational surfaces, cancels reminders, preserves done | 4 |
| 20 | Restart and outcome refresh cannot resurrect archive | 4 |
| 21 | Undo/restore preserves current done and avoids overdue reminder burst | 4 |
| 22 | Regeneration keeps IDs/manual state; missing task is not deletion | 4 |
| 23 | No Obsidian/network/model: saved data works and Markdown export succeeds | 2–6 |
| 24 | Read-only MCP sees committed UI data and excludes personal archive by default | 4 |
| 25 | Rename survives restart across all views/search/MCP; IDs unchanged | 3 |
| 26 | Cancel/blank rename leaves committed title unchanged; inline error | 3 |
| 27 | Rename one room occurrence; generator/calendar updates preserve override | 3 |
| 28 | Rename with B on/off updates only allowed content, never physical path | 5–6 |
| 29 | Correct day/session sort and counts with repeated room sessions | 3 |
| 30 | Midnight and late generation/edits leave group anchored to start | 3 |
| 31 | Legacy fallback/unknown dates and display-zone changes preserve export layout | 1, 3 |
| 32 | Collapsed groups/search/page boundary/scroll selection remain consistent | 3 |
| 33 | Disable A before first-ready; B updates only successful links; master blocks all | 5 |
| 34 | A-only offline retry delivers frozen snapshot; older job cannot undo newer manual save | 5 |
| 35 | Preference re-enable holds backlog; access recovery resumes eligible jobs | 5 |
| 36 | Generation-disabled initial export closes notes-only; later outcome follows B/manual | 5 |
| 37 | All worklog placements, late updates, Runtime-style year ambiguity | 6 |
| 38 | External managed edits/marker damage and hybrid partial crash preserve recovery | 5–6 |
| 39 | Disk failure plus last-editor close: honest state, explicit choice, current draft export | 2 |
| 40 | Ambiguous regenerated candidates, including archive, require review without duplicates | 4 |
| 41 | All filter ordering, date/instant deadlines, full MCP archive flag and assistant exclusion | 4 |

Additional boundary tests: crash after local commit, before file write, after replacement, between hybrid components and before acknowledgment; continuous first typing; two renames/edits during a delayed write; missing-file creation and naming collision; changed destination during queue processing; time-zone/DST transitions; task ownership change; absent IDs in old payloads; notes-only session with no ready outcome; conflicting managed metadata/frontmatter; backup failure and same-second backups.

Record measured editor p95, commit-to-export latency including all required components, continuous save intervals, and commit-to-task-list latency. Run destructive tests only on synthetic/copy fixtures and a test vault, never the real `Runtime.md`. Capture a native UI walkthrough plus machine-readable revision/job/component receipts. Existing tests can support specific claims but do not substitute for the 41-scenario ledger.

## Remaining engineering decisions

The design does not require a product clarification to begin phase 0. Choose the responsive layout and one-editor lease as defaults. Resolve TextKit/table rendering after the spike; fix a reproducible test Mac; confirm how the existing installation granted live export permission; validate notification cancellation/restart races; and validate destination-year preview against synthetic Runtime-style examples. Treat these as bounded engineering gates, not reasons to omit mandatory scope.
