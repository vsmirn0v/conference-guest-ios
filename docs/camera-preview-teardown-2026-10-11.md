# Mac camera-preview teardown crash

Two TestFlight 0.2.0 (72) crashes on macOS 27.0.1 were captured at 22:05:36 and
22:07:35 MSK on October 11. The executable UUID matches the published build:
`F848C417-CED0-34F4-ADA0-797B471F2D60`.

Trigger: join a guest meeting, enable the built-in Mac camera, then switch to
another conferencing client connected to the same meeting.

## Cause

`CameraCapturePreviewView.stop()` sets the borrowed native preview's session to
nil. AVFoundation synchronously reconfigures its graph and pumps the main run
loop while waiting. Gallery layout can therefore reenter cleanup on the same
surface before the first detach returns. The crash stack contains both calls.

The second detach attempts to remove AVFoundation's `changeSeed` observer again.
The system log confirms an uncaught `NSRangeException`: the observer is no
longer registered. This is app preview lifecycle reentrancy, rather than an
outgoing encoder failure or a provider screen-share uploader teardown.

## Fix and invariants

- A stopped preview retires its source before calling AVFoundation. Repeated or
  nested stop requests return without a second native detach.
- The embedding surface relinquishes the previous binding before stopping it.
  A revision check preserves any newer source requested during the wait; the
  latest visibility request also survives reentrancy.
- Retained, retired views do not prevent a replacement from using native
  preview. Additional live views still share raw frames.
- The capture session remains owned by its publisher. Preview cleanup never
  starts or stops capture, changes the encoder, or creates another output.

## Verification

- Before the fix, two deterministic Mac regression cases failed with three
  assertions: repeated teardown, and a replacement preview lost during detach.
- Final Mac suite: 29 passed, two opt-in hardware checks skipped, zero failures.
- Final iOS 27 simulator suite: 34 passed, four device/Mac-only checks skipped,
  zero failures.
- Separate real Mac camera qualification: five passed, zero skips/failures.
  Includes 16 native detach/re-attach cycles with nested gallery cleanup, active
  publishing throughout, secondary raw-frame preview and restored publishing
  cadence. Measured preview frame interval: 33.34 ms (30 fps).
- Live guest meeting: camera enabled with microphone off; switched to the other
  native client in the same meeting and returned. Rock’n’Roll stayed connected
  and its preview remained visible. Camera off and Leave completed normally.
- Signed Release build passed strict deep signature validation. The debug-only
  reentrancy injection symbol is absent from its executable.

Local evidence: `.build/preview-crash72/crash-evidence.json`, `exception-log.txt`,
`mac-red.xcresult`, `mac-final.xcresult`, `simulator-final.xcresult`,
`mac-camera-qualified.xcresult`, and `live-mac-status.txt`.
Build/signature/test summary: `.build/preview-crash72/verification.json`.

Standalone test-run attempts that selected a native Mac executable instead of
the iOS-on-Mac host failed before launching. Full project-based tests passed;
those launch failures are not counted as product or hardware-test results.

The installed TestFlight build 72 is immutable and does not contain this fix.
