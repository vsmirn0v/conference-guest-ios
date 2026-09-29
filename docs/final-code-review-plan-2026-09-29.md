# Final code review and implementation plan

Reviewed source: `6f946b6`, following TestFlight 0.2.0 (21). This is a review and
plan; application code, dependencies, and hosted services were not changed.

The review covers first-party meeting lifecycle, routing/profile gates, both
media adapters, chat/transcript persistence, sharing previews, PiP, and common
call UI. The dependency checkouts are clean and match the pinned revisions.

## Findings

### F1 — P1: delayed callbacks can operate on a newer meeting

Evidence:

- `RockNRoll/SystemCallCoordinator.swift:130`: the failure completion of an end
  transaction calls `markEnded` and the current `onEnded` without checking that
  `self.callID` still equals the captured transaction ID. The start transaction
  already performs that check. The resume failure path also changes state
  without checking its originating call ID.
- `RockNRoll/VendorIntegration/EventRelay.swift:8`: queued delivery looks up the
  mutable callback when the queued block executes. The joined-room argument is
  discarded. The engine then forwards through its current event callback.
  A generation check in `ConferenceModel` does not establish provenance when
  an old event is delivered through the new callback.
- `RockNRoll/VendorIntegration/NativeConferenceEngine.swift:304`: teardown
  awaits sharing shutdown, then clears shared engine state and terminates the
  SDK conference without verifying that the same session is still current.

These are source-confirmed missing guards. A resulting wrong-room hang-up has
not been reproduced in this review; it requires delayed/reordered completions.
It is nevertheless the most important rapid-switching regression risk.

Implement:

1. Add call-ID checks to all asynchronous CallKit transaction completions.
2. Give each engine join a session token. Capture that token in callbacks and
   asynchronous tasks; check it after suspension before changing active state.
3. Make teardown an explicit barrier before installing the next session's
   handlers. Preserve room identity in SDK events where the API supplies it.
4. Capture the session-bound event destination at enqueue time through a
   thread-safe relay. Do not simply stamp the current token on an old event.

Test with a fake call transaction requester and controllable capture shutdown:
complete A's failed hang-up after B starts; queue A's left event before changing
handlers; stop A while a share-stop operation awaits. B must retain its call ID,
audio, controls, transcript, and connection. Exercise guest→guest and
guest→community→guest sequences.

### F2 — P2: valid chat messages can be silently dropped

`ChatStore.swift:34` accepts 2,000 Swift Characters. The app receiver at
`RockRoomEngine.swift:451` and browser receiver at `RockServer/site-src/app.js:149`
reject packets over 4,096 bytes. Neither sender enforces that encoded-packet
budget. Publishing success can therefore be reported for a packet receivers
will reject.

Reproduced using the actual Swift JSON encoder and the current packet shape:

| 2,000-character text | Encoded bytes | Receiver accepts |
| --- | ---: | --- |
| ASCII | 2,055 | Yes |
| CJK | 6,055 | No |
| Guitar emoji | 8,055 | No |

There is also a counting mismatch: Swift counts grapheme clusters; the browser
counts Unicode code points.

Implement a documented chat wire contract with consistent packet/ID/text
limits and Unicode semantics in Swift and JavaScript. Encode and validate before
adding the outgoing bubble or clearing its draft. Either expand the shared wire
budget or explain the byte limit before sending; never truncate silently.
Represent successful publication as sent, without claiming a recipient delivery
acknowledgement the protocol does not provide.

Test Swift↔browser messages at byte boundaries, multibyte/combined emoji,
escaping, oversized IDs, retry/deduplication, and the exact maximum accepted
packet. Browser updates must rebuild the bundled asset and use the existing
isolated deployment workflow.

### F3 — P2: profile validation disagrees with the community service

`ConferenceModel.swift:34` and the first-join editor allow up to 80 grapheme
clusters. `RockServer/main.go:161` accepts at most 60 Unicode scalar values and
rejects control characters. The website also uses 60 code points. A name the app
accepts can therefore fail to join a community room. `JamService.swift:59`
converts that HTTP 400 into a generic secure-connection error.

Implement a small typed join-policy/capabilities value for each engine, used by
the join gate and name editor. Preserve existing saved names; when a particular
destination cannot accept one, ask for an acceptable display name rather than
silently truncating it. Align character counting and normalization with the
service contract. Map validation, rate-limit, transport, and malformed-response
failures to distinct actionable errors.

