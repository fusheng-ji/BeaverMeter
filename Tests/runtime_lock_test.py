#!/usr/bin/env python3
"""Verify real cross-process snapshot locking using only an isolated temporary home.

Usage: python3 -B Tests/runtime_lock_test.py --collector PATH/BeaverMeterCollector
The Python parent owns a genuine POSIX record lock. Both local-poll flags must
return successfully without replacing the snapshot or disturbing the owner.
A full refresh must wait, then finish once the owner releases the lock.
Every provider is disabled; no live credentials, sessions or network are used.
"""

from __future__ import annotations

import argparse
import fcntl
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import time


SKIPPED = "Local token refresh skipped: another refresh is already running.\n"


class Failure(Exception):
    pass


def require(condition: bool, label: str) -> None:
    if not condition:
        raise Failure(label)


def file_state(path: Path) -> tuple[bytes, int, int, int]:
    metadata = path.stat()
    return path.read_bytes(), metadata.st_mtime_ns, stat.S_IMODE(metadata.st_mode), metadata.st_ino


def run(executable: Path, output: Path, environment: dict[str, str], flag: str | None = None) -> subprocess.CompletedProcess:
    command = [str(executable), "--output", str(output)]
    if flag:
        command.append(flag)
    try:
        return subprocess.run(command, cwd=output.parent, env=environment, stdin=subprocess.DEVNULL,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10, check=False)
    except subprocess.TimeoutExpired as error:
        raise Failure("local poll waited for a held lock instead of skipping") from error


def probe_owner_still_holds_lock(path: Path, environment: dict[str, str]) -> None:
    # A separate interpreter is a separate process; POSIX locks acquired twice
    # inside the same XCTest/Python process would not test contention.
    code = """
import errno, fcntl, os, sys
with open(sys.argv[1], 'r+b') as lock:
    try:
        fcntl.lockf(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as error:
        sys.exit(0 if error.errno in (errno.EACCES, errno.EAGAIN) else 2)
    else:
        sys.exit(3)
"""
    result = subprocess.run([sys.executable, "-c", code, str(path)], env=environment,
                            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            timeout=5, check=False)
    require(result.returncode == 0, "another poll disturbed the process holding the lock")


def integration(executable: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="beavermeter-runtime-lock-", dir="/tmp") as temporary:
        root = Path(temporary).resolve()
        root.chmod(0o700)
        for name in ("output", "home", "tmp", "cache", "config"):
            (root / name).mkdir(mode=0o700)
        output = root / "output/beaver-meter-snapshot.json"
        settings = output.with_name("beaver-meter-settings.json")
        settings.write_text(json.dumps({"visibility": {provider: "hidden" for provider in (
            "codex", "claude", "cursor", "deepseek")}}) + "\n")
        settings.chmod(0o600)
        environment = {
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(root / "home"),
            "CFFIXED_USER_HOME": str(root / "home"), "TMPDIR": str(root / "tmp") + "/",
            "XDG_CACHE_HOME": str(root / "cache"), "XDG_CONFIG_HOME": str(root / "config"),
            "CODEX_HOME": str(root / "home/codex"), "CLAUDE_CONFIG_DIR": str(root / "home/claude"),
            "TZ": "UTC", "LANG": "en_US.UTF-8",
        }
        initial = run(executable, output, environment)
        require(initial.returncode == 0 and output.is_file(), "synthetic all-hidden setup failed")
        require(initial.stdout.decode() == str(output) + "\n", "normal full-refresh output changed")
        original = file_state(output)
        settings_original = file_state(settings)
        lock_path = output.with_suffix(output.suffix + ".lock")
        with lock_path.open("r+b") as owner:
            fcntl.lockf(owner, fcntl.LOCK_EX | fcntl.LOCK_NB)
            owner_inode = os.fstat(owner.fileno()).st_ino
            for flag in ("--codex-only", "--local-tokens"):
                started = time.monotonic()
                result = run(executable, output, environment, flag)
                elapsed = time.monotonic() - started
                require(result.returncode == 0, flag + ": busy poll did not return success")
                require(result.stdout.decode() == SKIPPED and not result.stderr,
                        flag + ": busy output contract changed")
                require(file_state(output) == original, flag + ": busy poll replaced or changed the snapshot")
                require(file_state(settings) == settings_original, flag + ": settings changed")
                require(lock_path.stat().st_ino == owner_inode, flag + ": lock file was replaced")
                probe_owner_still_holds_lock(lock_path, environment)
                print(f"PASS {flag}: skipped with the genuine cross-process lock still held ({elapsed:.3f}s)")

            process = subprocess.Popen([str(executable), "--output", str(output)], cwd=output.parent,
                                       env=environment, stdin=subprocess.DEVNULL,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                time.sleep(0.75)
                require(process.poll() is None, "full refresh skipped or failed instead of waiting")
                require(file_state(output) == original, "waiting full refresh changed the snapshot")
                probe_owner_still_holds_lock(lock_path, environment)
                fcntl.lockf(owner, fcntl.LOCK_UN)
                stdout, stderr = process.communicate(timeout=10)
                require(process.returncode == 0 and stdout.decode() == str(output) + "\n" and not stderr,
                        "full refresh failed after the owner released its lock")
            finally:
                # This is only our synthetic test child, never the installed app/helper.
                if process.poll() is None:
                    process.kill()
                    process.communicate(timeout=5)
        print("PASS full refresh: remained blocking and finished only after lock release")

        for flag in ("--codex-only", "--local-tokens"):
            result = run(executable, output, environment, flag)
            require(result.returncode == 0 and result.stdout.decode() == str(output) + "\n" and not result.stderr,
                    flag + ": later poll did not run normally after release")
        print("PASS released lock: subsequent local polls run normally")

        require(os.geteuid() != 0, "permission test requires an unprivileged user")
        before_permission_failure = file_state(output)
        lock_path.chmod(0o400)
        try:
            result = run(executable, output, environment, "--local-tokens")
            require(result.returncode != 0, "open EACCES was silently classified as a busy poll")
            require(SKIPPED.encode() not in result.stdout and b"Failed to refresh usage:" in result.stderr,
                    "filesystem permission failure lost its error result")
            require(file_state(output) == before_permission_failure, "permission failure changed the snapshot")
        finally:
            lock_path.chmod(0o600)
        print("PASS filesystem permission failure: reports an error without changing the snapshot")
    print("PASS isolated runtime lock CLI integration")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--collector", required=True, type=Path)
    arguments = parser.parse_args()
    try:
        executable = arguments.collector.resolve(strict=True)
        require(executable.name == "BeaverMeterCollector" and executable.is_file()
                and os.access(executable, os.X_OK), "expected an explicit built Collector executable")
        integration(executable)
        return 0
    except (Failure, OSError, subprocess.TimeoutExpired) as error:
        # Child output is captured, never echoed. No credentials are created or read.
        print("FAIL " + (str(error) if isinstance(error, Failure) else "synthetic filesystem or subprocess operation"))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
