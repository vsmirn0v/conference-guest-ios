"""Generate synthetic VP9 packets and independently decoded I420 pixel hashes.

Development-only dependencies: PyAV 19.0.1 (libvpx-vp9) and NumPy.
"""
import argparse
import base64
import hashlib
import json
from fractions import Fraction
from pathlib import Path

import av
import numpy as np


def fixture(width, height, color_range):
    encoder = av.CodecContext.create("libvpx-vp9", "w")
    encoder.width, encoder.height, encoder.pix_fmt = width, height, "yuv420p"
    encoder.time_base = Fraction(1, 15)
    encoder.framerate = Fraction(15)
    encoder.color_range = color_range
    encoder.options = {"deadline": "realtime", "cpu-used": "8", "lag-in-frames": "0", "lossless": "1", "g": "15"}
    decoder = av.CodecContext.create("vp9", "r")
    frames = []

    def append(packet):
        decoded = decoder.decode(packet)[0].reformat(format="yuv420p").to_ndarray()
        frames.append({"data": base64.b64encode(bytes(packet)).decode(), "key": packet.is_keyframe,
                       "sha256": hashlib.sha256(decoded.tobytes()).hexdigest()})

    for index in range(8):
        rgb = np.zeros((height, width, 3), dtype=np.uint8)
        rgb[:, :, 0] = np.arange(width, dtype=np.uint16)[None, :] % 256
        rgb[:, :, 1] = (np.arange(height, dtype=np.uint16)[:, None] + index * 16) % 256
        rgb[:, :, 2] = (index * 25) % 256
        frame = av.VideoFrame.from_ndarray(rgb, format="rgb24")
        frame.pts = index
        for packet in encoder.encode(frame):
            append(packet)
    for packet in encoder.encode(None):
        append(packet)
    return {"width": width, "height": height, "frames": frames}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path, nargs="?", default=Path(__file__).resolve().parents[2] / "RockNRollTests/Fixtures/vp9-lossless.json")
    output = parser.parse_args().output
    output.write_text(json.dumps([fixture(640, 360, 1), fixture(320, 180, 2)], separators=(",", ":")) + "\n")
