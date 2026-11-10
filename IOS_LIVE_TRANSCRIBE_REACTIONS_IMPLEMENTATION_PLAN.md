# iOS Live Transcribe Reactions Parity — Implementation Plan

## Status

- **Planning only — do not implement yet.**
- Source: Antigravity / Gemini conversation `c5ba4666-5e2e-4b51-b55c-539f531a3928`, titled **iOS Live Transcribe Reactions Parity**.
- Original feature request: reactions currently appear in iOS text chat, but are not duplicated in the Live text view as they are on Desktop.
- The original Gemini plan is preserved below, followed by Gemini's critique and an independent review against the current repository.
- No tracked app-source changes were present when this review was performed.

## Scope

### In scope

- Add reaction entries to the iOS **Live text** panel.
- Merge reactions and transcript segments chronologically.
- Preserve the existing iOS transcript availability behavior, scrolling, selection, and reaction unread/seen semantics.
- Add deterministic model tests and UIKit integration tests.

### Out of scope for this feature

- Adding reactions to iOS **Catch up** cards. Desktop has this behavior, but the original request concerns Live text; Catch up should be a separately approved change.
- Changing reaction transport, grouping, persistence, badges, or unread/seen behavior.
- Redesigning Desktop or sharing a new cross-platform UI model.
- Publishing a beta.

---

# 1. Transferred Gemini plan

## 1.1 How Desktop works today

Desktop uses `NativeMacGuest/DesktopMeetingModel.swift` and `NativeMacGuest/DesktopMeetingView.swift`:

1. A unified `LiveTextRow` model represents either a transcript line or a reaction.
2. `liveTextRows` merges transcript lines and `chat.reactionHistory.events` chronologically.
3. A line without a usable timestamp inherits the preceding line's effective timestamp for ordering, while retaining its original optional display timestamp.
4. If transcript lines exist, reactions earlier than the first line are omitted; if there are no transcript lines, all reactions are included.
5. The Live text view renders transcript lines and reaction rows from the merged result.

## 1.2 Why iOS does not show reactions in Live text

In `RockNRoll/ConversationPanelViewController.swift`:

1. The reaction-events subscription calls `requestContentRender(transcript: false)`, so reaction updates do not invalidate the transcript.
2. `renderTranscript()` only consumes `timeline.segments`; it does not read `chat.reactionHistory.events`.
3. The non-empty transcript guard hides the Live text content when no speech segments exist, so reactions before speech cannot appear.
4. `transcriptLines(...)` only formats `TranscriptSegment` values.

## 1.3 Proposed implementation

### A. Add an iOS unified row type

In `ConversationPanelViewController.swift`, or in a shared model helper:

```swift
enum LiveTextRow: Equatable {
    case line(TranscriptSegment)
    case reaction(MeetingReactionEvent)

    var id: String {
        switch self {
        case .line(let segment): return "line-" + segment.id
        case .reaction(let event): return "reaction-" + event.id
        }
    }
}
```

### B. Merge rows chronologically

Add an iOS equivalent of Desktop's `liveTextRows(limit:)`:

```swift
private func liveTextRows() -> [LiveTextRow] {
    var rows: [(Date, Int, LiveTextRow)] = []
    var last = Date.distantPast
    var order = 0

    for segment in timeline.segments {
        let time = segment.spokenAt ?? last
        last = time
        rows.append((time, order, .line(segment)))
        order += 1
    }

    if let first = rows.first?.0 {
        for event in chat.reactionHistory.events where event.timestamp >= first {
            rows.append((event.timestamp, order, .reaction(event)))
            order += 1
        }
    } else {
        for event in chat.reactionHistory.events {
            rows.append((event.timestamp, order, .reaction(event)))
            order += 1
        }
    }

    return rows.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }.map(\.2)
}
```

### C. Format reactions in the attributed transcript

Adapt Desktop's rows to the existing `UITextView` presentation:

- Spoken line: timestamp, semibold speaker, then body text on the next line.
- Reaction: timestamp followed by emoji and participant name.
- Use caption font and secondary/light-gray styling for reactions.
- Separate rows with a blank line.

The original draft showed bracketed timestamps such as `[14:05]`; the current iOS renderer actually uses unbracketed timestamps such as `14:05  `, so the existing style should be preserved.

### D. Update rendering and caching

