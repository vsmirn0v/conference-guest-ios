#!/bin/bash
set -euo pipefail
m155_dir="$(cd "$(dirname "$0")" && pwd)"
export ROCK_WEBRTC_PROBE_SOURCE="$m155_dir/MediaProbe.swift"
if [[ "${ROCK_WEBRTC_API:-guest}" == prefixed ]]; then
  generated="$(mktemp -t m155-prefixed-probe).swift"
  trap 'rm -f "$generated" "${generated%.swift}"' EXIT
  python3 - "$ROCK_WEBRTC_PROBE_SOURCE" "$generated" <<'PYCODE'
from pathlib import Path
import sys
# The prefixed flavor deliberately retains the standard LiveKit helper name.
Path(sys.argv[2]).write_text(Path(sys.argv[1]).read_text().replace('"RTCConferenceYUVHelper"', '"RTCYUVHelper"'))
PYCODE
  export ROCK_WEBRTC_PROBE_SOURCE="$generated"
  bash "$m155_dir/../WebRTCMaintenance/run-media-probe.sh" "$@"
else
  exec bash "$m155_dir/../WebRTCMaintenance/run-media-probe.sh" "$@"
fi
