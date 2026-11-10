# Local model status — iteration 2: placement, chrome, and honest memory visualization

**Status:** design draft for review, not implemented.
**Date:** 2026-11-10
**Context:** beta 84 user feedback (three comments) plus one defect visible in the feedback screenshot. Builds on `local-model-readiness-memory-design-2026-11-10.md`; all first-iteration invariants stay (readiness ≠ residency, estimates not download size, contended measurements are never attributed to two models, managed/external engines get no app-attributed memory, no changes to idle-retention policy).

## 1. Problems to solve

| # | Feedback | Root cause |
|---|----------|------------|
| 1 | Status is only accessible from the Assistant screen | Chip is gated on `workspace.selection == .assistant`; Settings exposes it only under Assistant |
| 2 | Status button overflows its background capsule | Chip sits inside `ToolbarItemGroup`, which draws one capsule for the whole group; the chip's own stroke is clipped by that background (screenshot evidence) |
| 3a | The bar shows only Mac usage, not per-model memory | Per-model memory is a text line only; the single bar is system-wide; the text line mixes two denominators (model MB vs Mac available GB) |
| 3b | No clue how much memory an unloaded model will need | Only live, in-session measurements exist; nothing is persisted or shown when a model is not resident |
| 4 | (Observed in the screenshot) Voice is Loaded · idle with **no** memory line at all | Suspected: startup voice prepare and speech warm-up overlapped → both measurements marked contended and discarded; a contended measurement is never retried and `refine` cannot recover without a baseline. To be confirmed from `probeLog` markers during implementation |

## 2. Design principles

- **Provenance on every number.** Each memory figure is labeled as one of: *live estimate* (measured this session), *last measured* (persisted, with date), or *not measured*. No silent blanks and no invented numbers.
- **Current vs historical never mix.** The system bar visualizes only the present. Last-known estimates appear only in the owning model's row, in a visually distinct ghost style, never in the stacked system bar.
- **Accessible without Assistant.** Transcription users who never open Assistant must reach the same surface.
- **No lifecycle changes for a number.** No "measure now" reload button, no polling of per-model memory (no public API exists), no changes to warm-up/unload policy.

## 3. Change 1 — placement and chrome

**Toolbar.** The chip moves into its **own `ToolbarItem`** with its own background group, the same approach the existing transcription pill already uses ("Sharing the button group's capsule clips this pill"). It is shown **whenever no meeting is selected, in every home section** (Home, Calendar, Assistant), before the Add favorite button. The group's capsule no longer clips it.

**Settings.** Keep the Settings → Assistant section as-is; add the same component to **Settings → Transcription** as an "On-device models" section (no settings-navigation buttons there). Same store, same popover, no duplicated logic.

**Unchanged.** The meeting transcription pill and the Assistant-screen behavior otherwise stay as they are.

Acceptance: chip fully inside its own background at all window widths; reachable from Home, Calendar, Assistant, Settings → Transcription, Settings → Assistant.

## 4. Change 2 — per-model bars and a stacked system bar

### 4.1 Popover layout (380 pt)

```
┌────────────────────────────────────────────────────┐
│ On-device models                                   │
│                                                    │
│ Speech recognition                    [ ✓ Ready ]  │
│ GigaAM v3 E2E RNNT (Neural Engine)                 │
│ Loaded · idle (ready to work)                      │
│ ⚙ Neural Engine + CPU                              │
│   encoder on ANE; decoder/joint on CPU             │
│ ▰▰▱▱▱▱▱▱▱▱  ≈ 426 MB of 16 GB · live estimate      │
│                                                    │
│ Voice synthesis                       [ ✓ Ready ]  │
│ VoxCPM2 (Neural Engine)                            │
│ Not loaded                                         │
│ ⚙ Neural Engine + CPU                              │
│ ▱▱▱▱▱▱▱▱▱▱  last measured ≈ 512 MB · 10 Nov        │
│                                                    │
│ ────────────────────────────────────────────────   │
│ This Mac                12.4 GB used of 16 GB      │
│ [S][V][──────── other ────────][-- available --]   │
│ speech ≈426 MB · voice not measured · other 12 GB  │
│                                                    │
│ Memory figures estimate this app's own footprint   │
│ while a model is loaded; not the download size.    │
└────────────────────────────────────────────────────┘
```

### 4.2 Per-model bar

