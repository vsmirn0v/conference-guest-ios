#!/usr/bin/env python3
"""Build a private RTC log parser with unambiguous feedback SSRCs, then restore source."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    source = args.source.resolve(strict=True)
    output = args.output.resolve()
    if output.exists():
        parser.error("Output must be new")
    relative = "rtc_tools/rtc_event_log_to_text/converter.cc"
    subprocess.run(["git", "diff", "--exit-code", "HEAD", "--", relative], cwd=source, check=True)
    file = source / relative
    original = file.read_bytes()
    text = original.decode()
    before = '" seq_nums=%s\\n",\n            GetLabel(direction), msg.log_time_ms(),'
    after = '" media_ssrc=%u seq_nums=%s\\n",\n            GetLabel(direction), msg.log_time_ms(), msg.nack.media_ssrc(),'
    assert text.count(before) == 1
    text = text.replace(before, after)
    before = '"RTCP_PLI_%s %" PRId64 " <contents omitted>\\n",\n            GetLabel(direction), msg.log_time_ms());'
    after = '"RTCP_PLI_%s %" PRId64 " media_ssrc=%u\\n",\n            GetLabel(direction), msg.log_time_ms(), msg.pli.media_ssrc());'
    assert text.count(before) == 1
    text = text.replace(before, after)
    before = '"RTCP_REMB_%s %" PRId64 " <contents omitted>\\n",\n            GetLabel(direction), msg.log_time_ms());'
    after = '"RTCP_REMB_%s %" PRId64 " bitrate_bps=%" PRId64 " media_ssrcs=%s\\n",\n            GetLabel(direction), msg.log_time_ms(), msg.remb.bitrate_bps(), StrJoin(msg.remb.ssrcs(), ",").c_str());'
    assert text.count(before) == 1
    modified = text.replace(before, after).encode()
    output.mkdir(parents=True)
    digest = lambda value: hashlib.sha256(value).hexdigest()
    evidence = {"sourceBeforeSHA256": digest(original), "sourcePatchedSHA256": digest(modified)}
    try:
        file.write_bytes(modified)
        build = source / "out/rock-native-guest-eventlog"
        subprocess.run([str(source / "third_party/ninja/ninja"), "-C", str(build), "-j4", "rtc_event_log_to_text"], cwd=source, check=True)
        binary = output / "rtc_event_log_to_text"
        shutil.copy2(build / binary.name, binary)
        evidence["binarySHA256"] = digest(binary.read_bytes())
    finally:
        if file.read_bytes() != modified:
            raise RuntimeError("Concurrent converter edit preserved; cannot restore safely")
        file.write_bytes(original)
        evidence["sourceRestoredSHA256"] = digest(file.read_bytes())
        (output / "build-evidence.json").write_text(json.dumps(evidence, indent=2) + "\n")


if __name__ == "__main__":
    main()
