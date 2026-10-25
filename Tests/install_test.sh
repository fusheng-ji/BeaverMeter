#!/bin/zsh
set -euo pipefail
unsetopt bgnice

project_dir="${0:A:h:h}"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/beavermeter-install-tests.XXXXXX")"
test_root="${test_root:A}"
lock_holder=""
cleanup() {
  local exit_code=$?
  [[ -z "$lock_holder" ]] || kill "$lock_holder" 2>/dev/null || true
  if (( exit_code )) && [[ -n "${case_root:-}" && -f "$case_root/output.log" ]]; then
    print -u2 "Installer output for failed test:"
    cat "$case_root/output.log" >&2
  fi
  rm -rf "$test_root"
  return "$exit_code"
}
trap cleanup EXIT
mock_dir="$test_root/commands"
mkdir -p "$mock_dir"
for command_name in xcodegen xcodebuild codesign plistbuddy launchctl pgrep pkill lsregister pluginkit killall open; do
  ln -s "$project_dir/Tests/Support/install_command_stub.sh" "$mock_dir/$command_name"
done

seed="$test_root/seed"
seed_data="$seed/Library/Application Support/BeaverMeter"
seed_app="$seed/Applications/BeaverMeter.app"
mkdir -p "$seed_data" "$seed_app/Contents/PlugIns/BeaverMeterWidgetExtension.appex" "$seed/Library/LaunchAgents"
/usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string com.test.beavermeter' "$seed_app/Contents/Info.plist" >/dev/null
print -r -- old > "$seed_app/version-marker"
print -r -- 'CODEX_ROOT=/custom/codex' 'CODEX_REMOTE_SSH_HOST=' 'CODEX_REMOTE_ROOT=/saved/codex' 'CODEX_REMOTE_PYTHON=/saved/python3' 'CURSOR_STATE_DB=/custom/cursor.db' > "$seed_data/config.env"
print -r -- original-test-credential > "$seed_data/deepseek-platform-token"
print -r -- '{"schemaVersion":5,"original":true}' > "$seed_data/beaver-meter-snapshot.json"
chmod 700 "$seed_data"
chmod 600 "$seed_data/"*
/usr/libexec/PlistBuddy -c 'Add :Label string io.github.beavermeter.refresh' "$seed/Library/LaunchAgents/io.github.beavermeter.refresh.plist" >/dev/null
/usr/libexec/PlistBuddy -c 'Add :StartInterval integer 600' "$seed/Library/LaunchAgents/io.github.beavermeter.refresh.plist"

prepare_case() {
  case_root="$test_root/$1"
  state="$case_root/state"
  task_user="$case_root/user"
  mkdir -p "$state" "$task_user"
  if [[ "${2:-existing}" == existing ]]; then
    /usr/bin/ditto "$seed" "$task_user"
    touch "$state/io.github.beavermeter.refresh.loaded" "$state/BeaverMeter.running"
  fi
  task_data="$task_user/Library/Application Support/BeaverMeter"
  task_app="$task_user/Applications/BeaverMeter.app"
  derived="$case_root/derived"
  # Disabled SSH asks six questions; extra blank lines also cover enabled SSH.
  printf '\ncom.test\n\n\n\n\n\n\n' > "$case_root/answers"
}

run_installer() {
  env -i PATH="$PATH" HOME="$HOME" USER=installer-test TMPDIR="$test_root/" \
    BEAVERMETER_USER_ROOT_OVERRIDE="$task_user" \
    BEAVERMETER_SYSTEM_COMMANDS="$mock_dir" \
    BEAVERMETER_DERIVED_DATA="$derived" \
    BM_TEST_STATE="$state" BM_TEST_PROJECT="$project_dir" BM_TEST_FAIL="${1:-}" \
    zsh "$project_dir/scripts/install.sh" < "$case_root/answers" > "$case_root/output.log" 2>&1
}

assert_original_installation() {
  diff -r "$seed_app" "$task_app"
  diff -r "$seed_data" "$task_data"
  diff -r "$seed/Library/LaunchAgents" "$task_user/Library/LaunchAgents"
  [[ ! -e "$task_user/Library/Logs/BeaverMeter" ]]
  [[ -f "$state/io.github.beavermeter.refresh.loaded" ]]
  [[ -f "$state/BeaverMeter.running" ]]
  [[ "$(stat -f '%Lp' "$task_data/deepseek-platform-token")" == 600 ]]
}

# Build/signing preflight failures must never touch the currently running app.
for failure in build preflight; do
  prepare_case "$failure"
  if run_installer "$failure"; then print -u2 "Expected $failure to fail"; exit 1; fi
  assert_original_installation
  if rg -q '^(launchctl|pkill|killall|lsregister|pluginkit|open) ' "$state/commands.log"; then
    print -u2 "A preflight failure mutated the running installation."
    exit 1
  fi