Test 60/61/80-character names, combining marks and emoji sequences, whitespace,
controls, saved-name reuse, both first-join entry paths, and service HTTP 400/429.

### F4 — P2: a failed video preference is cached as applied

`VideoSubscriptionCoordinator.swift:38` records the desired value before
awaiting the SDK operation. On failure it remains in `attempted`; the identical
preference will not be retried until a toggle or reconnect/reset. The existing
test explicitly confirms this behavior. Avoiding a retry spin is good, but a
transient failure can leave the visible mode inconsistent with actual reception.

Separate desired, in-flight, and successfully applied state. Permit a bounded
retry or an explicit retry action for failed preferences, with cancellation on
new intent/session. Keep one writer and latest-intent coalescing. Do not retry
permanent failures indefinitely or reset successful subscriptions wholesale.

Test fail-once→success without changing mode, permanent failure, intent change
during backoff, publication removal, and reset while an operation ignores
cancellation. Verify camera reception actually stops while shares remain visible.

### F5 — P2: long-session message work is only partly bounded

- `ChatStore.swift:26`: the visible list is capped at 200, but `seenMessageIDs`
  retains every ID until the room is cleared.
- `NativeConferenceEngine.swift:726`: each combined publisher update maps the
  full SDK snapshot twice, even though the chat store shows only its suffix.
- `CatchUpTimeline.swift:115`: transcript retention is capped at 5,000, but a
  repeated larger snapshot reinserts discarded segments and sorts the full
  merged set before dropping them again.

Implement bounded message accounting and source-aware snapshot deltas. Preserve
the existing invariant that replayed snapshots do not increase unread counts.
Use a stable provider cursor/anchor where available; if coverage cannot be
established after truncation, expose that limitation rather than guessing.
Avoid pruning the deduplication set blindly. Separate message updates from
permission/menu updates, and skip sorting when retained transcript content has
not changed.

Test repeated/reordered 10,000–50,000-message snapshots, edited transcript
segments, reconnect replay, bounded memory, and unread counts. Measure main-thread
time and allocations before choosing a more elaborate index or collection.

### F6 — P2: persistence can block the UI or fail silently

`CatchUpStore.swift:57` synchronously waits for the file-writer queue while
leaving. That queue can be encoding and atomically writing a large transcript.
Correct ordering prevents history from reappearing, but the wait is on the call
UI path. `RoomHistoryStore.swift:54` publishes a changed favorite/history list
before writing Keychain and ignores write failures other than item-not-found.
A star or rename may appear saved and disappear after restart.

Use an asynchronous ordered catch-up teardown with completion acknowledgement
and coalesce superseded snapshots. Preserve the no-history-after-explicit-leave
invariant, including app termination during cleanup; do not replace the sync
call with fire-and-forget deletion. Add an injectable Keychain storage boundary,
handle update/add failures, and report unsaved changes. Skip identical title
updates instead of writing the whole history again.

Test a deliberately blocked writer, immediate rejoin, leave/relaunch, queued
old snapshots, Keychain update/add failures, retry, and favorite rename across
restart. Keep invitation passwords in the existing protected storage.

### F7 — P2: network body limits are enforced after buffering

`ConferenceEndpointResolver.swift:23` and `JamService.swift:50` use
`URLSession.data(for:)`, then check their 64 KB/16 KB limits. Those checks bound
what is parsed, not the bytes already downloaded and retained. Their final-URL
checks likewise occur after URLSession has followed redirects.

Introduce a small bounded JSON transport shared by discovery and credentials:
abort on an oversized body while receiving it, validate redirects before
following them, keep cancellation/timeouts, and compose rather than replace
the additional-root trust delegate. Retain the existing service-specific schema
and endpoint validation. This is a source-derived robustness issue, not a
reproduced memory exhaustion or disclosure incident.

Test streamed oversized and chunked responses, cancellation, redirect policy,
valid responses, and system-plus-bundled certificate trust. Do not loosen TLS
verification or impose a new fixed meeting-domain allowlist.

### F8 — P3: local-preview policy notifications cause redundant disk writes

`LocalSharePreview.swift:69` invokes the policy callback even when the value is
unchanged. `Shared/LocalSharePreviewTransport.swift:62` always atomically rewrites
the endpoint file for that notification. The legacy preview consequently does
unnecessary metadata I/O while receiving thumbnails. Native capture also
rechecks policy on every frame before applying its one-frame-per-second limit.

