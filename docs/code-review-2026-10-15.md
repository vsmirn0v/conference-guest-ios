# Whole-codebase review and qualification

Baseline: `af28bbaa746b9ad5be5ba5f0ce733754ac114c1b` (build 88), `main`.
Two independent GPT-6 Astra ultra reviews inspected the application, core data
model, engine adapters, media/lifecycle code, browser service, tests and native
packaging. The first reviewer also delegated core/server and native/media review.
Accepted fixes were reviewed again, with subsequent routing and native-test
findings corrected before final approval. The reviewers found no remaining
actionable source blockers in the final implementation; this is scoped review
acceptance, not a claim that every dependency or device scenario is bug-free.

## Findings addressed

| Area | Change and invariant |
| --- | --- |
| Saved invitations | A successful A → B → A credential revisit now preserves A as the latest invitation across persistence and sync. |
| Engine identity | Versioned raw identifiers preserve verified routing for every supported engine, while retaining the legacy Codable representation for older clients. Unknown future identifiers remain readable. |
| Join consumers | History, calendar and handoff consume verified route evidence. A fresh positive probe wins; unresolved evidence does not arbitrarily override a known route. Legacy untyped entries can match rotated credentials without merging explicitly conflicting engines. |
| Persistence retry | Retry saves local changes even when cloud sync is disabled. |
| Microphone admission | Guest button, shortcut and workspace actions cannot unmute while held, unavailable or retiring. |
| Audio recovery | Admission and asynchronous worker completion use the same evidence rules, including observed hold when the delegate's unhold callback is missing. Current session and competing-call checks remain mandatory. |
| Broadcast lifecycle | One serial executor owns SDK startup, frame delivery and teardown. Stop closes admission immediately and drains an in-flight callback. Synchronous SDK errors cannot reenter teardown, and video frames cannot accumulate in a queued backlog. |
| Meter ownership | A reused microphone glyph rebinds when its model changes, without repeatedly resubscribing on level updates. |
| Publication watchdog | Production observers use active outbound statistics rather than mutating sender parameters. Missing/paused statistics are unknown. Startup requires two active zero-frame observations for the same stream before declaring failure, and bandwidth limitations suppress that conclusion. |
| Reaction work | Modern reaction adapters skip legacy view-tree discovery. History boundary grouping uses binary search and preserves inclusive boundaries, event order and duplicate-boundary semantics. |
| Stream pruning | Membership sets are built once per refresh instead of repeatedly scanning ordered ID arrays. |
| Cleanup | Removed an unused synchronous image decoder and unused reaction state; moved test hooks and diagnostic counters behind DEBUG. Added three missing English/Russian copy keys. |
| Browser ownership | Async join/media operations and callbacks are bound to their originating session. Leave invalidates admission immediately; rejected cleanup still releases tracks. Replaced tile attachments are detached and button labels follow actual publication state. |
| Native package identity | Packaging requires a clean Ninja dependency graph, correct evaluated GN arguments and matching linked, bundled and assembled binaries. It rechecks after notices and before ZIP creation. |
| Native test assertions | The hybrid decoder's Objective-C++ iOS XCTest patch now uses XCTest assertions, with explicit failure returns, instead of gtest macros that could miss XCTest failures. |

Unresolved calendar events remain hidden intentionally: the product requirement
is to list only meetings with resolved join links. No routing keyword heuristics
were introduced. The shipped native dependency remains r6; these changes do not
introduce a rebuilt decoder or new codec policy.

## Regression evidence

Evidence is under ignored `.build/review89/`:

- Core: 117 tests passed (`core-final.log`).
- Mac: 722 passed, 73 opt-in/platform skips, zero failures
  (`mac-final.xcresult`, 795 total).
- iOS 17.5 compatibility: 109 passed, three skips, zero failures
  (`compatibility-17.xcresult`).
- Final iOS 27 unit qualification passed (`simulator-final.xcresult`); the
  corrected control fixture and final localization resources are included.
- iOS 27 UI coverage: home, reaction overlays/palette, name entry and participant
  media badges passed in `simulator-full.xcresult`; the opt-in
  `ReviewRegressionUITests` cases were skipped.
  Its only failure was a new control fixture searching an unattached view.
  Mounting it in a window corrected the fixture; the focused follow-up passed.
- Browser chat and session/media lifecycle tests passed against the actual
  source with deterministic DOM/Room/fetch doubles; bundle regenerated.
- Go service tests passed. Twelve hermetic native-packaging regressions passed
  using the pinned real Ninja executable and temporary file-copy graphs.
- The native test patch parses with `git apply --numstat`; its standalone iOS
  Objective-C++ harness was not rebuilt or executed in this pass.

An earlier Mac run was interrupted twice by closing its last host window.
Unified logs identify normal UIKit termination (one later hit the termination
watchdog), not a renderer assertion or native crash. The focused 23-test retry
and subsequent full Mac run passed. No unsupported production workaround was
introduced for that interruption.

Reaction projection measured 0.160 seconds for 100 runs with 2,000 events and
400 boundaries on this Mac. This is a workload measurement, not a before/after
energy or battery claim. Hardware-only opt-in scenarios were not silently
converted into simulator acceptance, and no new physical call, AirPods or
ReplayKit qualification is claimed by this review.

## Web deployment

Only the `rock-web` binary/container was updated. Its previous binary is retained
as `/opt/rocknroll/bin/rock-web-linux-amd64.before-build89`; restart policy remains
`always`. No nginx or other service configuration changed. Public health,
generated JavaScript SHA-256 and the cache-busting `/app.js?v=8` reference were
read back after restart. Server binary SHA-256:
`1b8be109f9207fb50e0c8482df5701a5b5f46f90e979d86f90f3703ca61842aa`.

Signed artifact and TestFlight acceptance are recorded separately in the build
89 release record.
