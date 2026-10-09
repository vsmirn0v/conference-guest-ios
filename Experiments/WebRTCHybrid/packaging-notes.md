# Packaging the native WebRTC framework

After all three framework builds have completed, run:

```sh
Experiments/WebRTCHybrid/package-framework.sh \
  .build/native-webrtc-15003/src \
  out/rock-hybrid-mac out/rock-hybrid-ios-device out/rock-hybrid-ios-simulator \
  .build/native-webrtc-15003/release
```

Build-output arguments are absolute paths or paths relative to the source root.
The release-output argument is relative to the current directory. The helper
uses `verify-source.sh` and `build-lock.json`, requires completed Ninja targets,
and does not compile, download, publish, sign, or modify source/build outputs.
For the pinned iOS graph's missing `.unstripped` output, it accepts only the
exact link/post-processing pair and checks a temporary manifest omitting that
one output declaration. Ninja must then report no work with identical link
and post-processing commands; all input freshness and command-hash checks remain
active. The final unsigned bundle must match its linked binary.
Python 3.9+, Xcode, and the dependency-synced source tree are required. The sibling
`depot_tools` directory is added to `PATH` when present; otherwise provide it in
`PATH` for the pinned upstream license generator.

The release contains `LiveKitWebRTC.xcframework`, its deterministic ZIP,
`SHA256SUMS`, and `Supporting/`. SwiftPM can consume the hosted ZIP with its
printed SHA-256 checksum. Keep each published URL immutable. An existing output
is accepted only when its complete file/symlink inventory matches; different
contents fail without replacing it. Packaging uses a temporary sibling directory
and installs the completed output atomically.

`Supporting/provenance.json` records the full build lock, verified source commit,
ordered patch hashes, exact per-slice GN arguments, binary hashes, observed Xcode
and compiler versions, SDK versions, and license-file hashes. Tool versions are
observed during packaging; they do not replace build logs or runtime validation.
The helper checks for concurrent framework, lock, and patch changes and verifies
the source again before installing the release.

The exact-source upstream `generate_licenses.py` runs separately against each
framework target's GN dependency graph. Unknown license mappings fail packaging.
Generated notices plus WebRTC `LICENSE`, `PATENTS`, and `AUTHORS` are included in
the ZIP. `Supporting/LiveKitWebRTC-notices.txt` is a ready-to-copy app resource;
the same file is also placed inside every framework slice so it accompanies
normal framework embedding. Check the final app/archive to verify retention.
Notices intentionally include each slice's complete list rather than dropping
duplicate text that might differ between platforms.

Only macOS ARM64, iOS-device ARM64, and iOS-simulator ARM64 are packaged. Intel,
Catalyst, tvOS, and visionOS are not supplied. Packaging checks slice metadata
and the exported header declaration, but does not prove selector dispatch,
hardware decoding, pixel correctness, or guest/native integration behavior.
