# Isolated native Mac WebRTC M156 candidate

This experiment starts from upstream WebRTC `branch-heads/8078` commit
`19576e37870bfe5a0a910a32f98ff411f722f43a` (24 October 2026 snapshot).
The pristine Gitiles archive is retained under
`.build/webrtc-m156-port/source.tar.gz` with SHA-256
`286d27e706ddd3d91de71526cf35e93ff962e71a0b3f7706a4d54b1c6bd4acd4`.
The M155 cumulative guest patch had three rejected hunks on this source. The
`media/BUILD.gn` rejection was whitespace only; the audio-device test target
was reorganized upstream, so its obsolete dependency hunk was not copied.
The Objective-C peer factory additions were rebased by a three-way source
merge, retaining a distinct media worker thread: synchronous macOS audio
startup must not run on M156's network/ICE thread. The resulting
`m156-port.patch` applies cleanly to the pinned pristine source. A preliminary `git apply`
outside a repository ceiling returned a false success against the parent repo;
the independent source-contract extraction detected the real conflicts.

The isolated `.build/webrtc-m156-port/workspace` uses the M156 archive's DEPS
and an unmanaged `src` gclient solution. Current `gclient` duplicates CIPD
packages when this solution names the external `../DEPS`; using `deps_file:
'DEPS'` reads the identical pinned `src/DEPS` and completed the isolated sync.
Dependency directories were APFS-cloned from the prior M155 workspace solely
to accelerate sync. A completed `gclient sync --nohooks --no-history -j1` and
`record-dependencies.py` verified 58 Git checkouts against pinned revisions;
the record names 15 non-Git dependency declarations without claiming an
independent byte audit. The M155 lock, manifest, frameworks,
shipping dependency pins, application defaults and validation evidence remain
unchanged. Do not substitute M155's toolchain for M156's pinned LLVM.

`source-contract.py` binds the exact archive, rebased `m156-port.patch`, DEPS
and the 8,346-entry post-patch manifest. Verify a candidate source tree with:

```sh
python3 Experiments/WebRTCM156/source-contract.py verify \
  --archive .build/webrtc-m156-port/source.tar.gz \
  --patch Experiments/WebRTCM156/m156-port.patch \
  --deps .build/webrtc-m156-port/workspace/DEPS \
  --manifest Experiments/WebRTCM156/source-manifest.json \
  --lock Experiments/WebRTCM156/source-lock.json \
  --source .build/webrtc-m156-port/workspace/src
```

This verifies source content and dependency metadata, not the downloaded
dependency bytes or compiler. Negative controls for changed source and changed
DEPS both fail as intended. Verify the synced checkout revisions and build
toolchain separately before attributing any test result to M156.

The patched original and namespace-prefixed frameworks compiled for native
arm64 macOS. Exported header closure and H264/VP8/VP9/H265 loopback probes
passed, as did native engine and standalone-admission tests. The signed Release
companion explicitly packages the prefixed M156 binary; its build evidence
records source, compiler, dependency and framework hashes. The limited guest
audio/video Mac beta validation and remaining scope are in
`NativeMacGuest/VALIDATION.md`. Outgoing sharing/Presenter, speech quality,
other Mac hardware and iPhone remain outside this candidate's acceptance.

The source and media acceptance history is in
`docs/webrtc-m155-live-validation-2026-10-24.md`. The Mac system-background
rotation is already present in raw Designed-for-iPad camera output; rotating
the whole video would also rotate the person. Native AppKit capture must be
validated with the active macOS background in raw frames, local preview,
remote camera and Presenter output.
