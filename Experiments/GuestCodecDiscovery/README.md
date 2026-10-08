# Guest publishing codec discovery

This is an opt-in experiment, not an application-target source or a shipping
codec policy. It observes a documented Foundation WebSocket send boundary via
Objective-C runtime forwarding, using the concrete class returned by the public
URLSession factory. It does not modify a vendor binary, use a private OS selector,
or hardcode a provider hostname.

For a disposable Debug process only, include `GuestCodecTrial.swift`, call
`GuestSignalCodecTrial.install()` before SDK initialization, and set
`ROCKNROLL_TEST_GUEST_SIGNAL_CODEC` to `1` for H.264 or `vp9` for VP9. The native
SDK envelope is `event: media-in`; the browser envelope instead uses `type`.
The experiment changes only video AddTrackRequest codec metadata; encoded RTP
and an independent receiver must both confirm the actual selected codec.
Never install this hook in Release. It lacks production session/capability scope
and recovery qualification. The retained app test is
`MeetingNoticeLiveTests.testLiveCodecEvidence`, enabled with an authorized
`ROCKNROLL_TEST_GUEST_CODEC_INVITE`.

The earlier `GuestEncoderSelectorTrial` additionally requires
`configuration.allowCodecSwitching = true` on the disposable SDK connections.
It proved hardware H.264 encoding, but receivers remained configured for VP8
and decoded zero frames. Do not use it as a solution.

See `docs/hardware-codecs-2026-10-09.md` and
`docs/adaptive-codec-policy.md` for results and the adoption gates. Production
app source contains neither experimental interception.
