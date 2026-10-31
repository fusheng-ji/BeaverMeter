#!/bin/zsh
set -euo pipefail
collector="${1:?Pass the freshly built BeaverMeterCollector path}"
project_dir="${0:A:h:h}"

python3 -B - "$collector" "$project_dir/Tests/Fixtures" <<'PY'
import copy, datetime, json, os, pathlib, subprocess, sys, tempfile

collector = pathlib.Path(sys.argv[1]).resolve(strict=True)
fixtures = pathlib.Path(sys.argv[2]).resolve(strict=True)
assert collector.is_file() and os.access(collector, os.X_OK), 'Expected a built collector executable'
fields = ('antigravityQuota', 'antigravityTokens')

def read(path):
    return json.loads(path.read_text())

def write(path, value):
    path.write_text(json.dumps(value))
    path.chmod(0o600)

def anti(snapshot):
    return {key: snapshot[key] for key in fields}

with tempfile.TemporaryDirectory(prefix='beavermeter-antigravity-fixture-') as directory:
    root = pathlib.Path(directory)
    for name in ('home', 'tmp', 'cache', 'config', 'codex'):
        (root / name).mkdir(mode=0o700)
    output = root / 'snapshot.json'
    settings = root / 'beaver-meter-settings.json'
    env = dict(PATH='/usr/bin:/bin:/usr/sbin:/sbin', HOME=str(root / 'home'),
        CFFIXED_USER_HOME=str(root / 'home'), TMPDIR=str(root / 'tmp') + '/',
        XDG_CONFIG_HOME=str(root / 'config'), XDG_CACHE_HOME=str(root / 'cache'),
        TZ='Europe/Berlin', LANG='en_US.UTF-8', CODEX_HOME=str(root / 'codex'),
        CODEX_TOKEN_FIXTURE=str(fixtures / 'codex-token-totals.json'),
        CODEX_USAGE_FIXTURE=str(fixtures / 'codex-pro-week.json'),
        CLAUDE_USAGE_FIXTURE=str(fixtures / 'claude-usage.json'),
        CLAUDE_TOKEN_FIXTURE=str(fixtures / 'claude-token-totals.json'),
        CLAUDE_CONFIG_DIR=str(root / 'missing-claude'), CLAUDE_CLI_REFRESH='0', CLAUDE_KEYCHAIN_ACCESS='0',
        CURSOR_EVENTS_FIXTURE=str(fixtures / 'cursor-events-v3.json'),
        CURSOR_SUMMARY_FIXTURE=str(fixtures / 'cursor-summary-v3.json'),
        DEEPSEEK_SUMMARY_FIXTURE=str(fixtures / 'deepseek-summary.json'),
        DEEPSEEK_USAGE_FIXTURE=str(fixtures / 'deepseek-usage.json'),
        ANTIGRAVITY_QUOTA_FIXTURE=str(fixtures / 'antigravity-quota.json'),
        ANTIGRAVITY_TOKEN_FIXTURE=str(fixtures / 'antigravity-tokens.json'))

    def run(flag=None, overrides=None):
        current = env | (overrides or {})
        command = [str(collector), '--output', str(output)]
        if flag:
            command.append(flag)
        result = subprocess.run(command, cwd=root, env=current, stdin=subprocess.DEVNULL,
            capture_output=True, text=True, timeout=30)
        assert result.returncode == 0, 'Isolated collector operation failed: ' + (flag or 'full refresh')
        snapshot = read(output)
        assert snapshot['schemaVersion'] == 8, 'New snapshot schema was not published'
        return snapshot

    # Full refresh publishes both pools and a separate additive token reading.
    baseline = run()
    quota, tokens = baseline['antigravityQuota'], baseline['antigravityTokens']
    assert quota['status'] == 'ready' and quota['source'] == 'antigravityLocal'
    assert quota['value'] == read(fixtures / 'antigravity-quota.json')
    assert [group['id'] for group in quota['value']['groups']] == ['gemini', 'claude-gpt']
    assert [window['remainingPercent'] for group in quota['value']['groups'] for window in group['windows']] == [68, 42, 100, 0]
    assert tokens['status'] == 'ready' and tokens['source'] == 'codexBarLocal'
    assert tokens['value']['totalTokens'] == sum(tokens['value'][key] for key in (
        'inputTokens', 'cacheReadTokens', 'cacheCreationTokens', 'outputTokens', 'reasoningTokens')) == 1500
    assert not any('cost' in key.lower() for key in tokens['value'])

    # Local polling updates only token activity; a missing quota fixture proves
    # the online quota path is not entered on this refresh mode.
    changed_tokens = root / 'changed-tokens.json'
    write(changed_tokens, dict(totalTokens=15, inputTokens=1, cacheReadTokens=2,
        cacheCreationTokens=3, outputTokens=4, reasoningTokens=5, requestCount=1))
    local = run('--local-tokens', dict(ANTIGRAVITY_QUOTA_FIXTURE=str(root / 'missing-quota.json'),
        ANTIGRAVITY_TOKEN_FIXTURE=str(changed_tokens)))
    assert local['antigravityQuota'] == quota, 'Local polling modified online quota'
    assert local['antigravityTokens']['value']['totalTokens'] == 15
    for key in ('cursorCosts', 'cursorQuota', 'codexQuota', 'claudeQuota', 'claudeResetCards'):
        assert local[key] == baseline[key], 'Local polling changed ' + key

    # Dedicated Claude/Cursor operations must preserve positive Antigravity
    # fields without touching even an intentionally missing Antigravity fixture.
    preserved = anti(local)
    missing = dict(ANTIGRAVITY_QUOTA_FIXTURE=str(root / 'missing-quota.json'),
                   ANTIGRAVITY_TOKEN_FIXTURE=str(root / 'missing-tokens.json'))
    for flag in ('--claude-verify', '--cursor-only', '--cursor-authorize'):
        current = run(flag, missing)
        assert anti(current) == preserved, flag + ' changed independent Antigravity readings'

    # Hiding the service prevents both collectors and leaves prior data intact.
    write(settings, {'visibility': {'antigravity': 'hidden'}})
    hidden = run(overrides=missing)
    assert anti(hidden) == preserved, 'Hidden Antigravity attempted to refresh its missing fixtures'
    settings.unlink()

    # Independent collection errors cannot turn a valid counterpart stale.
    failed_quota = run(overrides={'ANTIGRAVITY_QUOTA_FIXTURE': str(root / 'missing-quota.json')})
    assert failed_quota['antigravityQuota']['status'] == 'stale'
    assert failed_quota['antigravityTokens']['status'] == 'ready'
    valid = run()
    failed_tokens = run(overrides={'ANTIGRAVITY_TOKEN_FIXTURE': str(root / 'missing-tokens.json')})
    assert failed_tokens['antigravityQuota']['status'] == 'ready'
    assert failed_tokens['antigravityTokens']['status'] == 'stale'
    assert failed_tokens['antigravityTokens']['value'] == valid['antigravityTokens']['value']

    # A failed refresh never extends the original quota measurement deadline.
    expired = copy.deepcopy(failed_tokens)
    old = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=1801)).strftime('%Y-%m-%dT%H:%M:%SZ')
    expired['antigravityQuota']['measuredAt'] = old
    write(output, expired)
    expired = run(overrides={'ANTIGRAVITY_QUOTA_FIXTURE': str(root / 'missing-quota.json')})
    assert expired['antigravityQuota']['status'] == 'unavailable'
    assert expired['antigravityQuota'].get('value') is None

print('Antigravity isolated integration passed (full/local/hidden/preservation/error/cache).')
PY