done

# Restore configuration, snapshots, caches and credentials after replacement,
# including a failure after the new LaunchAgent starts being installed.
for failure in collector verification bootstrap; do
  prepare_case "$failure"
  if run_installer "$failure"; then print -u2 "Expected $failure to fail"; exit 1; fi
  assert_original_installation
  rg -q '^pluginkit -a .*/Applications/BeaverMeter.app/Contents/PlugIns/' "$state/commands.log"
  [[ ! -e "$task_data/new-scan-cache.json" ]]
done

# A failed first installation removes only its new state; legacy data survives.
prepare_case first-failure fresh
legacy_data="$task_user/Library/Application Support/CodexWeek"
mkdir -p "$legacy_data"
print -r -- legacy-test-credential > "$legacy_data/deepseek-platform-token"
if run_installer collector; then print -u2 'Expected first installation to fail'; exit 1; fi
[[ ! -e "$task_app" && ! -e "$task_data" ]]
[[ "$(<"$legacy_data/deepseek-platform-token")" == legacy-test-credential ]]

# Upgrades preserve an explicit disabled host, saved paths and refresh interval.
prepare_case upgrade
run_installer
(
  source "$task_data/config.env"
  [[ -z "$CODEX_REMOTE_SSH_HOST" ]]
  [[ "$CODEX_REMOTE_ROOT" == /saved/codex && "$CODEX_REMOTE_PYTHON" == /saved/python3 ]]
  [[ "$BEAVERMETER_REFRESH_MINUTES" == 10 ]]
)
[[ "$(<"$task_data/deepseek-platform-token")" == original-test-credential ]]
[[ "$(<"$task_app/version-marker")" == new ]]
[[ -f "$state/io.github.beavermeter.refresh.loaded" && -f "$state/BeaverMeter.running" ]]
[[ -d "$derived/Build/Products/Release/BeaverMeter.app" ]]
# Cleanup must not unregister the build copy after the installed widget is live.
last_registration="$(rg '^(lsregister|pluginkit) ' "$state/commands.log" | tail -1)"
[[ "$last_registration" == 'lsregister -gc' ]]

prepare_case fresh fresh
run_installer
(
  source "$task_data/config.env"
  [[ -z "$CODEX_REMOTE_SSH_HOST" && -z "$CODEX_REMOTE_ROOT" && -z "$CODEX_REMOTE_PYTHON" ]]
  [[ -z "${CLAUDE_CONFIG_DIR:-}" && -z "${CLAUDE_KEYCHAIN_ACCESS:-}" ]]
)

prepare_case enabled
print -r -- 'CODEX_REMOTE_SSH_HOST=remote-box' 'CLAUDE_CONFIG_DIR=/custom/claude' 'CLAUDE_KEYCHAIN_ACCESS=0' >> "$task_data/config.env"
run_installer
(
  source "$task_data/config.env"
  [[ "$CODEX_REMOTE_SSH_HOST" == remote-box && "$CODEX_REMOTE_ROOT" == /saved/codex && "$CODEX_REMOTE_PYTHON" == /saved/python3 ]]
  [[ "$CLAUDE_CONFIG_DIR" == /custom/claude && "$CLAUDE_KEYCHAIN_ACCESS" == 0 ]]
)

# New source builds remain in the user's directory alongside an official DMG.
prepare_case source-with-system
system_app="$task_user/SystemApplications/BeaverMeter.app"
mkdir -p "${system_app:h}"
ditto "$seed_app" "$system_app"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier io.github.fushengji.beavermeter' "$system_app/Contents/Info.plist"
run_installer
[[ "$(<"$system_app/version-marker")" == old && "$(<"$task_app/version-marker")" == new ]]
! rg -Fq "lsregister -u $system_app" "$state/commands.log"

