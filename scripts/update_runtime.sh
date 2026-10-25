#!/bin/zsh
# Pause only this app's runtime. Sparkle owns app termination and replacement.
set -euo pipefail
umask 077
source "${0:A:h}/lib/install_common.sh"
bm_initialize
operation="${1:?Expected prepare, recover or complete}"
application="${2:?Expected the installed BeaverMeter.app path}"
case "$operation" in
  prepare) bm_require_preferred_official_app "$application" ;;
  recover|complete) bm_select_installed_app "$application" ;;
  *) print -u2 "Expected prepare, recover or complete."; exit 2 ;;
esac
application="$installed_app"
bm_lock_lifecycle
case "$operation" in
  recover) bm_recover_update_runtime "$application"; exit 0 ;;
  complete) bm_complete_update_runtime "$application"; exit 0 ;;
esac
target_build="${3:?Expected the target build number}"
[[ "$target_build" == <-> ]] || { print -u2 'The target build must be an integer.'; exit 2; }
[[ -d "$application" && -x "$application/Contents/Helpers/BeaverMeterCollector" ]]
bm_run codesign --verify --deep --strict "$application"
# The label is shared with source installs. Do not let launchd's bootout stop
# another copy's collector, even though direct helper signals are path-scoped.
if [[ -e "$agent_path" || -L "$agent_path" ]]; then
  agent_script="$(/usr/bin/plutil -extract ProgramArguments.1 raw -o - "$agent_path" 2>/dev/null || true)"
  if [[ "$agent_script" != "$application/Contents/Resources/collect_beaver_meter.sh" ]]; then
    print -u2 'Background refresh belongs to another BeaverMeter copy. Open that copy or reconfigure this installation before updating.'
    exit 1
  fi
fi
zmodload zsh/datetime
prepare_deadline=$((EPOCHREALTIME + 4.0))
current_uid="$(id -u)"

# ps supplies UID/name candidates; lsof verifies their kernel text-file paths.
# Repeat both checks before each signal to avoid targeting a recycled PID.
bm_target_helper_pids() {
  local listing line process_id process_uid executable text_files text_path
  listing="$(bm_run ps -ww -axo pid=,uid=,comm=)" || return 1
  while IFS= read -r line; do
    if [[ "$line" =~ '^[[:space:]]*([0-9]+)[[:space:]]+([0-9]+)[[:space:]]+(.+)$' ]]; then
      process_id="$match[1]"; process_uid="$match[2]"; executable="$match[3]"
      [[ "$process_uid" == "$current_uid" ]] || continue
      [[ "${executable:t}" == BeaverMeterCollector || "${executable:t}" == BeaverMeterWidgetExtension ]] || continue
      if ! text_files="$(bm_run lsof -a -p "$process_id" -d txt -Fn 2>/dev/null)"; then
        # A disappearing process is harmless; inability to inspect a live one is not.
        if bm_run kill -0 "$process_id" >/dev/null 2>&1; then
          print -u2 "Could not verify the executable of background process $process_id."
          return 1
        fi
        continue
      fi
      while IFS= read -r text_path; do
        [[ "$text_path" == n* ]] || continue
        text_path="${text_path#n}"
        text_path="${text_path:A}"
        if [[ "$text_path" == "$application/Contents/Helpers/BeaverMeterCollector" ||
              "$text_path" == "$application/Contents/PlugIns/BeaverMeterWidgetExtension.appex/Contents/MacOS/BeaverMeterWidgetExtension" ]]; then
          print -r -- "$process_id"
          break
        fi
      done <<< "$text_files"
    fi
  done <<< "$listing"
}

bm_signal_target_helpers() {
  local signal="$1" candidate current
  local candidates="$(bm_target_helper_pids)" || return 1
  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    current="$(bm_target_helper_pids)" || return 1
    if (( ${${(f)current}[(Ie)$candidate]} )); then
      if ! bm_run kill "-$signal" "$candidate"; then
        current="$(bm_target_helper_pids)" || return 1
        (( ! ${${(f)current}[(Ie)$candidate]} )) || return 1
      fi
    fi
  done <<< "$candidates"
}

state="$(bm_update_state_path)"
if [[ -d "$state" ]]; then
  bm_validate_update_state "$application"
  if [[ "$(/usr/bin/plutil -extract targetBuild raw -o - "$state/journal.plist")" == "$target_build" &&
        ! -e "$state/preparing" ]]; then
    # Repeated install requests must not replace the original recovery state.
    if ! bm_bootout_agent "$agent_label"; then bm_recover_update_runtime "$application" || true; exit 1; fi
    if ! helper_pids="$(bm_target_helper_pids)"; then bm_recover_update_runtime "$application" || true; exit 1; fi
    if [[ -n "$helper_pids" ]]; then
      print -u2 "Background helpers are still active. Recover and retry the update."
      bm_recover_update_runtime "$application" || true
      exit 1
    fi
    exit 0
  fi
  bm_recover_update_runtime "$application"
fi
mkdir -p "$config_dir" "$user_root/Library/LaunchAgents"
chmod 700 "$config_dir"
staging="$(mktemp -d "$config_dir/.update-runtime-staging.XXXXXX")"
journal_published=0
prepare_committed=0
cleanup() {
  local exit_code="$1"
  trap - ZERR EXIT INT TERM
  if (( journal_published && ! prepare_committed )); then
    if ! bm_recover_update_runtime "$application"; then exit_code=1; fi
  fi
  [[ -z "$staging" ]] || rm -rf "$staging"
  return "$exit_code"
}
trap 'cleanup $?' ZERR EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
bm_snapshot_agents "$staging" 0
bm_run plistbuddy -c 'Add :schemaVersion integer 1' "$staging/journal.plist"
bm_run plistbuddy -c "Add :appPath string $application" "$staging/journal.plist"
bm_run plistbuddy -c "Add :targetBuild string $target_build" "$staging/journal.plist"
chmod 600 "$staging/journal.plist"
touch "$staging/preparing"
mv "$staging" "$state"
staging=""
journal_published=1
bm_bootout_agent "$agent_label"
bm_signal_target_helpers TERM
grace_deadline=$((EPOCHREALTIME + 0.75))
while true; do
  helper_pids="$(bm_target_helper_pids)" || exit 1
  [[ -n "$helper_pids" ]] && (( EPOCHREALTIME < grace_deadline )) || break
  sleep 0.05
done
bm_signal_target_helpers KILL
while true; do
  helper_pids="$(bm_target_helper_pids)" || exit 1
  [[ -n "$helper_pids" ]] || break
  (( EPOCHREALTIME < prepare_deadline )) || { print -u2 'Could not stop BeaverMeter background helpers in time.'; exit 1; }
  sleep 0.05
done
# The collector uses the same fcntl lock for its entire normal refresh.
# Do not delete this lock: another process may still hold its inode.
snapshot_lock="$snapshot_path.lock"
[[ -e "$snapshot_lock" ]] || : > "$snapshot_lock"
chmod 600 "$snapshot_lock"
remaining=$((prepare_deadline - EPOCHREALTIME))
(( remaining > 0 )) || { print -u2 'Update preparation timed out.'; exit 1; }
if ! zsystem flock -t "$remaining" -i 0.05 -f snapshot_lock_fd "$snapshot_lock"; then
  print -u2 'Usage collection is still active. Wait for it to finish and retry the update.'
  exit 1
fi
rm -f "$state/preparing"
prepare_committed=1
print 'BeaverMeter background refresh is paused for installation.'
