# Rock’n’Roll 0.2.0 (109)

## Changes

Includes `86ebb9940aee7acdd007b385081b5d1ac59ed875`: the selected screen share stays authoritative across active-speaker, mute/pin and temporary renderer changes. The presenter camera is an independently movable/collapsible companion; explicit camera focus has Back to share, and PiP remains on the share. See [Focus implementation and acceptance](focus-share-companion-2026-10-23.md).

The separate native Mac release does not change the iOS guest/WebRTC engine. Latest shared continuation freshness and account/deletion guards are included from `5763633`.

Apple rejected uploaded build 108 during processing (90338): the experimental Mac-host adapter compiled a public macOS `terminate` selector into the iOS binary. Build 109 compiles that AppKit adapter out by default, with fail-closed stubs. Saved Mac preview preferences fall back to the standard engine and unavailable preview settings are hidden. The standalone native Mac app is unaffected. Internal adapter testing requires the explicit compiler definition `ROCK_NATIVE_GUEST_COMPANION=1`; this is absent from shipping settings. The selector is removed from the Release binary, not disguised.

## Validation

Fresh final simulator regressions: 162 cases, 142 passed, 20 explicit platform/live skips, zero failures. Mac: 162 cases, 158 passed, four explicit skips, zero failures. These cover Focus/companion, renderer retirement, PiP content/recovery, meeting controls, continuation, saved preference fallback and unavailable adapter behavior. Astra xhigh reviewed both release readiness and the processing fix; no concrete source blocker remained. Earlier live native and physical continuation acceptance is recorded separately; no new physical iPhone Focus/PiP/live-provider run is claimed for this release.

Signed Release archive and App Store export passed. App and three extensions are version 0.2.0 (109), team `5V64BP2H3P`, with matching app/extension dSYMs and no debugger entitlement. CloudKit is Production; the Activity extension links no media framework. All 355 recorded production manifest paths match the archived sources. Release `__objc_methname` contains no exact `terminate` selector. IPA SHA-256: `076dbe358ebea403879b57b278811937a0210f05bc02e942f3290edb9aff4a2d`. Evidence: `.build/release109/`. Six existing vendor-framework dSYM warnings remain; application/extension symbols match.

## Distribution

Upload succeeded. Apple processing and final tester assignments are pending; update this record from independent readback before claiming publication.

## What to Test

View a shared screen in Focus while participants speak, mute/unmute or change camera pins: the screen should stay on the main stage. Move/collapse the presenter camera, focus it explicitly and return to the same share/zoom. Check PiP, foreground/background and meeting recovery. Microphone/camera start off. The iOS media engine remains unchanged.
