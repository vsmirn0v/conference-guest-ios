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
`/tmp/rock53-live-chat-test.log`.

The anonymous provider denies chat writes and exposes no live caption feed. The
app explains these limits. Actual Telemost system capture, background/PiP, audio
routes and competing-call behavior on iPhone remain unverified because iVitalii
is unavailable. Mac development app tests were stopped before startup by host trust;
the signed build and independent Mac media receiver are separate evidence.

## Delivery

Artifact and testing-group readbacks are recorded after verified publication.
