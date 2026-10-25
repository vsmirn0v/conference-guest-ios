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

Local preflight completed on 25 October 2026:

- Direct native parity: 75 cases, 15 opt-in live cases skipped, zero failures.
  This includes 16 storage/process fence cases, eight admission/lifecycle cases
  and 13 actual Sparkle delegate/callback cases, including stale-status recovery.
- App Store parity: 62 cases, the same 15 opt-in live cases skipped, zero failures.
- Actual App Store product readback: no Sparkle framework, SU* keys or updater
  Mach exceptions after reusing the direct-build cache.
- Distribution tooling: 18 checks passed, including resolved specification
  resources, artifact collisions across channels, identity/profile checks,
  immutable publication, concurrent metadata changes and unchanged signed bytes.
- Developer ID app/profile: matching identifiers and team, Production CloudKit
  and APNs, sandbox, hardened runtime, no debugger entitlement, correctly signed
  nested updater helpers.
- Developer ID baseline 22 wrote a generated private CloudKit fixture; candidate
  24 read its name, favorite, alias and invitation correctly. The normal direct
  app also loaded the existing library and reached Up to date. Test fixtures do
  not change the user's real favorites or sync preferences.
- Stable default, automatic checks/downloads and beta toggle were inspected in
  the real signed direct app. Beta was restored to off after the check.
- Candidate 24's archive and submission include the exact checked-in Sparkle
  license. Candidate 25 also clears stale update-error status on the next cycle; its final
  parity run passed.

Release gates still required before public promotion:

1. Apple notarization acceptance, stapling and Gatekeeper readback.
2. Download/quarantine → mounted DMG → installed app validation.
3. Actual signed baseline-to-candidate Sparkle update, including a live/hidden
   meeting that continues until Leave and installation only afterward.
4. Stable/beta filtering, beta-to-stable no-downgrade and final stable promotion.
5. Post-update library/CloudKit verification and generated fixture cleanup.
6. HTTPS feed/artifact digest/signature checks and final website deployment.

At this record's creation Apple still reported Processing. The first actual
feed-signing preflight was also waiting for macOS Keychain approval for
`sign_update`; no private key was exported or its access protection bypassed. The native download
CTA, release artifacts and appcast had not been published. No pending
notarization result is treated as acceptance. An iPhone cross-device rerun was
requested but the device was unavailable; Mac Production CloudKit checks above
were completed independently.