# A source migration retires legacy service only after the new one is loaded,
# and retains its app, data, logs and agent for recovery or manual removal.
prepare_case source-legacy
legacy_app="$task_user/Applications/CodexWeek.app"
legacy_data="$task_user/Library/Application Support/CodexWeek"
legacy_logs="$task_user/Library/Logs/CodexWeek"
legacy_agent="$task_user/Library/LaunchAgents/io.github.codexweek.refresh.plist"
mkdir -p "$legacy_app/Contents/PlugIns/CodexWeekWidgetExtension.appex" "$legacy_data" "$legacy_logs"
print -r -- old-app > "$legacy_app/marker"
print -r -- old-token > "$legacy_data/deepseek-platform-token"
print -r -- old-log > "$legacy_logs/refresh.log"
/usr/libexec/PlistBuddy -c 'Add :Label string io.github.codexweek.refresh' "$legacy_agent" >/dev/null
cp "$legacy_agent" "$case_root/original-legacy-agent"
touch "$state/io.github.codexweek.refresh.loaded" "$state/CodexWeek.running"
run_installer
[[ -d "$legacy_app" && "$(<"$legacy_data/deepseek-platform-token")" == old-token && "$(<"$legacy_logs/refresh.log")" == old-log ]]
cmp "$legacy_agent" "$case_root/original-legacy-agent"
[[ ! -f "$state/io.github.codexweek.refresh.loaded" && ! -f "$state/CodexWeek.running" ]]
new_bootstrap="$(rg -n '^launchctl bootstrap .*io.github.beavermeter.refresh.plist$' "$state/commands.log" | head -1 | cut -d: -f1)"
legacy_bootout="$(rg -n '^launchctl bootout .*io.github.codexweek.refresh$' "$state/commands.log" | head -1 | cut -d: -f1)"
(( new_bootstrap < legacy_bootout ))

# Source installation and manual maintenance cannot race runtime preparation.
prepare_case manual-locked
lock_path="$task_user/Library/Logs/.beavermeter-runtime-lifecycle.lock"
mkdir -p "${lock_path:h}"
: > "$lock_path"
(
  zmodload zsh/system
  zsystem flock -f fixture_lock "$lock_path"
  touch "$state/locked"
  sleep 10
) &
lock_holder=$!
for attempt in {1..100}; do [[ ! -f "$state/locked" ]] || break; sleep 0.01; done
for script in repair_widget uninstall; do
  if env -i PATH="$PATH" HOME="$HOME" BEAVERMETER_USER_ROOT_OVERRIDE="$task_user" \
    BEAVERMETER_SYSTEM_COMMANDS="$mock_dir" BM_TEST_STATE="$state" \
    zsh "$project_dir/scripts/$script.sh" > "$case_root/output.log" 2>&1; then
    print -u2 "Expected $script to respect the lifecycle lock"; exit 1
  fi
  [[ -d "$task_app" && -f "$state/io.github.beavermeter.refresh.loaded" && ! -e "$state/commands.log" ]]
done
if run_installer; then print -u2 'Expected source installation to respect the lifecycle lock'; exit 1; fi
assert_original_installation
if rg -q '^(launchctl|pkill|killall|lsregister|pluginkit|open) ' "$state/commands.log"; then
  print -u2 'A blocked source installation mutated the running app.'; exit 1
fi
kill "$lock_holder"
wait "$lock_holder" 2>/dev/null || true
lock_holder=""

# Rollback may replace the app's log directory, but never the shared lock inode.
prepare_case rollback-lock-inode
lock_path="$task_user/Library/Logs/.beavermeter-runtime-lifecycle.lock"
mkdir -p "${lock_path:h}"
: > "$lock_path"
original_inode="$(stat -f '%i' "$lock_path")"
if run_installer collector; then print -u2 'Expected collection failure and rollback'; exit 1; fi
assert_original_installation
[[ "$(stat -f '%i' "$lock_path")" == "$original_inode" ]]

# Canonical system directory is preferred for manual official maintenance.
prepare_case manual-system
system_app="$task_user/SystemApplications/BeaverMeter.app"
mkdir -p "${system_app:h}"
ditto "$seed_app" "$system_app"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier io.github.fushengji.beavermeter' "$system_app/Contents/Info.plist"

# Repair and uninstall use the same isolated lifecycle operations.
env -i PATH="$PATH" HOME="$HOME" BEAVERMETER_USER_ROOT_OVERRIDE="$task_user" \
  BEAVERMETER_SYSTEM_COMMANDS="$mock_dir" BM_TEST_STATE="$state" \
  zsh "$project_dir/scripts/repair_widget.sh" >/dev/null
[[ -f "$state/BeaverMeter.running" ]]
lock_path="$task_user/Library/Logs/.beavermeter-runtime-lifecycle.lock"
original_inode="$(stat -f '%i' "$lock_path")"
rg -Fq "open $system_app" "$state/commands.log"
! rg -Fq "open $task_app" "$state/commands.log"
env -i PATH="$PATH" HOME="$HOME" BEAVERMETER_USER_ROOT_OVERRIDE="$task_user" \
  BEAVERMETER_SYSTEM_COMMANDS="$mock_dir" BM_TEST_STATE="$state" \
  zsh "$project_dir/scripts/uninstall.sh" >/dev/null
[[ ! -d "$system_app" && -d "$task_app" && ! -d "$task_data" && ! -f "$state/BeaverMeter.running" ]]
[[ -d "$task_user/.Trash" ]]
[[ "$(stat -f '%i' "$lock_path")" == "$original_inode" ]]

print "BeaverMeter installation lifecycle tests passed."
