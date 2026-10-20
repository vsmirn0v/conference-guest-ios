# One handed meeting controls

Approved design for easier access to meeting actions on iPhone, building on the View and More controls implemented in `90ee437`. The order is Share, Camera, Audio, Mic, Reactions, Leave. It brings Mic closer to a right-handed thumb and preserves direct reaction access. This is a reachability hypothesis to validate with both hands, not a measured ergonomic result.

Status: implemented against `b1ef18f`; qualification is recorded in `iphone-thumb-controls-validation-2026-10-20.md`. This design supersedes the primary action order in `meeting-access-plan-2026-10-20.md`; the rest remains in effect. The user explicitly requested commit/push without beta publication.

## Design

### Meeting dock

Keep the six actions in this logical order:

| Position | Action | Tap | Secondary action |
|---|---|---|---|
| 1 | Share | Existing sharing chooser or active-share controls | Open Share and Presenter settings |
| 2 | Camera | Toggle camera | Open Video settings and private preview |
| 3 | Audio | Open audio devices | Open the same devices destination |
| 4 | Mic | Toggle meeting microphone | Open Audio processing and private sound check |
| 5 | Reactions | Open the persistent reaction sender | Retain existing More shortcut |
| 6 | Leave | Existing leave flow | None |

Preserve the existing tap semantics, labels where already established, and accessibility identifiers. The draft uses “Camera” to make its purpose explicit; do not rename all existing “Video” labels merely to implement the order.

Use a short divider and modest internal spacing before Leave on narrow phones. Use the existing separate Leave surface when width permits. Do not reduce a touch target below 44 by 44 points to make the separation fit. The draft's leave confirmation illustrates separation only; it does not propose changing the existing leave-confirmation policy.

On portrait phones, View and More stay immediately above the trailing side of the dock. On landscape phones, the existing right rail follows the same order from top to bottom, with View and More to its lower left. Wide iPad and Mac windows retain inline View and More access and a separated Leave control. Reactions must remain adjacent to Mic in the primary-action sequence; supplemental accessories must not be inserted between them.

Never reorder by speaker, mute state, engine capability, grip detection or orientation. At accessibility text sizes, reflow in the same reading order into two columns:

| Left | Right |
|---|---|
| Share | Camera |
| Audio | Mic |
| Reactions | Leave |

Keep the symbols, visible labels and VoiceOver order consistent. Disabled or temporarily unavailable actions keep their position and existing explanation. Controls hide together; no permanent handle covers enlarged shared content.

### Settings sections

Present the section order as **Share, Video, Audio**. Keep the internal `StudioModel.Pane` identities and persisted values unchanged; presentation order must not depend on enum raw values or `allCases`.

The current Presenter-only pane cannot simply be relabeled Share. First make that pane a real sharing destination with the existing screen/window sharing action, active-source status and Stop controls, plus entry to Presenter. Reuse the existing source chooser and capability checks. Presenter remains the name of the composition feature inside Share.

On iPhone portrait, pin the selector above the primary action at the bottom of the sheet, inside the safe area. The settings body scrolls above this footer. Do not insert the selector into the Form's scrolling content or overlay it on fields. Reserve enough footer space that changing sections does not move the selector. When a section has no primary action, retain the selector's position without an unexplained disabled button.

On phone landscape, iPad and Mac, keep the selector below the sheet header. Short landscape windows need vertical space for preview and settings. Choose layout from the available presentation size and platform idiom, not a device model name. Do not move the selector merely because the software keyboard appears.

Maintain direct contextual opening:

- Camera secondary action opens Video; preview remains private while camera is off.
- Mic secondary action opens Audio processing and sound check.
- Audio tap opens Audio devices. Back returns to Audio, with its selector still available.
- Share secondary action opens the existing active Presenter editor when running, otherwise the Share landing content.
- More retains visible routes to the same destinations, so long press is optional.

Opening or switching sections must not publish a camera or microphone. Preserve the established private-preview lifecycle, sound-check privacy, active Presenter state, and full-canvas editor. Hide section switching during expanded canvas editing, as today. Returning from the editor restores the section and its scroll state.

Unsupported share capabilities must not expose a dead primary action. In Audio-only or held calls, explain availability without changing the other section positions. Leaving a meeting or replacing its engine retires the panel and all pending callbacks.

### Physical and visual details

- Validate 320- and 375-point widths, Pro Max portrait and both landscape directions. English and Russian labels must remain readable without forced hyphenation.
- Leave remains red; Mic and Camera use their existing on/off treatment. Do not make Mic a larger button that shifts its neighbors.
- Keep 44-point minimum target sizes and disjoint hit regions. Use the existing accessibility layout rather than shrinking text at large sizes.
- A completed long press consumes the short tap. Moving a finger away cancels it. Opening settings must never accidentally toggle Mic or Camera.
- VoiceOver announces selection and state, offers secondary settings actions, and restores focus on dismissal. Preserve Space-to-mute, existing Mac keyboard commands and Escape.
- Use existing Liquid Glass helpers and compatibility materials. Native blur, optical text sizing and SF Symbols will differ from the browser draft.
- Keep current landscape and fullscreen media geometry independent of toolbar drawing. A rotated or reopened panel must not leave an invisible touch-blocking layer.

## Implementation

