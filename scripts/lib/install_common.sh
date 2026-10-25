#!/bin/zsh
# Shared lifecycle operations for the installer, repair and uninstall commands.
# Source this file after enabling `set -euo pipefail`.

bm_initialize() {
  user_root="${BEAVERMETER_USER_ROOT_OVERRIDE:-$HOME}"
  app_name="BeaverMeter.app"
  install_dir="$user_root/Applications"
  installed_app="$install_dir/$app_name"
  system_install_dir="${BEAVERMETER_SYSTEM_APPLICATIONS_OVERRIDE:-/Applications}"
  installed_widget="$installed_app/Contents/PlugIns/BeaverMeterWidgetExtension.appex"
  agent_label="io.github.beavermeter.refresh"
  agent_path="$user_root/Library/LaunchAgents/$agent_label.plist"
  config_dir="$user_root/Library/Application Support/BeaverMeter"
  config_path="$config_dir/config.env"
  snapshot_path="$config_dir/beaver-meter-snapshot.json"
  log_dir="$user_root/Library/Logs/BeaverMeter"
  legacy_app="$install_dir/CodexWeek.app"
  legacy_agent_label="io.github.codexweek.refresh"
  legacy_agent_path="$user_root/Library/LaunchAgents/$legacy_agent_label.plist"
  legacy_config_dir="$user_root/Library/Application Support/CodexWeek"
  legacy_log_dir="$user_root/Library/Logs/CodexWeek"
  launch_domain="gui/$(id -u)"

  # Tests must provide every system command explicitly and use an isolated root.
  # A missing fake never falls through to a real launchctl, pkill or registration.
  if [[ -n "${BEAVERMETER_SYSTEM_COMMANDS:-}" ]]; then
    if [[ -z "${BEAVERMETER_USER_ROOT_OVERRIDE:-}" || "$user_root" == "$HOME" || "$user_root" != /* || "$user_root" == / ]]; then
      print -u2 "Test system commands require an isolated absolute user root."
      return 1
    fi
    [[ "$system_install_dir" != /Applications ]] || system_install_dir="$user_root/SystemApplications"
  elif [[ -n "${BEAVERMETER_SYSTEM_APPLICATIONS_OVERRIDE:-}" ]]; then
    print -u2 "The system Applications override is only available to isolated tests."
    return 1
  fi
}

bm_app_identifier() {
  /usr/bin/plutil -extract CFBundleIdentifier raw -o - "$1/Contents/Info.plist" 2>/dev/null
}

bm_is_official_app() {
  [[ -d "$1" && ! -L "$1" && "$(bm_app_identifier "$1" || true)" == io.github.fushengji.beavermeter ]]
}

# Source installation deliberately keeps bm_initialize's user-directory default.
# Runtime, repair and uninstall resolve their own explicit/canonical target.
bm_select_installed_app() {
  local requested="${1:-}" system_app="${system_install_dir:A}/$app_name" user_app="${install_dir:A}/$app_name"
  if [[ -z "$requested" ]]; then
    if bm_is_official_app "$system_app"; then requested="$system_app"; else requested="$user_app"; fi
  fi
  requested="${requested:A}"
  if [[ "$requested" != "$system_app" && "$requested" != "$user_app" ]]; then
    print -u2 "Drag BeaverMeter to Applications before opening it. Supported locations: $system_app or $user_app."
    return 1
  fi
  installed_app="$requested"
  installed_widget="$installed_app/Contents/PlugIns/BeaverMeterWidgetExtension.appex"
}

bm_require_preferred_official_app() {
  bm_select_installed_app "$1" || return 1
  if ! bm_is_official_app "$installed_app"; then
    print -u2 "Runtime setup and automatic updates require an official BeaverMeter application."
    return 1
  fi
  local system_app="$system_install_dir/$app_name"
  if bm_is_official_app "$system_app" && [[ "$installed_app" != "${system_app:A}" ]]; then
    print -u2 "Another official BeaverMeter copy is installed at $system_app. Open that copy; remove the duplicate when convenient."
    return 1
  fi
}

bm_lock_lifecycle() {
  # Outside the app's data/log directories: rollback and uninstall may replace
  # those directories, but every lifecycle must keep locking the same inode.
  local lock_path="${log_dir:h}/.beavermeter-runtime-lifecycle.lock"
  (umask 077; mkdir -p "${lock_path:h}")
  [[ -e "$lock_path" ]] || (umask 077; : > "$lock_path")
  chmod 600 "$lock_path"
  zmodload zsh/system
  if ! zsystem flock -t 0 -f lifecycle_lock_fd "$lock_path"; then
    print -u2 "BeaverMeter setup or update preparation is already running. Try again shortly."
    return 1
  fi
}

bm_bootout_agent() {
  local label="$1"
  if bm_run launchctl print "$launch_domain/$label" >/dev/null 2>&1; then
    bm_run launchctl bootout "$launch_domain/$label" || return 1
  fi
  if bm_run launchctl print "$launch_domain/$label" >/dev/null 2>&1; then
    print -u2 "Could not pause $label."
    return 1
  fi
}

# Private state files are data, never sourced as shell code.
bm_snapshot_agents() {
  local backup="$1" include_legacy="${2:-1}" label file prefix
  mkdir -p "$backup"
  chmod 700 "$backup"
  print -r -- "$include_legacy" > "$backup/include-legacy"
  for prefix in agent legacy-agent; do
    [[ "$prefix" != legacy-agent || "$include_legacy" == 1 ]] || continue
    if [[ "$prefix" == agent ]]; then label="$agent_label"; file="$agent_path"; else label="$legacy_agent_label"; file="$legacy_agent_path"; fi
    if [[ -f "$file" ]]; then
      /usr/bin/ditto "$file" "$backup/$prefix.plist" || return 1
      chmod 600 "$backup/$prefix.plist"
      print 1 > "$backup/$prefix-existed"
    else
      print 0 > "$backup/$prefix-existed"
    fi
    if bm_run launchctl print "$launch_domain/$label" >/dev/null 2>&1; then
      print 1 > "$backup/$prefix-loaded"
    else
      print 0 > "$backup/$prefix-loaded"
    fi
  done
}

bm_restore_agents() {
  local backup="$1" relocated_from="${2:-}" relocated_to="${3:-}" prefix label file existed loaded restored_script
  [[ -r "$backup/include-legacy" ]] || return 1
  for prefix in agent legacy-agent; do
    [[ "$prefix" != legacy-agent || "$(<"$backup/include-legacy")" == 1 ]] || continue
    [[ -r "$backup/$prefix-existed" && -r "$backup/$prefix-loaded" ]] || return 1
    existed="$(<"$backup/$prefix-existed")"; loaded="$(<"$backup/$prefix-loaded")"
    [[ "$existed" == [01] && "$loaded" == [01] ]] || return 1
    if [[ "$prefix" == agent ]]; then label="$agent_label"; file="$agent_path"; else label="$legacy_agent_label"; file="$legacy_agent_path"; fi
    bm_bootout_agent "$label" || return 1
    if [[ "$existed" == 1 ]]; then
      [[ -r "$backup/$prefix.plist" ]] || return 1
      /usr/bin/ditto "$backup/$prefix.plist" "$file" || return 1
      chmod 600 "$file" || return 1
      # Moving the only installed copy must not restore a now-missing launcher.
      # Retarget the restored file; leave the original backup unchanged until
      # restoration succeeds, so a failed recovery remains fully retryable.
      if [[ "$prefix" == agent && -n "$relocated_from" && "$relocated_from" != "$relocated_to" ]]; then
        restored_script="$(/usr/bin/plutil -extract ProgramArguments.1 raw -o - "$file" 2>/dev/null || true)"
        if [[ "$restored_script" == "$relocated_from/Contents/Resources/collect_beaver_meter.sh" ]]; then
          /usr/bin/plutil -replace ProgramArguments.1 -string "$relocated_to/Contents/Resources/collect_beaver_meter.sh" "$file" || return 1
        fi
      fi
    else
      rm -f "$file" || return 1
    fi
    if [[ "$loaded" == 1 ]]; then
      [[ "$existed" == 1 ]] || return 1
      bm_run launchctl bootstrap "$launch_domain" "$file" || return 1
      bm_run launchctl print "$launch_domain/$label" >/dev/null 2>&1 || return 1
    fi
  done
}

bm_update_state_path() { print -r -- "$config_dir/.update-runtime-state"; }

bm_validate_update_state() {
  local application="$1" state="$(bm_update_state_path)" recorded system_app="${system_install_dir:A}/$app_name" user_app="${install_dir:A}/$app_name"
  [[ -d "$state" ]] || return 0
  recorded="$(/usr/bin/plutil -extract appPath raw -o - "$state/journal.plist" 2>/dev/null)" || return 1
  if [[ "$recorded" != "$application" ]]; then
    # A sole canonical copy may be moved between the two Applications folders.
    # Never let a second existing copy (or an arbitrary old path) take ownership.
    if [[ ( "$recorded" == "$system_app" || "$recorded" == "$user_app" ) &&
          ( "$application" == "$system_app" || "$application" == "$user_app" ) &&
          ! -e "$recorded" && ! -L "$recorded" ]] && bm_is_official_app "$application"; then
      if [[ "$application" == "$system_app" ]] || ! bm_is_official_app "$system_app"; then return 0; fi
    fi
    print -u2 "An unfinished update belongs to $recorded. Reopen that copy before updating another installation."
    return 1
  fi
}

bm_recover_update_runtime() {
  local application="$1" state="$(bm_update_state_path)" recorded
  [[ -d "$state" ]] || return 0
  bm_validate_update_state "$application" || return 1
  recorded="$(/usr/bin/plutil -extract appPath raw -o - "$state/journal.plist")" || return 1
  if ! bm_restore_agents "$state" "$recorded" "$application"; then
    print -u2 "Could not restore background refresh. Update backups are retained at: $state"
    return 1
  fi
  bm_register_app "$application" || return 1
  rm -rf "$state"
}

bm_complete_update_runtime() {
  local application="$1" state="$(bm_update_state_path)" target current
  [[ -d "$state" ]] || return 0
  bm_validate_update_state "$application" || return 1
  target="$(/usr/bin/plutil -extract targetBuild raw -o - "$state/journal.plist" 2>/dev/null)" || return 1
  current="$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$application/Contents/Info.plist" 2>/dev/null)" || return 1
  [[ "$target" == "$current" ]] || { print -u2 "The installed build does not match the prepared update; reopen BeaverMeter to recover."; return 1; }
  [[ "$(/usr/bin/plutil -extract ProgramArguments.1 raw -o - "$agent_path" 2>/dev/null)" == "$application/Contents/Resources/collect_beaver_meter.sh" ]] || return 1
  bm_run launchctl print "$launch_domain/$agent_label" >/dev/null 2>&1 || return 1
  rm -rf "$state"
}

bm_run() {
  local command_name="$1"
  shift
  if [[ -n "${BEAVERMETER_SYSTEM_COMMANDS:-}" ]]; then
    local executable="$BEAVERMETER_SYSTEM_COMMANDS/$command_name"
    if [[ ! -x "$executable" ]]; then
      print -u2 "Missing test system command: $command_name"
      return 127
    fi
    "$executable" "$@"
    return
  fi
  case "$command_name" in
    lsregister)
      /System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister "$@"
      ;;
    plistbuddy) /usr/libexec/PlistBuddy "$@" ;;
    *) command "$command_name" "$@" ;;
  esac
}

bm_widget_path() {
  local application="$1"
  if [[ -d "$application/Contents/PlugIns/CodexWeekWidgetExtension.appex" ]]; then
    print -r -- "$application/Contents/PlugIns/CodexWeekWidgetExtension.appex"
  else
    print -r -- "$application/Contents/PlugIns/BeaverMeterWidgetExtension.appex"
  fi
}

bm_unregister_app() {
  local application="$1"
  [[ -d "$application" ]] || return 0
  bm_run pluginkit -r "$(bm_widget_path "$application")" >/dev/null 2>&1 || true
  bm_run lsregister -u "$application" >/dev/null 2>&1 || true
}

bm_unregister_other_apps() {
  local registered_app
  local registrations
  local identifier="$(bm_app_identifier "$installed_app" || true)"
  [[ -n "$identifier" ]] || return 0
  registrations="$(bm_run lsregister -dump 2>/dev/null)" || return 0
  while IFS= read -r registered_app; do
    if [[ -n "$registered_app" && "${registered_app:A}" != "$installed_app" &&
          "$(bm_app_identifier "$registered_app" || true)" == "$identifier" ]]; then
      bm_unregister_app "$registered_app"
    fi
  done < <(print -r -- "$registrations" | sed -En 's/^[[:space:]]*path:[[:space:]]*(.*BeaverMeter\.app)[[:space:]]+\(0x[0-9A-Fa-f]+\)$/\1/p')
}

bm_register_app() {
  local application="$1"
  bm_run lsregister -f -R -trusted "$application"
  bm_run pluginkit -a "$(bm_widget_path "$application")"
}

bm_stop_processes() {
  local process_name attempt
  for process_name in "$@"; do
    bm_run pkill -x "$process_name" >/dev/null 2>&1 || true
  done
  for process_name in "$@"; do
    for attempt in {1..20}; do
      bm_run pgrep -x "$process_name" >/dev/null 2>&1 || break
      sleep 0.1
    done
    if bm_run pgrep -x "$process_name" >/dev/null 2>&1; then
      bm_run pkill -KILL -x "$process_name" >/dev/null 2>&1 || true
      sleep 0.2
      if bm_run pgrep -x "$process_name" >/dev/null 2>&1; then
        print -u2 "Could not stop $process_name. Quit it manually and try again."
        return 1
      fi
    fi
  done
}

bm_stop_applications() {
  local include_legacy="${1:-1}"
  bm_unregister_app "$installed_app"
  [[ "$include_legacy" != 1 ]] || bm_unregister_app "$legacy_app"
  bm_run killall chronod >/dev/null 2>&1 || true
  bm_stop_processes BeaverMeter BeaverMeterWidgetExtension BeaverMeterCollector || return 1
  [[ "$include_legacy" != 1 ]] || bm_stop_processes CodexWeek CodexWeekWidgetExtension CodexWeekCollector
}

bm_refresh_widget_services() {
  bm_run lsregister -gc >/dev/null 2>&1 || true
  bm_run killall chronod >/dev/null 2>&1 || true
  bm_run killall NotificationCenter >/dev/null 2>&1 || true
}

bm_open_app() {
  local application="$1" attempt
  for attempt in {1..10}; do
    if bm_run open "$application"; then
      return 0
    fi
    sleep 0.5
  done
  print -u2 "Could not relaunch ${application:t}."
  return 1
}
