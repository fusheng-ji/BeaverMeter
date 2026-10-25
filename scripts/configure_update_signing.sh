#!/bin/zsh
# Provision an existing release key without printing private material.
set -euo pipefail
umask 077
project_dir="${0:A:h:h}"
cd "$project_dir"
operation="${1:---check}"
case "$operation" in
  --check|--backup|--github-secret) ;;
  *) print -u2 'Usage: configure_update_signing.sh --check | --backup <encrypted-file> | --github-secret'; exit 2 ;;
esac
tools_dir="$(python3 - <<'PY'
import os, sys
sys.path.insert(0, 'scripts')
from sparkle_release import find_tools
root = os.environ.get('BEAVERMETER_SPARKLE_TOOLS_ROOT')
if root is None and os.path.exists('.build/sparkle-tooling/distribution'):
    root = '.build/sparkle-tooling/distribution'
print(find_tools('.build/release', root))
PY
)"
# This verifies that an existing Keychain key matches the committed public key.
# Never silently create a replacement for a missing release key.
python3 scripts/sparkle_release.py --tools-root "${tools_dir:h}" --check-key
if [[ "$operation" == --check ]]; then
  print 'The Keychain release key matches the committed public key.'
  exit 0
fi
if [[ "$operation" == --github-secret ]]; then
  command -v gh >/dev/null || { print -u2 'Install GitHub CLI and run gh auth login before provisioning the Actions secret.'; exit 1; }
  gh auth status --hostname github.com >/dev/null 2>&1 || { print -u2 'Run gh auth login before provisioning the Actions secret.'; exit 1; }
fi
if [[ "$operation" == --backup ]]; then
  target="${2:?Expected an encrypted backup path}"
  [[ ! -e "$target" ]] || { print -u2 'The backup file already exists; choose a new path.'; exit 1; }
  [[ -t 0 ]] || { print -u2 'Run backup in an interactive terminal to enter its encryption password.'; exit 1; }
  mkdir -p "${target:A:h}"
fi
private_dir="$(mktemp -d "${TMPDIR:-/tmp}/beavermeter-signing.XXXXXX")"
trap 'rm -rf "$private_dir"' EXIT INT TERM
"$tools_dir/generate_keys" --account BeaverMeter.Release -x "$private_dir/release.private-key" >/dev/null
chmod 600 "$private_dir/release.private-key"
case "$operation" in
  --backup)
    # OpenSSL asks twice on the controlling terminal; passwords never enter argv.
    /usr/bin/openssl enc -aes-256-cbc -salt -pbkdf2 -iter 600000 \
      -in "$private_dir/release.private-key" -out "$private_dir/backup.enc"
    chmod 600 "$private_dir/backup.enc"
    /bin/mv -n "$private_dir/backup.enc" "$target"
    print 'Encrypted release-key backup created. Keep its password separately from the backup and Keychain.'
    ;;
  --github-secret)
    gh secret set BEAVERMETER_SPARKLE_PRIVATE_KEY --repo fusheng-ji/BeaverMeter < "$private_dir/release.private-key"
    print 'The repository Actions signing secret is configured.'
    ;;
esac
