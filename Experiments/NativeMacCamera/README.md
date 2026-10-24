# Native macOS camera diagnostic

Local capture feasibility experiment for the system-background/reaction rotation
seen in the iPad-on-Mac app. It is not linked into the production app.

Build with an existing development identity:

```sh
python3 Experiments/NativeMacCamera/build.py --identity '<Apple Development identity>'
```

Use `--mode reaction` for a separately observed thumbs-up effect. Open the
printed app path through the normal macOS launcher. Grant camera permission if
requested; enable the system background before assessing background orientation.
The build script does not launch the app or change privacy permissions.

The probe captures built-in camera video only at 1280×720/24 fps. It writes four
local PNGs plus logs under `.build/native-mac-camera108/evidence`, restores the
camera format/cadence and stops. Capture has a 15-second hard deadline; the
permission prompt precedes that deadline. A fallback run without an active
background or observed reaction does **not** qualify that effect. Images require
visual inspection; successful capture is not an orientation assertion.

The local bundle uses the development app's identifier, so Launch Services may
register it under that identity. After testing, unregister this exact probe:

```sh
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$PWD/.build/native-mac-camera108/NativeCameraProbe.app"
```

Camera images stay local and must not be committed. The probe opens no microphone,
meeting or network connection. It measures neither energy nor end-to-end latency.
For results and the guest SDK packaging limitation, see
`docs/camera-preview-mirroring-2026-10-10.md`.