1. Replace `renderedTranscriptSegments: [TranscriptSegment]?` with a cache of merged rows.
2. Permit reaction rows when there are no transcript segments.
3. If the new rows start with the previously rendered rows, append only the suffix to `transcript.textStorage`.
4. Rebuild the full attributed string when an earlier row changes or rows are inserted out of order.
5. Preserve the existing incomplete-text/status notes, including a waiting-for-speech note when only reactions are present.

### E. Invalidate transcript rendering for reaction updates

- Change the `chat.reactionHistory.$events` subscription to request transcript rendering as well as message rendering.
- Ensure reactions received while Chat is selected or the app is inactive are reflected when Live text becomes visible.
- Do not change `markVisibleReactions()`: viewing Live text must not mark reactions as seen or alter chat badges.

### F. Add tests

Add coverage in `RockNRollTests/ReactionHistoryPanelTests.swift` for:

- A reaction received while Live text is selected appearing in `transcript.attributedText`.
- Chronological ordering of transcript segments and reactions.
- Behavior comparable to Desktop's `testUndatedLiveTextReceivedWhileMutedIsCaughtUpAndListedWithReactions` parity test.

---

# 2. Gemini's subsequent critique

Gemini reviewed its own plan and added these corrections:

1. **Use unconditional transcript invalidation.** Call `requestContentRender()` from the reaction-events subscription rather than making transcript invalidation conditional on the currently selected tab. It also suggested removing `transcript: false` from the reaction-history-availability subscription.
2. **Handle undated segments deliberately.** Derive the reaction cutoff from the first dated segment rather than the first effective row timestamp. Do not expose `Date.distantPast` as a visible timestamp.
3. **Preserve empty-state text.** When reactions exist before speech, retain the incomplete-text warning and waiting-for-speech prompt above the reaction rows.
4. **Prevent `UITextView` attribute bleed.** Reset body font and white text color before using the plain-text unavailable/empty-state branch.
5. **Use iOS naming behavior.** Display `You` for an own reaction and fall back to `Participant` when the display name is absent.
6. **Keep incremental append, with full rebuild on mutation.** Synthesized `Equatable` conformance detects changed earlier rows and prevents incorrect append-only rendering.
7. **Leave unread/seen state scoped to Chat.** Live text must not call the reaction visibility acknowledgment path.
8. **Identify Catch up as a scope question.** Desktop also shows reactions in Catch up interval cards; iOS does not.

---

# 3. Independent repository review

## Verdict

The approach is sound, but the original plan should **not** be implemented unchanged. The unified row model, chronological merge, unconditional invalidation, and append/rebuild strategy fit the codebase. One material Desktop-parity gap and several implementation details need correction first.

## Findings

### 3.1 High — reaction visibility must not depend on transcription availability

The draft still requires `canViewTranscript == true && transcriptionEnabled` before rendering merged rows. That preserves an iOS restriction that Desktop does not have:

- Desktop's Live text view always iterates `model.liveTextRows()` in the Live text branch.
- `liveTextRows()` includes reactions even when there are no transcript lines.
- Desktop does not gate reaction-row rendering on transcription being active or available.

Therefore, gating all merged rows on active transcription would still fail parity when transcription is off, unavailable, or its availability is unknown.

**Required correction:** decouple reaction visibility from transcript-line visibility. Preserve the current iOS rules for showing transcript lines, but render available reactions alongside the existing off/unavailable/checking status message.

### 3.2 Medium — Gemini's dirty-flag recommendation is right, but its stated failure mechanism is incomplete

Gemini said a reaction received in Chat could remain invisible because `transcriptDirty` was never set. In the current controller:

- `renderMode()` already calls `requestContentRender()` with both flags defaulting to `true`.
- Switching tabs invokes `renderMode()`.
- Appearance and application-activation paths also invoke `renderMode()`.

Those paths would usually force a later transcript render even with the draft's conditional subscription.

**Required correction:** still use unconditional invalidation from `$events`; it is simpler and removes reliance on unrelated `renderMode()` side effects. No additional special dirty-flag mechanism is needed in `renderMode()`. The availability subscription already calls `renderMode()`, so changing its earlier `transcript: false` call is optional cleanup rather than the core fix.

### 3.3 Medium — undated-line display concerns need a more precise statement

