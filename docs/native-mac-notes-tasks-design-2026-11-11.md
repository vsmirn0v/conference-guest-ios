# Native Mac notes, tasks and Obsidian design draft

Date: 11 November 2026. Status: proposed design, ready for review.

Extend the existing Assistant and meeting notes surfaces around one durable meeting session. Make notes editable regardless of outcome generation, give personal tasks a dedicated tab, and distinguish saving on this Mac from delivery to Obsidian.

Scope comes from [the supplied feature request](/Users/v.smirnov/Downloads/ROCKNROLL_NOTES_TASKS_AUTOSYNC_SPEC.md). Its instructions to implement and ship are requirements for future implementation; the current deliverable is design and planning. All seven feature areas and all 41 acceptance scenarios are covered. Product copy below is English; use the app's existing localization system for Russian equivalents.

Companion: [implementation plan](native-mac-notes-tasks-plan-2026-11-11.md).

## Recommended layout

Keep the existing Assistant section picker and add **My Tasks**: Moments · Outcomes · My Tasks · Talk. Preserve the app's SwiftUI/AppKit appearance, system typography, accent color, native menus, keyboard navigation, and window controls.

Use **Side by side** as the wide-window layout: a day-grouped meeting list followed by a detail area containing Outcome and My Notes. The comparison draft **Notes first** puts notes above the outcome in a single reading column. Use that stacked arrangement automatically when the detail area cannot provide approximately 320 points for each column. A draggable divider remembers the preferred proportion; these widths are proposed starting values, not fixed acceptance limits.

Keep notes and outcomes separate visible sections. A tab that makes users hide the outcome to see their notes is not the default. Notes remain present for every selected session, including sessions with pending or failed generation.

## Draft A: Outcomes workspace

```text
Assistant                         Moments  Outcomes  My Tasks  Talk
┌────────────────────────┬─────────────────────────────────────────────────┐
│ Search saved meetings  │ Release review                     Rename  ⋯    │
│                        │ 11 Nov 2026 · 14:00–14:45 · Outcome ready       │
│ ▾ Today · 11 Nov 2026   ├────────────────────────┬────────────────────────┤
│   2 meetings           │ Outcome                │ My Notes         ↗     │
│   14:00 Release review │ Summary                │ Formatted | Markdown   │
│   10:30 Weekly sync    │ Decisions              │                        │
│ ▾ Yesterday · 10 Nov…  │ Tasks                  │ Editable Markdown      │
│   16:00 Design review  │ Open questions         │                        │
│ ▸ 9 Nov 2026           │                        │ Saved on this Mac      │
│ ▸ Date unknown         ├────────────────────────┴────────────────────────┤
│ Export Markdown…       │ Obsidian · Up to date                    Details│
└────────────────────────┴─────────────────────────────────────────────────┘
```

The title is the session's effective title. **Rename** starts a local field with Save/Cancel, Enter/Escape, and an inline error for a blank trimmed value. Intermediate typing is not published. The title updates across notes, detached windows, task source links, search and MCP only after a successful local commit. It never renames a provider room or calendar series.

The title menu contains **Export Markdown…**, **Save in Obsidian**, and **Open notes in a separate window**. Independent Markdown export stays available without a vault or model. The history toolbar adds selection and period export, with separate-file and combined-worklog choices.

Day headers show full date, year and matching meeting count. Today/Yesterday supplement the date. Groups sort newest first, sessions by effective date descending, then stable ID. Unknown dates go last. Imported records using an end-time fallback visibly say **Based on end time**. A meeting spanning midnight stays with its start day.

Collapsed state and scroll anchor survive opening details. Search temporarily expands matching groups and shows matching counts; clearing it restores the previous collapsed state. Paginated days have one header; show **N loaded** until the count is known. A newly ready outcome updates its original row without stealing selection or scrolling to the top.

### Meeting and notes states

| Condition | Outcome area | My Notes |
| --- | --- | --- |
| Meeting in progress | In progress; generation controls remain contextual | Editable, live formatting |
| Generation pending | Preparing outcome | Editable, with its own save state |
| Generation failed | Outcome unavailable; Retry when retained input exists | Editable; no regeneration required |
| Generation disabled | No outcome; Generate if available | Editable; export can say Notes only |
| No notes | Existing outcome or its status | Add notes, then the same editor |
| Local save failed | Existing committed outcome remains visible | Buffer retained; Retry / Export draft…; explicit close decision |
| Obsidian unavailable | Unchanged | Local editing continues; separate Waiting for vault status |

## Draft B: Notes editor and detached window

