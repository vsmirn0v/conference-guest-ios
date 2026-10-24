#!/bin/bash
set -euo pipefail
experiment_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
repo_dir="$(cd -- "$experiment_dir/../../.." && pwd)"
output="${1:?Pass new distinct evidence directory}"
if [[ -e "$output" ]]; then echo 'Evidence directory already exists' >&2; exit 1; fi
mkdir -p "$output"
output="$(cd -- "$output" && pwd)"
python3 - "$repo_dir" "$output" <<'PY'
import sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter
root, output = map(Path, sys.argv[1:])
image = Image.open(root/'.build/webrtc-m155-port/live-validation/sharing-h264-r10/decoded-screen-static.png')
image.filter(ImageFilter.GaussianBlur(1)).save(output/'blur1.png')
image.resize((image.width//2, image.height//2), Image.Resampling.BILINEAR).resize(image.size, Image.Resampling.BILINEAR).save(output/'half-resolution.png')
corners = Image.new('RGB', (16, 16), 'white')
draw = ImageDraw.Draw(corners)
draw.rectangle((0, 0, 7, 7), fill=(255, 0, 0))
draw.rectangle((8, 0, 15, 7), fill=(0, 255, 0))
draw.rectangle((0, 8, 7, 15), fill=(0, 0, 255))
corners.save(output/'asymmetric-corners.png')
PY
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcrun --sdk macosx swiftc -O -parse-as-library "$experiment_dir/PixelAcceptance.swift" \
  "$experiment_dir/PixelAcceptanceTests.swift" -o "$output/PixelAcceptanceTests"
"$output/PixelAcceptanceTests" "$repo_dir" "$output" > "$output/tests.log" 2>&1
tail -n 1 "$output/tests.log"
