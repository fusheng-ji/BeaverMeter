#!/bin/zsh
set -euo pipefail
setopt NO_BG_NICE

project_dir="${0:A:h:h}"
fixtures="$project_dir/Tests/Fixtures"
collector="${1:-${BEAVERMETER_COLLECTOR:-/private/tmp/beavermeter-derived/Build/Products/Debug/BeaverMeterCollector}}"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/cursor-codex-tests.XXXXXX")"

# The test suite never inherits real account paths or an SSH source. Every
# provider that could contact a service uses a fixture or an intentionally
# missing database/file in the individual case below.
unset CODEX_REMOTE_SSH_HOST CODEX_REMOTE_ROOT CODEX_REMOTE_PYTHON CODEX_REMOTE_RESPONSE_FIXTURE BEAVERMETER_SSH
unset DEEPSEEK_PLATFORM_TOKEN CODEX_HOME CODEX_TOKEN_FIXTURE CODEX_LEGACY_TOKEN_FIXTURE CURSOR_STATE_DB
unset CLAUDE_TOKEN_FIXTURE CLAUDE_TOKEN_CACHE_ROOT CLAUDE_KEYCHAIN_ACCESS CLAUDE_CLI_PATH
unset CODEX_HISTORY_FIXTURE CLAUDE_HISTORY_FIXTURE CODEX_RESET_CARDS_FIXTURE CLAUDE_RESET_CARDS_FIXTURE
# Tests never launch the real Claude Code CLI.
export CLAUDE_CLI_REFRESH=0
export CODEX_USAGE_FIXTURE="$fixtures/codex-pro-week.json"
export CLAUDE_USAGE_FIXTURE="$fixtures/claude-usage.json"
# A missing Claude home keeps every case away from the real ~/.claude logs.
export CLAUDE_CONFIG_DIR="$test_dir/missing-claude-home"
export DEEPSEEK_SUMMARY_FIXTURE="$fixtures/deepseek-summary.json"
export DEEPSEEK_USAGE_FIXTURE="$fixtures/deepseek-usage.json"

cleanup() {
  local failure_status=$?
  if (( failure_status )) && [[ -f "${live_snapshot:-}" ]]; then
    print -u2 "Collector test failed; final Codex snapshot:"
    jq '.codexTokens' "$live_snapshot" >&2 || true
  fi
  [[ -d "$test_dir" ]] && rm -rf "$test_dir"
}
trap cleanup EXIT

if [[ ! -x "$collector" ]]; then
  print -u2 "Collector executable not found: $collector"
  exit 1
fi

snapshot="$test_dir/snapshot.json"
CURSOR_EVENTS_FIXTURE="$fixtures/cursor-events-v3.json" \
CURSOR_SUMMARY_FIXTURE="$fixtures/cursor-summary-v3.json" \
CODEX_TOKEN_FIXTURE="$fixtures/codex-token-totals.json" \
CODEX_USAGE_FIXTURE="$fixtures/codex-pro-week.json" \
CLAUDE_TOKEN_FIXTURE="$fixtures/claude-token-totals.json" \
DEEPSEEK_SUMMARY_FIXTURE="$fixtures/deepseek-summary.json" \
DEEPSEEK_USAGE_FIXTURE="$fixtures/deepseek-usage.json" \
  "$collector" --output "$snapshot" >/dev/null

jq -e '
  .schemaVersion == 7 and
  .claudeTokens.status == "ready" and
  .claudeTokens.value.totalTokens == 2500 and
  .claudeTokens.value.cacheReadTokens == 1900 and
  .claudeQuota.status == "ready" and
  .claudeQuota.value.label == "Claude 5h" and
  .claudeQuota.value.remainingPercent == 62 and
  .claudeQuota.value.windowSeconds == 18000 and
  ([.claudeQuota.value.windows[].label] == ["Claude 5h", "Claude Week", "Claude Fable Week", "Claude Opus Week"]) and
  .codexTokens.status == "ready" and
  .codexTokens.value.totalTokens == 1000 and
  .codexTokens.value.inputTokens == 900 and
  .codexTokens.value.outputTokens == 100 and
  .cursorCosts.status == "ready" and
  .cursorCosts.value.todayCostUSD == 0.15 and
  (.cursorCosts.value.recentEvents | length) == 3 and
  .cursorCosts.value.recentEvents[0].costUSD == 0.03 and
  .cursorCosts.value.recentEvents[0].tokenCount == 1630 and
  .cursorQuota.value.used == 42.5 and
  .cursorQuota.value.limit == 100 and
  .cursorQuota.value.remaining == 57.5 and
  .codexQuota.value.remainingPercent == 63
  and .deepseekUsage.status == "ready"
  and .deepseekUsage.value.monthTokens == 1400000
  and .deepseekUsage.value.monthRequests == 16
  and .deepseekUsage.value.monthCosts[0].amount == 1.24
  and .deepseekUsage.value.balances[0].amount == 18.76
  and (.deepseekUsage.value | has("models") | not)
