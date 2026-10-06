# Meeting Studio

Studio is available from More in both meeting views. Opening it starts no camera,
microphone or additional processing pipeline. Appearance opens Apple's video-effect
interface while the camera is on; Sound opens Apple's microphone-mode interface
while the microphone is on. Capture remains under the meeting engine's ownership.
Supported effects are selected by the system for the current camera and format.
Simulator cannot qualify those effects and the system-settings buttons are disabled
there. English and Russian copy, Dynamic Type and scrolling use native form layout.

## Sound profiles

Profiles are scoped to one meeting and retained through media recovery. A new jam
starts with normal engine defaults. System microphone settings remain user-owned;
Studio reads their active selection while its panel is visible. For music, the panel
recommends Standard or Wide Spectrum when available.

| Engine capability | Conversation | Music |
| --- | --- | --- |
| Noise-suppression control | Enable SDK suppression | Disable SDK suppression; other SDK processing remains unchanged |
| Full capture/runtime processing | SDK automatic AEC, suppression and AGC | Software AEC retained, suppression/AGC/high-pass filtering disabled |

The full Music profile deliberately selects software AEC: platform echo and noise
processing may be coupled. This is a fidelity option, not a battery optimization or
a promise of stereo, lossless audio or lower network latency. Codec and publication
defaults remain unchanged. No second audio engine or neural denoiser is installed.

Selecting a profile while muted prepares it for the next unmute. Existing audio
tracks receive the same policy through the SDK's public runtime setter. One worker
serializes updates and retains only the newest pending operation. SDK calls that
block on signaling run off the main thread. Room/intent checks reject retired
sessions; sound-setting failure does not falsely report a working microphone as off.
Studio disables changes during hold and after Leave. Guest suppression readback is
shown independently from the selected profile.

## Validation boundaries

UI fixtures exercise both production entry points without opening capture, connecting
to a room, or persisting a profile. State tests cover failure, hold/end, delayed
results, suppression readback and update serialization. Release tests cover the
production policy as well as the existing hardware-video and colour path.

The opt-in Mac live-sender test uses manual rendering and synthetic silence. It
publishes one track to the test jam, applies Conversation → Music → Conversation,
checks processing state and increasing RTP packet counts, then disconnects and
restores the audio session. It saves no PCM and opens no microphone. It qualifies
the runtime setter and sending continuity, not listening quality or battery life.

Before judging effects or fidelity, use a physical iPhone to check remote camera
output, instrument attacks/sustain, speaker echo, AirPods/receiver/speaker switching,
and call-interruption recovery. Each requested phone test must stay within one
minute. Sustained thermal and battery behaviour cannot be established by those
short checks. No physical-device acceptance is claimed for this beta.

Custom background processing, presenter composition and ML denoising remain later
stages of the approved roadmap. They require separate quality/energy qualification;
custom guest camera effects additionally require a supported outgoing-frame hook.
