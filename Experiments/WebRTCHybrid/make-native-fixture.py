"""Convert independent SVC reference JSON to the native test's binary format."""
import base64
import json
import struct
import sys
from pathlib import Path

stream = max(json.loads(Path(sys.argv[1]).read_text()), key=lambda item: item["width"] * item["height"])
with open(sys.argv[2], "wb") as output:
    output.write(b"RVP9SVC1" + struct.pack("<I", len(stream["frames"])))
    for frame in stream["frames"]:
        data = base64.b64decode(frame["data"], validate=True)
        digest = bytes.fromhex(frame["sha256"])
        if len(digest) != 32 or not data:
            raise ValueError("Invalid fixture frame")
        output.write(struct.pack("<IIII", stream["width"], stream["height"], int(frame["key"]), len(data)))
        output.write(data)
        output.write(digest)
