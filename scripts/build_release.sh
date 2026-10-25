#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
cd "$project_dir"
# Keep the CI signing secret out of build, dependency-install and validation child processes.
release_signing_key_present=0
release_signing_key=''
if (( ${+BEAVERMETER_SPARKLE_PRIVATE_KEY} )); then
  release_signing_key_present=1
  release_signing_key="$BEAVERMETER_SPARKLE_PRIVATE_KEY"
  unset BEAVERMETER_SPARKLE_PRIVATE_KEY
fi
run_sparkle_signing() {
  if (( release_signing_key_present )); then
    BEAVERMETER_SPARKLE_PRIVATE_KEY="$release_signing_key" python3 scripts/sparkle_release.py "$@"
  else
    python3 scripts/sparkle_release.py "$@"
  fi
}
local_build=0
if [[ "${1:-}" == --local ]]; then local_build=1; shift; fi
output_dir="${1:-$project_dir/.build/release-artifacts}"
output_dir="${output_dir:A}"
tag="${2:-${GITHUB_REF_NAME:-}}"
version="$(python3 scripts/release_metadata.py)"
validation_flags=()
updates_enabled=YES
if (( local_build )); then
  updates_enabled=NO
  validation_flags+=(--local)
else
  [[ -n "$tag" ]] || { print -u2 'Specify a vX.Y.Z tag, or --local for an unpublished DMG.'; exit 1; }
  python3 scripts/release_metadata.py --tag "$tag" >/dev/null
  [[ -z "$(git status --porcelain --untracked-files=no -- . ":(exclude)App/Info.plist" ":(exclude)Widget/Info.plist")" ]] || { print -u2 'Release checkout must be clean.'; exit 1; }
  [[ -z "$(git ls-files --others --exclude-standard)" ]] || { print -u2 'Release checkout must not contain untracked source files.'; exit 1; }
fi
public_key="$(python3 -c 'import sys; sys.path.insert(0, "scripts"); from release_metadata import ROOT, public_key; print(public_key(ROOT / "Config/SparklePublicKey.txt"))')"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export BEAVERMETER_BUNDLE_PREFIX=io.github.fushengji
export BEAVERMETER_DEVELOPMENT_TEAM=''
derived_data="${BEAVERMETER_RELEASE_DERIVED_DATA:-$project_dir/.build/release}"
xcodegen generate
if (( ! local_build )); then
  xcodebuild -resolvePackageDependencies -project BeaverMeter.xcodeproj -scheme BeaverMeter -derivedDataPath "$derived_data"
  run_sparkle_signing --derived-data "$derived_data" --check-key
fi
xcodebuild -project BeaverMeter.xcodeproj -scheme BeaverMeter -configuration Release \
  -derivedDataPath "$derived_data" ONLY_ACTIVE_ARCH=NO 'ARCHS=arm64 x86_64' \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
  BEAVERMETER_DIRECT_INSTALL=YES "BEAVERMETER_UPDATES_ENABLED=$updates_enabled" \
  "BEAVERMETER_SPARKLE_PUBLIC_KEY=$public_key" build
app="$derived_data/Build/Products/Release/BeaverMeter.app"
python3 scripts/release_metadata.py --app "$app" "${validation_flags[@]}"
mkdir -p "$output_dir"
stage="$(mktemp -d "${TMPDIR:-/tmp}/beavermeter-release.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/BeaverMeter.app"
# Lifecycle scripts compile create-dmg's native macOS Finder alias dependencies.
npm ci --prefix scripts/packaging --no-audit --no-fund
npm test --prefix scripts/packaging
node scripts/packaging/create_dmg.mjs "$stage/BeaverMeter.app" "$stage" \
  --no-code-sign --dmg-title="BeaverMeter $version"
dmg="BeaverMeter-$version-universal.dmg"
[[ -f "$stage/BeaverMeter $version.dmg" ]] || { print -u2 'create-dmg did not produce the expected image.'; exit 1; }
mv "$stage/BeaverMeter $version.dmg" "$stage/$dmg"
python3 scripts/release_metadata.py --dmg "$stage/$dmg" "${validation_flags[@]}"
if (( local_build )); then
  cp "$stage/$dmg" "$output_dir/$dmg"
  (cd "$output_dir"; shasum -a 256 "$dmg" > SHA256SUMS)
  print 'Local validation DMG only; production updates are disabled.'
else
  artifacts="$stage/artifacts"
  mkdir "$artifacts"
  mv "$stage/$dmg" "$artifacts/$dmg"
  source_zip="BeaverMeter-$version-source.zip"
  git archive --format=zip --prefix="BeaverMeter-$version/" "$tag" > "$artifacts/$source_zip"
  run_sparkle_signing --derived-data "$derived_data" --output "$artifacts"
  python3 scripts/release_metadata.py --artifacts "$artifacts"
  for asset in "$artifacts"/*; do cp "$asset" "$output_dir/"; done
  python3 scripts/release_metadata.py --artifacts "$output_dir"
fi
print "Artifacts: $output_dir"