' "$snapshot" >/dev/null

[[ "$(stat -f '%Lp' "$snapshot")" == "600" ]]
if rg -q 'accessToken|access_token|WorkosCursorSessionToken|owningUser|owningTeam|conversation|userToken|Bearer|DEEPSEEK_PLATFORM_TOKEN' "$snapshot"; then
  print -u2 "Snapshot leaked a credential or private identifier."
  exit 1
fi

# A live Codex rollout keeps growing while a task is active. Verify that a
# second refresh consumes the newly appended token-count tail instead of
# returning the cached prefix forever.
today_path="$(date '+%Y/%m/%d')"
timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
codex_home="$test_dir/codex-home"
token_cache="$test_dir/codex-token-cache"
session_dir="$codex_home/sessions/$today_path"
session_file="$session_dir/rollout-live-growth.jsonl"
mkdir -p "$session_dir"
print -rl -- \
  "{\"type\":\"session_meta\",\"timestamp\":\"$timestamp\",\"payload\":{\"id\":\"live-growth\",\"session_id\":\"live-growth\",\"timestamp\":\"$timestamp\"}}" \
  "{\"type\":\"turn_context\",\"timestamp\":\"$timestamp\",\"payload\":{\"model\":\"openai/gpt-5.4\"}}" \
  "{\"type\":\"event_msg\",\"timestamp\":\"$timestamp\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":100,\"cached_input_tokens\":20,\"output_tokens\":10},\"total_token_usage\":{\"input_tokens\":100,\"cached_input_tokens\":20,\"output_tokens\":10}}}}" \
  > "$session_file"

CODEX_HOME="$codex_home" \
CODEX_TOKEN_CACHE_ROOT="$token_cache" \
CURSOR_EVENTS_FIXTURE="$fixtures/cursor-events-v3.json" \
CURSOR_SUMMARY_FIXTURE="$fixtures/cursor-summary-v3.json" \
CODEX_USAGE_FIXTURE="$fixtures/codex-pro-week.json" \
DEEPSEEK_SUMMARY_FIXTURE="$fixtures/deepseek-summary.json" \
DEEPSEEK_USAGE_FIXTURE="$fixtures/deepseek-usage.json" \
  "$collector" --output "$snapshot" >/dev/null
jq -e '.codexTokens.value.totalTokens == 110' "$snapshot" >/dev/null

print -r -- \
  "{\"type\":\"event_msg\",\"timestamp\":\"$timestamp\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":75,\"cached_input_tokens\":10,\"output_tokens\":15},\"total_token_usage\":{\"input_tokens\":175,\"cached_input_tokens\":30,\"output_tokens\":25}}}}" \
  >> "$session_file"

CODEX_HOME="$codex_home" \
CODEX_TOKEN_CACHE_ROOT="$token_cache" \
CURSOR_EVENTS_FIXTURE="$fixtures/cursor-events-v3.json" \
CURSOR_SUMMARY_FIXTURE="$fixtures/cursor-summary-v3.json" \
CODEX_USAGE_FIXTURE="$fixtures/codex-pro-week.json" \
DEEPSEEK_SUMMARY_FIXTURE="$fixtures/deepseek-summary.json" \
DEEPSEEK_USAGE_FIXTURE="$fixtures/deepseek-usage.json" \
  "$collector" --output "$snapshot" >/dev/null
jq -e '.codexTokens.value.totalTokens == 200' "$snapshot" >/dev/null

# Codex Desktop can keep appending to a rollout under the task's original date
# directory after midnight. Its new token_usage_record entries are authoritative
# per-response deltas and must be counted even when CodexBar cannot materialize
# the accompanying legacy token_count events into today's report.
cross_day_home="$test_dir/cross-day-codex-home"
cross_day_cache="$test_dir/cross-day-token-cache"
yesterday_path="$(date -v-1d '+%Y/%m/%d')"
cross_day_dir="$cross_day_home/sessions/$yesterday_path"
cross_day_file="$cross_day_dir/rollout-cross-day.jsonl"
mkdir -p "$cross_day_dir"
print -rl -- \
  "{\"type\":\"session_meta\",\"timestamp\":\"$timestamp\",\"payload\":{\"id\":\"cross-day\",\"session_id\":\"cross-day\",\"timestamp\":\"$timestamp\"}}" \
  "{\"type\":\"token_usage_record\",\"timestamp\":\"$timestamp\",\"payload\":{\"response_id\":\"response-one\",\"session_id\":\"cross-day\",\"usage\":{\"input_tokens\":100,\"cached_input_tokens\":20,\"output_tokens\":10,\"reasoning_output_tokens\":3,\"total_tokens\":110}}}" \
  > "$cross_day_file"