- One small horizontal bar per model row: **estimate ÷ physical total memory**, so models are comparable with each other and with the system bar. The numeric label is always present; the bar is never the only carrier of the value.
- A minimum visible segment (~3 pt) keeps sub-1% estimates legible; the label carries the precise value.
- Live estimate → solid bar in the role color (speech teal, voice indigo), suffix "live estimate".
- Last-known estimate → ghost/dashed track-only bar in the same hue at low opacity, suffix "last measured · \<date\>".
- No data → no bar, text "No measurement yet — attributed on first load".

### 4.3 Stacked system bar

Segments left to right: **speech** (teal), **voice** (indigo), **other used** (neutral blue-gray), **available** (track). Only **live** estimates become segments. `other = max(0, used − speech − voice)`. Legend line below the bar names each segment with its number, including "voice not measured" when there is no live estimate. Contended-active keeps the existing inline note in the model row; the system bar simply omits that segment.

## 5. Change 3 — persisted last-known estimates

**Storage.** `UserDefaults` key `localModels.memoryEstimates.v1`: dictionary `[modelID: { bytes, measuredAt, build, afterInference }]`. Written on every uncontended `complete`/`refine`. Deleted when the model is deleted. No expiry — the date is always displayed.

**Use.** Shown only when there is no live estimate for a loaded-but-unmeasured model, or when the model is not loaded:

- unloaded + last-known → ghost bar + "Last measured ≈ N MB · \<date\> · not loaded"
- loaded + unmeasured + last-known → ghost bar + "last measured \<date\> · not measured this session"
- never measured → the explicit "No measurement yet" text

Build changes do not clear the record; the build is stored for diagnostics. Managed/external engines never read or write these records.

## 6. Change 4 — measurement lifecycle: contention recovery and honest states

- A contended completion records an explicit **unmeasured(reason: concurrentLoad)** state for the role instead of silently leaving `nil`; the UI shows "Measuring… another model loaded at the same time" only while a measurement is active, and afterwards the last-known or "not measured this session" state.
- Attribution is retried automatically on the role's **next real load** (the existing begin/complete path already re-measures); no forced reload of a resident model.
- The voice-row defect in the screenshot is expected to be resolved by this retry plus the last-known fallback; confirm the startup-overlap hypothesis in `probeLog` before finalizing.

### Memory block state matrix (per model)

| Residency | Live estimate | Last-known | Rendered |
|-----------|---------------|------------|----------|
| loaded | yes | any | solid bar, "≈ N MB · live estimate" |
| loading (measurement active) | — | any | "Measuring…" (+ concurrent note if contended) |
| loaded | no (contended) | yes | ghost bar, "last measured \<date\> · not measured this session" |
| loaded | no | no | "Not measured yet" |
| unloaded | — | yes | ghost bar, "Last measured ≈ N MB · \<date\> · not loaded" |
| unloaded | — | no | "No measurement yet — attributed on first load" |
| managed/off/notApplicable | — | — | no memory block |

## 7. Accessibility and localization

- Every bar gets an accessibility label containing its numeric value and provenance; ghost state is announced ("last measured", "not loaded").
- New en/ru strings: "live estimate", "last measured %@", "not measured this session", "Not measured yet", "No measurement yet — attributed on first load", the legend line, "Measuring… concurrent load".
- Chip summary and VoiceOver behavior are unchanged.

## 8. Test plan

- **Reducer:** full state-matrix mapping; last-known used only when no live estimate; never for managed engines; last-known never contributes to system-bar segments; `other` clamped at zero.
- **Persistence:** record roundtrip; delete clears; live measurement overwrites; build change retains with date.
- **Tracker:** contended completion records the explicit unmeasured state; next uncontended load produces a live estimate; `refine` without a baseline stays a no-op.
- **View logic:** minimum segment width; legend contents; contended-active message.
- All existing suites must stay green; full `NativeDesktopTests` run before any beta.
- Visual verification on hardware: chip inside its own background; both bars render; unloaded model shows ghost bar with date.

## 9. Alternatives considered and rejected

- **Stacked bar only** (no per-row bars): less vertical space, but the per-row provenance text is needed anyway; per-row bars are the direct answer to "which model uses what".
- **Download size as expected memory:** rejected — disk size is not runtime footprint and would silently break the disclaimer.
- **"Measure now" button (unload + reload):** rejected — changes model lifecycle for a cosmetic number.
- **Expiring last-known estimates after N days:** rejected — staleness is communicated by the displayed date; expiring only removes information.

## 10. Open questions

1. Ghost bar for last-known estimates: dashed track vs low-opacity solid — decide at implementation, prefer whichever reads better in dark mode.
2. Should the Settings → Transcription section default to expanded speech-only detail (since voice is configured elsewhere)? Default draft: same full component for consistency.
