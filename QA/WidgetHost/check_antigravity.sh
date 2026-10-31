#!/bin/zsh
# Offline synthetic decoding/composition only. Never applies a case or starts UI.
set -euo pipefail
qa_source_dir="${0:A:h}"
qa_repo_root="${qa_source_dir:h:h}"
qa_output="$qa_repo_root/.build/widget-antigravity-qa"
mkdir -p "$qa_output"
python3 -B "$qa_source_dir/antigravity_fixtures.py" generate
python3 -B "$qa_source_dir/antigravity_fixtures.py" verify
python3 -B -m unittest discover -s "$qa_source_dir" -p 'antigravity_fixtures_test.py'
qa_shared_sources=()
for qa_source in "$qa_repo_root"/Shared/*.swift; do
  case "${qa_source:t}" in
    UsageSnapshotStore.swift|DeepSeekCredentialStore.swift) continue ;;
  esac
  qa_shared_sources+=("$qa_source")
done
xcrun swiftc -parse-as-library -module-name AntigravityWidgetQAContractCheck \
  -module-cache-path "$qa_output/contract-module-cache" \
  -o "$qa_output/check-antigravity-cases" "${qa_shared_sources[@]}" \
  "$qa_source_dir/Common/WidgetQACase.swift" "$qa_source_dir/Tools/CheckAntigravityCases.swift"
"$qa_output/check-antigravity-cases" "$qa_output/fixtures/manifest.json"
