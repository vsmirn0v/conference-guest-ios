# Audio unit session ownership

Patch `0007-audio-session-ownership.patch` is applied after
`0006-audio-initialization-failure.patch` and changes only AudioDeviceIOS.h/mm.
It preserves the earlier Initialize-failure unwind.

`has_begun_session_` records WebRTC session ownership independently of
`has_configured_session_`, which records AVAudioSession activation/configuration.

- A successful begin owns one session count for the unit lifetime.
- Temporary interruption unconfiguration releases AV activation but preserves
  session ownership and its observer registration for resume.
- Full shutdown ends ownership once, even if audio was never available.
- Failed begin/configuration/initialization uses the same shutdown path.
- Explicit stop/Terminate also releases initialized-but-never-started resources.
- Shutdown does not invoke AudioOutputUnitStop on an uninitialized/disposed unit.

Before/after hashes are stored in local generated analysis. Reverse patch and
whitespace checks passed. The implementing agent did not build or run tests.

Required regression: with manual audio enabled and audioEnabled=false, snapshot
session count, reserve/create then release and assert count returns to baseline.
Repeat with availability false->true->false->true, ensuring the unit lifetime
retains exactly one begin and full shutdown restores the original count.
A test-only native diagnostic or KVC getter can read the pinned WebRTC
webRTCSessionCount; no Apple private API is needed.

## Integration validation

The root integration subsequently built both ARM64 slices and passed the native
session-count/unavailable-audio regression on Mac, iOS 27 Simulator and iOS 17.5
Simulator. Physical background quiet-gap, late-participant and call-resume checks
also passed. See `docs/guest-sdk-audio-rebuild-2026-10-13.md` for the actual runs
and remaining coverage; the implementing agent's source-only review above is not
the final integration status.
