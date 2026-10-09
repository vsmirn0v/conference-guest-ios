# Decoder factory feasibility

These probes exercise the SDK's documented Objective-C `createDecoder:` method
through runtime forwarding. They do not modify a vendor binary or use a private
selector/C++ ABI. This is an experimental integration boundary, not a supported
high-level SDK configuration API. It is excluded from Release.

Pass the already-resolved `LiveKitWebRTC.xcframework` to:

```bash
bash Experiments/CodecFactories/build-check.sh /path/to/LiveKitWebRTC.xcframework
bash Experiments/CodecFactories/build-loopback.sh /path/to/LiveKitWebRTC.xcframework
```

The first check uses an inherited default decoder factory, as the LiveKit SDK
does. It verifies all 16 independent reference frames, profile preservation,
once-only failure, original software selection after failure, and a fresh
hardware decoder after restart. The second check sends synthetic VP9/Opus through
two local RTC peers for 15 seconds and verifies actual hardware-decoded frames.
It needs neither an external room nor microphone/camera capture.

The app experiment requires a Debug build and
`ROCKNROLL_EXPERIMENT_HARDWARE_VP9=1`. Only the active guest/jam scope can select
hardware profile-0 VP9. Other codecs/profiles and unsupported hardware retain
the original decoder. Failure disables selection for that scope and requests
the existing guest media recovery or LiveKit's public client full-reconnect
debug operation. A new meeting resets the experiment; retired callbacks are
ignored. The app's Release build contains neither factory forwarding nor the
guest experiment adapter.

Opt-in guest qualification:
`GuestDecoderExperimentLiveTests.testHardwareVP9ThenAutomaticSoftwareRecovery`,
with `ROCKNROLL_TEST_GUEST_CODEC_INVITE` set to an authorized room containing an
independent VP9 publisher. It verifies fresh hardware frames, then forces a
decoder failure and requires actual VP9/libvpx frames after recovery. Repeated
meeting replacement, competing calls, system PiP and LiveKit full recovery still
need live qualification before enabling these new paths in Release.

Current qualification: single-layer guest VP9 (`L1T3`) and forced software
recovery pass on Mac and iPhone. The normal browser's multilayer `L3T3_KEY`
stream fails hardware qualification. Keep this experiment disabled for shipping
until a native hybrid decoder is integrated and qualified. Spatial hardware VP9
failed even with a valid frame index on Mac and iPhone; returning fallback status
alone does not activate software fallback in the pinned factory. See
`docs/vp9-production-path-2026-10-09.md` for the framework/API requirements.

The VideoToolbox packet/session implementation is shared with the already
qualified native receiving adapter. It requires a hardware session and verifies
the actual hardware property; the generic WebRTC statistics flag can remain
false. Codec selection and exact pixels do not establish battery savings.
