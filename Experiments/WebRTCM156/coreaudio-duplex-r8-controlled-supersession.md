# R8 controlled startup supersession diagnostic

Default-off DEBUG harness only. `ROCK_MIC_RAW_START_TRACK_SUPERSESSION=1` observes the first raw-output start for at most20 seconds, targeting2ms passive observations. After two matching snapshots it invokes existing track-publication invalidation once. No SDK/API, DSP, IO, timing hold, transport or retry behavior is added.

Every flagged event has `coldStartupTimingQualified=false`. The proof covers the phase13 marker-to-start-return control window; it does not observe instructions inside Apple's HAL call. Missing the window remains **not exercised**.

The evidence checker requires the accepted same-flags N→N+1 latch before raw-start return, exact old native-call/prepare identity, native-21/retryLatest then accepted newer serial, same owner/audio operation/native deadline/caller deadline/output epoch, create/start/bind counts1, converted output progress, no input generation and closed capture gates. Native errors, cleanup debt or changed output generation reject the proof.

Frozen source: `.build/airpods-transition-startup/controlled-raw-start-supersession/revision-2`. Exact patch reconstruction and reviewer source identity checks passed. Pure Foundation proof tests and R6/default DEBUG syntax parsing passed. These do not establish natural runtime supersession or hardware/quality/latency acceptance. Root owns the signed automated controlled run and one default-off check.

The R8 SDK binary remains `b70fbdfcf9b012db54ea7760080a16240abf935a37b460e5a2844ebae7487353`. Canonical/default/iOS artifacts remain unchanged.