CODEX_HOME="$cross_day_home" \
CODEX_TOKEN_CACHE_ROOT="$cross_day_cache" \
CURSOR_EVENTS_FIXTURE="$fixtures/cursor-events-v3.json" \
CURSOR_SUMMARY_FIXTURE="$fixtures/cursor-summary-v3.json" \
CODEX_USAGE_FIXTURE="$fixtures/codex-pro-week.json" \
DEEPSEEK_SUMMARY_FIXTURE="$fixtures/deepseek-summary.json" \
DEEPSEEK_USAGE_FIXTURE="$fixtures/deepseek-usage.json" \
  "$collector" --output "$snapshot" >/dev/null
jq -e '
  .codexTokens.status == "ready" and
  .codexTokens.value.totalTokens == 110 and
  .codexTokens.value.inputTokens == 100 and
  .codexTokens.value.cachedInputTokens == 20 and
  .codexTokens.value.outputTokens == 10 and
  .codexTokens.value.reasoningTokens == 3 and
  .codexTokens.value.sessionCount == 1
' "$snapshot" >/dev/null

print -r -- \
  "{\"type\":\"token_usage_record\",\"timestamp\":\"$timestamp\",\"payload\":{\"response_id\":\"response-two\",\"session_id\":\"cross-day\",\"usage\":{\"input_tokens\":75,\"cached_input_tokens\":10,\"output_tokens\":15,\"reasoning_output_tokens\":2,\"total_tokens\":90}}}" \
  >> "$cross_day_file"

CODEX_HOME="$cross_day_home" \
CODEX_TOKEN_CACHE_ROOT="$cross_day_cache" \
CURSOR_EVENTS_FIXTURE="$fixtures/cursor-events-v3.json" \
CURSOR_SUMMARY_FIXTURE="$fixtures/cursor-summary-v3.json" \
CODEX_USAGE_FIXTURE="$fixtures/codex-pro-week.json" \
DEEPSEEK_SUMMARY_FIXTURE="$fixtures/deepseek-summary.json" \
DEEPSEEK_USAGE_FIXTURE="$fixtures/deepseek-usage.json" \
  "$collector" --output "$snapshot" >/dev/null
jq -e '
  .codexTokens.value.totalTokens == 200 and
  .codexTokens.value.inputTokens == 175 and
  .codexTokens.value.cachedInputTokens == 30 and
  .codexTokens.value.outputTokens == 25 and
  .codexTokens.value.reasoningTokens == 5
' "$snapshot" >/dev/null

# The live App refresh updates only Codex. It must preserve the other provider
# payloads byte-for-byte and avoid rewriting the snapshot when no usage changed.
live_home="$test_dir/live-only-codex-home"
live_dir="$live_home/sessions/$(date -v-9d '+%Y/%m/%d')"
live_file="$live_dir/rollout-live-only.jsonl"
live_snapshot="$test_dir/live-only-snapshot.json"
live_cache="$test_dir/beaver-meter-codex-scan-v2.json"
mkdir -p "$live_dir"

CURSOR_EVENTS_FIXTURE="$fixtures/cursor-events-v3.json" \
CURSOR_SUMMARY_FIXTURE="$fixtures/cursor-summary-v3.json" \
CODEX_TOKEN_FIXTURE="$fixtures/codex-token-totals.json" \
CODEX_USAGE_FIXTURE="$fixtures/codex-pro-week.json" \
DEEPSEEK_SUMMARY_FIXTURE="$fixtures/deepseek-summary.json" \
DEEPSEEK_USAGE_FIXTURE="$fixtures/deepseek-usage.json" \
  "$collector" --output "$live_snapshot" >/dev/null
jq '
  .codexTokens.value = {
    totalTokens: 0,
    inputTokens: 0,
    cachedInputTokens: 0,
    outputTokens: 0,
    reasoningTokens: 0,
    sessionCount: 0
  }
' "$live_snapshot" > "$test_dir/live-zero-snapshot.json"
mv "$test_dir/live-zero-snapshot.json" "$live_snapshot"
jq '{cursorCosts,cursorQuota,codexQuota,claudeQuota,deepseekUsage}' "$live_snapshot" > "$test_dir/providers-before.json"

print -r -- \
  "{\"type\":\"token_usage_record\",\"timestamp\":\"$timestamp\",\"payload\":{\"response_id\":\"private-response-one\",\"session_id\":\"private-session\",\"usage\":{\"input_tokens\":100,\"cached_input_tokens\":20,\"output_tokens\":10,\"reasoning_output_tokens\":3,\"total_tokens\":110}}}" \
  > "$live_file"
