# Offline pinned LiveKit compilation

`compile-pinned-livekit.py` plans or executes a direct Clang/Swift compiler build
of the production SDK. It reads the original checkouts without copying or
modifying their source. It does not invoke SwiftPM, Xcode package resolution,
Git mutation, or a downloader. Shipping package manifests and pins are unchanged.

The inspected resolved workspace is
`.build/udp-sdk-comparison/DerivedData/SourcePackages`:

| Production dependency | Existing local input |
| --- | --- |
| LiveKit | `checkouts/client-sdk-swift`, clean revision `57a84d71c33e97349963c1cbd442fb4b01428b7c` |
| CLiveKitProto | Same checkout, `Sources/CLiveKitProto`; eight C source files and its original module map |
| LiveKitNanopb | Same checkout, `Sources/LiveKitNanopb`; three Swift source files |
| LKObjCHelpers | Same checkout, `Sources/LKObjCHelpers`; one Objective-C source file and its original module map |
| LiveKitUniFFI | `checkouts/livekit-uniffi-xcframework`, clean revision `7a9bf91b1601d5c408ae0cac7dc2047b5a4f615e`, version `0.1.9`; three Swift source files |
| RustLiveKitUniFFI | `artifacts/livekit-uniffi-xcframework/RustLiveKitUniFFI/RustLiveKitUniFFI.xcframework`, resolved archive checksum `8db93e8ccd9f22263c39855808da48a4d6b5d620d8f6e43ab4501ede847b23eb` |
| LiveKitWebRTC | Caller-selected newly built prefixed platform framework |

`swift-protobuf` is used by tests and `swift-docc-plugin` by documentation.
Neither is needed for production source compilation, nor present among the
resolved source checkouts. The original package manifests are included in the
input hash inventory. No replacement or truncated package is created.

Set the two variables to the actual prefixed framework output directories.
Each argument must name a platform slice's `LiveKitWebRTC.framework`, rather
than an XCFramework containing several slices:

```bash
PREF_MAC_FRAMEWORK=/absolute/path/to/mac/LiveKitWebRTC.framework
PREF_SIM_FRAMEWORK=/absolute/path/to/simulator/LiveKitWebRTC.framework

python3 Experiments/WebRTCM155/compile-pinned-livekit.py \
  --developer-dir /Applications/Xcode.app/Contents/Developer \
  --source-packages .build/udp-sdk-comparison/DerivedData/SourcePackages \
  --webrtc-framework "$PREF_MAC_FRAMEWORK" \
  --platform macos \
  --output .build/webrtc-m155-port/livekit-swift-mac \
  --execute

python3 Experiments/WebRTCM155/compile-pinned-livekit.py \
  --developer-dir /Applications/Xcode.app/Contents/Developer \
  --source-packages .build/udp-sdk-comparison/DerivedData/SourcePackages \
  --webrtc-framework "$PREF_SIM_FRAMEWORK" \
  --platform ios-simulator \
  --output .build/webrtc-m155-port/livekit-swift-simulator \
  --execute
```

Omit `--execute` to generate only `compile-plan.json` and a readable
`commands.sh`. This mode accepts a pending WebRTC output path; execution
requires the framework binary to exist. The JSON is the complete command and
input inventory. Use the Python harness for execution so it creates output
directories and verifies inputs after compilation.

The build uses arm64 and the selected Xcode toolchain/SDK. This machine's global
`xcode-select` points at Command Line Tools, which has no simulator SDK. The
explicit `--developer-dir` selects the installed Xcode for this process without
changing the global selection. Default minimum
versions are macOS 11.0 and iOS 13.0, matching the pinned package's effective
arm64 platform support; use `--deployment-target` when the framework was built
with a higher deployment minimum. Swift 6 is the default, selecting the latest
mode supported by the pinned LiveKit manifest; `--swift-version 5` checks its
older supported mode. UniFFI remains in Swift 5 mode as required by its
own pinned manifest. Compiler concurrency defaults to two jobs.

Clang compiles and archives both C/Objective-C targets. Swift compiles
LiveKitUniFFI and LiveKitNanopb into static libraries and module files, then
compiles all 300 `Sources/LiveKit` Swift files and links `libLiveKit.dylib`
against those archives, the helper archives, the Rust framework and the new
WebRTC framework. This checks real source signatures, Swift imports, object
generation and linking. It omits test targets and resource packaging; the
production Swift source has no `Bundle.module` references.

Each Swift target has a persistent per-source output-file map. This avoids
missing temporary objects in Xcode 27's batch driver, and archive member counts
reject a nominally successful but empty static archive. Each compiler command
gets a numbered log. A passing execution writes
`compile-result.json` with hashes of the resulting modules and libraries after
checking that input bytes and both clean checkout revisions remain unchanged.
Output paths inside dependency or framework trees are rejected. Runtime
coexistence, media behavior and app packaging remain separate acceptance gates.

Preparation verified both checkout revisions and generated 14-command macOS and
simulator plans covering 300 LiveKit, three UniFFI and three Nanopb Swift files. No compiler
build was run during harness preparation.
