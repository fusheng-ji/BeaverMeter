#!/bin/zsh
# Configure a canonical prebuilt app without developer tools.
set -euo pipefail
umask 077
script_dir="${0:A:h}"
source "$script_dir/lib/install_common.sh"
bm_initialize
bm_require_preferred_official_app "${1:?Expected the installed BeaverMeter.app path}"
[[ -x "$installed_app/Contents/Helpers/BeaverMeterCollector" ]]
[[ -f "$installed_app/Contents/Resources/collect_beaver_meter.sh" ]]
bm_run codesign --verify --deep --strict "$installed_app"
mkdir -p "$config_dir" "$log_dir" "$user_root/Library/LaunchAgents"
chmod 700 "$config_dir" "$log_dir"
bm_lock_lifecycle

# A failed prior setup keeps its original state until restoration succeeds.
backup_agent_dir="$log_dir/.runtime-setup-backup"
if [[ -d "$backup_agent_dir" ]]; then
  bm_restore_agents "$backup_agent_dir" || { print -u2 "Runtime backups remain at: $backup_agent_dir"; exit 1; }
  rm -rf "$backup_agent_dir"
fi
update_state="$(bm_update_state_path)"
if [[ -d "$update_state" ]]; then
  bm_validate_update_state "$installed_app"
  target_build="$(/usr/bin/plutil -extract targetBuild raw -o - "$update_state/journal.plist")"
  current_build="$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$installed_app/Contents/Info.plist")"
  # Reopening the old build after an interrupted/failed installation recovers it.
  if [[ "$target_build" != "$current_build" ]]; then bm_recover_update_runtime "$installed_app"; fi
fi
temporary_agent="$(mktemp "$user_root/Library/LaunchAgents/.beavermeter.XXXXXX")"
backup_staging=""
agent_changed=0
setup_committed=0
cleanup() {
  local exit_code="$1"
  trap - ZERR EXIT INT TERM
  if (( ! setup_committed && agent_changed )); then
    if bm_restore_agents "$backup_agent_dir"; then
      rm -rf "$backup_agent_dir"
      if ! bm_recover_update_runtime "$installed_app"; then exit_code=1; fi
    else
      print -u2 "Could not restore background refresh. Runtime backups remain at: $backup_agent_dir"
      exit_code=1
    fi
  fi
  rm -f "$temporary_agent"
  [[ -z "$backup_staging" ]] || rm -rf "$backup_staging"
  return "$exit_code"
}
trap 'cleanup $?' ZERR EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
refresh_minutes=5
if [[ -r "$agent_path" ]]; then
  prior_interval="$(/usr/bin/plutil -extract StartInterval raw -o - "$agent_path" 2>/dev/null || true)"
  if [[ "$prior_interval" == <-> ]] && (( prior_interval >= 300 && prior_interval <= 86400 && prior_interval % 60 == 0 )); then refresh_minutes=$((prior_interval / 60)); fi
elif [[ -r "$legacy_agent_path" ]]; then
  prior_interval="$(/usr/bin/plutil -extract StartInterval raw -o - "$legacy_agent_path" 2>/dev/null || true)"
  if [[ "$prior_interval" == <-> ]] && (( prior_interval >= 300 && prior_interval <= 86400 && prior_interval % 60 == 0 )); then refresh_minutes=$((prior_interval / 60)); fi
fi
rm -f "$temporary_agent"
bm_run plistbuddy -c "Add :Label string $agent_label" "$temporary_agent"
bm_run plistbuddy -c 'Add :ProgramArguments array' "$temporary_agent"
bm_run plistbuddy -c 'Add :ProgramArguments:0 string /bin/zsh' "$temporary_agent"
bm_run plistbuddy -c "Add :ProgramArguments:1 string $installed_app/Contents/Resources/collect_beaver_meter.sh" "$temporary_agent"
bm_run plistbuddy -c 'Add :RunAtLoad bool true' "$temporary_agent"
bm_run plistbuddy -c "Add :StartInterval integer $((refresh_minutes * 60))" "$temporary_agent"
bm_run plistbuddy -c "Add :StandardOutPath string $log_dir/refresh.out.log" "$temporary_agent"
bm_run plistbuddy -c "Add :StandardErrorPath string $log_dir/refresh.err.log" "$temporary_agent"
chmod 600 "$temporary_agent"

backup_staging="$(mktemp -d "$log_dir/.runtime-setup-staging.XXXXXX")"
bm_snapshot_agents "$backup_staging"
mv "$backup_staging" "$backup_agent_dir"
backup_staging=""
agent_changed=1
bm_register_app "$installed_app"
# Migration copies only missing files and leaves all old data recoverable.
BEAVERMETER_USER_ROOT_OVERRIDE="$user_root" zsh "$script_dir/migrate_beavermeter_data.sh"
if [[ ! -f "$agent_path" ]] || ! cmp -s "$temporary_agent" "$agent_path" \
   || ! bm_run launchctl print "$launch_domain/$agent_label" >/dev/null 2>&1; then
  bm_bootout_agent "$agent_label"
  mv -f "$temporary_agent" "$agent_path"
  bm_run launchctl bootstrap "$launch_domain" "$agent_path"
  bm_run launchctl print "$launch_domain/$agent_label" >/dev/null 2>&1
fi
bm_bootout_agent "$legacy_agent_label"
bm_unregister_other_apps
bm_complete_update_runtime "$installed_app"
setup_committed=1
rm -rf "$backup_agent_dir"
print "BeaverMeter background refresh is ready."
