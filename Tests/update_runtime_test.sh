#!/bin/zsh
set -euo pipefail
unsetopt bgnice
umask 077
project_dir="${0:A:h:h}"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/beavermeter-update-tests.XXXXXX")"
test_root="${test_root:A}"
lock_holder=""
cleanup_tests() {
  local exit_code=$?
  [[ -z "$lock_holder" ]] || kill "$lock_holder" 2>/dev/null || true
  if (( exit_code )) && [[ -f "${case_root:-}/output.log" ]]; then cat "$case_root/output.log" >&2; fi
  rm -rf "$test_root"
  return "$exit_code"
}
trap cleanup_tests EXIT
mock_dir="$test_root/commands"
mkdir -p "$mock_dir"
for command_name in codesign plistbuddy launchctl lsregister pluginkit ps lsof kill; do
  ln -s "$project_dir/Tests/Support/install_command_stub.sh" "$mock_dir/$command_name"
done
zmodload zsh/datetime
current_uid="$(id -u)"
prepare_case() {
  case_root="$test_root/$1"
  task_user="$case_root/user"
  state="$case_root/state"
  task_app="$task_user/Applications/BeaverMeter.app"
  task_data="$task_user/Library/Application Support/BeaverMeter"
  journal_dir="$task_data/.update-runtime-state"
  agent="$task_user/Library/LaunchAgents/io.github.beavermeter.refresh.plist"
  mkdir -p "$state" "$task_app/Contents/Helpers" "$task_app/Contents/Resources" \
    "$task_app/Contents/PlugIns/BeaverMeterWidgetExtension.appex/Contents/MacOS" "$task_data"
  print '#!/bin/zsh' > "$task_app/Contents/Helpers/BeaverMeterCollector"
  chmod +x "$task_app/Contents/Helpers/BeaverMeterCollector"
  touch "$task_app/Contents/Resources/collect_beaver_meter.sh"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string io.github.fushengji.beavermeter' "$task_app/Contents/Info.plist" >/dev/null
  /usr/libexec/PlistBuddy -c 'Add :CFBundleVersion string 36' "$task_app/Contents/Info.plist"
  print -r -- local-credential > "$task_data/deepseek-platform-token"
  print -r -- 'CODEX_ROOT=/saved/codex' > "$task_data/config.env"
  print -r -- '{"schemaVersion":7,"original":true}' > "$task_data/beaver-meter-snapshot.json"
  run_script configure_runtime.sh "$task_app"
  cp "$agent" "$case_root/original-agent"
  # Keep unrelated apps, users, the main app and tools in the mocked process list.
  print -rl -- \
    "101 $current_uid $task_app/Contents/Helpers/BeaverMeterCollector" \
    "102 $current_uid $task_app/Contents/PlugIns/BeaverMeterWidgetExtension.appex/Contents/MacOS/BeaverMeterWidgetExtension" \
    "103 $current_uid $task_app/Contents/MacOS/BeaverMeter" \
    "104 $current_uid $case_root/development/BeaverMeter.app/Contents/Helpers/BeaverMeterCollector" \
    "105 $((current_uid + 1)) $task_app/Contents/Helpers/BeaverMeterCollector" \
    "106 $current_uid /usr/bin/ssh" \
    "107 $current_uid $task_app/Contents/Helpers/BeaverMeterCollector" > "$state/processes"
  print -r -- "$case_root/development/BeaverMeter.app/Contents/Helpers/BeaverMeterCollector" > "$state/107.executable"
}
run_script() {
  local script="$1"
  shift
  env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOME" \
    BEAVERMETER_USER_ROOT_OVERRIDE="$task_user" BEAVERMETER_SYSTEM_COMMANDS="$mock_dir" \
    BM_TEST_STATE="$state" BM_TEST_FAIL="${test_failure:-}" \
    /bin/zsh "$project_dir/scripts/$script" "$@" > "$case_root/output.log" 2>&1
}
assert_private_data() {
  [[ "$(<"$task_data/deepseek-platform-token")" == local-credential ]]
  [[ "$(<"$task_data/config.env")" == CODEX_ROOT=/saved/codex ]]
  [[ "$(<"$task_data/beaver-meter-snapshot.json")" == '{"schemaVersion":7,"original":true}' ]]
}
assert_other_processes() {
  for process_id in 103 104 105 106 107; do
    rg -q "^$process_id " "$state/processes"
    ! rg -q "^kill -[A-Z]+ $process_id$" "$state/commands.log"
  done
  ! rg -q '^(pkill|killall) ' "$state/commands.log"
}

