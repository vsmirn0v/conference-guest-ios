# R8 controlled supersession verifier revision3

The diagnostic harness and SDK are unchanged. Host58 controlled run1 reached the exact accepted track latch during the raw-start marker-to-return span and returned native-21/retryLatest then0/accept. Its final authority changed afterward because native recording demand opened: Closed->Open advances the shared capture epoch even when no input hardware is authorized. The earlier verifier rejected that legitimate diagnostic difference.

Revision3 retains exact full words for the latch and both receipts. Final state may be that exact word or only one Closed->Open epoch increment with the same intent/publicflags6 and no seal/commit/private/terminal/authorization. The demand-step case requires recordingRequested=true, recording/inputAvailable=false. Both cases retain zero input resources/callbacks/physical generation, no prepared input, empty HAL journals, no errors/unsafe/quarantine, unchanged output epoch and one create/start/bind. The result emits finalCaptureAuthority and finalCaptureAuthorityChange. ABA/multiple epoch/other changes reject.

Exact source review, focused pure tests and retained-log replay passed. Replay classifies singleNativeCaptureDemandOpened; it does not change the original run acceptance=false. Fresh Host59 validation remains pending. The whole opted-in run is timing-excluded and a missed window stays not exercised. No SDK/default/DSP changes or additional native IO, retries or holds.

Evidence: `.build/airpods-transition-startup/controlled-raw-start-supersession/revision-3/`. The prior revision2 patch, source and negative Host58 artifacts remain immutable.
