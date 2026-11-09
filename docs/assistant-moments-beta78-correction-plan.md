# Assistant Moments — beta 78 correction plan

Status: implemented, reviewed, rebased onto beta 78, and published as native Mac beta **0.3.0 (79)**. Release source: `1a9d22a03077405c5d406e6985108fa0a3557566`; validation record: `docs/native-direct-0.3.0-79-validation.json`.

Base: beta 77, implementation commit `eba0c2d` and publication record `e0ee217`; final source also includes beta 78 commits `3a246ff` and `71be05a`.

## Objective

Close the reviewed gaps between Claude's Moments draft and the shipped Assistant view without expanding into reply variants, conversational commands, meeting outcomes, memory, or historical transcript storage.

## 1. P1 — Restore the overflow affordance

### Required behavior

When more than two current cards qualify, the overlay continues to show at most two cards and adds a compact **“+N in Assistant”** button beneath them. `N` is the number of currently displaced cards, not the inbox's total unread or historical Missed count.

Selecting the button opens the Assistant section. It must not open a meeting, deliver a reply, or change any Moment state.

### Implementation

- Add a coordinator-owned, in-memory set of displaced Moment IDs. Do not derive it from `unreadCount` or all Missed Moments.
- Add an ID when `apply()` displaces a qualifying card beyond `maxCards`.
- Remove an ID when that Moment is opened, answered, dismissed, or declined.
- Clear meeting-owned IDs when the meeting closes or its attention mode becomes Off.
- Clear the remaining overflow collection when its overlay cycle ends and no visible cards remain. It must start empty after relaunch.
- Extend `AttentionCardStack` with an `onOpenAssistant` closure. Render the localized overflow button only when the collection is nonempty.
- Wire the closure in `DesktopHomeView` to `workspace.show(section: .assistant)`; keep workspace navigation out of the reusable card view.

### Tests

- Three simultaneous qualifying cards produce two visible cards and overflow count one; additional cards increase it accurately.
- Historical unread/Missed records do not affect overflow count.
- Opening/answering/dismissing/declining an overflow Moment removes exactly that ID.
- Off, meeting close, overlay-cycle completion, and relaunch leave no stale overflow entry.
- The overflow action selects Assistant and has no delivery or learning side effects.

## 2. P1 — Keep terminal Moment details truthful and inspectable

### Required behavior

After Open, Send, reaction, Say it, Dismiss, or Decline, the selected Moment remains selected and displays its new terminal state. It must never claim that an open meeting is closed.

- **Answered:** show original evidence and the final sent text, spoken text, reaction, or opened outcome when present.
- **Dismissed / Not for me:** show original evidence and the recorded terminal state.
- Terminal details are read-only but retain **Why** and inspector evidence.
- Live and Missed Moments retain their current active-meeting actions; only an actually missing/closed meeting shows the closed-meeting explanation.

### Implementation

- Separate “terminal Moment” presentation from “meeting unavailable” presentation in `AttentionMomentsView`; do not use `selectedCard == nil` as a proxy for a closed meeting.
- Preserve or reconstruct a read-only card for inspector use after `feedback()` removes the overlay card. Do not reopen the overlay.
- Ensure terminal cards expose no chat, reaction, voice, Open, Dismiss, Decline, or learning controls.
- Render `AttentionMoment.sent` and `AttentionMoment.reaction` in the Answered detail when available.
- Keep the existing journal outcome ordering and feedback/learning records unchanged.

### Tests

- Each terminal outcome leaves the Moment selected, inspectable, and read-only.
- An Answered Moment in a still-active meeting never shows the closed-meeting message.
- Sent chat, spoken text, and reactions appear in their Answered details.
- Terminal Moments cannot deliver a second response through stale card controls.
- Existing feedback, edited-reply learning, and overlay removal tests remain unchanged and green.

## 3. P2 — Correct detail-state presentation

### 3a. Remove duplicate inspector controls

Remove the outer **Why** button from `AttentionMomentsView`; the selected card already provides it. The fallback/terminal presentation must use the same single inspector entry point.

### 3b. Scope errors to their Moment and operation

Replace the coordinator-wide `summaryError` display state with per-Moment error state, keeping summary and reminder failures distinct.

- Read only the selected Moment's corresponding error in the detail view.
- Clear that Moment's summary error when a new summary starts and its reminder error when a new reminder is attempted.
- Switching rows neither moves nor clears another Moment's error.
- Cancellation remains silent and does not create an error.

