# One handed controls qualification

Source baseline: `b1ef18f`, October 20, 2026. The approved design is in `iphone-thumb-controls-plan-2026-10-20.md`. Beta publication was explicitly excluded.

## Changes

- Both meeting UI implementations use the same named toolbar initializer: Share, Video, Audio, Mic, Reactions, Leave. Narrow layouts separate Leave with a divider; wide layouts retain its separate surface. Accessibility reading order matches the visual order, including the two-column layout. View and More remain outside this sequence.
- Studio presents Share, Video, Audio. The selector stays above a stable action slot on portrait phones and below the header in landscape, on iPad and on Mac. Presentation-container size decides placement, so a narrow landscape inspector does not masquerade as portrait. Resizing preserves private capture and preview identity.
- Share opens a landing page for the existing source picker, current sharing status and Stop. Presenter remains an explicit private editor with a Back to Share action. A running Presenter reopens directly; ordinary sharing continues while a replacement is prepared privately.
- Sharing requests dismiss Studio before native consent, then check current capability, hold/end and engine ownership again. An unavailable action is explained without a dead primary button. Navigation does not publish private checks.
- Share observes only Presenter availability/start/stop state. Scene/frame updates are not forwarded to the whole panel. A delayed start cannot leave the landing's Stop button stale or disabled.
- Largest text exposed an oversized scaled footer in landscape. The footer now uses intrinsic height there; only portrait reserves a stable slot, scaling typography rather than all padding. Long primary labels have localized short fallbacks with their full accessibility names.

No codec, resolution, frame-rate, subscription, audio-route, PiP or recovery policy changed. No new recurring task or per-frame observer was introduced. No energy or ergonomic benefit is claimed without physical measurements.

## Review

GPT-6-Astra xhigh reviewed the design, initial implementation and subsequent fixes. Resolved findings: source replacement blocked during ordinary sharing, missing return from Presenter to Share, disabled unsupported-share button, unobserved asynchronous Presenter state, and large-text footer/body starvation. Final source review found no remaining P1/P2 issues.

## Automated evidence

Results and screenshots are retained under ignored `.build/thumb-controls/`.

| Target | Evidence |
|---|---|
| Mac, Designed for iPad | `mac-final.xcresult`: 101 checks, five expected hardware/live-room skips, zero failures. Broad regression before the final accessibility footer adjustment; covers toolbar/access, Studio, call presentation, meeting actions and Presenter. |
| Mac, final source | `mac-acceptance.xcresult`: 24 checks, zero skips/failures. Includes mounted inspector dismissal, late hold/end requests, preview identity across resize, and filtered asynchronous Presenter observation. |
| iPhone Pro Max, iOS 26.5 | `sim-regression.xcresult`: seven UI checks plus 101 unit/integration checks, eight expected unit skips, zero failures. Broad regression before the final accessibility footer adjustment: native/guest direct access, rotation, private preview, long-press sharing, dock order and Russian largest text. Final footer rendering is covered on SE and final source builds on Mac/iOS 27. |
| iPhone SE, iOS 17.5 | `se-regression.xcresult`: Presenter canvas expansion/return, private preview, native sharing shortcut, prejoin privacy, delayed Presenter start and adaptive dock/selector passed; all 17 workflow checks passed. The added profile-scroll assertion initially failed: its control-type locator and full swipes missed a short profile row between tall accessibility rows. `se-accessibility.xcresult` passes with the actual Music button and bounded drags. Its portrait/landscape screenshots confirm readable primary actions and a usable scrolling settings body. |
| iPad, iOS 27 | `ipad-smoke.xcresult`: dock order, private media remaining off, top selector, selected pane and portrait/landscape round trip passed. |
| iPhone Pro Max, iOS 27 | `ios27-smoke.xcresult`: both checks passed. Short-tap sharing still starts/stops; long press remains private. Dock order, adaptive selector, pane switching and rotation passed on the final source. |

Geometry tests cover normal, vertical and accessibility layouts, disjoint touch targets of at least 44 points, visible ordering and accessibility traversal. Mounted lifecycle tests use the production custom presentation and reject source requests retired during dismissal. Preview tests check the same view and exactly one private-capture start across size changes.

Localization property-list lint and `git diff --check` pass. Builds use Xcode 27 and the retained qualified framework cache. An initial build failure was stale ignored package-cache metadata pointing to a deleted DerivedData directory; only that metadata was repaired, with no dependency/source revision change.

## Limits

Physical one-handed reach, real VoiceOver focus, native broadcast consent and hardware media acceptance remain follow-up checks. Tests here use capture-free fixtures and existing media lifecycle regressions; they do not claim a new live multi-engine sharing qualification or a battery comparison. Existing largest-text Form rows can still wrap awkwardly; the verified improvement is usable body space and reachable scrolling controls.

The previously published build remains unchanged. No version bump, archive upload or TestFlight distribution is part of this change.
