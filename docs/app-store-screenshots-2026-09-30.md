# Current App Store screenshots — 2026-09-30

Captured against source `31e9a541dd84d552ed78ac332c6a962a610d273e`, the current
UI of Rock’n’Roll 0.2.0 (23). No production app code changed for this task.

## Capture set

Original PNGs and SHA-256 hashes are in
`AppStore/Screenshots/2026-09-30-build23/manifest.json`.

Each device set contains, in order:

1. Saved jams, with a starred room renamed Friday rehearsal and a saved name.
2. A pinned, live screen share of the public demo score, with call and zoom controls.
3. A live two-way room chat, with the keyboard dismissed.
4. Musicians, with audio/video status and screen pinning controls.

The iPad set also shows the wide home layout and chat docked alongside sharing.
Only fictional demo names and the public test room were used. No private invitation,
third-party product name or private contact is present in these images.

Devices: isolated iPhone 18 Pro Max / iOS 27.0 and iPad Pro 13-inch (M4) / iOS 17.5,
with dark appearance and a 9:41 status bar. Capture flows passed on both devices.
The initial unmodified Release Simulator join could not activate CallKit; final
captures use the existing DEBUG Simulator direct-media path against the real
room. No UI fixture or mock room supplied the captured interface. Native image
orientation metadata is preserved; iPad captures render in landscape.

Capture evidence: `/tmp/rock-store-phone-final.xcresult` and
`/tmp/rock-store-ipad-final.xcresult`. The temporary capture method and scheme were
removed from the repository after export; copies remain under `/tmp/rock-store-screenshot-capture-*`.
Previous screenshot files remain in `AppStore/Screenshots/` for rollback.

## App Store Connect state

App: 6815394127. Editable iOS App 1.0 draft, English (U.S.).
Four new iPhone 6.9-inch screenshots were uploaded and listed in filename order.
The older custom 6.5-inch set and the new iPad upload still require final read-back
verification; the Safari confirmation window became inaccessible to automation.