### 3c. Mark only rendered rows seen

Move seen marking from whole-filter `onAppear` / filter-change handlers to each Moment row's actual appearance.

- Remove bulk `seen()` calls over the filtered array.
- A row appearing in the lazy viewport marks only that Moment seen.
- Scrolling reveals additional rows and marks them seen once; store/journal deduplication remains unchanged.
- Notification selection must still reveal and mark the requested Moment seen through its rendered row.

### Tests

- Summary/reminder failure for Moment A is not displayed for Moment B; retry semantics and cancellation remain correct.
- Reducer/store tests confirm repeated seen events are not journaled.
- UI acceptance covers initial viewport, scrolling, filter changes, and notification click-through.

## 4. Verification and release gate

1. Run focused `AttentionTests` and `AttentionMomentsTests`, including the new overflow, terminal-detail, error-scoping, and seen-marking coverage.
2. Run `DesktopParityTests` and `VoiceCloneTests` without rebuilding to catch navigation and voice regressions.
3. Run the complete Debug suite and separate any unrelated existing failures from regressions.
4. Perform a manual Mac UI pass with English and Russian:
   - Three-card overflow and Assistant navigation.
   - Send, reaction, Say it, Open, Dismiss, and Decline terminal details.
   - Active versus closed meeting messaging.
   - Summary/reminder errors across two selected Moments.
   - Viewport-based unread badge clearing and notification selection.
5. Check VoiceOver labels, narrow-window layout, and that no overlay or terminal detail can accidentally deliver content.
6. Run localization lint, `git diff --check`, Release archive validation, and all distribution-tool tests.
7. Publish as the next beta only after the focused and regression suites pass; verify immutable DMG bytes, beta feed/inventory, and unchanged stable target.

## Explicitly out of scope for the beta 78 correction

These were out of scope for that correction. Later commits on main added reply variants, typed commands, meeting outcomes, local memory, and Neural Engine voice-cache recovery; this plan does not describe them.

- Historical **Since then** generation after a meeting's in-memory transcript is gone.
- Roadie persona and a Settings reorganization beyond what those later commits shipped.
- Unrelated full-suite failures.

## Acceptance result

The working tree matches the reviewed step-2 interaction contract: overflow is discoverable, terminal details remain truthful and inspectable, errors belong to the correct Moment, and unread state reflects rows actually shown. The final UI acceptance pass also verified notification click-through, the 900 × 560 layout, accessibility exposure, and duplicate-delivery prevention.

### Completed verification — 2026-11-08

- Focused `AttentionTests`, `AttentionMomentsTests`, and `MicrophoneMoveTests`: **80 tests, 0 failures, 2 skipped** (`focused-attention-final.log`). Both skips require Rapid-MLX on `127.0.0.1:8000`, which was not running. The new reducer test confirms that a Seen event keeps `updatedAt` unchanged both immediately and during journal replay while retaining the event's actual timestamp.
- Native SwiftUI/AppKit UI acceptance in English: **3 tests, 0 failures** (`ui-acceptance-en-readorder.log`). Russian: **3 tests, 0 failures** (`ui-acceptance-ru-readorder.log`). Each result exported **22 screenshot/accessibility attachments**. The harness renders the production views in real `NSWindow` instances and presses their actual accessibility actions against isolated stores and fake delivery channels.
- All six terminal flows—Open, Send, reaction, Say it, Dismiss, and Decline—leave the Moment selected, truthful, inspectable, and read-only. Reselecting each terminal Moment and attempting the available coordinator actions produced no second chat, reaction, voice, or open action. Overflow opened Assistant once without changing state or delivering content.
- Notification selection starts with an old target outside the rendered viewport, scrolls its real row into view, marks only that rendered row seen, and leaves the row exposed. Seen updates no longer alter recency ordering, avoiding both the selection jump and unnecessary lazy-list reordering.
- Card identity/read-only transitions clear stale decline editing state; a declined terminal Moment no longer retains its reason editor. Send, reaction-menu, and overflow controls expose accessibility labels/identifiers and usable actions.
- English and Russian error, notification, terminal, and narrow-window captures were visually reviewed at **900 × 560**. The Russian Moments filter uses the small control size and displays “Отвечено” without clipping. Intentional single-line card-title truncation does not remove the full detail title. Transparent capture backgrounds are a harness rendering artifact.
- Separate live VoiceOver navigation sessions ran in English and Russian with real speech output active: **1 test, 0 failures per language** (`voiceover-auditory-en.log`, `voiceover-auditory-ru.log`). VoiceOver was stopped afterward. System output activity confirms spoken playback, but the logs do not transcribe or independently assess every phrase heard by the listener.
- Offline and hardware `SharedEngineSpikeTests`: **2 tests, 0 failures**. The hardware fixture mixes its deterministic tone with the microphone upstream of VPIO's input mixer; sender switching takes about **0.10 seconds** without an engine restart.
- Broader selected parity run (`SharedAudioEngineTests`, `SharedPlayoutGateTests`, `SharedEngineSpikeTests`, `DesktopParityTests`, and `UpdateAdmissionTests`): **111 tests, 0 failures**. `DirectUpdaterTests` was selected but compiled out because `NATIVE_DIRECT_UPDATES` is not enabled in this configuration.
- Camera metadata barrier regression: isolated test passed in **0.056 seconds**. Warm-up and join now use the same saved-camera cache key.
- Live AirPods acceptance: headphone route recognized; local talk-back played successfully with **0 remote-peer RMS**; assistant hold/release, push-to-talk isolation, synthesized voice reply, and clean leave passed. Voice-reply remote RMS was **0.1296**.
- Final `git diff --check`: clean. Temporary camera, spike, and route diagnostics were removed.