CODEX_HOME="$live_home" "$collector" --codex-only --output "$live_snapshot" >/dev/null
jq -e '.codexTokens.value.totalTokens == 110 and .codexTokens.value.sessionCount == 1' "$live_snapshot" >/dev/null
jq '{cursorCosts,cursorQuota,codexQuota,claudeQuota,deepseekUsage}' "$live_snapshot" > "$test_dir/providers-after.json"
cmp "$test_dir/providers-before.json" "$test_dir/providers-after.json"
[[ "$(stat -f '%Lp' "$live_cache")" == "600" ]]
if rg -q 'private-response|private-session|rollout-live-only|codex-home' "$live_cache"; then
  print -u2 "Codex scan cache leaked an unhashed private identifier."
  exit 1
fi

snapshot_checksum="$(shasum -a 256 "$live_snapshot" | cut -d' ' -f1)"
CODEX_HOME="$live_home" "$collector" --codex-only --output "$live_snapshot" >/dev/null
[[ "$(shasum -a 256 "$live_snapshot" | cut -d' ' -f1)" == "$snapshot_checksum" ]]

# Repeated response IDs are ignored even if the appended copy reports different totals.
print -r -- \
  "{\"type\":\"token_usage_record\",\"timestamp\":\"$timestamp\",\"payload\":{\"response_id\":\"private-response-one\",\"session_id\":\"private-session\",\"usage\":{\"input_tokens\":900,\"cached_input_tokens\":800,\"output_tokens\":90,\"reasoning_output_tokens\":30,\"total_tokens\":990}}}" \
  >> "$live_file"
CODEX_HOME="$live_home" "$collector" --codex-only --output "$live_snapshot" >/dev/null
jq -e '.codexTokens.value.totalTokens == 110' "$live_snapshot" >/dev/null

print -r -- \
  "{\"type\":\"token_usage_record\",\"timestamp\":\"$timestamp\",\"payload\":{\"response_id\":\"private-response-two\",\"session_id\":\"private-session\",\"usage\":{\"input_tokens\":75,\"cached_input_tokens\":10,\"output_tokens\":15,\"reasoning_output_tokens\":2,\"total_tokens\":90}}}" \
  >> "$live_file"
CODEX_HOME="$live_home" "$collector" --codex-only --output "$live_snapshot" >/dev/null
jq -e '.codexTokens.value.totalTokens == 200' "$live_snapshot" >/dev/null

# The bundled shell wrapper forwards Codex-only mode and the configured root.
print -r -- \
  "{\"type\":\"token_usage_record\",\"timestamp\":\"$timestamp\",\"payload\":{\"response_id\":\"through-wrapper\",\"session_id\":\"private-session\",\"usage\":{\"input_tokens\":8,\"cached_input_tokens\":0,\"output_tokens\":2,\"reasoning_output_tokens\":0,\"total_tokens\":10}}}" \
  >> "$live_file"
BEAVER_METER_CONFIG=/dev/null \
BEAVERMETER_COLLECTOR="$collector" \
CODEX_ROOT="$live_home" \
  zsh "$project_dir/scripts/collect_beaver_meter.sh" --codex-only --output "$live_snapshot" >/dev/null
jq -e '.codexTokens.value.totalTokens == 210' "$live_snapshot" >/dev/null
[[ "$(stat -f '%Lp' "$live_snapshot.lock")" == "600" ]]

# Optional remote records are merged with local records by response hash. The
# remote protocol contains only hashed identifiers and numeric usage fields.
remote_home="$test_dir/remote-merge-home"
remote_dir="$remote_home/archived_sessions/old-task"
remote_local_file="$remote_dir/rollout-local.jsonl"
remote_case_dir="$test_dir/remote-case"
remote_snapshot="$remote_case_dir/snapshot.json"
remote_fixture="$remote_case_dir/response.json"
# This case isolates the remote protocol from CodexBar's incomplete history
# indexing of its synthetic record-only local rollout.
legacy_zero_fixture="$test_dir/legacy-zero.json"
print -r -- '{"totalTokens":0,"inputTokens":0,"cachedInputTokens":0,"outputTokens":0,"reasoningTokens":0,"sessionCount":0}' > "$legacy_zero_fixture"
export CODEX_LEGACY_TOKEN_FIXTURE="$legacy_zero_fixture"
mkdir -p "$remote_dir" "$remote_case_dir"
shared_hash="$(printf %s 'shared-response' | shasum -a 256 | cut -d' ' -f1)"
shared_session_hash="$(printf %s 'shared-session' | shasum -a 256 | cut -d' ' -f1)"
unique_hash="$(printf %s 'remote-unique' | shasum -a 256 | cut -d' ' -f1)"
unique_session_hash="$(printf %s 'remote-session' | shasum -a 256 | cut -d' ' -f1)"
epoch_now="$(date '+%s')"
print -r -- \
  "{\"type\":\"token_usage_record\",\"timestamp\":\"$timestamp\",\"payload\":{\"response_id\":\"shared-response\",\"session_id\":\"shared-session\",\"usage\":{\"input_tokens\":100,\"cached_input_tokens\":20,\"output_tokens\":10,\"reasoning_output_tokens\":3}}}" \
  > "$remote_local_file"
