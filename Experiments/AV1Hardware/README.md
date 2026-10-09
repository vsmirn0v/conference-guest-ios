# AV1 hardware receiving capability probe

This development-only experiment feeds complete AV1 temporal units to a
VideoToolbox session that **requires** hardware and reads back the actual hardware
property. The synthetic 640×360, 8-bit 4:2:0 stream is encoded by SVT-AV1; decoded
Y/U/V pixels are compared exactly with an independent dav1d reference. No camera,
microphone, meeting service, or production decoder factory is used.

```sh
# PyAV 19.0.1 must contain libsvtav1 and libdav1d.
python3 Experiments/AV1Hardware/generate-fixture.py /tmp/av1-fixture.json
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun --sdk macosx \
  swiftc -O -parse-as-library Experiments/AV1Hardware/HardwareProbe.swift \
  -o /tmp/av1-hardware-probe
/tmp/av1-hardware-probe /tmp/av1-fixture.json
```

On the M4 Mac and iVitalii (A19 Pro), all 16 frames matched dav1d exactly with
verified hardware use. The phone check used the separately signed native hybrid
harness with its optional AV1 fixture argument.
This qualifies ordinary AV1 decoding only. It does not qualify AV1 spatial SVC,
WebRTC's packet/operating-point bridge, temporal-layer switching, or hardware encoding.
The experiment consumes the encoder/container's `av1C` record according to the
[AV1 ISO media binding](https://aomediacodec.github.io/av1-isobmff/); a production
WebRTC adapter must instead parse the received sequence-header OBUs safely.
