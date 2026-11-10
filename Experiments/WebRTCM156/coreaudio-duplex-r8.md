R8 experimental CoreAudio completion follow-up

Candidate: `.build/airpods-transition-startup/coreaudio-duplex-r8/LiveKitWebRTC.xcframework`.
Binary SHA256: `b70fbdfcf9b012db54ea7760080a16240abf935a37b460e5a2844ebae7487353`.
Build evidence SHA256: `1bb21c8f3f2946356ff48863c75c35cf74ce2007b573bf5fd27247181dff0d50`.
Base is immutable R7/2d58. R7/Host56 failure evidence is retained; app/public API/default/canonical/iOS/DSP are unchanged.

Fixes the observed AIR-R7-builtin-cold-2 track-reassociation race: expected intent1 became2 with identical muted/listening flags while raw output Start completed. Healthy superseded output-only work now returns typed-21 after success or interruption, allowing the existing bounded Swift latest-intent reconciliation to reuse the same raw endpoint. It never resets the original deadline or reopens a failed generation. Native error/unsafe/terminal/retirement-debt/deadline outcomes take precedence; HAL Create failures are recorded before classification.

A same-intent native output-demand withdrawal may retire once and return success only after checked cleanup and a still-unrequested output. Same-intent false→true demand ABA that loses binding proof remains fail-closed; no automatic physical retry is added or qualified.

Validation:94 hardware-free native tests passed, including eight completion regressions; construction and default/R6 SystemAudio Swift suites passed against R8. Unchanged Engine memory fixtures were not repeated. All7717 inherited source files verified, only the reviewed three-file delta; exact patch reconstruction/no fuzz. Existing linker/Swift warnings are retained. Exact reviewed patch: `28013a5cefdd3de33074de7c3b5e926dd2eb7433b1294ee925a07598172e77d4`.

Runtime must still demonstrate retained-21→same-owner success, no second native Start, strict350ms continuity and clean shutdown. AirPods/quality qualification remains open; user requested automated checks only. No promotion or DSP-fix claim. Select the existing explicit R6 construction against this SDK and verify exact embedded binary content identity plus the R7 priming/scoped-seal readback fields.
