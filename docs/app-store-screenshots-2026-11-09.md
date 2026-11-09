# Current App Store screenshots — 2026-11-09

Captured against source `02d74d8`, the current UI of Rock’n’Roll 0.2.0
(build 114). No production app code changed for this task.

The repository advanced to `2da1adb` (build 115 candidate) after the capture;
the later diagnostics and Settings additions do not change the four captured
screens.

## Capture set

PNG files and SHA-256 hashes are in
`AppStore/Screenshots/2026-11-09-current/manifest.json`.

Each device set contains, in order:

1. Home with the saved jam renamed Friday rehearsal and the display name Aram.
2. A live, pinned screen share of the public demo score, with the call controls.
3. A live two-way room chat between Aram and the browser participant Ani.
4. Musicians, with both participants and the screen pin control.

Devices and sizes:

- iPhone 18 Pro Max / iOS 27.2, dark appearance, 1320 × 2868.
- iPad Pro 13-inch (M4) / iOS 27.2, dark appearance, landscape 2752 × 2064.

The iPhone set was captured in portrait. The iPad set was captured through the
same UI test in landscape and rotated to landscape pixels so no EXIF
orientation is required.

The room was `https://rock.glowsoft.ru/jams/test`, published as the ordinary
public demo. The second participant Ani joined in the in-app browser and used
the public “Share demo card” and room chat. The app used the existing DEBUG
Simulator direct-media path. No UI fixture or mock room supplied the captured
interface. Only fictional participant names and the public test room appear.

Capture evidence: `.build/appstore-phone6.xcresult` and
`.build/appstore-pad2.xcresult`. The temporary `AppStoreCaptureUITests` class
was appended to `RockNRollUITests/HomeLayoutUITests.swift` for the run and
removed afterwards; a copy remains at
`.build/appstore-capture/AppStoreCaptureTests.swift`.

## App Store Connect state

App: 6815394127. Editable iOS App 1.0 draft, English (U.S.).

Completed and read back on 2026-11-09 through the authenticated App Store
Connect session:

- iPhone set `afd23f53-99b4-4c26-a727-600ebc401d0a`
  (`APP_IPHONE_67`): four screenshots, 1320 × 2868, in order
  `01-saved-jams.png`, `02-screen-sharing.png`, `03-chat.png`,
  `04-musicians.png`.
- iPad set `aead9a83-544d-487f-85f9-a891743a4e9d`
  (`APP_IPAD_PRO_3GEN_129`): the same four screens in the same order,
  2752 × 2064.
- Every new asset reports `assetDeliveryState = COMPLETE`, and the old
  September screenshots were removed from both sets.
- The version remains **Prepare for Submission**. No build assignment, review
  submission or release setting changed.

The current App Store Connect version page uses the new Product Page
Information / Asset Library UI and did not expose the legacy screenshot tab, so
the replacement was applied through the same authenticated App Store Connect
screenshot endpoints the web app uses. The screenshot sets and asset metadata
were read back after the update.

## Notes

The visible chat timestamps reflect the simulator’s local clock at capture
time; the status bar keeps the standard 09:41 override. The capture did not
alter app code, the public demo room or any TestFlight build.
