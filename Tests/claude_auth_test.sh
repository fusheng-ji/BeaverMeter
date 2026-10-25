#!/bin/zsh
set -euo pipefail
collector="${1:?Pass the built BeaverMeterCollector path}"
project_dir="${0:A:h:h}"
python3 - "$collector" "$project_dir/Tests/Fixtures/claude-usage.json" <<'PY'
import copy, datetime, json, os, pathlib, signal, subprocess, sys, tempfile, time

collector, fixture = sys.argv[1:]
now = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
empty = dict(status='unavailable', source='none', lastAttemptAt=now, message='fixture')
seed = {key: copy.deepcopy(empty) for key in (
    'codexTokens', 'cursorCosts', 'cursorQuota', 'codexQuota', 'claudeTokens',
    'deepseekUsage', 'codexAccounts', 'codexHistory', 'claudeHistory')}
seed.update(schemaVersion=7, generatedAt=now)
seed['claudeQuota'] = dict(status='ready', source='accountAPI', measuredAt=now,
    lastAttemptAt=now, value=dict(label='Claude Week', remainingPercent=42,
    resetAt='2099-01-05T00:00:00Z', windowSeconds=604800, detail='42% left'))
seed['claudeResetCards'] = dict(status='ready', source='accountAPI', measuredAt=now,
    lastAttemptAt=now, value=dict(availableCount=2, observedAt=now, batches=[]))
preserved = [key for key in seed if key not in ('generatedAt', 'claudeQuota', 'claudeResetCards')]

def setup(root):
    root.mkdir()
    output = root / 'snapshot.json'
    output.write_text(json.dumps(seed))
    output.chmod(0o600)
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(('CLAUDE_', 'ANTHROPIC_'))}
    env.update(CLAUDE_CONFIG_DIR=str(root), CLAUDE_CLI_REFRESH='0', CLAUDE_KEYCHAIN_ACCESS='0',
               CLAUDE_CLI_PATH=str(root / 'missing-cli'))
    return output, env

def assert_snapshot(output, authenticated, failed_status='unauthenticated'):
    current = json.loads(output.read_text())
    for key in preserved:
        assert current[key] == seed[key], f'Claude operation changed {key}'
    for key in ('claudeQuota', 'claudeResetCards'):
        data = current[key]
        if authenticated:
            assert data['status'] == 'ready' and data.get('value') is not None, key
        else:
            assert data['status'] == failed_status and data['source'] == 'none', key
            assert data.get('value') is None, key

def run(output, env, mode):
    return subprocess.run([collector, mode, '--output', str(output)], env=env,
                          capture_output=True, text=True, timeout=30)

def write_cli(root, text):
    cli = root / 'fake-claude'
    cli.write_text('#!/bin/sh\n' + text + '\n')
    cli.chmod(0o700)
    return cli

with tempfile.TemporaryDirectory(prefix='beavermeter-claude-auth-') as directory:
    base = pathlib.Path(directory)
    output, env = setup(base / 'missing')
    result = run(output, env, '--claude-verify')
    assert result.returncode != 0
    assert_snapshot(output, False)

    output, env = setup(base / 'failed-login')
    root = output.parent
    (root / '.credentials.json').write_text('{"claudeAiOauth":{"accessToken":"synthetic"}}')
    cli = write_cli(root, 'rm -f "$CLAUDE_CONFIG_DIR/.credentials.json"\nprintf "private-output-sentinel" >&2\nexit 1')
    env['CLAUDE_CLI_PATH'] = str(cli)
    result = run(output, env, '--claude-login')
    assert result.returncode != 0
    assert 'private-output-sentinel' not in result.stdout + result.stderr
    assert_snapshot(output, False)

    output, env = setup(base / 'zero-exit')
    env['CLAUDE_CLI_PATH'] = str(write_cli(output.parent, 'exit 0'))
    result = run(output, env, '--claude-login')
    assert result.returncode != 0, 'CLI exit zero alone certified login'
    assert_snapshot(output, False)

    output, env = setup(base / 'verified')
    response = json.loads(pathlib.Path(fixture).read_text())
    response['cedar_ember'] = dict(eligible=True, grants=[])
    response_file = output.parent / 'usage-response.json'
    response_file.write_text(json.dumps(response))
    env['CLAUDE_USAGE_FIXTURE'] = str(response_file)
    result = run(output, env, '--claude-verify')
    assert result.returncode == 0, result.stderr
    assert_snapshot(output, True)
    result = run(output, env, '--claude-authorize')
    assert result.returncode == 0, result.stderr
    assert_snapshot(output, True)

    # A CLI ignoring SIGTERM must not survive cancellation of its owning helper.
    output, env = setup(base / 'cancel')
    root = output.parent
    pid_file = root / 'cli.pid'
    cli = write_cli(root, 'trap "" TERM\nprintf "%s" "$$" > "$CLAUDE_TEST_PID"\nexec /bin/sleep 90')
    env.update(CLAUDE_CLI_PATH=str(cli), CLAUDE_TEST_PID=str(pid_file))
    process = subprocess.Popen([collector, '--claude-login', '--output', str(output)],
                               env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    child_pid = None
    try:
        deadline = time.monotonic() + 5
        while not pid_file.exists() and time.monotonic() < deadline:
            time.sleep(.025)
        assert pid_file.exists(), 'fake login did not launch'
        child_pid = int(pid_file.read_text())
        started = time.monotonic()
        process.terminate()
        process.wait(timeout=1)
        assert time.monotonic() - started < 1
        try:
            os.kill(child_pid, 0)
        except ProcessLookupError:
            pass
        else:
            raise AssertionError('cancel left a login CLI running')
        # Cancellation does not read credentials again, so it cannot prove
        # sign-out. It still removes unverified cached quota and card values.
        assert_snapshot(output, False, failed_status='error')
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        if child_pid:
            try: os.kill(child_pid, signal.SIGKILL)
            except ProcessLookupError: pass
print('Claude auth command integration passed (6 isolated cases).')
PY