Notify only on policy transitions, and make `setWanted` idempotent. Reset the
published-policy cache explicitly when a session starts/ends. This is a small,
safe cleanup; it is not evidence of a major current CPU regression.

Test callback/write counts for unchanged frames, hide/show, background/foreground,
new session, and end. Preserve the last-frame preview and recursion protection.

### F9 — P3: UI and lifecycle responsibilities are too concentrated

`RockCallViewController` is 1,090 lines; guest `CallControls` is 928;
`NativeConferenceEngine` is 770. Keyboard actions, menus, toolbar appearance,
pin/zoom behavior and state projection overlap. `ConferenceModel` also handles
link resolution, profile gates, session switching and an alert-level UIWindow.
These are maintainability costs, not a reason for a full UI or engine rewrite.

After the correctness fixes, extract small shared call-action/menu/style helpers,
an explicit pending-invitation value, and presentation ownership for the website
picker. Move DEBUG fixture setup out of normal scene wiring. Keep vendor layout
workarounds inside its integration boundary and keep engine-specific capture,
audio recovery and participant representations separate until contracts align.

Validate extracted behavior with existing phone/iPad/Mac keyboard, orientation,
pin/zoom, conversation and deep-link tests. Make each extraction behavior-neutral.

## Implementation order and acceptance

1. **Session safety — F1.** Add controllable async service seams and regression
   tests, then fix call/session ownership. Acceptance: delayed work from A cannot
   stop, rename, render into, or clear history for B. No parallel active calls.
2. **User-visible contracts — F2/F3.** Agree limits between app, browser and
   service, validate before joining/sending, and improve typed errors. Acceptance:
   valid UI input reaches every supported recipient; rejected input keeps its draft
   or pending invitation and gives the correct next action.
3. **Preference recovery — F4.** Add bounded failed-operation recovery while
   preserving coalescing. Acceptance: displayed mode and reception converge after
   a transient failure without a room rejoin or an infinite retry loop.
4. **Bounded data and persistence — F5/F6.** Preserve unread/history semantics
   while removing the main-thread writer wait and silent persistence failures.
   Acceptance: memory plateaus for long sessions; leaving remains responsive;
   old history cannot reappear; failed favorite saves are visible and recoverable.
5. **Small resource fixes — F7/F8.** Bound network reads and deduplicate preview
   policy writes. Acceptance: body budgets stop receipt; idle policy produces no
   repeated endpoint writes; certificate and preview behavior remain intact.
6. **Optional structural cleanup — F9.** Extract shared pieces incrementally.
   Stop if an extraction adds more abstraction than duplication it removes.

Use Simulator first for injected races, contracts, storage, layout and long-session
fixtures. Use iVitalii only for real CallKit interruption recovery, capture
start→leave races, legacy ReplayKit behavior if matching hardware is available,
and background/PiP checks. Physical iPad testing remains intentionally excluded.
Measure CPU, resident memory, frame throughput and main-thread stalls on the same
fixtures and scene modes before/after relevant performance changes. Publication
should follow those checks, not an upload-only success signal.

## Changes not justified by this pass

- No convincing bulk-unused-code deletion was found. Indexed zero usages are
  not sufficient for UIKit selectors, closures and delegate entry points; direct
  checks found several apparently unused symbols are actually called.
- LiveKit already serializes its publishing operations internally. Do not add
  a second broad SDK lock as a generic response to the lifecycle findings.
- The current guest frame processor has bounded pending work and pixel-buffer
  pooling/zero-copy paths. A GPU/shader rewrite is not justified by this review.
- The provider frame tap is a deliberate, isolated compatibility dependency.
  Preserve its fallback and add compatibility checks when changing SDK revisions;
  do not spread renderer introspection into shared UI.

## Validation performed during review

- `ConferenceCore`: 21 tests passed.
- `RockServer`: `go test ./...` passed.
- Swift JSON encoding reproduced the chat byte-limit mismatch above.
- Main checkout and both package checkouts were clean; package revisions match
  `project.yml` and `Package.resolved`.
- The full application UI/physical suite was not rerun during this read-only
  pass. Source-derived races, storage stalls and long-session costs still need
  the targeted reproductions specified above.
