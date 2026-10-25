#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/beavermeter-runtime-tests.XXXXXX")"
test_root="${test_root:A}"
cleanup_tests() {
  local exit_code=$?
  if (( exit_code )) && [[ -f "${case_root:-}/output.log" ]]; then cat "$case_root/output.log" >&2; fi
  rm -rf "$test_root"
  return "$exit_code"
}
trap cleanup_tests EXIT
mock_dir="$test_root/commands"
mkdir -p "$mock_dir"
for command_name in codesign plistbuddy launchctl lsregister pluginkit; do
  ln -s "$project_dir/Tests/Support/install_command_stub.sh" "$mock_dir/$command_name"
done
prepare_case() {
  case_root="$test_root/$1"
  task_user="$case_root/user"
  state="$case_root/state"
  task_app="$task_user/Applications/BeaverMeter.app"
  task_data="$task_user/Library/Application Support/BeaverMeter"
  agent="$task_user/Library/LaunchAgents/io.github.beavermeter.refresh.plist"
  mkdir -p "$task_app/Contents/Helpers" "$task_app/Contents/Resources" \
    "$task_app/Contents/PlugIns/BeaverMeterWidgetExtension.appex" "$task_data" "$state"
  print '#!/bin/zsh' > "$task_app/Contents/Helpers/BeaverMeterCollector"
  chmod +x "$task_app/Contents/Helpers/BeaverMeterCollector"
  touch "$task_app/Contents/Resources/collect_beaver_meter.sh"
  mkdir -p "$task_app/Contents"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string io.github.fushengji.beavermeter' "$task_app/Contents/Info.plist" >/dev/null
  /usr/libexec/PlistBuddy -c 'Add :CFBundleVersion string 36' "$task_app/Contents/Info.plist"
  print -r -- 'CODEX_ROOT=/custom/saved' > "$task_data/config.env"
  print -r -- test-credential > "$task_data/deepseek-platform-token"
  print -r -- '{"selection":"christmas"}' > "$task_data/beaver-meter-appearance.json"
  cp -R "$task_data" "$case_root/original-data"
}
run_setup() {
  env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOME" \
    BEAVERMETER_USER_ROOT_OVERRIDE="$task_user" BEAVERMETER_SYSTEM_COMMANDS="$mock_dir" \
    BM_TEST_STATE="$state" BM_TEST_FAIL="${1:-}" \
    /bin/zsh "$project_dir/scripts/configure_runtime.sh" "$task_app" > "$case_root/output.log" 2>&1
}
prepare_case fresh
run_setup
[[ "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:1' "$agent")" == "$task_app/Contents/Resources/collect_beaver_meter.sh" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :StartInterval' "$agent")" == 300 ]]
[[ -f "$state/io.github.beavermeter.refresh.loaded" ]]
diff -r "$task_data" "$case_root/original-data"
run_setup
[[ "$(rg -c '^launchctl bootstrap' "$state/commands.log")" == 1 ]]
if rg -q 'xcode|brew|sqlite' "$state/commands.log"; then
  print -u2 'Prebuilt runtime setup invoked developer tools.'
  exit 1
fi

prepare_case upgrade
mkdir -p "${agent:h}"
/usr/libexec/PlistBuddy -c 'Add :Label string io.github.beavermeter.refresh' "$agent"
/usr/libexec/PlistBuddy -c 'Add :StartInterval integer 600' "$agent"
cp "$agent" "$case_root/old-agent"
touch "$state/io.github.beavermeter.refresh.loaded"
if run_setup bootstrap; then print -u2 'Expected bootstrap failure'; exit 1; fi
cmp "$agent" "$case_root/old-agent"
diff -r "$task_data" "$case_root/original-data"
[[ -f "$state/io.github.beavermeter.refresh.loaded" ]]
run_setup
[[ "$(/usr/libexec/PlistBuddy -c 'Print :StartInterval' "$agent")" == 600 ]]
diff -r "$task_data" "$case_root/original-data"

# An existing but unloaded agent remains unloaded after a failed setup.
prepare_case unloaded
mkdir -p "${agent:h}"
/usr/libexec/PlistBuddy -c 'Add :Label string io.github.beavermeter.refresh' "$agent" >/dev/null
/usr/libexec/PlistBuddy -c 'Add :StartInterval integer 600' "$agent"
cp "$agent" "$case_root/old-agent"
if run_setup bootstrap; then print -u2 'Expected bootstrap failure'; exit 1; fi
cmp "$agent" "$case_root/old-agent"
[[ ! -f "$state/io.github.beavermeter.refresh.loaded" ]]

# If restoration also fails, retain the original backup and retry it next launch.
prepare_case restore-failure
mkdir -p "${agent:h}"
/usr/libexec/PlistBuddy -c 'Add :Label string io.github.beavermeter.refresh' "$agent" >/dev/null
/usr/libexec/PlistBuddy -c 'Add :StartInterval integer 600' "$agent"
cp "$agent" "$case_root/old-agent"
touch "$state/io.github.beavermeter.refresh.loaded"
if run_setup bootstrap-always; then print -u2 'Expected restoration failure'; exit 1; fi
backup="$task_user/Library/Logs/BeaverMeter/.runtime-setup-backup"
cmp "$backup/agent.plist" "$case_root/old-agent"
run_setup
[[ ! -d "$backup" && -f "$state/io.github.beavermeter.refresh.loaded" ]]

# First official launch migrates only missing legacy files and retires its agent.
prepare_case legacy
legacy_data="$task_user/Library/Application Support/CodexWeek"
legacy_agent="$task_user/Library/LaunchAgents/io.github.codexweek.refresh.plist"
mkdir -p "$legacy_data" "${legacy_agent:h}"
rm "$task_data/config.env"
print -r -- 'CODEX_ROOT=/legacy/saved' > "$legacy_data/config.env"
print -r -- legacy-credential > "$legacy_data/deepseek-platform-token"
/usr/libexec/PlistBuddy -c 'Add :Label string io.github.codexweek.refresh' "$legacy_agent" >/dev/null
/usr/libexec/PlistBuddy -c 'Add :StartInterval integer 900' "$legacy_agent"
touch "$state/io.github.codexweek.refresh.loaded"
if run_setup bootstrap; then print -u2 'Expected legacy migration setup failure'; exit 1; fi
[[ -f "$state/io.github.codexweek.refresh.loaded" && ! -f "$state/io.github.beavermeter.refresh.loaded" ]]
run_setup
[[ "$(<"$task_data/config.env")" == CODEX_ROOT=/legacy/saved ]]
[[ "$(<"$task_data/deepseek-platform-token")" == test-credential ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :StartInterval' "$agent")" == 900 ]]
[[ ! -f "$state/io.github.codexweek.refresh.loaded" && -f "$legacy_agent" && -d "$legacy_data" ]]

# Canonical system directory wins only for official copies.
prepare_case duplicate
system_app="$task_user/SystemApplications/BeaverMeter.app"
mkdir -p "${system_app:h}"
ditto "$task_app" "$system_app"
if run_setup; then print -u2 'Expected duplicate user copy to be refused'; exit 1; fi
rg -q 'Another official BeaverMeter copy' "$case_root/output.log"
[[ ! -e "$state/commands.log" ]]
task_app="$system_app"
run_setup
[[ "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:1' "$agent")" == "$system_app/Contents/Resources/collect_beaver_meter.sh" ]]

# Canonical app symlinks may not redirect runtime setup into another folder.
prepare_case symlink-location
outside_app="$case_root/outside/BeaverMeter.app"
mkdir -p "${outside_app:h}"
mv "$task_app" "$outside_app"
ln -s "$outside_app" "$task_app"
if run_setup; then print -u2 'Expected symlink app location to be refused'; exit 1; fi
rg -q 'Drag BeaverMeter to Applications' "$case_root/output.log"
[[ ! -e "$state/commands.log" ]]

prepare_case temporary-location
mkdir -p "$task_user/Downloads"
mv "$task_app" "$task_user/Downloads/BeaverMeter.app"
task_app="$task_user/Downloads/BeaverMeter.app"
if run_setup; then print -u2 'Expected temporary app location to be refused'; exit 1; fi
rg -q 'Drag BeaverMeter to Applications' "$case_root/output.log"
[[ ! -e "$state/commands.log" ]]

# Cleanup unregisters another copy with the same identity, retaining development IDs.
prepare_case registrations
same_app="$case_root/same/BeaverMeter.app"
development_app="$case_root/development/BeaverMeter.app"
ditto "$task_app" "$same_app"
ditto "$task_app" "$development_app"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.example.beavermeter' "$development_app/Contents/Info.plist"
print -rl -- "    path: $same_app (0x1234)" "    path: $development_app (0x1235)" > "$state/registrations"
run_setup
rg -Fq "lsregister -u $same_app" "$state/commands.log"
if rg -Fq "lsregister -u $development_app" "$state/commands.log"; then
  print -u2 'Runtime setup unregistered a development application.'
  exit 1
fi
print 'Prebuilt runtime setup tests passed without any developer-tool commands.'
