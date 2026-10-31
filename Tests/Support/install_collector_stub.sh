#!/bin/zsh
set -euo pipefail
if [[ "${BM_TEST_FAIL:-}" == collector ]]; then
  print -r -- changed-by-failed-collection > "${1:h}/deepseek-platform-token"
  print -r -- changed-by-failed-collection > "${1:h}/new-scan-cache.json"
  exit 16
fi
if [[ "${BM_TEST_FAIL:-}" == schema ]]; then
  printf '{"schemaVersion":7}\n' > "$1"
else
  printf '{"schemaVersion":8}\n' > "$1"
fi
chmod 600 "$1"
