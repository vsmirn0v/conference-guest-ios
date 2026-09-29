# Rock’n’Roll 0.2.0 (23)

Prepared 2026-09-30, against published source `6f946b6` / build 21.
Minimum deployment version remains iOS 16.0 for the app and both extensions.

## Implemented review findings

- F1: CallKit transaction failures check their call UUID. Guest events retain
  their enqueue-time recipient and joined-room identity. Per-join epochs guard
  SDK phases, representations, title/message subscriptions, controls and delayed
  recovery. Capture/history teardown completes before replacement-room delivery.
  Community teardown also awaits room disconnection before replacement delivery.
- F2: Swift and browser chat share a 2,000 Unicode-scalar, 16,384 encoded-byte
  contract with a nonempty ID bounded to 64 UTF-8 bytes. Validation precedes
  outgoing bubbles/draft clearing. Browser receipt deduplicates retry IDs with a
  bounded ledger. Successful publication remains “sent,” without recipient ACKs.
- F3: Join-time name policies use 60 scalars for community rooms and 80 for guest
  rooms, reject controls, preserve saved names, and request acceptable input for
  the selected destination. HTTP validation/rate-limit/service failures have
  distinct messages.
- F4: Subscription state tracks successful application separately from intent.
  Failures get at most two retries with backoff; intent removal/change and reset
  invalidate old work. One writer and latest-intent coalescing remain in place.
- F5: Chat shows 200 entries, retains fewer than 4,096 deduplication IDs and a
  2,048-ID source anchor. Reconnect/reordered coverage limitations are explicit.
  Empty initial/reconnect snapshots preserve cursor semantics. Provider message
  updates are deduplicated and separated from menu/permission updates; only
  visible chat bodies are projected. Discarded transcript entries are rejected
  before merging; unchanged retained transcripts skip sorting.
- F6: Superseded file snapshots are coalesced. Leave writes a tiny separate
  atomic session marker, then awaits ordered asynchronous deletion rather than
  blocking the UI on a writer queue. Restore requires the matching session marker.
  Keychain history has an injectable boundary, reports failures and offers retry;
  identical title updates skip writes. Invitation secrets remain in Keychain.
- F7: Shared JSON transport bounds reads as bytes arrive, rejects cross-origin,
  downgraded or changed-port redirects before following, supports cancellation,
  and leaves authentication/trust evaluation to the existing session delegate.
- F8: Preview policy callbacks occur only on transitions; loopback metadata
  writes are idempotent. New sessions/end explicitly reset policy state.
- F9: Shared keyboard commands, website-window presentation, a typed replacement
  invitation and DEBUG scene fixtures were extracted. Engine-specific audio,
  rendering and capture paths remain separate. No speculative bulk deletion or
  controller rewrite was performed.

## Interactive sharing preview

The Mac thumbnail consumes the existing capture/track frames, capped at two
frames per second and 640 pixels on its longest edge. Pause/Resume, single-frame
Refresh, Hide/Show and an enlarged pinch/zoom panel are available. Enlargement
pauses when capture membership cannot be established, avoiding a growing mirror
loop; a manual refresh still works. Designed-for-iPad on Mac cannot reliably
report its own capture membership, so that case is conservative.

On iPhone/iPad, the foreground app retains the latest external frame; Refresh
can request one frame. It does not create a continuously repeating foreground
screen. Stop clears pixels and hides both visual and accessibility elements.
No second capturer or encoder was added.

## Validation

- 55 app unit tests passed on iOS 17.5 / iPhone SE and iOS 27 / iPhone 18 Pro Max
  after the final changes, including empty snapshot regression coverage.
- 27 ConferenceCore tests passed: Unicode contracts, name boundaries, bounded
  HTTP reads/redirect policy/cancellation, transcript replay and existing routing.
- Browser wire-contract tests and Go server tests passed.
- Live guest → guest → community → guest switching passed again on the final
  build in Simulator. Layout/conversation, ambiguity resolution, preview controls
  and zoom/tile replacement checks passed on iOS 27; rotation/preview checks also
  passed on iPhone SE 17.5. Wide home and docked conversation passed on iPad mini
  17.5. An immediate post-stop accessibility assertion failed once; explicit
  accessibility visibility plus a bounded removal wait passed the retest.
- Mac joined a guest room, displayed a live share thumbnail, paused/refreshed/
  resumed it, stopped sharing, and left cleanly. A live SDK API trap discovered
  during testing was removed by using room-value identity rather than a
  token-dependent link-building helper.
- Real community-room browser → native chat sent 2,000 CJK scalars; native →
  browser sent 2,000 guitar-emoji scalars. Both appeared in the receiving UI.
- iVitalii passed the automatic real CallKit hold/catch-up/leave check. A new
  ordinary phone/FaceTime call, long background/PiP soak and physical iPad run
  were not performed for this release. The browser-mediated guest chat test was
  skipped when no corresponding observer was configured.
- Strict deep code-signature verification passed. The main app and both
  extensions report 0.2.0 (23), minimum iOS 16.0.

## Performance evidence

Same optimized standalone first-party store fixture, 50,000 messages and 20
replays, on this Mac:

| Measurement | Before | After |
| --- | ---: | ---: |
| Transcript replay average | 127.56 ms | 7.25 ms |
| Chat replay average | 1.46 ms | 0.27 ms |
| Retained chat identities after fixture | 50,000 | 2,896 |
| Maximum process resident memory | 36.91 MB | 35.88 MB |
| Total process user CPU time | 2.32 s | 0.28 s |

Isolated 1080p → 640-pixel Core Image thumbnail conversion averaged 1.52 ms wall
and 0.90 ms CPU per frame. At two frames/sec, conversion alone is approximately
0.18% of one CPU core; this excludes UIKit presentation and meeting encoding.
The app test also exercises 100 bounded thumbnail conversions.

Whole-call Mac full-display sharing samples ranged about 103–162% CPU and
109–144 MB resident memory while source content/build/UI work changed. These
are not an isolated measurement of preview overhead. Provider-owned snapshots,
media buffers and encoding workloads are outside the standalone store benchmark;
first-party retention bounds do not guarantee a plateau for every SDK allocation.
An existing synchronous audio-session runtime warning remains in the SDK/audio
integration path; it did not cause a failure in these checks.

## Hosted service and release artifact

Only `rock-web` was updated/restarted. `rock-room`, nginx configuration and
unrelated services were preserved. Public health returned `ok`; served JavaScript
matched the rebuilt bundle byte-for-byte. Restart policy is `always` and
`podman-restart.service` remains enabled. Web binary SHA-256:
`010b840765d0fb9d3349f87e39b46f7d4dae7854e2e714f2e22ea282e0b2ba74`.

Signed archive:
`~/Library/Developer/Xcode/Archives/2026-09-30/RockNRoll-0.2.0-b23.xcarchive`.
Main executable SHA-256:
`71a5273438aeb2026d76f6eacd7283e6efd1ff6b9247908ba8d8f1054e3486e3`.
Build 22's upload was interrupted at preparation, was not assigned to testers,
and was absent from App Store Connect's build list when checked.

Beta notes: “Improved stability when opening multiple jams in succession.
Smoother sharing previews and fixes for chat and saved rooms.”

TestFlight upload, processing and group availability will be recorded after
read-back verification; uploading alone is not publication.
