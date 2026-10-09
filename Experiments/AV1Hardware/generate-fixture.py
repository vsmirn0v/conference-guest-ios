"""Generate a synthetic AV1 temporal-unit fixture with independent dav1d pixels.

Development dependency: PyAV 19.0.1 with libsvtav1 and libdav1d. This is a
container/VideoToolbox capability check, not a WebRTC or spatial-SVC test.
"""
import argparse
import base64
import hashlib
import json
from fractions import Fraction
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


def generate(output):
    movie = output.with_suffix(".mp4")
    with av.open(str(movie), "w") as container:
        stream = container.add_stream("libsvtav1", rate=10)
        stream.width, stream.height, stream.pix_fmt = 640, 360, "yuv420p"
        stream.codec_context.thread_count = 2
        stream.options = {"preset": "12", "crf": "24", "svtav1-params": "lp=2"}
        for index in range(16):
            frame = av.VideoFrame(640, 360, "yuv420p")
            frame.pts, frame.time_base = index, Fraction(1, 10)
            for channel, plane in enumerate(frame.planes):
                rows = bytearray(plane.line_size * plane.height)
                for y in range(plane.height):
                    start = y * plane.line_size
                    rows[start:start + plane.width] = bytes(16 + (x + y + index * 9 + channel * 47) % 220 for x in range(plane.width))
                plane.update(rows)
            for packet in stream.encode(frame):
                container.mux(packet)
        for packet in stream.encode():
            container.mux(packet)
    with av.open(str(movie)) as container:
        stream = container.streams.video[0]
        config = stream.codec_context.extradata
        assert config and config[0] == 0x81, "Expected an AV1CodecConfigurationRecord"
        packets = list(container.demux(stream))
        decoder = av.CodecContext.create("libdav1d", "r")
        decoder.thread_count = 1
        decoder.extradata = config
        values = []
        for packet in packets:
            if not packet.size:
                continue
            decoded = decoder.decode(packet)
            values.append({"data": base64.b64encode(bytes(packet)).decode(),
                           "sha256": [digest(frame) for frame in decoded]})
        delayed = decoder.decode(None)
        if delayed:
            values[-1]["sha256"].extend(digest(frame) for frame in delayed)
        assert sum(len(value["sha256"]) for value in values) == 16
        result = {"width": stream.width, "height": stream.height,
                  "av1C": base64.b64encode(config).decode(), "packets": values}
    output.write_text(json.dumps(result, separators=(",", ":")) + "\n")
    print(f"Generated {len(values)} temporal units, 16 dav1d reference frames")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    generate(parser.parse_args().output)
