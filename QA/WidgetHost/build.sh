#!/bin/zsh
set -euo pipefail

qa_source_dir="${0:A:h}"
qa_repo_root="${qa_source_dir:h:h}"
qa_derived_data="$qa_repo_root/.build/widget-desktop-qa"
qa_app="$qa_derived_data/Build/Products/Debug/BeaverMeter QA.app"
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

zsh "$qa_source_dir/check.sh"
print "Built isolated QA app: $qa_app"