1. **Define the action order once.** Introduce a small semantic order for the six existing toolbar roles. Supply existing button instances to `CallToolbar`; use the same order in `RockCallViewController` and `VendorIntegration/CallControls`. Audit accessory placement: `CallToolbar.items` currently inserts at `count - 2`, which would place accessories between Mic and Reactions after this reorder. Replace that positional assumption with an explicit accessory slot outside the primary sequence.
2. **Update dock geometry and accessibility.** Adjust `CallToolbar` separation and `MeetingAccessGeometry` together. Narrow layouts use a divider; wide layouts keep a separate Leave surface. Keep measured width and accessibility-size fallbacks. Set accessibility traversal to the visible reading order without changing action identifiers.
3. **Create the Share section contract.** Route its screen/window source action and active-share state to the existing sharing owner. Keep Presenter composition, permissions and system picker lifecycle in their current owners. Support source replacement, cancel, Stop and active Presenter reentry without starting two captures. Do not build another sharing transport.
4. **Extract an adaptive Studio selector and footer.** `StudioPanel` currently owns a top Picker and a separate footer. Render one selector at a time, above the footer action in phone portrait or under the header elsewhere. Derive presentation order explicitly as Presenter/Share, Camera/Video, Sound/Audio, while preserving model IDs. Keep preview/editor surfaces mounted across layout changes.
5. **Wire contextual routes and localization.** Preserve `StudioShortcut` cancellation and accessibility behavior; use it to open the right pane/subsection. Update More only where needed to expose the shared destinations. Localize Share/Video/Audio, instructions and availability states; leave data migration unnecessary.
6. **Validate and review.** Run focused geometry, routing and lifecycle tests, then the existing meeting access and Studio regression suites on Simulator and Mac. Review the diff for positional assumptions, capture lifecycle changes and event click-through. Physical iPhone validation is an ergonomic and native-media acceptance step when available.

## Invariants

The feature changes action placement and settings navigation. It must not change audio route selection, codec/bitrate policy, frame rate, receive subscriptions, PiP configuration or call recovery.

Opening settings performs only the existing authorized private preview/check behavior. Visual layout must not recreate active capture, renderers or the Presenter canvas. A layout-only change cannot start a broadcast, toggle the microphone, reset share zoom or replace a meeting.

Use one mounted dock and one active settings presentation per call. Avoid new per-frame layout timers, new material effects per button or a second model observing every audio-level update. Keep current model ownership and retirement guards.

## Acceptance

| Area | Required evidence |
|---|---|
| Geometry | Every button has disjoint targets at least 44 points in both dimensions; Leave separation fits at 320 points; View and More remain reachable. Cover normal and accessibility layouts. |
| Engine integration | Guest SDK, Rock, Telemost and TrueConf present the same order and callbacks. Check optional accessories and permission-limited controls. |
| Actions | Every short tap reaches its original action. Long press opens the correct settings without triggering the short tap. Reactions supports repeated sends. |
| Settings | Portrait selector stays fixed while content scrolls; landscape selector moves to the header on rotation; selected pane and preview identity survive. Audio devices Back returns correctly. |
| Share section | Screen/window source selection and cancellation, start/stop, running Presenter reentry, share replacement and window-resize regressions pass using existing transports. |
| Privacy | Switching Video/Audio/Share does not transmit private checks. Initial mic/camera remain off. Reactions and menus do not start capture. |
| Lifecycle | First portrait join, repeated rotation, background/PiP return, dismiss by outside tap and Escape, terminal meeting end and room switch leave no stale overlay or callback. |
| Accessibility | EN/RU and largest text; correct VoiceOver order/labels and focus restoration; keyboard commands preserved; Reduce Motion/Transparency respected. |
| Performance | Compare matched multi-participant Mac runs before/after for menu-open main-thread stalls and frame pacing; no new recurring work from the footer. No battery benefit is claimed from rearrangement. |
| Physical follow-up | Check both hands on a large iPhone, accidental Leave taps, native long press and portrait/landscape sheet behavior. Validate private preview and AirPods device access without changing routes unintentionally. |

The implementation can be accepted for source integration after automated Simulator/Mac checks and review. Record any deferred physical acceptance separately. Publishing a beta remains a separate user instruction.

## Draft

Interactive draft: `iphone-thumb-controls.html` in this chat's visualization directory. Variants: Portrait, Camera & sound, Small iPhone, Landscape, iPad & Mac. Tap Mic/Camera, open Reactions, use More to open settings, or hold Mic/Camera to inspect contextual routing. The settings section selector works; the source picker and system effects are represented as local placeholders.

The draft models layout and navigation only. It does not access a camera, microphone, Bluetooth device, system picker or conference.

Browser draft checks completed on October 20: all five variants at 760- and 320-pixel host widths, disjoint dock targets at least 44 pixels in both dimensions, Russian labels and larger control text, repeated reactions, long-press Mic opening Audio without unmuting, audio-device return navigation, and section switching with a stable portrait footer. Fixed a prototype long-press release issue found during these checks. Native Dynamic Type, system materials, media behavior and physical reachability remain implementation acceptance work.

## References

- [Apple toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars): grouping, consistent placement and distinguishing critical actions.
- [Apple segmented controls](https://developer.apple.com/design/human-interface-guidelines/segmented-controls): related selections and consistent segments.
- Existing `meeting-access-plan-2026-10-20.md` and `meeting-access-validation-2026-10-20.md`.
