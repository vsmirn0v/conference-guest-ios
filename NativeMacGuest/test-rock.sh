#!/bin/bash
set -euo pipefail
source_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
exec bash "$source_dir/Tests/run-meeting-engine-fixtures.sh" rock "$@"
