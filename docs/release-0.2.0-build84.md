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
- Archive, export, upload and TestFlight readback are pending.
