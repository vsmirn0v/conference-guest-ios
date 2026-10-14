# Screen-sharing integration review

The requested GPT-6 Astra ultra review examined the native screen-detail encoder,
SDK sender policy and integration with completed recovery work (`903cb05`,
`cd753a8`). Both parent commits are ancestors of the integration base `5a47a5d`.

## Corrections

1. A recreated VideoToolbox session inherited cached bitrate/frame-rate values
   but not its actual rate properties. Reapply AverageBitRate, DataRateLimits and
   ExpectedFrameRate before the first frame of every replacement session. Tests
   read the actual hardware properties across format and quality-budget resets.
2. The background sender binder used the public RTP parameter getter/setter.
   Its getter invalidated an SDK transaction held concurrently. An additive
   native API now applies only the screen-resolution preference on the signaling
   thread using internal parameters. The SDK's transaction and encoding edits
   remain valid; its later writes retain the screen preference.
3. Full-suite audio replacement exposed independently queued old-device shutdown
   and replacement startup. A serial ownership coordinator and managed-device
   admission gate order retirement before startup, coalesce pending replacements,
   retain SDK media intent, and reject obsolete owners and callbacks. Ordinary
   unreserved SDK media remains supported. Caller-owned/custom ADMs are unchanged;
   the public native vtable is unchanged.
4. Synthetic recovery tests broadcast media-reset events to unrelated SDKs and
   fake activation still performed real audio deactivation. Tests now use private
   notification centers and injected teardown, with production defaults unchanged.
5. Correct a stale experimental-media expectation: production intentionally keeps
   camera tracks enabled for background PiP rather than suspending them.

The ownership helper has 14 deterministic sanitizer cases; the preceding audio
recovery suite has 11. Swift/native tests additionally check obsolete-factory peer
creation, session overlap, media reservation release and reacquisition, atomic
sender transactions, replacement track identities and actual encoder rate limits.
These helper tests alone do not establish hardware callback behavior.

## Lifetime tradeoff

The ownership coordinator retains at most the active factory and latest pending
replacement (plus an in-flight owner). It releases obsolete factories on its own
control queue, never their worker threads. The last idle factory and its three
parked threads remain retained until replacement or process exit. Releasing that
last owner safely would require an explicit SDK lifetime protocol; weak-reference
or idle heuristics could restore the startup/destruction race. This is bounded
retention rather than unbounded per-meeting accumulation.

## Screen quality

Native source/canvas pixels are preserved up to the existing 3840-edge/8.29MP
budget. Hardware H.264 remains the production encoder. The detail policy changes
neither camera limits nor other engines' encoder settings. A full 4K source cannot
remain both sharp and smoothly scrolling over an arbitrarily small uplink.

Initial corrected-rate matched trials improved normal-budget synthetic text from
36–37dB to 53–54dB with similar process CPU (~57–58% of one core). The initial
300kb/s trial showed excessive update-rate reduction; the fallback threshold was
calibrated from source pixels/32 to pixels/16, retaining the 25% restoration
margin. This allows upstream QP39 earlier under tight budgets and retains QP24
above the recovery threshold. Final qualification and artifact identity are in
[build 82](release-0.2.0-build82.md). Raw nonidentifying metric summaries are in
[the measurement record](measurements/screen-detail-2026-10-14.json).

The comparison uses generated gray text/patterns at 5fps and real RTP transport,
not the user's desktop or arbitrary browser content. Bitrate ceilings are not
packet-loss simulators. Similar CPU and confirmed hardware encoding do not
establish equal battery consumption or perceptual quality on every screen.

## Remaining upstream follow-up

If native AVAudioSession configuration fails, upstream can activate the session
without balancing that failed configuration on teardown. The affected session
configuration files are unchanged from the pinned upstream source. Test setup
now prepares PlayAndRecord/videoChat before creating any factory; physical
output ownership/release/replacement passes with that valid configuration.
Track the failure rollback separately rather than treating a failed fixture
as successful native startup.
