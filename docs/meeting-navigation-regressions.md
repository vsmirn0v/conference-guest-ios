# Phone navigation and solo meeting regression fixes

2026-10-01. These changes follow build 28 and are not yet in a distributed beta.

## Behaviour

- Stream navigation uses the authoritative participant roster instead of the
  SDK's visible phone page. Remote participants remain navigable when their
  renderers are hidden, have zero bounds, use a preview layout, or have not
  been created yet. An available offscreen renderer can feed the main stage.
- Camera-off participants show their name and microphone state. A renderer
  arriving later fills the same selected participant rather than losing the
  user's selection. Departures remove obsolete browsing targets.
- With another participant present, the user's own camera tile is navigable,
  including its camera-off placeholder. An idle self tile is never chosen as
  the automatic main stage.
- When alone with camera and screen sharing off, the central invitation and
  Copy link actions take precedence over SDK self-tile updates. Navigation is
  hidden in this waiting state. The source tiles are also excluded from
  accessibility because the app-owned stage provides the accessible content.
- Existing pin, display-mode, zoom, Focus and background selection rules remain
  in place. This change does not request additional video subscriptions.

## Verification

- iPhone SE / iOS 17.5: full app suite passed (103 passed, one optional iCloud
  test skipped), and all seven meeting-presentation UI tests passed.
- Final refinement: 13 stream-selection tests and the two new compact/solo UI
  tests passed again on iPhone SE / iOS 17.5.
- iPhone 18 Pro / iOS 27: 18 selection/geometry tests and both new UI tests
  passed. Rotation checks wait for the visible window and invitation to settle.
- A live guest room with two browser peers passed a complete navigation cycle
  through both peers and the local participant, swipe wraparound, landscape
  navigation and returning to automatic selection. Cameras were off in this
  live navigation check; frame delivery uses the existing media path.
- No physical-device audio/interruption or PiP checks were repeated.

Local evidence: `/tmp/rock-compact-final17.xcresult`,
`/tmp/rock-compact-refined17.xcresult`, `/tmp/rock-compact-refined27.xcresult`,
`/tmp/rock-compact-live-final.xcresult`. Invitation screenshots are exported to
`/tmp/rock-solo-ui-proof` and `/tmp/rock-solo27-proof` and stay local.