prepare_case successful-prepare
touch "$state/101.ignore-term"
run_script update_runtime.sh prepare "$task_app" 37
[[ -d "$journal_dir" && ! -f "$state/io.github.beavermeter.refresh.loaded" ]]
[[ "$(stat -f '%Lp' "$journal_dir")" == 700 && "$(stat -f '%Lp' "$journal_dir/journal.plist")" == 600 ]]
cmp "$agent" "$case_root/original-agent"
cmp "$journal_dir/agent.plist" "$case_root/original-agent"
rg -q '^kill -TERM 101$' "$state/commands.log"
rg -q '^kill -KILL 101$' "$state/commands.log"
rg -q '^kill -TERM 102$' "$state/commands.log"
assert_other_processes
assert_private_data
run_script update_runtime.sh prepare "$task_app" 37
cmp "$journal_dir/agent.plist" "$case_root/original-agent"
if run_script update_runtime.sh complete "$task_app"; then print -u2 'An old build cannot complete an update'; exit 1; fi
[[ -d "$journal_dir" ]]
run_script update_runtime.sh recover "$task_app"
cmp "$agent" "$case_root/original-agent"
[[ ! -d "$journal_dir" && -f "$state/io.github.beavermeter.refresh.loaded" ]]
run_script update_runtime.sh recover "$task_app"
assert_private_data

prepare_case new-launch
run_script update_runtime.sh prepare "$task_app" 37
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 37' "$task_app/Contents/Info.plist"
run_script configure_runtime.sh "$task_app"
[[ ! -d "$journal_dir" && -f "$state/io.github.beavermeter.refresh.loaded" ]]
run_script update_runtime.sh complete "$task_app"
assert_private_data

prepare_case interrupted-install
run_script update_runtime.sh prepare "$task_app" 37
# Reopening the old bundle recovers an abandoned update before normal setup.
run_script configure_runtime.sh "$task_app"
[[ ! -d "$journal_dir" && -f "$state/io.github.beavermeter.refresh.loaded" ]]

# The sole official app can move between canonical Applications folders while
# its journal keeps the true original backup until recovery is complete.
prepare_case moved-interrupted-install
run_script update_runtime.sh prepare "$task_app" 37
old_app="$task_app"
task_app="$task_user/SystemApplications/BeaverMeter.app"
mkdir -p "${task_app:h}"
mv "$old_app" "$task_app"
test_failure=bootstrap-always
if run_script update_runtime.sh recover "$task_app"; then print -u2 'Expected moved recovery to retain its backup on failure'; exit 1; fi
cmp "$journal_dir/agent.plist" "$case_root/original-agent"
[[ "$(/usr/bin/plutil -extract appPath raw -o - "$journal_dir/journal.plist")" == "$old_app" ]]
test_failure=""
run_script configure_runtime.sh "$task_app"
[[ ! -d "$journal_dir" && -f "$state/io.github.beavermeter.refresh.loaded" ]]
[[ "$(/usr/bin/plutil -extract ProgramArguments.1 raw -o - "$agent")" == "$task_app/Contents/Resources/collect_beaver_meter.sh" ]]
assert_private_data

prepare_case moved-new-launch
run_script update_runtime.sh prepare "$task_app" 37
old_app="$task_app"
task_app="$task_user/SystemApplications/BeaverMeter.app"
mkdir -p "${task_app:h}"
mv "$old_app" "$task_app"
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 37' "$task_app/Contents/Info.plist"
run_script configure_runtime.sh "$task_app"
[[ ! -d "$journal_dir" && -f "$state/io.github.beavermeter.refresh.loaded" ]]
[[ "$(/usr/bin/plutil -extract ProgramArguments.1 raw -o - "$agent")" == "$task_app/Contents/Resources/collect_beaver_meter.sh" ]]

prepare_case second-copy-cannot-take-journal
run_script update_runtime.sh prepare "$task_app" 37
old_app="$task_app"
task_app="$task_user/SystemApplications/BeaverMeter.app"
mkdir -p "${task_app:h}"
ditto "$old_app" "$task_app"
if run_script configure_runtime.sh "$task_app"; then print -u2 'An existing second copy must not take another journal'; exit 1; fi
cmp "$journal_dir/agent.plist" "$case_root/original-agent"
[[ ! -f "$state/io.github.beavermeter.refresh.loaded" ]]
run_script update_runtime.sh recover "$old_app"
[[ ! -d "$journal_dir" && -f "$state/io.github.beavermeter.refresh.loaded" ]]

prepare_case unloaded-recovery
rm "$state/io.github.beavermeter.refresh.loaded"
run_script update_runtime.sh prepare "$task_app" 37
run_script update_runtime.sh recover "$task_app"
[[ ! -f "$state/io.github.beavermeter.refresh.loaded" && ! -d "$journal_dir" ]]
cmp "$agent" "$case_root/original-agent"

prepare_case absent-agent
rm "$state/io.github.beavermeter.refresh.loaded" "$agent"
run_script update_runtime.sh prepare "$task_app" 37
run_script update_runtime.sh recover "$task_app"
[[ ! -f "$agent" && ! -f "$state/io.github.beavermeter.refresh.loaded" && ! -d "$journal_dir" ]]