cat > "$remote_fixture" <<EOF
{"complete":true,"failedFiles":[],"activeFiles":["remote-file"],"files":{"remote-file":{"offset":500,"reset":false,"records":[{"responseHash":"$shared_hash","sessionHash":"$shared_session_hash","timestamp":$epoch_now,"inputTokens":900,"cachedInputTokens":800,"outputTokens":90,"reasoningTokens":30},{"responseHash":"$unique_hash","sessionHash":"$unique_session_hash","timestamp":$epoch_now,"inputTokens":200,"cachedInputTokens":50,"outputTokens":20,"reasoningTokens":4}]}}}
EOF
CODEX_HOME="$remote_home" \
CODEX_REMOTE_SSH_HOST="fixture-host" \
CODEX_REMOTE_ROOT="/fixture/codex" \
CODEX_REMOTE_PYTHON="/fixture/python3" \
CODEX_REMOTE_RESPONSE_FIXTURE="$remote_fixture" \
  "$collector" --codex-only --output "$remote_snapshot" >/dev/null
jq -e '
  .codexTokens.status == "ready" and
  .codexTokens.value.totalTokens == 330 and
  .codexTokens.value.inputTokens == 300 and
  .codexTokens.value.outputTokens == 30 and
  .codexTokens.value.sessionCount == 2
' "$remote_snapshot" >/dev/null
remote_cache="$remote_case_dir/codex-history-remote-v3.json"
[[ "$(stat -f '%Lp' "$remote_cache")" == "600" ]]
if rg -q 'shared-response|shared-session|remote-unique|remote-session|fixture/codex' "$remote_cache"; then
  print -u2 "Remote Codex cache leaked an unhashed identifier."
  exit 1
fi

# A failed remote refresh retains the current-day remote cache and marks the
# otherwise fresh local total as incomplete. A subsequent success clears it.
CODEX_HOME="$remote_home" \
CODEX_REMOTE_SSH_HOST="fixture-host" \
CODEX_REMOTE_ROOT="/fixture/codex" \
CODEX_REMOTE_PYTHON="/fixture/python3" \
CODEX_REMOTE_RESPONSE_FIXTURE="$test_dir/missing-remote-response.json" \
  "$collector" --codex-only --output "$remote_snapshot" >/dev/null
jq -e '
  .codexTokens.status == "stale" and
  .codexTokens.value.totalTokens == 330 and
  (.codexTokens.message | contains("last remote reading"))
' "$remote_snapshot" >/dev/null
print -r -- '{"complete":true,"failedFiles":[],"activeFiles":["remote-file"],"files":{}}' > "$remote_fixture"
CODEX_HOME="$remote_home" \
CODEX_REMOTE_SSH_HOST="fixture-host" \
CODEX_REMOTE_ROOT="/fixture/codex" \
CODEX_REMOTE_PYTHON="/fixture/python3" \
CODEX_REMOTE_RESPONSE_FIXTURE="$remote_fixture" \
  "$collector" --codex-only --output "$remote_snapshot" >/dev/null
jq -e '.codexTokens.status == "ready" and .codexTokens.value.totalTokens == 330' "$remote_snapshot" >/dev/null
unset CODEX_LEGACY_TOKEN_FIXTURE

# A truncated rollout and a corrupt cache both fall back to a full rescan
# without regressing an already measured same-day total.
print -r -- \
  "{\"type\":\"token_usage_record\",\"timestamp\":\"$timestamp\",\"payload\":{\"response_id\":\"replacement\",\"session_id\":\"replacement-session\",\"usage\":{\"input_tokens\":40,\"cached_input_tokens\":5,\"output_tokens\":10,\"reasoning_output_tokens\":1,\"total_tokens\":50}}}" \
  > "$live_file"
CODEX_HOME="$live_home" "$collector" --codex-only --output "$live_snapshot" >/dev/null
jq -e '.codexTokens.value.totalTokens == 210' "$live_snapshot" >/dev/null
print -r -- '{not-valid-json' > "$live_cache"
print -r -- \
  "{\"type\":\"token_usage_record\",\"timestamp\":\"$timestamp\",\"payload\":{\"response_id\":\"after-corruption\",\"session_id\":\"replacement-session\",\"usage\":{\"input_tokens\":8,\"cached_input_tokens\":0,\"output_tokens\":2,\"reasoning_output_tokens\":0,\"total_tokens\":10}}}" \
  >> "$live_file"
CODEX_HOME="$live_home" "$collector" --codex-only --output "$live_snapshot" >/dev/null
jq -e '.codexTokens.value.totalTokens == 210' "$live_snapshot" >/dev/null

