# Rock’n’Roll 0.2.0 (82)

## Changes

- Preserve native Mac screen/window and Presenter pixels up to 3840 per edge
  and 8.29 megapixels. Incoming screen subscriptions and display preserve those
  pixels instead of losing text detail through camera-oriented limits.
- Hardware H.264 screen-detail policy favors text quality at adequate bandwidth
  and allows more compression under constrained sender budgets. Restore the
  actual encoder rate settings after format/quality resets.
- Apply screen sender policy atomically without invalidating SDK transactions.
- Integrate completed parent-thread recovery work (`903cb05`, `cd753a8`) and
  serialize native audio-device replacement before admitting its successor.

Details: [quality policy](screen-share-detail-policy-2026-10-14.md),
[review](screen-share-review-2026-10-14.md),
[measurements](measurements/screen-detail-2026-10-14.json).

## Validation

- Final isolated Mac suite: 719 cases, 68 platform/opt-in skips, zero failures.
- Final isolated iOS 17.5 Simulator suite: 720 cases, 86 platform/opt-in skips,
  zero failures. Native RemoteIO lifecycle requires physical hardware; its
  attempted Simulator runs stalled in host CoreAudio, so these cases run on iOS
  hardware instead. Mac production disables trackless output reservation.
- Physical iVitalii output lifecycle and sender-policy qualification: 14 cases,
  two Mac-only skips, zero failures. Actual output ownership/release/replacement
  passed; maximum concurrent native session count is one.
- Native deterministic recovery/ownership helpers: 25 cases passed with
  AddressSanitizer and UndefinedBehaviorSanitizer. Core suite: 103 cases passed.
- Real SDK/independent browser decoder: all five final calibrated 4K benchmark
  phases passed, including scrolling, annotated Presenter, a 300kb/s sender
  ceiling, and restoration. Fresh decoded content and unchanged 4K dimensions
  were observed in each phase. Text-region PSNR was 54dB at normal budget versus
  36–37dB for the matched upstream hardware reference, with similar app CPU.
- Final real SDK resize qualification passed through the independent browser:
  1920 → 2560 → 3840 → annotated 3840 output, with fresh decoded content.
- Final physical live receiving qualification passed three successive joins
  with actual audio energy and decoded moving video (14.3 seconds total).
- Normal signed Mac Release build passed. Both normal-package native slices
  match the published r5 provenance; a fresh release ZIP download matches its
  checksum. Normal iOS 17.5 Simulator integration passed 101 cases with five
  expected skips and zero failures.
- Publication gate still pending: real Mac receive-only audio plus microphone
  toggle validation. The run stalls inside AudioOutputUnitStart → CoreAudio HAL
  property IPC. Independent Chrome capture also stalled in AudioUnitSetProperty
  → CoreAudio HAL property IPC. Generated browser tracks bypassed its capture
  stall and qualified the phone, but not the Mac's actual output device. The host
  audio service must recover before this acceptance can be completed.
- No battery-life claim follows from process CPU. Real packet loss/reordering
  and all possible server configurations are outside this synthetic test.

## Artifact

- Native release: `guest-native-webrtc-150.7871.03-r5`.
- ZIP SHA-256: `ca2a0bbc319d1a9ea5cf9937339784139c8f59e362d4211ebec8d2a30ba49be3`.
- Provenance verifies all 19 native patches, wrapper/source revisions, build
  recipes, and both compiled slices; includes the complete parent patch series.
- Product commit: `982b27d` (native release tag and tested app sources).
- Archive: `2026-10-14/RockNRoll-0.2.0-b82.xcarchive`.
- App/dSYM UUID: `6CB1E9D2-3B60-3733-A152-DC23E26669C7`.
- Exported IPA SHA-256: `04a582c4fcdbcceadf5c03ea9e74740a9bcf63568d211223142844257a9dca86`.
- Archive/export passed strict/deep signature validation. All three bundles use
  version 0.2.0/build 82, iOS 16.0 minimum, team 5V64BP2H3P. Export uses production
  iCloud and lacks debugger entitlement. Purpose strings, encryption declaration,
  and required native symbols were verified; application dSYM UUID matches.
- Signed IPA remains local. Not uploaded or assigned to TestFlight groups while
  the Mac live audio acceptance is blocked by the host CoreAudio service.
- Tester notes prepared: “Sharper screen sharing and improved stability.”
