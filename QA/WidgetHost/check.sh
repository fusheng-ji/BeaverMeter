#!/bin/zsh
# Offline contracts only: no application build, registration, apply or collection.
set -euo pipefail
qa_source_dir="${0:A:h}"
qa_repo_root="${qa_source_dir:h:h}"
qa_output="$qa_repo_root/.build/widget-module-qa"
mkdir -p "$qa_output"
python3 -B "$qa_source_dir/module_fixtures.py" generate
qa_shared_sources=()
for qa_source in "$qa_repo_root"/Shared/*.swift; do
  case "${qa_source:t}" in
    UsageSnapshotStore.swift|DeepSeekCredentialStore.swift) continue ;;
  esac
  qa_shared_sources+=("$qa_source")
done
xcrun swiftc -parse-as-library -module-name WidgetQAContractCheck \
  -module-cache-path "$qa_output/contract-module-cache" \
  -o "$qa_output/check-cases" "${qa_shared_sources[@]}" \
  "$qa_source_dir/Common/WidgetQACase.swift" "$qa_source_dir/Tools/CheckCases.swift"
"$qa_output/check-cases" --manifest "$qa_output/fixtures/manifest.json" \
  --report "$qa_output/offline-model-check.json"
