#!/bin/zsh
set -euo pipefail

qa_source_dir="${0:A:h}"
qa_repo_root="${qa_source_dir:h:h}"
qa_derived_data="$qa_repo_root/.build/widget-desktop-qa"
qa_app="$qa_derived_data/Build/Products/Debug/BeaverMeter QA.app"
qa_antigravity=0
if [[ "${1:-}" == "--antigravity" && "$#" == 1 ]]; then
  qa_antigravity=1
elif (( $# != 0 )); then
  print -u2 "Usage: $0 [--antigravity]"
  exit 2
fi
mkdir -p "$qa_derived_data"

# Regeneration expands the Shared/Widget directories, including new activity
# files, without touching the production Xcode project. Standard macOS app
# builds register this private QA identity with LaunchServices; they do not add
# a desktop Widget, start this host, or alter the production application.
xcodegen generate --spec "$qa_source_dir/project.yml"
xcodebuild -project "$qa_source_dir/BeaverMeterWidgetQA.xcodeproj" \
  -scheme BeaverMeterWidgetQA -configuration Debug \
  -derivedDataPath "$qa_derived_data" CODE_SIGNING_ALLOWED=YES \
  ONLY_ACTIVE_ARCH=YES ARCHS="$(uname -m)" build \
  > "$qa_derived_data/build.log" 2>&1
/usr/bin/codesign --verify --deep --strict "$qa_app"
"$qa_app/Contents/MacOS/BeaverMeter QA" --self-test

if (( qa_antigravity )); then
  zsh "$qa_source_dir/check_antigravity.sh"
else
  zsh "$qa_source_dir/check.sh"
fi
print "Built isolated QA app: $qa_app"
