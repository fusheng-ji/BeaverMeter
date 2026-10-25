#!/bin/zsh
# Opt-in macOS integration test. Uses only temporary demo app copies and test bundle IDs.
set -euo pipefail
project_dir="${0:A:h:h}"
cd "$project_dir"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
python3 -B Tests/Integration/sparkle_install.py \
  "${1:-$project_dir/.build/release/Build/Products/Release/BeaverMeter.app}" \
  "${2:-$project_dir/.build/release/SourcePackages/artifacts/sparkle/Sparkle}" "${@:3}"
