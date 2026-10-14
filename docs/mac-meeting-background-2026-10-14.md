# Mac meeting window lifecycle

## Plan and final implementation

Keep the existing application process, UIKit scene, meeting model and media engine.
An additional media extension would introduce another owner without solving native
window closing. The retained meeting keeps the existing audio recovery and routing.

During a meeting, the native Close button hides the application. Command-W has a
meeting-scoped UIKit command; the forwarding native window delegate also protects
the normal AppKit Close path. Idle Close and ordinary Quit retain normal behavior.
The native menu-bar item offers Show meeting, microphone mute/unmute, input/output
selection, Leave and Quit. Leave reveals the home screen and removes the item.
Show uses the owning UIKit window's `makeKeyAndVisible()` after unhiding the
application, and restores incoming video demand without creating another session.
Visibility confirmation is bounded and rejects completions from an older hide,
show or invalidated coordinator. The hidden marker clears only when the actual
native window is visible. Apple processing rejected `makeKeyAndOrderFront:` in
build 85; that selector is entirely absent from build 86.

The bridge resolves public AppKit APIs only on the Designed-for-iPad Mac runtime.
It does not link AppKit directly, inspect private UIKit internals, or swizzle classes.
Apple does not document an exact UIWindow-to-NSWindow mapping for this runtime:
binding therefore requires a sole foreground application scene, its sole visible
normal UIKit window, and either the eligible native main window or a unique
eligible native window. Ambiguity fails closed. Panels, sheets, child windows,
hidden windows and non-normal window levels are excluded.

The captured native window remains weak; its disappearance requires a new scene
coordinator. Its original delegate is forwarded with the correct ABI, including
scalar and struct returns. Invalidation restores the delegate and Close button's
opaque target/action only when still owned. A Close button with no original action
is left alone. Model activity is refreshed synchronously before a cached Close
keyboard action so an ended meeting cannot remain hidden accidentally.

All engines expose their existing workspace controls. Menu actions carry the
meeting generation and desired microphone state; stale commands cannot affect a
replacement meeting or reverse a newer headset mute decision. Hold, unavailable
microphone, ownership loss and termination reject inappropriate actions. Audio
device choices reuse the existing validated Mac device selector.

## Qualification and limits

- Astra ultra reviewed the plan and final source; discovered Close-action,
  ownership and asynchronous-state edges were fixed with focused regressions.
- Automated Mac tests cover forwarding, owned restoration, stale actions,
  reconnect replacement controls, hold/availability, termination and idle Close.
- A disposable guest room with an independent synthetic browser sender qualifies
  the real standard Close button and native Show menu. Audio continues hidden;
  fresh moving video returns after restoration in the same logical meeting.
- The normal AppKit Close delegate path is included in live qualification.
- iOS simulator checks cover runtime gating and the absence of a Mac shortcut.
- User requested automated checks only. A physical Dock click, physical keyboard
  Command-W, full-screen transitions and macOS 26.2 were not manually qualified.
- The bridge remains runtime-qualified compatibility code, not a full AppKit port.

## Initial guest audio focus

For an explicit foreground iOS guest join, prepare nonmixable communication audio
once so session activation can pause music already playing. Preserve HFP duplex
routing and the selected external output. Route notifications cannot re-enable
mixing before the call owner grants activation. After that grant, restore ordinary
mixing so deliberately started YouTube/Instagram audio can coexist with the meeting.
Mac behavior and other engines retain their existing policy.

Service resets and transport recovery never repeat this initial music takeover,
including a reset while the first preparation is queued. Audio-session work stays
on the existing serialized worker and uses revocable leases.

An explicit join grants a bounded, single-episode startup permission to retry a
transient initial activation failure or a began-only route interruption. Successful
AVAudioSession activation is still mandatory. Competing calls, transfer hold,
service loss, Leave, replacement and timeout revoke the permission. Competitors
are checked again before publishing a queued activation. Later interruptions
cannot reuse the startup permission. Persistent initial failure retires the owner
before reporting failure. Unknown audio interruptions do not claim a confirmed
phone-call hold.

Automated checks cover focus/mixing ordering, reset-before-preparation, bounded
retry, competitor arrival during queued activation, permission retirement and
existing phone-call recovery rules. Physical Volvo acceptance remains pending:
Music playing → Join → Music paused → meeting audible on the car route; then
mute/unmute, other-app playback and real phone-call recovery. Simulator evidence
does not prove Bluetooth routing or audible playback.

Apple references: [mixing options](https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/mixwithothers),
[Bluetooth profiles](https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/allowbluetootha2dp),
[activation priority](https://developer.apple.com/documentation/avfaudio/avaudiosession/setactive(_:options:)).