# Full and Codex-only processes share the snapshot lock, so concurrent writes
# always leave a valid schema and never erase the other provider values.
for index in 1 2 3; do
  print -r -- \
    "{\"type\":\"token_usage_record\",\"timestamp\":\"$timestamp\",\"payload\":{\"response_id\":\"concurrent-$index\",\"session_id\":\"replacement-session\",\"usage\":{\"input_tokens\":1,\"cached_input_tokens\":0,\"output_tokens\":1,\"reasoning_output_tokens\":0,\"total_tokens\":2}}}" \
    >> "$live_file"
  CODEX_HOME="$live_home" "$collector" --codex-only --output "$live_snapshot" >/dev/null &
  codex_pid=$!
  CURSOR_EVENTS_FIXTURE="$fixtures/cursor-events-v3.json" \
  CURSOR_SUMMARY_FIXTURE="$fixtures/cursor-summary-v3.json" \
  CODEX_TOKEN_FIXTURE="$fixtures/codex-token-totals.json" \
  CODEX_USAGE_FIXTURE="$fixtures/codex-pro-week.json" \
  DEEPSEEK_SUMMARY_FIXTURE="$fixtures/deepseek-summary.json" \
  DEEPSEEK_USAGE_FIXTURE="$fixtures/deepseek-usage.json" \
    "$collector" --output "$live_snapshot" >/dev/null &
  full_pid=$!
  wait "$codex_pid" "$full_pid"
  jq -e '
    .schemaVersion == 7 and
    .cursorCosts.status == "ready" and
    .cursorQuota.status == "ready" and
    .codexQuota.status == "ready" and
    .deepseekUsage.status == "ready"
  ' "$live_snapshot" >/dev/null
done

# A new local day with no completed responses clears yesterday's total.
empty_home="$test_dir/empty-next-day-home"
mkdir -p "$empty_home/sessions"
jq '.dayStart = "2000-01-01T00:00:00Z"' "$live_cache" > "$test_dir/old-day-cache.json"
mv "$test_dir/old-day-cache.json" "$live_cache"
jq '
  .generatedAt = "2000-01-01T00:00:00Z" |
  .codexTokens.measuredAt = "2000-01-01T00:00:00Z" |
  .codexTokens.lastAttemptAt = "2000-01-01T00:00:00Z"
' "$live_snapshot" > "$test_dir/old-day-snapshot.json"
mv "$test_dir/old-day-snapshot.json" "$live_snapshot"
CODEX_HOME="$empty_home" "$collector" --codex-only --output "$live_snapshot" >/dev/null
jq -e '.codexTokens.value.totalTokens == 0 and .codexTokens.value.sessionCount == 0' "$live_snapshot" >/dev/null

CURSOR_STATE_DB="$test_dir/missing-cursor.vscdb" \
CODEX_TOKEN_FIXTURE="$fixtures/codex-token-totals.json" \
CODEX_USAGE_FIXTURE="$fixtures/codex-pro-week.json" \
DEEPSEEK_USAGE_FIXTURE="$test_dir/missing-deepseek-usage.json" \
  "$collector" --output "$snapshot" >/dev/null

jq -e '
  .codexTokens.status == "ready" and
  .codexQuota.status == "ready" and
  .cursorCosts.status == "stale" and
  .cursorCosts.source == "cache" and
  .cursorCosts.value.todayCostUSD == 0.15 and
  .cursorQuota.status == "stale"
  and .deepseekUsage.status == "stale"
  and .deepseekUsage.source == "cache"
  and .deepseekUsage.value.monthTokens == 1400000
' "$snapshot" >/dev/null

CURSOR_STATE_DB="$test_dir/missing-cursor.vscdb" \
CODEX_TOKEN_FIXTURE="$fixtures/codex-token-totals.json" \
CODEX_USAGE_FIXTURE="$fixtures/codex-pro-week.json" \
DEEPSEEK_SUMMARY_FIXTURE="$fixtures/deepseek-summary.json" \
DEEPSEEK_USAGE_FIXTURE="$fixtures/deepseek-usage-invalid.json" \
  "$collector" --output "$snapshot" >/dev/null

jq -e '
  .codexTokens.status == "ready" and
  .codexQuota.status == "ready" and
  .deepseekUsage.status == "stale" and
  .deepseekUsage.source == "cache" and
  .deepseekUsage.value.monthTokens == 1400000 and
  (.deepseekUsage.message | contains("changed format"))
' "$snapshot" >/dev/null

