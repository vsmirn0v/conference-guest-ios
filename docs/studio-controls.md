# Meeting Studio

Camera & sound is the first item in More in both meeting views. Hold the microphone
or audio-route control to open Sound; hold Video to open Camera. Short taps keep
their mute/video/route behaviour. Secondary pointer clicks, VoiceOver actions and
Command-comma expose the same settings. The secondary-click recognizer accepts
pointer touches only, so it cannot swallow a touchscreen short tap.

The join screen also offers an optional Check camera & sound. It neither joins a
room nor publishes media, and it closes when joining starts. Phone portrait uses
a sheet; landscape and wide windows use a side inspector. Native scrolling and a
fixed bottom action keep controls available with small screens, larger text and
English/Russian copy. Dismissal targets the settings host, never the meeting host.

## Private camera preview

While outgoing video is off, an AVFoundation session captures only local video.
It has no audio input, recording/encoding output or network publication, and it
never reconfigures the app's audio session. This front-camera preview (default
camera on Mac) is marked Preview · Only you. Apple video effects can be opened
against this capture before publishing, subject to platform/camera capabilities.
Starting video explicitly releases the capture device before the meeting engine
can acquire it. Permission failure, cancellation, tab changes, hold, backgrounding
and leaving all invalidate pending preview work and release the device. Apple's
effects overlay is allowed to appear without treating inactive as background.

With video already on, the panel observes the existing engine stream rather than
opening another capturer or encoder. The guest renderer tap supports independent
weak observers, allowing the stage/PiP and the Studio preview to coexist. The
settings observer stops on close and processes at most 15 frames per second.
The other engine uses a VideoView attached to its existing local camera track.
Live camera switching continues through each engine's existing control. Private
preview is never registered as a floating-video source. Closing a private preview
keeps video off; closing a live preview keeps the existing publication on.

Sound profiles and route selection remain available while muted. Apple's native
microphone-mode panel still requires active microphone capture; opening settings
never starts a separate microphone or changes mute intent. Simulator fixtures
open no capture or network. Real camera/effect behaviour is tested on Mac/iPhone.

## Sound profiles

The chosen sound profile is saved on this device after successful application and
restored for the next jam, including a choice made before joining. Capture intent
is never saved: new joins still start with microphone and video off. Profiles are
retained through media recovery. System microphone settings remain user-owned;
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

On 6 October, iVitalii passed the real-capture Conversation → Music → Conversation
sender check: effective processing matched the policy and RTP packets increased
in every phase. The guest Studio UI kept capture off when choosing Music, applied
it on unmute, and exposed Apple's camera-effect panel during active video.
Portrait was toggled and restored. The user confirmed audible guest-meeting
recovery after a regular cellular call with Music selected and reported the
subsequent basic Music-profile listening check as satisfactory. A later call
exposed a recovery-readiness gap; after tightening the guest recovery guards,
the user confirmed recovery for both outgoing and incoming cellular calls.

Remote camera-effect quality, instrument attacks/sustain, speaker echo and
AirPods/receiver/speaker switching specifically with Music remain unqualified.
Functional device tests may exceed a minute; the user's one-minute limit applies
to CPU/GPU/energy profiling. Sustained thermal and battery behaviour cannot be
established within that profiling limit. Detailed evidence and boundaries are in
`physical-validation-2026-10-06.md`.

The foreground Presenter canvas now provides compositing, person cutout and image
backgrounds through the guest screen-share API; see `presenter-studio.md` for scope
and qualification. Custom processing of the separate SDK camera tile still needs a
supported outgoing-frame hook. Neural denoising remains an isolated experiment in
`Experiments/EnhancedSpeech`, pending quality, energy and echo/recovery qualification.
