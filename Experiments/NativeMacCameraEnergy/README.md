# Native Mac camera energy probes

Local, video-only measurements for native Mac camera capture with macOS Video
Effects. No microphone, network, preview or saved images. Not linked into the app.

Both probes use the native app's bundle identifier so they inherit its camera
permission and per-app Video Effects state (for example Background). Launch them
through Launch Services (`open -n -W ...`) so TCC attributes them to themselves,
then unregister the bundles with `lsregister -u`.

- `build.py` / `main.swift`: raw AVFoundation phases (legacy unlocked preset,
  locked 720p30, locked 720p24, locked 1080p30) with process and system-wide CPU.
  Summarize with `analyze.py <run>/probe.jsonl`.
- `build-pipeline.py` / `PipelineMain.swift`: the real `GuestCamera` (shipped
  revision and working-tree candidate) feeding `LKRTCVideoSource` and the
  hardware H.264 encoder at 1280x720. `PIPELINE_LABEL` names a window and
  `PIPELINE_BACKGROUND_FPS` overrides the candidate's Background cadence.

Results: `docs/native-mac-camera-energy-2026-10-30.md`.
