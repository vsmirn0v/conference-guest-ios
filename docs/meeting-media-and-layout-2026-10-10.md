# Meeting media and layout corrections

## Design invariants

- A muted microphone is an immediate disabled-track gate, not merely a signalling
  flag or a removed sender reference. Negotiation keeps the initial audio identity.
- Camera devices are selected by actual connected device identity. A switch retains
  the published source and track; failure restores the working device where possible.
- Camera frames retain their source pixels, timestamps and aspect ratio. Mac-specific
  rotation metadata is corrected from the connected capture output. Inline video and
  Picture in Picture fit the complete received frame by default.
- Grid has stable participant/source ordering and equal tiles. Speaker view follows
  the current speaker. Pinning and new screen sharing take the main stage; selecting
  Grid explicitly can include a current share alongside the other participants.
- Handoff starts the destination connection before waiting for source preparation.
  The destination starts muted. Source departure still requires the destination's
  connected acknowledgement; a failed transfer preserves the original meeting.
- Calendar and handoff cards display website and room identity, without invitation
  password query parameters.

## Regression evidence

The full ConferenceCore suite passed: 101 tests, no failures. The final simulator
app suite passed 424 tests with 54 expected opt-in/hardware skips and no failures.
Simulator checks
cover compact home cards, room metadata, large text, landscape/portrait transitions,
Grid/Speaker selection and a reaction palette that stays open after selection.
Detailed microphone, camera and guest reaction evidence is kept in their companion
documents; release acceptance and final artifact identity are recorded separately.

- [Microphone regression](native-microphone-regression-2026-10-10.md)
- [Camera geometry and device selection](camera-geometry-and-device-selection-2026-10-09.md)
- [Guest reaction transport](guest-reactions-receive-2026-10-10.md)

Validation uses the Mac and simulator, as requested. No physical iPhone or iPad
tests are performed for this change. Device discovery and deterministic source
identity tests do not claim acceptance of a real two-camera phone switch. The
host's asynchronous Designed-for-iPad Mac XCTest runner does not resume its first
asynchronous API; ordinary signed app UI and independent decoded receivers qualify
live Mac capture and microphone behavior instead.

TrueConf exposes a server-composited incoming stream. Its grid uses the participant
regions advertised by the server, without duplicating the entire composition into
each tile. It cannot expose a separate camera that the server does not include.
