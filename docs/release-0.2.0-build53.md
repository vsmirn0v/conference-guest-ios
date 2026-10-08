# Rock’n’Roll 0.2.0 (53)

Includes build 52's native meeting transport, presentation capture and read-only
chat, with the provider's history/push message envelope correctly parsed. Build 52
was uploaded but not assigned after this final acceptance check found the issue.
All three bundles retain iOS 16 minimum and version 0.2.0, build 53.

Beta notes: “Improved meeting compatibility, screen sharing and connection stability.”

Implementation, provider capability limits and qualification:
[native feature completion](telemost-feature-completion.md).

## Validation

Build 52's 92 core, 28 focused app, five UI and 14 iOS 17.5 checks are unchanged
except for the chat parser correction. Five focused app checks passed again with
the correction, including an existing browser message. A separate live browser
message received after initialization also passed with outgoing presentation
encoding and clean departure. Logs: `/tmp/rock53-real-chat-test.log` and
`/tmp/rock53-live-chat-test.log`. Two corrected chat parser checks passed on iOS
17.5 (`/tmp/rock53-ios17-chat.log`). The native join/chat/presentation test also
passed with no synthetic remote publisher and all other participants muted
(`/tmp/rock53-muted-room-test.log`).

The anonymous provider denies chat writes and exposes no live caption feed. The
app explains these limits. Actual Telemost system capture, background/PiP, audio
routes and competing-call behavior on iPhone remain unverified because iVitalii
is unavailable. Mac development app tests were stopped before startup by host trust;
the signed build and independent Mac media receiver are separate evidence.

## Delivery

Signed archive: `~/Library/Developer/Xcode/Archives/2026-10-08/RockNRoll-0.2.0-b53.xcarchive`.
Runtime source: `a214920034aa2890a04976e3d339e500ad9e8b3c`.
Distribution export: `/tmp/rock-build53-export/RockNRoll.ipa`.
Archive and exported application passed strict deep signature verification; all
three bundles are 0.2.0 (53), minimum iOS 16. Production iCloud and distribution
entitlements are present; debugging is disabled. Required privacy/encryption
declarations passed, and test-only markers are absent from the app executable.

- Exported IPA SHA-256: `ecde0e0ce23bfe2fd2565b6cca9549c004ea5bbdbcfc62e55ed6cb3f3cd49eff`.
- App executable SHA-256: `738a29729e64b65328431a803179fadcbe6af683d1e9cc84f4a6d401d6e8e18d`.
- App/dSYM UUID: `F3F435E8-EBB5-3310-B315-D1EF1EA68079` (arm64).

Upload uses the same signed archive. Exported IPA identity does not imply identical
transport-package bytes. Logs: `/tmp/rock-build53-{archive,export,upload}.log`.
Testing-group readbacks are recorded after verified publication.