`CatchUpTimeline.precedes` orders dated segments before undated segments and orders undated segments by ID. Thus undated lines normally trail dated lines rather than lead them. The all-undated case still needs explicit handling.

The original proposed `.line(TranscriptSegment)` case already retains `spokenAt: Date?`; formatting can continue to use `segment.spokenAt`, so `Date.distantPast` need never be displayed. A second associated display date is unnecessary.

**Required correction:** use the earliest dated segment for the reaction cutoff, use an internal effective date only for sorting, and format from the original optional `spokenAt`. Add tests for trailing undated lines and an entirely undated transcript.

### 3.4 Medium — the append cache needs render-context validation

Caching only `renderedRows` is insufficient. The header/status can change while the row prefix remains equal, and an empty-to-non-empty transition may need to replace waiting or unavailable text rather than append to it.

**Required correction:** cache the rendered rows plus a header/status context. Use the append fast path only when:

- the context is unchanged;
- the previous row list is non-empty;
- the new visible rows strictly extend the previous rows by a tail suffix.

Rebuild on context changes, empty-to-non-empty transitions, changed earlier rows, removals, reordering, and cutoff changes. Clear the cache when returning to a plain status-only view.

### 3.5 Medium — status-message updates should invalidate the renderer

`CatchUpStore.transcriptUnavailableReason` is `@Published`, but the current transcript subscription combines only timeline, permission, and enabled state. Once status text becomes part of a composite reaction view, a reason-only update must also refresh it.

**Required correction:** include `catchUp.$transcriptUnavailableReason` in the transcript input publisher and invalidate through the existing coalesced render path.

### 3.6 Low — preserve current iOS transcript formatting

The original draft's bracketed timestamp example does not match the existing renderer. Reaction rows should use the same unbracketed leading-time pattern as current transcript lines:

```text
14:05  Alex
Hello everyone

14:06  👍  Alex
```

### 3.7 Low — synthesized event equality is safe but conservative

`MeetingReactionEvent` equality includes fields such as `isSeen` and delivery state that are not all visible in Live text. A seen-state update can therefore cause a harmless full rebuild. This is acceptable for the first implementation and safer than incomplete cache invalidation; presentation-specific equality can be considered later only if profiling shows a problem.

### 3.8 Scope — Catch up remains separate

Desktop's `catchUpReactions(_:)` and interval-card rendering confirm the additional Desktop behavior. It is not necessary to complete the requested Live text parity and should not be silently added to this change.

---

# 4. Revised implementation plan

## Step 1 — Extract a deterministic Live text timeline helper

Add `RockNRoll/LiveTranscriptTimeline.swift` containing:

- `LiveTranscriptRow: Equatable` with `.line(TranscriptSegment)` and `.reaction(MeetingReactionEvent)` cases.
- A pure internal helper that accepts transcript segments and reaction events and returns merged rows.

Algorithm:

1. Iterate segments in timeline order, assigning each an internal effective sort date from `spokenAt` or the preceding effective date.
2. Keep the original segment unchanged for display, including `spokenAt == nil`.
3. Compute the reaction cutoff from the first dated segment.
4. If a cutoff exists, include only reactions at or after it; otherwise include all reactions.
5. Sort by effective date, then insertion order for deterministic ties.
6. Do not introduce Desktop's 1,000-line suffix limit in this iOS change; preserve the currently retained iOS transcript range and avoid an unrelated history truncation change.

This helper has no UIKit dependency and can be tested without presenting a view controller.

## Step 2 — Define rendering behavior explicitly

Use this behavior matrix in `ConversationPanelViewController`:

| Transcript state | Rows available | Live text content |
| --- | --- | --- |
| Available and enabled, speech segments present | Merged lines and reactions | Existing incomplete-text note, then merged rows |
| Available and enabled, no speech segments | Reactions, if any | Incomplete-text note, waiting-for-speech note, then reactions |
| Off, unavailable, or availability unknown | Reactions, if any | Existing status/unavailable reason, then reactions; keep transcript lines hidden as today |
| Off, unavailable, or availability unknown | None | Existing plain status/unavailable message |
| Any state | No reactions | Existing behavior, apart from the refactored renderer |

This adds Desktop-style reaction visibility without broadening transcript permissions or changing existing transcript-line availability semantics.

## Step 3 — Refactor attributed-string formatting

Replace the segment-only formatter with a row formatter:

- For `.line`, preserve the existing speaker, text, font, color, optional timestamp, and spacing exactly.
- For `.reaction`, render `time  emoji  name` using caption font and light-gray text.
- Resolve `name` as `You` for own reactions, otherwise `displayName`, otherwise `Participant`.
- Never format the internal effective sort date; only a real segment/event timestamp may be shown.
- Keep blank-line separation consistent for full builds and appended suffixes.

## Step 4 — Replace the cache with context-aware content caching

Store:

- the visible merged rows used for the current content;
- the header/status rendering context.

On each render:

1. Compute the current context and visible rows.
2. Append only for a same-context, non-empty, strict tail extension.
3. Otherwise rebuild the complete attributed string from the current status/header and rows.
4. Set the cache to `nil` for a plain status-only fallback.
5. Before assigning plain fallback text, restore body font and white text color so caption-styled reaction attributes cannot bleed into the fallback.
6. Preserve the existing near-bottom/follow-button logic and retain selection/scroll position on the append path.

## Step 5 — Update subscriptions without changing read state

- Change `chat.reactionHistory.$events` to call `requestContentRender()` unconditionally.
- Include `catchUp.$transcriptUnavailableReason` among transcript render inputs.
- Continue relying on `renderMode()` for tab-selection, appearance, and activation invalidation; no extra dirty-flag workaround is needed.
- Leave `markVisibleReactions()` scoped to Chat so Live text never acknowledges reaction visibility or changes unread badges.

## Step 6 — Add model and integration tests

### New `RockNRollTests/LiveTranscriptTimelineTests.swift`

Cover:

1. Reactions before, between, and after dated segments.
2. Exclusion of reactions earlier than the first dated segment.
3. Inclusion of all reactions when there are no segments.
4. Deterministic ordering for equal timestamps.
5. Trailing undated segments after dated segments.
6. An entirely undated segment list, with no visible distant-past date.
7. Reaction-only output when transcription is inactive, through panel-level tests below.

### Extend `RockNRollTests/ReactionHistoryPanelTests.swift`

Cover:

1. A reaction arriving on the visible Live text tab appears in the attributed transcript.
2. A reaction arriving before speech appears together with the waiting/status notes.
3. Reactions remain visible when transcription is off, unavailable, or still being checked.
4. Own and unknown-participant names render as `You` and `Participant`.
5. A reaction received in Chat appears after switching to Live text.
6. A reaction received while inactive/backgrounded appears after activation without hidden-view rendering.
7. A tail addition uses append behavior and preserves scroll/selection state.
8. A participant-name resolution or earlier/out-of-order event causes a correct full rebuild.
9. A status-context change cannot leave stale waiting/unavailable text.
10. Viewing Live text does not mark reactions seen and existing reaction panel tests remain valid.

New source and test files under `RockNRoll/` and `RockNRollTests/` are already covered by the folder-based target sources in `project.yml`.

## Step 7 — Verify after implementation is authorized

1. Run the new timeline tests and the full `RockNRollTests` suite using the existing `RockNRoll` scheme.
2. Run existing conversation/reaction UI tests.
3. On a narrow iPhone layout and a wide/docked layout, verify:
   - reaction before speech;
   - reaction between two spoken lines;
   - own and remote reactions;
   - arrival while Chat is selected;
   - arrival while backgrounded;
   - transcription off/unavailable with reactions;
   - scrolling, follow button, text selection, and Dynamic Type.
4. Confirm Catch up and unread badges are unchanged.
5. Report only checks actually executed; do not claim beta publication as part of this plan.

---

# 5. Acceptance criteria

The feature is ready when:

- Every reaction available in `ReactionHistoryStore` and passing the Desktop-style cutoff appears once in iOS Live text as well as in Chat.
- Reaction rows are chronologically interleaved with transcript rows and have deterministic tie ordering.
- Reactions can appear before speech and independently of transcription availability.
- No transcript line gains a fabricated visible timestamp.
- Existing transcript status notes remain accurate and no stale status text survives a context change.
- Tail updates append efficiently; mutations and reordering rebuild correctly.
- Live text does not alter reaction unread/seen state.
- Existing transcript-line availability behavior, Chat behavior, Catch up behavior, and scrolling behavior remain intact.
- The model and integration tests above pass after implementation is explicitly approved.