# A shared label can currently belong to a separate source-installed copy.
# Refuse before journaling or allowing launchd to stop that copy's collector.
prepare_case other-copy-agent
source_app="$task_app"
task_app="$task_user/SystemApplications/BeaverMeter.app"
mkdir -p "${task_app:h}"
ditto "$source_app" "$task_app"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.example.beavermeter' "$source_app/Contents/Info.plist"
# The current agent and processes still belong to the user's source copy.
cp "$agent" "$case_root/other-copy-agent"
: > "$state/commands.log"
if run_script update_runtime.sh prepare "$task_app" 37; then print -u2 'Expected another copy LaunchAgent to be refused'; exit 1; fi
[[ ! -d "$journal_dir" && -f "$state/io.github.beavermeter.refresh.loaded" ]]
cmp "$agent" "$case_root/other-copy-agent"
! rg -q '^launchctl bootout ' "$state/commands.log"
! rg -q '^kill -[A-Z]+ ' "$state/commands.log"
rg -q 'Background refresh belongs to another BeaverMeter copy' "$case_root/output.log"
assert_private_data

prepare_case malformed-agent
/usr/bin/plutil -remove ProgramArguments "$agent"
cp "$agent" "$case_root/malformed-agent"
: > "$state/commands.log"
if run_script update_runtime.sh prepare "$task_app" 37; then print -u2 'Expected an unidentifiable LaunchAgent to be refused'; exit 1; fi
[[ ! -d "$journal_dir" && -f "$state/io.github.beavermeter.refresh.loaded" ]]
cmp "$agent" "$case_root/malformed-agent"
! rg -q '^launchctl bootout ' "$state/commands.log"

prepare_case recovery-failure
run_script update_runtime.sh prepare "$task_app" 37
test_failure=bootstrap-always
if run_script update_runtime.sh recover "$task_app"; then print -u2 'Expected recovery failure'; exit 1; fi
cmp "$journal_dir/agent.plist" "$case_root/original-agent"
test_failure=""
run_script update_runtime.sh recover "$task_app"
[[ ! -d "$journal_dir" && -f "$state/io.github.beavermeter.refresh.loaded" ]]

for failure in ps lsof helpers-stuck bootout; do
  prepare_case "$failure"
  test_failure="$failure"
  started_at="$EPOCHREALTIME"
  if run_script update_runtime.sh prepare "$task_app" 37; then print -u2 "Expected $failure to fail"; exit 1; fi
  (( EPOCHREALTIME - started_at < 5.5 ))
  assert_private_data
  assert_other_processes
  test_failure=""
  run_script update_runtime.sh recover "$task_app"
  cmp "$agent" "$case_root/original-agent"
  [[ ! -d "$journal_dir" && -f "$state/io.github.beavermeter.refresh.loaded" ]]
done

# A lifecycle lock prevents two installations from changing agent state at once.
prepare_case concurrent
lock_path="$task_user/Library/Logs/.beavermeter-runtime-lifecycle.lock"
(
  zmodload zsh/system
  zsystem flock -f fixture_lock "$lock_path"
  touch "$state/locked"
  sleep 10
) &
lock_holder=$!
for attempt in {1..100}; do [[ ! -f "$state/locked" ]] || break; sleep 0.01; done
if run_script update_runtime.sh prepare "$task_app" 37; then print -u2 'Expected concurrent lifecycle to be refused'; exit 1; fi
[[ ! -d "$journal_dir" && -f "$state/io.github.beavermeter.refresh.loaded" ]]
kill "$lock_holder"
wait "$lock_holder" 2>/dev/null || true
lock_holder=""

# A collector lock is never removed or bypassed even with no helper listed.
prepare_case busy-snapshot-lock
: > "$state/processes"
snapshot_lock="$task_data/beaver-meter-snapshot.json.lock"
: > "$snapshot_lock"
original_inode="$(stat -f '%i' "$snapshot_lock")"
# Python lockf uses the same fcntl record lock as SnapshotWriter's Darwin.lockf.
python3 - "$snapshot_lock" "$state/locked" <<'PY' &
import fcntl
import pathlib
import sys
import time
with open(sys.argv[1], "r+") as lock:
    fcntl.lockf(lock, fcntl.LOCK_EX)
    pathlib.Path(sys.argv[2]).touch()
    time.sleep(10)
PY
lock_holder=$!
for attempt in {1..100}; do [[ ! -f "$state/locked" ]] || break; sleep 0.01; done
started_at="$EPOCHREALTIME"
if run_script update_runtime.sh prepare "$task_app" 37; then print -u2 'Expected active collector lock to refuse installation'; exit 1; fi
(( EPOCHREALTIME - started_at < 5.5 ))
[[ "$(stat -f '%i' "$snapshot_lock")" == "$original_inode" ]]
[[ ! -d "$journal_dir" && -f "$state/io.github.beavermeter.refresh.loaded" ]]
kill "$lock_holder"
wait "$lock_holder" 2>/dev/null || true
lock_holder=""
print 'Update runtime preparation and recovery tests passed in isolated fixtures.'