The same editor appears in the meeting panel, outcome detail and detached window. It is attached to a session ID rather than to the currently active meeting model.

```text
Release review · 11 Nov 2026, 14:00                       native title bar
Meeting ended                          Show in main window
My Notes                               Formatted | Markdown
──────────────────────────────────────────────────────────
Release checklist
□ Confirm the fallback with the team
Bring the latest measurements to the follow-up.

**Owner:** Maya                       ← active syntax visible
──────────────────────────────────────────────────────────
Saved on this Mac · 14:46                Obsidian · Waiting
```

Formatted is the default editing mode, with markup exposed around the caret as needed. Source mode changes presentation of the same Markdown. It preserves caret, selection, undo history and content. Both modes support normal macOS text operations, multi-line paste and IME input. Complete headings, emphasis, strikeout, nested lists, checkboxes, quotes, links, inline/fenced code, tables and rules format in place. Unknown Obsidian syntax remains intact. Links do not fetch remote content automatically.

A note checkbox edits Markdown only. It does not complete a structured task unless the application already has an explicit link.

For the first implementation, use an **editing lease**: one editable view per session, other views show the current buffer and **Editing in another window · Continue here**. Continue here transfers the lease after finishing marked text composition; it does not replace the document from a stale view buffer. This is explicitly permitted by the specification and keeps the first release manageable. Different sessions can be edited independently.

Opening a detached window again focuses the existing window for that session. A different session opens a different window. The detached window survives meeting end and main-window minimization. Closing it flushes notes without ending the meeting. **Show in main window** selects the matching session and leaves the detached window open by default. Save geometry and move off-screen windows onto an available display after monitor removal.

Local status: **Saving…**, **Saved on this Mac**, **Couldn’t save**. Do not show Saved for a dirty buffer. On closing the last unsaved editor or quitting after a failed save, offer **Keep editing**, **Retry**, **Export draft…**, and a clearly destructive **Discard unsaved changes**. An exported recovery draft does not silently count as a successful local save.

## Draft C: My Tasks

```text
My Tasks                                  3 open · 1 overdue       ⋯
All     Open (selected)     Completed
─────────────────────────────────────────────────────────────────────
□ Send the revised rollout checklist           Overdue · 10 Nov   ⋯
  Release review · 10 Nov 2026, 16:00             Open meeting
□ Confirm the fallback path                    Today · 11 Nov    ⋯
  Release review · 11 Nov 2026, 14:00             Open meeting
□ Review accessibility copy                    No due date       ⋯
  Design review · 9 Nov 2026, 11:00              Open meeting
─────────────────────────────────────────────────────────────────────
Task archived                                               Undo
```

Use the requested filter order **All / Open / Completed**, defaulting to Open and remembering the choice. All excludes archived tasks. Open tasks sort by due date, no-date tasks last, then meeting date descending and stable ID. Completed tasks sort by completed time, falling back to meeting date, with unknown dates last. All places open tasks before completed tasks using those same orders.

Use full-width rows rather than cards. Each row has completion, text, due date/overdue label, source meeting/date, and an Archive action in its menu. Completing or reopening edits the original task. In Open, completion removes the row after commit; preserve focus on an adjacent row and do not reset scroll. Late-arriving task data must not clear the current filter.

The menu contains **My names in tasks…** and **Manage archive…**. Archive is a separate sheet, never a fourth ordinary filter. It shows current completion state and Restore. Restore changes only personal archive state. A brief Undo follows archiving. Archiving an open task leaves it open in historical exports, while removing it from personal counts, operational task rows, task search, suggestions and reminders.

Task rows in a meeting's operational Tasks section also respect the current profile's archive visibility. Historical summary text and previous exported Markdown remain untouched. A link to archive management provides deliberate access where needed. Full MCP outcome data carries the personal archive flag rather than deleting history.

### Identity and empty states

- Identity not configured: **Which task names are yours?** with **Set up my names**; do not show a misleading empty list.
- Setup: prefer stable assignee IDs; otherwise show full owner strings from saved tasks for explicit confirmation. Normalize only case and whitespace for aliases. Never infer identity from a first-name substring or strip organization suffixes.
- Configured with no tasks: **No tasks assigned to you yet** with access to alias settings.
- No open tasks: **No open tasks** with **View completed**.
- New outcome has ambiguous task matches: **Tasks need review** in the source meeting. Keep existing tasks active; unresolved candidates stay outside personal lists and reminders. Review offers Link to existing / Add as new / Dismiss candidate.

## Draft D: Obsidian settings and delivery status

