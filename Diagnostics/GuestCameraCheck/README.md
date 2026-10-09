# Guest camera qualification harness

Standalone SDK integration diagnostics; not included in the shipping app.
Uses the app's original camera delegate and H.264 color adapter against the
same pinned SDK. No SDK source or binary is forked here.

On an Apple Silicon Mac, generate the project with `xcodegen generate`, open
`CameraCheck.xcodeproj`, select **My Mac (Designed for iPad)** and Run. Press
**Check camera and codec**. Allow camera access for this diagnostic app.

The check captures six seconds of camera metadata, tests eight synthetic NV12
color/range/crop combinations, then runs H.264 local peer loopbacks for both a
synthetic pattern and the real Mac camera. It never joins an external room.
Only scalar metadata is saved to the app's temporary `camera-check.json` file;
no camera images or audio are saved. The real camera check should decode a
320×180 landscape image, RTC rotation 0, BT.709 attachments and advancing frames.
The synthetic check should decode 320×240 with BT.709 metadata.

To independently validate the SPS editor with FFmpeg/PyAV:

```sh
uv run --with av python oracle/generate.py
swiftc ../../RockNRoll/VendorIntegration/H264ColorSignalling.swift oracle/Normalize.swift -o oracle/normalize
oracle/normalize oracle/*.h264
uv run --with av python oracle/verify.py
```

This creates six synthetic Baseline/Main/High streams, supplements their color
signalling, and compares independently decoded visible Y/U/V samples and range.
A successful result is pixel identity for all six, including explicit-VUI inputs.

The shipping code does not log frame metadata or run these measurements.
