# Direct meeting View and More access

Implemented the approved [access plan](meeting-access-plan-2026-10-20.md) on
`main`, starting from `de99013`. This task does not publish or bump a beta.

## Behavior

- View/current mode and More have a stable capsule beside the meeting dock on
  wide windows, above the dock in phone portrait, and beside the landscape rail.
  Reactions, Audio and Leave retain direct access. Holding Reactions still opens
  More, and the palette's existing More link remains available.
- View separates Focus/Gallery from incoming All video, Screen sharing only
  and Audio only. Audio only remembers the layout. The current filter is shown
  in the capsule; VoiceOver also announces the remembered layout. Unavailable
  Gallery has an explanation. Follow speaker is shown for manual focus.
- More opens directly to Camera & sound, Share & Presenter, Invite people and
  Meeting details. Existing transport handlers and capability checks are reused.
  Control visibility, Fit and floating-video preferences remain in Meeting
  details. Redundant header/layout-picker entry points are removed; paginated
  galleries retain their page controls.
- The shared screen keeps full-window bounds, renderer identity and zoom.
  Opening tools does not publish local media or change incoming subscriptions.
  Default and largest accessibility text have disjoint targets of at least
  44 points; English and Russian labels are localized.
- Command-Shift-L opens View and Command-Shift-M opens More. Existing shortcuts,
  Escape, Space-to-mute and the reactions shortcut are retained.

## Review fixes

An independent `gpt-6-astra` xhigh review covered the shared controls, both
renderer integrations, panel lifetime, and state/geometry tests. All actionable
findings were addressed; its final source pass found no remaining P1/P2 issues.

The fixes include moving the multi-share selector clear of the new capsule,
distinguishing effective and remembered layout, explaining unavailable Gallery,
and giving dock/chat tools the same per-call presentation owner. Ending a call
invalidates queued actions before asynchronous media teardown. Retirement also
handles a panel still being presented, without issuing a duplicate dismissal
during an active dismissal. Temporary unmounting and terminal retirement are
separate states.

Rendered Mac inspection caught a View panel too short to show Audio only and
dark menu icons with poor contrast. View now requests 600 points, or 680 when
Follow speaker is available, clamped to the available sheet height; short and
large-text layouts scroll. Icons use adaptive template rendering. Dismissal
tests wait for UIKit transition state instead of fixed animation sleeps.

The dock More button and the palette's legacy More link now have distinct
accessibility identifiers. The retained composer test selects the visible
Meeting details action rather than the similarly named header behind its panel.
Both previously failing UI scenarios pass in their final rerun.

## Regression results

Counts in different rows overlap; they are not a unique-test total.

| Target | Result | Local evidence |
|---|---|---|
| ConferenceCore | 122 passed, no failures | `core.log` |
| Mac hosted regression | 116 selected, 5 expected skips, no failures | `mac-final5.xcresult` |
| Final Mac access/actions checks | 11 passed, including mounted button hit tests, teardown transitions and rendered panels | `mac-final9.xcresult` |
| Final iOS 26.5 hosted regression | 116 selected, 7 expected skips, no failures | `sim-final9.xcresult` |
| iPhone 17 Pro Max, iOS 26.5 UI | 12 distinct scenarios pass across the corrected runs: direct View/More, layout/filter independence, rotation, Russian large text, Gallery selection, chrome dismissal, full-canvas zoom/Fit, held reactions, palette, unsupported reactions and composer draft retention | `sim-interaction4.xcresult` and `sim-final9.xcresult` |
| iPhone SE, iOS 17.5 UI | All 3 direct-access scenarios pass, including rotation and largest Russian text with scrolling | `small-final10.xcresult` |
| iPad, iOS 27 UI | Guest layout/filter flow and native direct controls through rotation both pass in an isolated rerun | `ipad-isolated11.xcresult` |

The first broad UI run found locator/navigation failures and the duplicate More
identifier; final reruns above close those failures. The iPhone SE run slowed
while an additional iPad runtime automation session was stalled; its duration
is not a responsiveness or performance measurement. English/Russian catalogs
pass `plutil -lint`; `git diff --check` passes.

The initial parallel iPad attempt was interrupted while XCTest waited for its
post-tap idle notification. A screenshot showed the correctly presented View
popover; a later sample found the main thread idle in 99.44% of samples, with no
SwiftUI/layout loop. This does not establish the source of an earlier CPU spike.
No production timing workaround was added. Both iPad scenarios subsequently
passed when run serially with bounded test timeouts.

## Evidence boundaries

Mac checks use the signed Designed for iPad target, real hosted UIKit windows,
mounted-view hit testing, panel presentation/dismissal and rendered attachments.
Xcode rejects external XCUI tests for this Mac target; no Mac XCUI pass is
claimed. Simulator tests provide actual touch, sheet/popover, scrolling and
rotation coverage. No physical iPhone, new live-room codec/audio, or battery
qualification is claimed for this UI change. Media processing and frame-rate
policy are unchanged.

The local `.build/meeting-access/` directory retains logs, result bundles and
rendered screenshots; these generated files are not committed.
