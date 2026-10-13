# Legacy Objective-C facade compatibility

`patches/0001-legacy-objc-compatibility.patch` targets WebRTC M150 source
`0385653a83f21acf3c916466d4088b29fe2f160b` with the existing hybrid decoder
patches applied and the LiveKit `apple_prefix.patch` reversed. Its diff was
created from immediate before/after snapshots, excluding carried hybrid edits.

The original binary wrappers import `RTCEAGLVideoView`; M150 retains its source
and header but does not include the UI implementation in the shipping framework.
The patch adds the existing `opengl_ui_objc` target to the iOS framework's deps.
Existing `-all_load` preserves the Objective-C class and metaclass exports.

The original wrappers call the four-argument `RTCCryptoOptions` initializer.
The compatibility initializer forwards to M150's designated initializer with
`prefer_gcm_crypto_suites = false` and
`enable_aes128_sha1_80_crypto_cipher = true`, preserving the native defaults in
`api/crypto/crypto_options.h`. It does not change the new initializer.

No degradation-preference alias was added: current app and inspected wrapper
imports do not require the removed spelling. Existing numeric values are stable.

Validation performed: reverse patch application check; ARM64 iOS Objective-C++
syntax check with warnings as errors; standalone Mac runtime check of all 16
boolean input combinations, including the two new SRTP defaults. Full framework
linking and original-SDK runtime qualification are separate release gates.

Local comparison evidence and before/after SHA-256 inventory are stored under
`.build/reverse-sdk/compatibility/`. Only open-source facade changes are contained
in this patch; proprietary SDK framework binaries are unchanged.
