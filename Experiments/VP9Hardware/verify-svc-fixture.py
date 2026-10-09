"""Convert GenerateSVC.c output to fixture pixels checked by two software decoders.

Development-only dependency: PyAV 19.0.1 with libvpx-vp9. No meeting, permissions,
network or real camera/microphone is used. Supply a binary produced by GenerateSVC.c.
"""
import argparse
import base64
import hashlib
import json
import struct
from pathlib import Path
import av


def digest(frame):
    frame = frame.reformat(format="yuv420p")
    result = hashlib.sha256()
    for plane in frame.planes:
        data = bytes(plane)
        for row in range(plane.height):
            result.update(data[row * plane.line_size:row * plane.line_size + plane.width])
    return result.hexdigest()


def fixture(binary):
    packets = binary.read_bytes()
    full_frames, base_frames = [], []
    full = av.CodecContext.create("libvpx-vp9", "r")
    independent = av.CodecContext.create("vp9", "r")
    base = av.CodecContext.create("libvpx-vp9", "r")
    while packets:
        if len(packets) < 4:
            raise ValueError("Truncated packet length")
        size = struct.unpack_from("<I", packets)[0]
        data, packets = packets[4:4 + size], packets[4 + size:]
        if len(data) != size or not size:
            raise ValueError("Truncated or empty packet")
        marker = data[-1]
        count, magnitude = (marker & 7) + 1, ((marker >> 3) & 3) + 1
        index = len(data) - 2 - count * magnitude
        if marker & 0xe0 != 0xc0 or count != 3 or index < 0 or data[index] != marker:
            raise ValueError("Expected a three-frame VP9 Annex-B index")
        sizes = [int.from_bytes(data[index + 1 + i * magnitude:index + 1 + (i + 1) * magnitude], "little") for i in range(count)]
        if min(sizes) <= 0 or sum(sizes) != index:
            raise ValueError("Invalid VP9 frame sizes")
        decoded, other = full.decode(av.Packet(data))[-1], independent.decode(av.Packet(data))[-1]
        if (decoded.width, decoded.height) != (640, 360) or digest(decoded) != digest(other):
            raise ValueError("Software references disagree")
        lower = base.decode(av.Packet(data[:sizes[0]]))[-1]
        if (lower.width, lower.height) != (160, 90):
            raise ValueError("Unexpected base dimensions")
        full_frames.append({"data": base64.b64encode(data).decode(), "key": not full_frames, "sha256": digest(decoded)})
        base_frames.append({"data": base64.b64encode(data[:sizes[0]]).decode(), "key": not base_frames, "sha256": digest(lower)})
    if len(full_frames) != 12:
        raise ValueError("Expected twelve synthetic frames")
    return [{"width": 160, "height": 90, "frames": base_frames}, {"width": 640, "height": 360, "frames": full_frames}]


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    args.output.write_text(json.dumps(fixture(args.binary), separators=(",", ":")) + "\n")
    print("Verified 12 base and 12 three-spatial-layer frames against software reference pixels")