Extend Settings → Obsidian. Keep a master integration toggle, then two independently stored preferences:

1. **Save to vault when a meeting ends.** Help: notes saved before the first ready outcome are included in the initial full export.
2. **Automatically sync changes.** Help: changes to outcomes, notes and tasks go from Rock’N’Roll to Obsidian.

| After meeting | Sync changes | Visible explanation |
| --- | --- | --- |
| Off | Off | Only explicit saves. Automatic jobs are paused. |
| On | Off | Save the ending snapshot and the first ready outcome. Later changes need a manual save. |
| Off | On | Update meetings already saved to this vault. Save a new meeting manually to link it. |
| On | On | Save after the meeting and keep linked meetings updated. |

Below: vault name/access, format, relative paths, content selection, destination preview, queue status and last successful delivery. Missing access does not prevent storing preferences. The master switch prevents all automatic writes. Enabling either option does not silently send accumulated work: show **Send accumulated changes…** with a preview of affected meetings.

Formats are **Meeting files**, **Worklog**, and **Meeting files + index**. Worklog/index can be monthly or one permanent file. Content defaults to notes, outcome, decisions, tasks and questions; automatic full transcripts are excluded. A worklog has independent controls for insertion at beginning/end, day grouping, day direction and within-day placement. The **Runtime style** preset uses a permanent file, newest days first and new meetings at the end of a day. Existing headings without years require year confirmation in the preview.

Destination preview shows the root, physical paths, managed section boundaries, a representative entry, and the destination time zone. It identifies preserved introduction/conclusion text. Changing formats or paths does not move old files automatically; an explicit history migration is a separate operation. UI day grouping never changes export layout.

### Delivery and conflict states

| Status | Meaning and action |
| --- | --- |
| Up to date | Required components have the same successfully delivered revision; show time |
| Waiting for vault | Local changes saved; reauthorize or reconnect the folder |
| Waiting for first outcome | Ending snapshot delivered; initial export still awaits first ready outcome |
| Notes only | Initial export closed because generation is disabled or declined |
| Paused by settings | Retain queued work; do not automatically replay on re-enabling |
| Partially updated | Meeting file succeeded, index/worklog component still pending |
| Needs review | Managed text/markers changed externally; pause this destination |

**Review conflict** opens a comparison of the last exported base, current vault text, and current local content, naming the affected file/block. Offer **Keep paused**, **Save a separate copy…**, and **Replace app section with backup…**. Replacement is explicit and preserves unrelated text. A copy does not silently resolve or relink the original destination. Missing/duplicate markers or an unknown moved file require placement review, not blind Retry.

## Keyboard and accessibility

Use standard native menu commands and AppKit window behavior. Rename supports Enter/Escape. The editor retains Command-Z/Shift-Command-Z, Find, selection, paste and composition. Label formatting/source controls and all icon buttons. Announce save failures, task state changes and archive Undo without reading every autosave aloud. Support VoiceOver, keyboard-only task actions, reduced motion, light/dark appearance and enlarged system text. Do not use color alone for overdue, failed or paused states.

## Design decisions and boundaries

| Decision | Rationale |
| --- | --- |
| Responsive side-by-side, with stacked notes-first fallback | Keeps outcome and personal notes available together |
| One editing lease per session initially | Avoids stale buffer overwrite without building collaborative editing |
| Separate local and Obsidian status | Export failure must not imply lost local notes, or vice versa |
| Archive behind a menu | Matches complete hiding from ordinary task workflows |
| Stable physical export path | Rename changes content and link labels without breaking links |
| Explicit accumulated-send preview | Re-enabling automation is not permission to replay old changes |
| Exact confirmed owner aliases | Avoids including another person's tasks |

The interactive drafts demonstrate layout, rename, status selection, task filtering/archive, and the export preference matrix using sample data. They are not a native app build, a full Markdown editor, or evidence of persistence, timing, export safety or accessibility acceptance. The plan defines those validation gates.

Optional task text search and bulk archiving can follow the mandatory release. Full two-way Obsidian import, a cloud service, new MCP write tools and a replacement outcome generator remain outside this feature.

## Draft verification

The browser prototype was checked for blank-title validation, confirmed rename propagation, detached-window title, archive exclusion from All, restore preserving completion, all four A/B combinations and the master override. Conflict and accumulated-send flows were exercised. Desktop light and 320-point-wide dark layouts were inspected; the two desktop variants have equal stage height, and the narrow layout has no horizontal overflow. Browser console reported no errors. These are prototype checks, not execution of the native acceptance matrix. Source links resolve and the plan maps scenarios 1–41 exactly once.
