# Rock’n’Roll 0.2.0 (84)

## Changes

- Keep Mac incoming audio running across microphone mute/unmute. Avoid unnecessary
  synchronous native receiver-observer work during media updates.
- Restore Mac AirPods mute/unmute, including the first unmute after joining with
  the microphone off. Add Space as a Mac microphone toggle while preserving typing
  and focused-control behavior.
- Coalesce Mac audio-route notifications and avoid redundant UI refreshes.
- Keep repeated background/foreground reaction-reception notices out of chat.
  Show concise reception information separately, preserving history, scroll and
  unread state.

Details: [Mac media controls](mac-guest-media-controls-2026-10-14.md).

## Qualification

- Live Mac six-participant qualification: mic calls 5–24 ms, camera calls 4–55 ms,
  maximum sampled main-queue delay 225 ms. Incoming audio/video counters advanced
  throughout four toggle cycles. Real receiver-delegate callbacks still work.
- User confirmed Mac AirPods unmute/mute from a newly joined muted meeting and
  Space toggling both ways.
- Eleven native recovery and fourteen ownership checks passed with ASan/UBSan.
- Final combined Mac regression: 127 cases, one expected opt-in microphone skip,
  zero failures. The real Mac input-mute callback passed in its dedicated run.
- Final iOS 27 Simulator regression: 128 cases, two expected Mac-only skips,
  zero failures. Includes thirty background/foreground cycles with stable reaction
  history, scroll position and unread state.
- Final iOS 17.5 Simulator regression: 127 cases, two expected Mac-only skips,
  zero failures.
- Physical iPhone is unavailable for this release. Mac-specific changes are runtime
  guarded; shared receiver-wrapper behavior is covered by simulator regressions.
- macOS 26.2 overlapping-speaker volume remains unreproduced on the macOS 27 host.
  Menu-bar/window-close behavior is a separate proposal and is not included.

## Artifact and distribution

- Version 0.2.0/build 84; iOS 16.0 minimum; team 5V64BP2H3P.
- Native dependency: `guest-native-webrtc-150.7871.03-r6`.
- Native ZIP SHA256: `6d9655dad8e0ad9fb5a77e47a43e9064b5f6c6ee40c1eeaca53d1632cb0ef789`.
  Remote download/readback matched; provenance includes all cumulative patches.
- Tester notes: “Improved stability, responsiveness and meeting controls.”
- Product commit: `483fe4e`.
- Archive: `2026-10-14/RockNRoll-0.2.0-b84.xcarchive`.
- App/dSYM UUID: `C067C167-7C5D-3B1B-BC30-4FE3259AD3E4`.
- Exported IPA SHA256: `b6bce5da2a468625b42c655d269fceffca7386aba5bd4fe0a57a491485196496`.
- Archive/export succeeded. The app and both extensions passed strict/deep
  signature checks, use version 0.2.0/build 84/iOS 16.0 minimum/team 5V64BP2H3P,
  and have no debugger entitlement. Export uses production iCloud; purpose strings
  and encryption declaration are present. Embedded native r6 provenance matches
  the verified release, including all 23 cumulative patches and required APIs.
- Xcode upload succeeded on October 14, 2026. App Store Connect received build 84
  at 17:11 MSK and initially showed Processing. Existing third-party missing-dSYM
  warnings remain; the application symbols match its executable.
- App Store Connect build ID: `d37eecdd-971d-49d0-ab85-0186cd5dea3c`.
- Read back on October 14, 2026: build 84 is **Testing** in both Rock’n’Roll
  Internal (one tester) and Rock’n’Roll Public Beta (six testers), confirmed on
  each group's Builds page. The build detail page lists both groups and the
  saved tester notes. Public submission had automatic notification enabled and
  immediately reached Testing.
- Public invitation: https://testflight.apple.com/join/Hd13C9U3
