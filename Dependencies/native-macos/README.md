# Native Mac build SDK

The Git repository includes `LiveKitWebRTC-m157-audio-route-r1.tar.gz` (about 7 MB).
It is the **native macOS arm64 M157 (`branch-heads/8103`, `95554e4a0c5c343fdc989387d9d0ce18e2a2294b`) audio-route-recovery SDK**,
including public Objective-C headers, module maps, the exact binary, matching
`build-evidence.json` (`audioRouteRecovery`), source manifests, GN arguments,
and WebRTC/third-party license notices. It is an ordinary Git file, not a Git
LFS pointer or a download of the installed app.

`sdk.lock.json` pins the archive and every framework file. The binary SHA-256 is
`87214268a7a0837ef1e85e1202f623c62c34fbc6c8a9f1a3381eed20acf67519`.
An installed app contains the runtime binary but omits the development headers;
do not extract its framework as a build SDK or substitute unpatched upstream M150.
(`LiveKitWebRTC-m156-screen-r5.tar.gz` and `sdk.screen-r5.lock.json` are retained untouched as M156 baseline provenance.)

## Fresh checkout

Use Apple Silicon, Python 3.12+, Xcode 26+ with its macOS SDK, Git and XcodeGen.
Run from the repository root:

```sh
brew install python xcodegen
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
python3 NativeMacGuest/bootstrap.py
python3 NativeMacGuest/build.py --compile-only --output-dir .build/native-clean-build
```

The bootstrap extracts the verified SDK to the default
`.build/webrtc-m157-desktop-audio/native-framework-audio-route-r1` and fetches
LiveKit Swift `2.19.0` at commit `43c1c0870e51eedbfd95b20b1b5c43a767886786`
(`livekit-ffi-xcframework` `0.13.1`) into an independent `.build/native-sdk` checkout; `prepare-livekit.py` applies `Dependencies/native-macos/livekit-patches/*.patch` (`cancellable-app-reply.patch`, `shared-factory.patch`, `shared-track.patch`, `video-encoder-callback-prefix.patch`) to a build copy. `build.py` also prepares missing dependencies
automatically. It does not depend on a previous Xcode build's SourcePackages.
For offline SDK extraction only, use `bootstrap.py --framework-only`; LiveKit
and its transitive Swift packages still need network access on the first build.

The unsigned check compiles the complete native app. It does not run, install,
archive, or validate CloudKit/Handoff. A signed production-identity build needs
an Apple Development certificate and provisioning access for team `5V64BP2H3P`:

```sh
python3 NativeMacGuest/build.py \
  --identity 'Apple Development: YOUR TEAM IDENTITY' \
  --allow-provisioning-updates --output-dir .build/native-signed-build
```

Engineers using a different Apple team must configure their own signing/cloud
identities in their development target. SDK provisioning does not change app
identity, CloudKit, Handoff, sync provider, permissions, or shipping defaults.

Existing custom SDK paths remain supported through `--framework-root DIR`.
They must contain the matching XCFramework and build evidence. A missing custom
SDK fails rather than silently falling back to a different engine. Changed or
unrelated directories at the pinned destination are never overwritten.

## Direct distribution

Direct/Sparkle builds additionally need the pinned official Sparkle package:

```sh
mkdir -p .build/native-dmg/Sparkle
curl --fail --location --retry 2 \
  https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-2.10.0.tar.xz \
  --output .build/native-dmg/Sparkle-2.10.0.tar.xz
echo 'c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c  .build/native-dmg/Sparkle-2.10.0.tar.xz' | shasum -a 256 -c -
tar -xJf .build/native-dmg/Sparkle-2.10.0.tar.xz -C .build/native-dmg/Sparkle
```

Only extract after the checksum passes. The direct builder also checks the
framework version and binary hash. See [release tooling](../../NativeMacGuest/distribution/README.md).

## Source and validation

The archive retains the original build evidence byte-for-byte; its absolute
source paths describe the original build machine and are not prerequisites for
using this SDK. The corresponding manifests and previous r4 evidence are in
`provenance/`. The committed source recipe and patches are under
[`Experiments/WebRTCM157`](../../Experiments/WebRTCM157/README.md), with the
desktop audio, screen-detail, and audio-route recovery patches beside the rebased
M157 port (`Experiments/WebRTCM156/` retains M156 provenance).

Updating the default SDK requires a new immutable archive, lock and validation;
do not modify an existing archive in place.

Run dependency regressions with:

```sh
python3 -m unittest discover -s NativeMacGuest/Tests -p test_native_dependencies.py -v
```
