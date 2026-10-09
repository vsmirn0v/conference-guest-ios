#!/usr/bin/env python3
"""Independent FFmpeg/PyAV color oracle for synthetic device encoder packets."""
import argparse
import base64
import io
import json
from pathlib import Path

import av
import numpy as np
from PIL import Image


def verify(row):
    decoder = av.CodecContext.create("h264", "r")
    reference = np.array(Image.open(io.BytesIO(base64.b64decode(row["reference_png"]))).convert("RGB"))
    decoded = []
    for packet in row["packets"]:
        decoded.extend(decoder.decode(av.Packet(base64.b64decode(packet["data"]))))
    decoded.extend(decoder.decode(None))
    if len(decoded) < 10:
        raise ValueError("No advancing decoded video")
    frame = decoded[-1]
    rgb = frame.to_ndarray(format="rgb24")
    if rgb.shape != reference.shape:
        raise ValueError("Unexpected decoded dimensions")
    # Centers avoid the expected 4:2:0 chroma blur at high-contrast boundaries.
    centers = [(frame.height // 4, int(frame.width * (column + 0.5) / 8)) for column in range(8)] + [(frame.height * 3 // 4, max(2, min(frame.width - 3, int(frame.width * x)))) for x in [0.00625, 0.0625, 0.25, 0.5, 0.75, 0.990625]]
    errors = [np.abs(rgb[y-2:y+3, x-2:x+3].astype(float) - reference[y-2:y+3, x-2:x+3].astype(float)) for y, x in centers]
    result = {key: row[key] for key in ["family", "bgra", "cropped", "hardware"]}
    result["qualified"] = row.get("qualified", True)
    result["scaled"] = row.get("scaled", False)
    result.update(frames=len(decoded), width=frame.width, height=frame.height,
                  color_range=int(frame.color_range), color_space=int(frame.colorspace),
                  mean_center_rgb_error=float(np.mean(errors)), maximum_center_rgb_error=float(np.max(errors)))
    # Core Image color-managed reference and FFmpeg matrix conversion differ
    # slightly for BT.709 transfer; compare BGRA and NV12 within separate budgets.
    result["passes"] = (result["color_space"] == 1 and result["color_range"] == (1 if row["bgra"] else 2)
                        and result["maximum_center_rgb_error"] <= (6 if row["bgra"] else 14))
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    results = [verify(row) for row in json.loads(args.input.read_text())]
    args.output.write_text(json.dumps(results, indent=2) + "\n")
    print(json.dumps(results, indent=2))
    if not all(row["passes"] for row in results):
        raise SystemExit(1)
