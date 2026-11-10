R7 experimental CoreAudio duplex candidate

SDK: `.build/airpods-transition-startup/coreaudio-duplex-r7/LiveKitWebRTC.xcframework`.
Binary SHA256: `2d58a37341fbc3bdfda051fb0457001e77fd76d66c484e4be93cb80f7977cefe`.
Build evidence: `8b7b174b28f9d581de181dff915ed595c5a0bf9ec022e09faa4a039917af882b`.
Base SDK is immutable R6/ef48; canonical microphone-r2/default VPIO, app source, iOS and APM/DSP configuration are unchanged. Select the existing explicit R6 construction against this SDK; no new app API is required.

Requested output starts once as a format-agnostic silence-only IOProc before binding. After native Start returns, fresh endpoint callbacks and route/shape/epoch checks seal immutable input/output resources. A Bound CAS precedes converter creation, then a release-published gate opens data on the same still-started registration. Raw silence never counts as converted-output readiness. No fixed settling delay or second native Start is used for binding.

Input seal covers full input ASBD and both selected IDs/UIDs/alive identity. Output has an independent monotonic lifecycle/Sound/format epoch. Selected output sfmt is output-only in proved Dormant+SoundOff, resource-free PendingRaw, or RawNegotiating; it cannot mute a committed microphone. Bound/Closing output changes, sealed input changes, identity/nonformat changes, exhaustion and uncertain cleanup still fail closed. SoundOff never starts output for negotiation; later SoundOn requires fresh output proof and sealed input revalidation. Retired/invalidated owners never reopen.

Passive readback must include `presealOutputPrimingSupported=true` and `resourceScopedFormatSealSupported=true`; also compare the exact SDK binary/evidence identity. State distinguishes raw output start/callbacks from data-ready/converted callbacks/bind count. Lifecycle values:0 Dormant,2 RawNegotiating,4 Bound,6 Closing,8 PendingRaw. Existing phase IDs0–12, including Ready8, are preserved; new phases13/14 append. Unbound retirement archives `formatBound=false` with zero ASBD.

Validation:86 hardware-free native tests passed (82 driver/ring/transport/negotiation +4 AudioState); five Swift suites passed (construction, default/R6 SystemAudio, default/R6 Engine). All7716 inherited source files were checked; only the reviewed10-file delta/new test was present, and the patch reconstructs exact bytes without fuzz. The first test-only enum compiler failure and script-permission launch error remain preserved. Existing missing-libLTO linker warnings and Swift warnings are recorded; no warning-free claim.

Runtime format transitions, strict350ms continuity, SoundOff→SoundOn, late mute/Leave, energy and acoustic acceptance remain pending. The earlier intermittent R6 near-end speech gap is unresolved and was not reproduced in later tapped/untapped controls; R7 makes no DSP/quality-fix claim. Malformed HAL layouts are bounded/fail-terminal, with no assumed HAL error-return-silence guarantee. No default promotion.

Exact reviewed source: `source-review/revision-7`, patch `6d32b0c272bdc581e36a577cd1a90371db13ae8c0d36994ac12a984f1c397f70`. Complete build/test logs, source manifest/overlay, reconstruction proof, warning inventory and review clearance are retained in the candidate root/provenance and its `.lock.json`.