### Release-gate results — 2026-11-08

- `VoiceCloneTests` without rebuilding: **13 tests, 0 failures** (`voiceclone-release-gate.log`).
- Complete Debug suite without rebuilding: **370 tests, 33 skipped, 3 assertion failures across 2 test cases** (`complete-debug-release-gate.log`). `DesktopSharedTextTests.testNativeCopyActionFromRealTextSelectionInActiveWindow` could not obtain an active key window and did not reach an active text selection; it failed again in isolation. `LocalTranscriptionTests.testBundledCatalogPinsEveryFileToARevisionAndChecksum` has no configuration-key mapping for the existing `voxcpm2_coreai` model kind; its test and catalog implementation are unchanged by this work. Isolation results are in `full-suite-failures-isolated.log`. Neither failure is in the Assistant/Moments change set, and neither was altered under the explicit unrelated-failure and Neural Engine exclusions.
- Localization: all six English/Russian `.strings` and `.stringsdict` resources passed `plutil -lint`. Key, nonempty-translation, format-argument, and plural-key parity passed for **1,812 strings and 8 plural entries**. The iOS `LocalizationTests` bundle could not be resolved in this detached worktree because five vendor XCFramework binary artifacts are absent; no simulator resource-test pass is claimed.
- Distribution tooling: Python compilation passed and **27 tests, 0 failures** passed after supplying the account variables required by XcodeGen (`distribution-tests.log`). The read-only publication fixture inside those tests did not publish anything.
- The earlier local direct **0.3.0 (78)** Release archive succeeded and its **58 archive hashes** matched `build-evidence.json`, but it predates the final UI fixes and does not validate the current source. It was not Developer ID export, notarization, Gatekeeper acceptance, or distribution evidence (`release-archive.log`).

### Beta 79 publication — 2026-11-08

- Final source `1a9d22a03077405c5d406e6985108fa0a3557566` includes the beta 78 Neural Engine recovery fix. Focused Assistant, voice, audio, update, and parity gates: **206 tests, 0 failures, 3 skipped**. English/Russian UI acceptance: **0 failures in each language**; live VoiceOver sessions also completed without interaction failures.
- Direct Release archive **0.3.0 (79)** was Developer ID exported, notarized, stapled, Gatekeeper-validated, packaged, and revalidated from its mounted DMG. The outer DMG is not separately notarized.
- Immutable `RockNRoll-0.3.0-79-arm64.dmg`: **26,974,695 bytes**, SHA-256 `e090e5c66a372cdc8c9d06feb6c5bc64715b2fc134720d6972ca52a4b30f865a`.
- The publisher installed the files but its first HTTPS verification timed out. Direct readback subsequently matched the immutable artifact, beta alias, signed feed, and inventory exactly. Stable remains **0.3.0 (53)**, SHA-256 `0eb305ed22fcfb2e8de2d6bb53fdb76cfce7b31d88faaf4e8b2e7f5f5641a009`.
- Full evidence and the disposition of the two unrelated earlier complete-suite failures are in `docs/native-direct-0.3.0-79-validation.json`.
