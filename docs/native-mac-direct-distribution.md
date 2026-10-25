# Native Mac direct distribution

The native Mac app can be distributed separately from TestFlight, using the same
bundle ID, team, sandbox, app group and Production CloudKit container. iOS and
its media engine are unchanged. The default build remains the App Store variant.

## Distribution and channels

`NativeMacGuest/build.py --distribution direct` embeds pinned Sparkle 2.10.0,
its license, the public Ed25519 key, the HTTPS appcast URL and its required
sandbox exceptions. App Store builds omit the framework, updater UI, feed/key
configuration and updater exceptions. Generated specifications do not modify
the checked-in Info.plist, entitlements or XcodeGen project specification.

The Developer ID export uses Xcode's cloud-managed signing certificate and
existing account session. `release.py export` uploads for notarization;
`finalize` resumes pending processing without re-uploading. Packaging requires
a stapled app accepted by Gatekeeper. An outer DMG ticket is recorded separately
and is never inferred from the app's notarization.

The stable channel is the default. Settings → Updates permits opting into beta
releases. Both channels share the signed feed; stable releases are untagged and
beta releases have the `beta` channel. Numeric build numbers increase across
both channels. Disabling beta never installs an older stable build. Channel
selection is locked while an update is pending.

The private Ed25519 key stays in the local Keychain account
`dev.vsmirn0v.conferenceguest.nativeguest.sparkle`. Neither the private key nor
Apple credentials are uploaded to the website. Feed and enclosure signatures,
Developer ID signatures, notarization, runtime entitlements and immutable
artifact digests are validated independently.

See [release commands](../NativeMacGuest/distribution/README.md) and
[hosting/publication](../RockServer/README.md). The public download is
`https://rock.glowsoft.ru/mac/stable/latest.dmg`; the appcast is
`https://rock.glowsoft.ru/mac/appcast.xml`. Public bytes live under
`/var/www/rocknroll/releases`; existing private service configuration under
`/opt/rocknroll` retains its restricted permissions.

## Never interrupt a meeting

All admission and updater decisions run on MainActor. Busy includes preparation,
connected/recovering or hidden meetings, cancellation drain, media teardown,
failed cleanup, companion admission and application termination.

- Downloaded updates do not reserve or terminate an active meeting.
- Updater UI and interactive installation callbacks wait for idle.
- The final public Sparkle relaunch gate atomically checks busy state and
  reserves installation. New manual, calendar, URL and continuation joins then
  fail closed. The gate runs on retries too.
- Explicit user Quit retains normal media cleanup; updater termination cannot
  bypass the busy check or masquerade as a user-requested meeting switch.
- A lifetime exclusive process lock prevents another direct-build instance from
  starting a competing media session.
- Before downloading/extracting, a private atomic durable fence records the
  source/target build and a generated installation ID. Once an installer might
  exist, cancellation/error callbacks never erase that fence.
- A restarted old build cannot join meetings while its fence exists. It offers
  Finish update. The target or a newer build retires the fence under the
  exclusive process lock. There is no timeout that silently reopens admission.
- Active update-cycle epochs invalidate stale UI, installation and retry
  callbacks. A new cycle cannot revive an old installation reply.

The fence contains no meeting identifiers, invitations, participant names,
CloudKit records or audio/video data. Normal meeting rendering has no updater
polling loop.

## Qualification record

Release 0.3.0 (25) was qualified on 25 October 2026:

- Direct native parity: 75 cases, 15 opt-in live cases skipped, zero failures.
  Includes storage/process fences, meeting admission and actual Sparkle callbacks.
- App Store parity: 62 cases, the same 15 opt-in live cases skipped, zero failures.
  Product readback confirms no Sparkle framework, SU* keys or updater exceptions.
- Distribution tooling: 18 checks passed; server Go tests passed.
- Developer ID identity/profile, Production CloudKit/APNs, sandbox, hardened
  runtime and signed nested helpers passed. Both baseline22 and candidate25
  apps are notarized, stapled and accepted by Gatekeeper. The outer DMG itself
  is not notarized.
- A quarantined HTTPS baseline22 download was mounted and copied using Finder
  to Applications. After Apple's normal verified-app Open confirmation, the
  process ran from the canonical Applications path without translocation.
- Stable22 ignored beta25. Enabling Beta during a disposable synthetic meeting
  downloaded and verified25 while PID54163 remained on22. The independent peer
  retained one healthy connection through window close/hide/restore; incoming
  generated video resumed after restoration. No update UI interrupted the call.
- Leave triggered the pending installation only after meeting cleanup. Sparkle
  replaced22 with25 and relaunched PID55549 from Applications. Its executable
  SHA-256 matches the notarized candidate. Gatekeeper accepted the installed app.
- Name, favorites, history and iCloud settings survived. Disabling Beta did not
  downgrade25 to stable22. A fresh meeting join/leave on installed25 passed.
- The Developer ID baseline wrote a generated private Production CloudKit
  fixture. Installed25 verified its name/favorite/alias/invitation after the
  actual update; cleanup deleted only the generated fixture zone. The normal
  library also reached Up to date. The iPhone rerun remains deferred by user.
- Final 6-astra xhigh review found no release blocker.
- The signed feed and enclosure verify; changed signed bytes are rejected.
  The exact same25 DMG bytes were promoted to stable and beta, with HTTPS hash,
  metadata, alias and cache-policy readback. No immutable artifact was replaced.
- The public homepage now exposes the Mac download and existing iOS TestFlight
  link. Homepage/privacy bytes match committed source; health passed. Only the
  web process restarted, with its old binary preserved. The meeting-server
  process and start time remained unchanged.

These updater tests establish meeting connection continuity and generated video
recovery, not a new acoustic-quality or battery qualification. Earlier media
validation remains separate. No quarantine stripping or security-policy bypass
was used. The previously installed app is preserved locally for recovery.

The bounded release record is
[native-direct-0.3.0-25-validation.json](native-direct-0.3.0-25-validation.json).
