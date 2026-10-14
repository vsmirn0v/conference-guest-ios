# Rock’n’Roll 0.2.0 (90)

Performance and startup audio-route release. Baseline: `50f5420` (build 89).
The [performance report](performance-2026-10-15.md) records the implementation,
paired workload measurements, review findings and remaining qualification plan.

## Changes

- Conversation rendering coalesces bursts and defers invisible content layout.
- Participant-strip updates preserve controls and update only changed chips.
- Camera availability uses an observed inventory rather than repeated discovery.
- Already-seen reactions do not copy/publish the full history on scrolling.
- Fresh guest meetings keep the active external audio route instead of applying
  the SDK's default Speaker override. Same-call selected-route recovery remains.
- Default 30 fps, outgoing media quality, codecs and native r6 are unchanged.

## Qualification

- ConferenceCore: 117 passed.
- Full Mac: 736 passed, 74 explicit opt-in/platform skips, zero failures.
- iOS 27 full units: 716 passed, 92 skips; final changed-source follow-up:
  57 passed, seven skips. Zero failures.
- iOS 17.5 changed-source compatibility: 91 passed, seven skips, zero failures.
- iVitalii physical audio/session tests: 47 passed, no skips, zero failures.
  Two fresh muted/camera-off guest joins retained AirPods at settled checkpoints.
- Physical and Mac paired performance fixtures: three tests passed on each.
  CPU-work gains are measured; a valid battery-power trace remains unavailable.
- Independent GPT-6 Astra ultra source review closed all three reported issues;
  final review found no remaining actionable source blocker in this diff.
- An initial Release compile exposed a missing direct AVFoundation import that
  Debug's transitive module had masked. The explicit import fixes it; final
  signed Release archive succeeds.

Raw evidence is under ignored `.build/performance90/`. UI regression results,
signed IPA verification and TestFlight group readback are recorded after final
qualification. Upload alone is not publication acceptance.
