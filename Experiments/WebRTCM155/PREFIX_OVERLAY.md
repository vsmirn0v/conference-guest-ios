# M155 LiveKit namespace overlay

`prefix_overlay.py` emits a patch and a caller-named audit file. It never applies
the patch, copies an SDK checkout, builds a framework, or changes shipping pins.
Apply the patch only to a separately prepared SDK source tree.

The domain model is a formal C/Objective-C API catalog: types, protocols, enum
members, constants and exported functions. The catalog combines declarations
from the pinned M150 fork (`0385653a83f21acf3c916466d4088b29fe2f160b`) with
declarations in the frozen M155 port. A lexer changes code identifier tokens;
comments, string literals, imports and filenames retain their original bytes.
Existing `RTC_OBJC_TYPE`/`RTC_CONSTANT_TYPE` arguments are protected against
double wrapping. C++ scope-qualified names retain their native spelling even
when they collide with Objective-C names, such as `webrtc::RTCCertificate` or
`PeerConnectionInterface::RTCConfiguration`; the audit records these exclusions.
Owned native Objective-C translation units and formal SDK consumers outside
`sdk/objc` are also discovered and audited. This includes the audio engine's
adapter forward declaration, field and allocation. Native C++ typedefs and
enums do not enter the Objective-C catalog. A literal import graph repairs
dependency headers first, adding `#import` of `RTCMacros.h` only when the macro
is unavailable before its first use. The current direct imports are limited
to `RTCVideoRendererAdapter.h`, `RTCNetworkMonitor.h` and
`RTCDisplayLinkTimer.h`. Transitive consumers gain no redundant GN dependency.
The `#import` spelling lets the existing framework packager rewrite the source
path to `<LiveKitWebRTC/RTCMacros.h>`; existing imports retain their bytes.
The five packaging files use separate field-scoped GN, plist
and Python syntax checks to name the module and framework `LiveKitWebRTC`.

The `livekit` flavor sets the prefixes to `LK`/`kLK`, including enums, typedefs
and internal Objective-C classes such as
`LKRTCNativeAudioSessionDelegateAdapter`. It restores the standard helper class
`LKRTCYUVHelper`; its source filename remains `RTCYUVHelper.h`. The `guest`
flavor retains empty/`k` prefixes and `RTCConferenceYUVHelper`.

Primary Objective-C class and protocol definitions also provide a separate
catalog of local names without an `RTC` prefix. LiveKit rewrites these as
direct `LK…` identifier tokens, including `LKSckHelper` and
`LKObjCAudioDeviceDelegate`, without adding a macro dependency to native targets.
Guest flavor keeps their original names. Apple categories and external forward
declarations are excluded. Native C++ scope syntax is preserved; an ambiguous
unqualified C++ class declaration matching a local Objective-C name is rejected.

The two maximum H264 profile accessors use the M150 fork's lazy function API:
`RTC_OBJC_TYPE(RTCMaxSupportedH264ProfileLevelConstrainedHigh)` and
`RTC_OBJC_TYPE(RTCMaxSupportedH264ProfileLevelConstrainedBaseline)`. The overlay
preserves callable `LKRTCMaxSupported…` exports. The earlier M155 candidate's
same-named data exports are retained only in its preserved artifacts; revised
frameworks need fresh ABI and runtime qualification.

Guest policy C exports need explicit flavor isolation. The qualified M150
LiveKit framework comes from `prefixed-src`, which has the prefix, three hybrid
patches and maintenance patches; `guest-src` has additional guest policies.
The script reads `nm -gU` from the qualified framework and records its SHA256.
It compares formal legacy and current function declarations, accounting for
functions already wrapped in the original fork. The eight additional guest
functions receive `LKRTC…` names in LiveKit:

- `RTCApplicationCaptureMuted`
- `RTCApplicationInputMuteReconfiguring`
- `RTCConfigureScreenShareEncoderQuality`
- `RTCGetScreenShareEncoderRates`
- `RTCSetApplicationCaptureMuted`
- `RTCSetApplicationInputMuteIntent`
- `RTCSetConferencePlayoutReserved`
- `RTCSetScreenShareSenderResolution`

Declarations, definitions and direct calls are changed together. Guest flavor
keeps these names raw. App `dlsym` strings are outside the overlay domain and
continue to resolve the guest framework's policy functions. The two original
raw metrics exports, `RTCEnableMetrics` and `RTCGetAndResetMetrics`, retain their
existing ABI in both flavors. A selected baseline containing guest-only raw
exports, or missing legacy raw exports, is rejected.

Run from the repository root; artifact filenames remain the caller's choice:

```bash
python3 Experiments/WebRTCM155/test-prefix-overlay.py
python3 Experiments/WebRTCM155/prefix_overlay.py plan \
  --source .build/webrtc-m155-port/src \
  --old-fork .build/webrtc-maintenance-20261024/guest-src \
  --flavor livekit \
  --qualified-prefix-binary .build/webrtc-maintenance-20261024/prefixed-src/out/rock-hybrid-mac/LiveKitWebRTC.framework/LiveKitWebRTC \
  --livekit-source /absolute/path/to/pinned/client-sdk-swift \
  --audit /absolute/path/outside/sdk/livekit-prefix-audit.json \
  --patch /absolute/path/outside/sdk/livekit-prefix.patch
python3 Experiments/WebRTCM155/prefix_overlay.py verify \
  --source .build/webrtc-m155-port/src \
  --audit /absolute/path/outside/sdk/livekit-prefix-audit.json \
  --patch /absolute/path/outside/sdk/livekit-prefix.patch \
  --stage before
```

The optional Swift inventory requires a clean `Sources/LiveKit` at
`57a84d71c33e97349963c1cbd442fb4b01428b7c`. It records source hashes and every
`LKRTC`/`kLKRTC` identifier reference. This is a namespace presence check;
method signatures, Swift importing, linking and runtime isolation still require
compilation and runtime acceptance.

The audit locks every code file under `sdk/objc`, discovered owned native
consumers, and all five packaging files, including unchanged files.
Verification checks both path set and content
hashes, rejects a changed patch, and supports `--stage after` on the separate
tree after application. Planning rejects drift during inventory, already
prefixed sources, source symlinks and outputs inside either SDK checkout.

The current frozen port yields 485 audited inputs, 531 SDK namespace symbols,
19 local Objective-C class/protocol names, 188 changed paths and 92 matching
pinned Swift identifiers. Sixteen synthetic lexer,
declaration, flavor and packaging fixtures pass; patch dry-run and verification
against the frozen source pass. No prefix SDK build is claimed by this check.

`audit-prefix-header-closure.py` projects a verified overlay entirely in memory,
checks every resulting file hash, and runs the actual audited framework-header
replacement function on the existing framework's exported header set:

```bash
python3 Experiments/WebRTCM155/audit-prefix-header-closure.py \
  --source .build/webrtc-m155-port/src \
  --audit /absolute/path/to/livekit-prefix-audit.json \
  --patch /absolute/path/to/livekit-prefix.patch \
  --headers /absolute/path/to/LiveKitWebRTC.framework/Headers \
  --report /absolute/path/outside/sdk/header-closure.json
```

The final accepted static check covers 111 exported headers with no unresolved packaged
imports and 153 ordinary `.mm` macro consumers. It reports the unit test's
retained `<WebRTC/WebRTC.h>` module import separately. Conditional import
branches, GN dependency checks and compiled runtime coexistence remain compiler
and runtime acceptance gates.
