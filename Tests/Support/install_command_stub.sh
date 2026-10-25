#!/bin/zsh
set -euo pipefail

command_name="${0:t}"
print -r -- "$command_name ${(j: :)@}" >> "$BM_TEST_STATE/commands.log"
case "$command_name" in
  xcodegen) ;;
  xcodebuild)
    [[ "${BM_TEST_FAIL:-}" != build ]] || exit 12
    task_derived=""
    while (( $# )); do
      if [[ "$1" == -derivedDataPath ]]; then task_derived="$2"; break; fi
      shift
    done
    [[ -n "$task_derived" ]]
    task_app="$task_derived/Build/Products/Release/BeaverMeter.app"
    mkdir -p "$task_app/Contents/Resources" "$task_app/Contents/PlugIns/BeaverMeterWidgetExtension.appex"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string ${BEAVERMETER_BUNDLE_PREFIX:-com.test}.beavermeter" "$task_app/Contents/Info.plist" >/dev/null
    print -r -- new > "$task_app/version-marker"
    cp "$BM_TEST_PROJECT/Tests/Support/install_collector_stub.sh" "$task_app/Contents/Resources/collect_beaver_meter.sh"
    chmod +x "$task_app/Contents/Resources/collect_beaver_meter.sh"
    ;;
  codesign)
    task_app="${@[-1]}"
    [[ -d "$task_app" ]]
    if [[ "${BM_TEST_FAIL:-}" == preflight && "$task_app" == */Build/Products/* ]]; then exit 13; fi
    if [[ "${BM_TEST_FAIL:-}" == verification && "$task_app" == */Applications/* ]]; then exit 14; fi
    ;;
  plistbuddy) exec /usr/libexec/PlistBuddy "$@" ;;
  launchctl)
    case "$1" in
      print) [[ -f "$BM_TEST_STATE/${2:t}.loaded" ]] ;;
      bootout)
        [[ "${BM_TEST_FAIL:-}" != bootout ]] || exit 17
        rm -f "$BM_TEST_STATE/${2:t}.loaded"
        ;;
      bootstrap)
        task_label="$(/usr/libexec/PlistBuddy -c 'Print :Label' "$3")"
        if [[ "${BM_TEST_FAIL:-}" == bootstrap-always ||
              ( "${BM_TEST_FAIL:-}" == bootstrap && ! -f "$BM_TEST_STATE/failed-once" ) ]]; then
          touch "$BM_TEST_STATE/failed-once"
          exit 15
        fi
        touch "$BM_TEST_STATE/$task_label.loaded"
        ;;
    esac
    ;;
  pgrep) [[ -f "$BM_TEST_STATE/${@[-1]}.running" ]] ;;
  pkill) rm -f "$BM_TEST_STATE/${@[-1]}.running" ;;
  ps)
    [[ "${BM_TEST_FAIL:-}" != ps ]] || exit 16
    [[ ! -f "$BM_TEST_STATE/processes" ]] || cat "$BM_TEST_STATE/processes"
    ;;
  lsof)
    [[ "${BM_TEST_FAIL:-}" != lsof ]] || exit 18
    process_id="$3"
    while read -r candidate_id candidate_uid executable; do
      [[ "$candidate_id" == "$process_id" ]] || continue
      [[ ! -f "$BM_TEST_STATE/$process_id.executable" ]] || executable="$(<"$BM_TEST_STATE/$process_id.executable")"
      print -rl -- "p$process_id" "n$executable"
      exit 0
    done < "$BM_TEST_STATE/processes"
    exit 1
    ;;
  kill)
    [[ "${BM_TEST_FAIL:-}" != helpers-stuck ]] || exit 0
    process_id="${@[-1]}"
    if [[ "$1" == -0 ]]; then
      awk -v target="$process_id" '$1 == target { found=1 } END { exit(found ? 0 : 1) }' "$BM_TEST_STATE/processes"
      exit $?
    fi
    if [[ "$1" == -TERM && -f "$BM_TEST_STATE/$process_id.ignore-term" ]]; then exit 0; fi
    awk -v target="$process_id" '$1 != target' "$BM_TEST_STATE/processes" > "$BM_TEST_STATE/processes.new"
    mv "$BM_TEST_STATE/processes.new" "$BM_TEST_STATE/processes"
    ;;
  lsregister)
    if [[ "$1" == -dump && -f "$BM_TEST_STATE/registrations" ]]; then cat "$BM_TEST_STATE/registrations"; fi
    ;;
  pluginkit) ;;
  killall) ;;
  open) touch "$BM_TEST_STATE/${1:t:r}.running" ;;
  *) print -u2 "Unexpected test system command: $command_name"; exit 99 ;;
esac
