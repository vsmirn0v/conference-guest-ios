# Microphone feedback and private sound check

Implemented 2026-10-07. No release or TestFlight upload is included in this change.

## Interaction

The existing microphone glyph fills from orange to a warm light color as local input rises. Its size, label and position remain stable. The same glyph appears in the PiP **You** badge, independently of the remote speaking indicator. Silence is normal; unavailable or stale data never animates a healthy signal.

Long-press Mic, or open Camera & sound → Audio → Sound. Live microphones show the existing publication's input level without muting or opening another capture session. While muted, an already-authorized microphone starts a private live meter; otherwise **Test microphone** requests permission explicitly. Both adapters confirm meeting mute before private capture starts. Closing, changing pane, backgrounding, interruption, route change, ending the meeting, or deliberately unmuting stops private capture. Testing never automatically unmutes.

The forced five-second recording/playback workflow has been removed. Input levels provide immediate feedback; no microphone clips are retained. The separate Devices pane offers a brief generated speaker sound.

A moving meter proves local capture only. Meeting mute/readiness and interruption state control the publication indicator; neither indicator proves another participant can hear the user. Private input monitoring can differ from meeting noise/echo processing.

## Implementation

- `MicrophoneActivity` applies a logarithmic scale and attack/release smoothing; missing samples expire after 650 ms. PCM metering is throttled before delivery to the main actor, to about 12.5 updates per second.
- `MicrophoneActivityView` changes only small gradient/mask layers. It does not recreate a video renderer, redraw frames, or relayout the meeting. Symbol images are reused between status changes.
- The jam adapter observes processed PCM via LiveKit's public local audio renderer. It neither changes the processing delegate nor starts local recording to obtain a meter.
- The guest adapter observes the pinned bundled WebRTC factory's public creation methods, forwarding their original implementations unchanged. A weak, locked registry tracks peers; enabled outgoing audio sources are sampled through public WebRTC statistics about every 150 ms. There is no replacement audio device, second capture engine for the live meter, SDK field inspection, or private Apple API. This boundary needs requalification when the vendor SDK is upgraded.
- Private checks use a separate AVAudioEngine input tap only after confirmed meeting mute, or before joining. They do not contain room, track, encoder or network references. In an active meeting they do not change/deactivate its audio session. The engine exists only while testing; it is released when capture stops.
- Private metering keeps no audio clip. Speaker check synthesizes 400 ms of mono PCM in memory for AVAudioPlayer; it never captures microphone input or changes an active meeting audio category. No audio files, backend, transcription, or package dependencies are introduced.
- New controls and microphone permission copy are localized in English and Russian.

## Earlier validation

The results below predate the removal of timed recording. Current qualification is in `studio-workflow-validation-2026-10-07.md`.


- iOS 27: 35 focused app checks completed with 33 passes and two opt-in hardware skips. The final microphone/check rerun completed with 11 passes and one hardware skip; all three UI scenarios passed after lifecycle/UI changes.
- iOS 17.5 iPhone SE: guest/jam inspector checks and Russian checks passed through portrait, landscape and background dismissal. Screenshots exposed a tall landscape section; the compact layout now keeps level/record/stop actions together. Rotation checks wait for the completed transition.
- iVitalii: live guest input statistics and private PCM capture, five-second recording/playback, and staying muted after dismissal passed. The same workflow passed in the live test jam using the processed-PCM observer. A separate real, standalone capture/record/playback check passed in about 12 seconds.
- Mac: 25 focused unit checks completed with 23 passes and two hardware skips. Actual capture remains unqualified on the development Mac host: its microphone authorization is undetermined and its noninteractive unit request waits for permission. Designed-for-iPad Mac destinations do not support XCTest UI tests. This is not reported as a successful Mac capture check.
- 16 audio/network/media-recovery policy tests passed. The live jam check caught and fixed self-cancellation when mute verification called the ordinary mute path.
- The final signed Release build and localized plist/string validation passed.
- PiP layer tests verify visible fill changes, stable badge geometry and preservation of the video view. Physical system-PiP metering, headset-specific sound quality and a fresh competing phone-call test are not part of this qualification.

No battery-saving claim is made: the guest stats poll adds work only while unmuted, and physical energy profiling was not performed for this feature.