# Claude transcripts are scanned by CodexBarCore on the local-token refresh.
# Streamed chunks of one message are counted once, cache traffic is part of
# the total, and a home without transcripts reports no data instead of zero.
claude_home="$test_dir/claude-home"
claude_snapshot="$test_dir/claude-snapshot.json"
claude_file="$claude_home/projects/-private-project/private-session.jsonl"
mkdir -p "${claude_file:h}" "$test_dir/claude-codex-home/sessions"
print -rl -- \
  "{\"type\":\"assistant\",\"timestamp\":\"$timestamp\",\"requestId\":\"req_one\",\"sessionId\":\"private-session\",\"message\":{\"id\":\"msg_one\",\"model\":\"claude-sonnet-4-5-20250929\",\"stop_reason\":null,\"usage\":{\"input_tokens\":10,\"cache_creation_input_tokens\":20,\"cache_read_input_tokens\":300,\"output_tokens\":2}}}" \
  "{\"type\":\"assistant\",\"timestamp\":\"$timestamp\",\"requestId\":\"req_one\",\"sessionId\":\"private-session\",\"message\":{\"id\":\"msg_one\",\"model\":\"claude-sonnet-4-5-20250929\",\"stop_reason\":\"end_turn\",\"usage\":{\"input_tokens\":10,\"cache_creation_input_tokens\":20,\"cache_read_input_tokens\":300,\"output_tokens\":5}}}" \
  "{\"type\":\"assistant\",\"timestamp\":\"$timestamp\",\"requestId\":\"req_two\",\"sessionId\":\"private-session\",\"message\":{\"id\":\"msg_two\",\"model\":\"claude-sonnet-4-5-20250929\",\"stop_reason\":\"end_turn\",\"usage\":{\"input_tokens\":1,\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":100,\"output_tokens\":4}}}" \
  > "$claude_file"
CLAUDE_CONFIG_DIR="$claude_home" \
CODEX_HOME="$test_dir/claude-codex-home" \
  "$collector" --local-tokens --output "$claude_snapshot" >/dev/null
jq -e '
  .schemaVersion == 7 and
  .claudeTokens.status == "ready" and
  .claudeTokens.value.totalTokens == 440 and
  .claudeTokens.value.inputTokens == 11 and
  .claudeTokens.value.cacheCreationTokens == 20 and
  .claudeTokens.value.cacheReadTokens == 400 and
  .claudeTokens.value.outputTokens == 9 and
  .claudeTokens.value.costUSD > 0
' "$claude_snapshot" >/dev/null
if rg -q 'private-session|private-project|msg_one|req_one' "$claude_snapshot"; then
  print -u2 "Snapshot leaked a Claude transcript identifier."
  exit 1
fi
CODEX_HOME="$test_dir/claude-codex-home" "$collector" --local-tokens --output "$claude_snapshot" >/dev/null
jq -e '.claudeTokens.status == "unavailable" and .claudeTokens.value == null' "$claude_snapshot" >/dev/null

# Services switched off in the App are not contacted and keep their values:
# the missing Cursor database and DeepSeek fixture would otherwise mark them stale.
hidden_dir="$test_dir/hidden-services"
mkdir -p "$hidden_dir"
cp "$snapshot" "$hidden_dir/snapshot.json"
print -r -- '{"visibility":{"cursor":"hidden","deepseek":"hidden"}}' > "$hidden_dir/beaver-meter-settings.json"
jq '{cursorCosts,cursorQuota,deepseekUsage}' "$hidden_dir/snapshot.json" > "$hidden_dir/before.json"
CURSOR_STATE_DB="$test_dir/missing-cursor.vscdb" \
CODEX_TOKEN_FIXTURE="$fixtures/codex-token-totals.json" \
DEEPSEEK_USAGE_FIXTURE="$test_dir/missing-deepseek-usage.json" \
  "$collector" --output "$hidden_dir/snapshot.json" >/dev/null
jq '{cursorCosts,cursorQuota,deepseekUsage}' "$hidden_dir/snapshot.json" > "$hidden_dir/after.json"
cmp "$hidden_dir/before.json" "$hidden_dir/after.json"
jq -e '.codexTokens.status == "ready" and .claudeQuota.status == "ready"' "$hidden_dir/snapshot.json" >/dev/null

# Full monitoring refresh, independent reset-card states, and no account requests
# in the frequent local-only refresh. Fixtures cannot fall through to live APIs.
monitor_dir="$test_dir/monitoring"
monitor_home="$monitor_dir/default"
monitor_other="$monitor_dir/work"
mkdir -p "$monitor_home/sessions" "$monitor_other/sessions"
print -r -- '{"tokens":{"access_token":"demo-access","refresh_token":"demo-refresh","account_id":"workspace-a"}}' > "$monitor_home/auth.json"
print -r -- '{"tokens":{"access_token":"demo-access-2","refresh_token":"demo-refresh-2","account_id":"workspace-b"}}' > "$monitor_other/auth.json"
print -r -- "{\"version\":1,\"providers\":[{\"id\":\"codex\",\"codexProfileHomePaths\":[\"$monitor_other\",\"$monitor_other\"]}]}" > "$monitor_dir/beaver-meter-accounts.json"
print -r -- '{"availableCount":2,"observedAt":"2026-10-01T00:00:00Z","batches":[]}' > "$monitor_dir/codex-cards.json"
print -r -- '{"cedar_ember":{"eligible":true,"grants":[{"id":"private-grant","resets_left":1,"ends_at":"2099-10-22T00:00:00Z"}]}}' > "$monitor_dir/claude-cards.json"
CODEX_HOME="$monitor_home" CODEX_TOKEN_FIXTURE="$fixtures/codex-token-totals.json" \
CODEX_RESET_CARDS_FIXTURE="$monitor_dir/codex-cards.json" CLAUDE_RESET_CARDS_FIXTURE="$monitor_dir/claude-cards.json" \
  "$collector" --output "$monitor_dir/snapshot.json" >/dev/null
jq -e '
  .schemaVersion == 7 and (.codexAccounts.value | length) == 2 and
  .codexAccounts.value[0].resetCards.value.availableCount == 2 and
  .codexAccounts.value[1].quota.status == "ready" and
  .claudeResetCards.value.availableCount == 1
' "$monitor_dir/snapshot.json" >/dev/null
if rg -q 'demo-access|demo-refresh|private-grant' "$monitor_dir/snapshot.json"; then
  print -u2 "Monitoring snapshot leaked credentials or a raw grant identifier."
  exit 1
fi
jq '{codexAccounts,claudeResetCards,codexQuota,claudeQuota}' "$monitor_dir/snapshot.json" > "$monitor_dir/before.json"
CODEX_HOME="$monitor_home" CODEX_TOKEN_FIXTURE="$fixtures/codex-token-totals.json" \
CODEX_USAGE_FIXTURE="$test_dir/missing-quota.json" CODEX_RESET_CARDS_FIXTURE="$test_dir/missing-cards.json" \
CLAUDE_USAGE_FIXTURE="$test_dir/missing-quota.json" CLAUDE_RESET_CARDS_FIXTURE="$test_dir/missing-cards.json" \
  "$collector" --local-tokens --output "$monitor_dir/snapshot.json" >/dev/null
jq '{codexAccounts,claudeResetCards,codexQuota,claudeQuota}' "$monitor_dir/snapshot.json" > "$monitor_dir/after.json"
cmp "$monitor_dir/before.json" "$monitor_dir/after.json"

# Disabled services preserve monitoring values too.
print -r -- '{"visibility":{"codex":"hidden","claude":"hidden","cursor":"hidden","deepseek":"hidden"}}' > "$monitor_dir/beaver-meter-settings.json"
CODEX_HOME="$monitor_home" CODEX_USAGE_FIXTURE="$test_dir/missing-quota.json" \
CLAUDE_USAGE_FIXTURE="$test_dir/missing-quota.json" \
  "$collector" --output "$monitor_dir/snapshot.json" >/dev/null
jq '{codexAccounts,claudeResetCards,codexQuota,claudeQuota}' "$monitor_dir/snapshot.json" > "$monitor_dir/after.json"
cmp "$monitor_dir/before.json" "$monitor_dir/after.json"

# A single SSH range request supplies both the seven-day and original daily readings.
ssh_dir="$test_dir/single-ssh"
mkdir -p "$ssh_dir/home/sessions"
print -r -- '{"complete":true,"failedFiles":[],"activeFiles":[],"files":{}}' > "$ssh_dir/response.json"
cat > "$ssh_dir/fake-ssh" <<'EOF'
#!/bin/sh
cat >/dev/null
printf 'request\n' >> "$BEAVERMETER_TEST_SSH_CALLS"
cat "$BEAVERMETER_TEST_REMOTE_FIXTURE"
EOF
chmod +x "$ssh_dir/fake-ssh"
CODEX_HOME="$ssh_dir/home" CODEX_REMOTE_SSH_HOST="fixture-host" \
CODEX_REMOTE_ROOT="/fixture" CODEX_REMOTE_PYTHON="/python" \
BEAVERMETER_SSH="$ssh_dir/fake-ssh" BEAVERMETER_REMOTE_SCRIPT="$project_dir/scripts/remote_codex_usage.py" \
BEAVERMETER_TEST_SSH_CALLS="$ssh_dir/calls" BEAVERMETER_TEST_REMOTE_FIXTURE="$ssh_dir/response.json" \
  "$collector" --local-tokens --output "$ssh_dir/snapshot.json" >/dev/null
[[ "$(wc -l < "$ssh_dir/calls" | tr -d ' ')" == "1" ]]
jq -e '(.codexHistory.value.days | length) == 7 and .codexTokens.value.totalTokens == 0' "$ssh_dir/snapshot.json" >/dev/null

print "Collector fixture tests passed."
