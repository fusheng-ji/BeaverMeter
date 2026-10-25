#!/usr/bin/env python3
"""Private synthetic Widget QA case backend. No UI, AX, screenshots or collectors.

Start explicitly after reviewing the QA app and fixtures:
  python3 QA/WidgetHost/control_runner.py \
    --control .build/widget-desktop-qa/control \
    --app '.build/widget-desktop-qa/Build/Products/Debug/BeaverMeter QA.app' \
    --manifest .build/widget-desktop-qa/fixtures/manifest.json

Write request.json atomically in the control directory with
{"seq": 1, "caseID": "reference-four-rows"}. Read ack.json and require matching
seq/caseID and status == "applied" before inspecting the actual desktop via CUA.
Use strictly increasing nonnegative integer sequences, including after errors.
Create control/stop to exit. Remove that file before a later explicit restart.
This script never starts the GUI host, registers widgets, sends UI input, kills
processes, or accesses production configuration, snapshots or credentials.
"""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import time
from typing import Callable
import unittest


APP_ID = "com.jiwenbo.beavermeter.widgetqa"
EXTENSION_ID = APP_ID + ".widget"
EXECUTABLE_NAME = "BeaverMeter QA"
MAX_REQUEST_BYTES = 64 * 1024


class ControlError(ValueError):
    pass


def atomic_json(path: Path, value: dict) -> None:
    """Only the caller's control directory is used for transient/backend files."""
    fd, temporary_name = tempfile.mkstemp(prefix=".control-", suffix=".tmp", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def private_executable(app: Path) -> Path:
    app = app.resolve(strict=True)
    if not app.is_dir() or app.suffix != ".app":
        raise ControlError("--app must identify the reviewed private QA application bundle.")
    with (app / "Contents/Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    if info.get("CFBundleIdentifier") != APP_ID or info.get("CFBundleExecutable") != EXECUTABLE_NAME:
        raise ControlError("Refusing a bundle that is not the fixed private BeaverMeter QA app.")
    extension = app / "Contents/PlugIns/BeaverMeterWidgetQAExtension.appex"
    with (extension / "Contents/Info.plist").open("rb") as handle:
        extension_info = plistlib.load(handle)
    if extension_info.get("CFBundleIdentifier") != EXTENSION_ID:
        raise ControlError("Refusing an app without the fixed private QA extension identity.")
    executable = (app / "Contents/MacOS" / EXECUTABLE_NAME).resolve(strict=True)
    if executable.parent != app / "Contents/MacOS" or not executable.is_file() or not os.access(executable, os.X_OK):
        raise ControlError("The approved QA executable is missing or escapes its application bundle.")
    return executable


class CaseRegistry:
    def __init__(self, manifest: Path):
        manifest = manifest.resolve(strict=True)
        with manifest.open(encoding="utf-8") as handle:
            data = json.load(handle)
        if not isinstance(data, dict) or data.get("schemaVersion") != 1 or data.get("syntheticOnly") is not True:
            raise ControlError("Only the version-1 synthetic QA manifest is accepted.")
        cases_directory = manifest.parent / "cases"
        self.directory = cases_directory.resolve(strict=True)
        if self.directory != cases_directory or not self.directory.is_dir():
            raise ControlError("The fixtures/cases directory must not be redirected by a symlink.")
        self.records: dict[str, tuple[Path, str]] = {}
        for record in data.get("cases", []):
            if not isinstance(record, dict):
                raise ControlError("Manifest cases must be objects.")
            case_id, filename, digest = record.get("caseID"), record.get("file"), record.get("sha256")
            if not isinstance(case_id, str) or not case_id or case_id in self.records:
                raise ControlError("Manifest case identities must be nonempty and unique.")
            if not isinstance(filename, str) or Path(filename).is_absolute() or ".." in Path(filename).parts:
                raise ControlError("A manifest case path escapes fixtures/cases.")
            case_file = (manifest.parent / filename).resolve(strict=True)
            if not case_file.is_relative_to(self.directory) or not case_file.is_file():
                raise ControlError("A manifest case path escapes fixtures/cases.")
            if not isinstance(digest, str) or len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest):
                raise ControlError("A manifest case SHA256 is invalid.")
            self.records[case_id] = (case_file, digest)
        if not self.records or data.get("caseCount") != len(self.records):
            raise ControlError("The synthetic manifest case count is invalid.")

    def checked_path(self, case_id: str) -> Path:
        if case_id not in self.records:
            raise ControlError("caseID is not in the approved manifest whitelist.")
        path, expected = self.records[case_id]
        current = path.resolve(strict=True)
        if current != path or not current.is_relative_to(self.directory) or not current.is_file():
            raise ControlError("The case path no longer remains inside fixtures/cases.")
        raw = current.read_bytes()
        if hashlib.sha256(raw).hexdigest() != expected:
            raise ControlError("The synthetic case SHA256 no longer matches the manifest.")
        payload = json.loads(raw)
        if not isinstance(payload, dict) or payload.get("caseID") != case_id:
            raise ControlError("The synthetic file caseID differs from its manifest identity.")
        return current


def apply_with_qa(executable: Path, case_file: Path) -> None:
    # The fixed QA executable is the only child process this backend can launch.
    # In particular: no shell=True, shell command strings, open, kill or collector.
    result = subprocess.run([str(executable), "--apply", str(case_file)],
                            stdin=subprocess.DEVNULL, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "QA --apply failed.").strip()[-1200:]
        raise ControlError(f"QA --apply exited {result.returncode}: {detail}")


class ControlRunner:
    def __init__(self, control: Path, app: Path, manifest: Path,
                 executor: Callable[[Path, Path], None] = apply_with_qa):
        self.executable = private_executable(app)
        self.registry = CaseRegistry(manifest)
        self.executor = executor
        self.control = control.resolve()
        self.control.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.last_seq = -1
        self.last_case_id = ""
        state = self.control / "state.json"
        if state.exists():
            data = json.loads(state.read_text(encoding="utf-8"))
            if type(data.get("lastSeq")) is not int or data["lastSeq"] < 0 or not isinstance(data.get("caseID"), str):
                raise ControlError("The backend sequence state is invalid; inspect it before restarting.")
            self.last_seq, self.last_case_id = data["lastSeq"], data["caseID"]

    def acknowledge(self, seq: int, case_id: str, status: str, error: str | None = None) -> dict:
        ack = {"seq": seq, "caseID": case_id, "status": status}
        if error:
            ack["error"] = error
        atomic_json(self.control / "ack.json", ack)
        return ack

    def handle(self, raw: bytes) -> dict:
        seq, case_id = -1, ""
        try:
            if len(raw) > MAX_REQUEST_BYTES:
                raise ControlError("request.json exceeds the 64 KiB limit.")
            request = json.loads(raw)
            if not isinstance(request, dict):
                raise ControlError("request.json must be an object.")
            proposed_seq, proposed_id = request.get("seq"), request.get("caseID")
            if type(proposed_seq) is not int or proposed_seq < 0:
                raise ControlError("seq must be a nonnegative integer, not a boolean.")
            seq = proposed_seq
            if not isinstance(proposed_id, str) or not proposed_id:
                raise ControlError("caseID must be a nonempty manifest identity.")
            case_id = proposed_id
            if seq <= self.last_seq:
                ack_path = self.control / "ack.json"
                if seq == self.last_seq and case_id == self.last_case_id and ack_path.exists():
                    previous_ack = json.loads(ack_path.read_text(encoding="utf-8"))
                    if previous_ack.get("seq") == seq and previous_ack.get("caseID") == case_id:
                        return previous_ack
                raise ControlError("Sequence was already reserved or is stale; use a larger seq. It was not applied again.")
            # Reserve before invoking the child so a crash/restart cannot apply
            # the same sequence twice. Any failed valid sequence is consumed.
            atomic_json(self.control / "state.json", {"lastSeq": seq, "caseID": case_id})
            self.last_seq, self.last_case_id = seq, case_id
            fixture = self.registry.checked_path(case_id)
            # Recheck the fixed bundle identity immediately before invocation.
            self.executable = private_executable(self.executable.parents[2])
            self.executor(self.executable, fixture)
            return self.acknowledge(seq, case_id, "applied")
        except (OSError, ValueError, TypeError, KeyError, plistlib.InvalidFileException) as error:
            return self.acknowledge(seq, case_id, "error", str(error))

    def watch(self) -> None:
        lock_path = self.control / "runner.lock"
        with lock_path.open("a", encoding="utf-8") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise ControlError("Another control runner already owns this directory.") from error
            # Restore state only after owning the lock in case another runner
            # finished a request between this object's construction and lock.
            state = self.control / "state.json"
            if state.exists():
                saved = json.loads(state.read_text(encoding="utf-8"))
                self.last_seq, self.last_case_id = saved["lastSeq"], saved["caseID"]
            last_request_digest = None
            print(f"Private Widget QA control ready: {self.control}", flush=True)
            while not (self.control / "stop").exists():
                request_path = self.control / "request.json"
                try:
                    with request_path.open("rb") as request:
                        raw = request.read(MAX_REQUEST_BYTES + 1)
                except FileNotFoundError:
                    raw = None
                if raw is not None:
                    digest = hashlib.sha256(raw).digest()
                    if digest != last_request_digest:
                        self.handle(raw)
                        last_request_digest = digest
                time.sleep(0.2)


class ControlRunnerTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="widget-qa-control-self-test-")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.app = self.root / "BeaverMeter QA.app"
        (self.app / "Contents/MacOS").mkdir(parents=True)
        executable = self.app / "Contents/MacOS" / EXECUTABLE_NAME
        executable.write_text("synthetic self-test marker; never executed", encoding="utf-8")
        executable.chmod(0o700)
        self.write_plist(self.app / "Contents/Info.plist", {"CFBundleIdentifier": APP_ID, "CFBundleExecutable": EXECUTABLE_NAME})
        self.write_plist(self.app / "Contents/PlugIns/BeaverMeterWidgetQAExtension.appex/Contents/Info.plist",
                         {"CFBundleIdentifier": EXTENSION_ID})
        self.fixture = self.root / "fixtures/cases/allowed.json"
        self.fixture.parent.mkdir(parents=True)
        self.fixture.write_text(json.dumps({"caseID": "allowed"}), encoding="utf-8")
        self.manifest = self.root / "fixtures/manifest.json"
        self.manifest_data = {"schemaVersion": 1, "syntheticOnly": True, "caseCount": 1,
                              "cases": [{"caseID": "allowed", "file": "cases/allowed.json",
                                         "sha256": hashlib.sha256(self.fixture.read_bytes()).hexdigest()}]}
        self.save_manifest()
        self.calls = []
        self.runner = self.make_runner()

    @staticmethod
    def write_plist(path, value):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(plistlib.dumps(value))

    def save_manifest(self):
        self.manifest.write_text(json.dumps(self.manifest_data), encoding="utf-8")

    def make_runner(self):
        return ControlRunner(self.root / "control", self.app, self.manifest,
                             executor=lambda executable, fixture: self.calls.append((executable, fixture)))

    def request(self, seq, case_id="allowed"):
        return self.runner.handle(json.dumps({"seq": seq, "caseID": case_id}).encode())

    def test_negative_boolean_sequence_and_invalid_identity_never_apply(self):
        for sequence in [-1, True, "1"]:
            self.assertEqual(self.request(sequence)["status"], "error")
        self.assertEqual(self.request(1, "not-allowed")["status"], "error")
        self.assertEqual(self.calls, [])

    def test_sequence_applies_once_including_restart_and_stale_requests(self):
        self.assertEqual(self.request(2)["status"], "applied")
        self.assertEqual(self.request(2)["status"], "applied")
        self.runner = self.make_runner()
        self.assertEqual(self.request(2)["status"], "applied")
        self.assertEqual(self.request(1)["status"], "error")
        self.assertEqual(self.request(2, "different")["status"], "error")
        self.assertEqual(len(self.calls), 1)

    def test_changed_hash_never_applies(self):
        self.fixture.write_text(json.dumps({"caseID": "allowed", "changed": True}), encoding="utf-8")
        ack = self.request(1)
        self.assertEqual(ack["status"], "error")
        self.assertIn("SHA256", ack["error"])
        self.assertEqual(self.calls, [])

    def test_manifest_traversal_and_symlink_escape_are_rejected(self):
        outside = self.root / "outside.json"
        outside.write_text('{"caseID":"allowed"}', encoding="utf-8")
        self.manifest_data["cases"][0]["file"] = "../outside.json"
        self.save_manifest()
        with self.assertRaises(ControlError):
            self.make_runner()
        self.manifest_data["cases"][0]["file"] = "cases/escape.json"
        (self.fixture.parent / "escape.json").symlink_to(outside)
        self.save_manifest()
        with self.assertRaises(ControlError):
            self.make_runner()

    def test_real_application_identity_is_rejected(self):
        self.write_plist(self.app / "Contents/Info.plist",
                         {"CFBundleIdentifier": "com.jiwenbo.beavermeter", "CFBundleExecutable": EXECUTABLE_NAME})
        with self.assertRaises(ControlError):
            self.make_runner()
        self.assertEqual(self.calls, [])

    def test_redirected_cases_directory_is_rejected(self):
        redirected = self.root / "redirected-cases"
        self.fixture.parent.rename(redirected)
        self.fixture.parent.symlink_to(redirected, target_is_directory=True)
        with self.assertRaises(ControlError):
            self.make_runner()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--control", type=Path)
    parser.add_argument("--app", type=Path)
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--self-test", action="store_true", help="Use temporary synthetic files and a fake executor; never start the watcher/app")
    args = parser.parse_args()
    if args.self_test:
        result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(ControlRunnerTests))
        return 0 if result.wasSuccessful() else 1
    if not all((args.control, args.app, args.manifest)):
        parser.error("--control, --app and --manifest are required outside --self-test")
    try:
        ControlRunner(args.control, args.app, args.manifest).watch()
    except (OSError, ValueError, TypeError, KeyError, plistlib.InvalidFileException) as error:
        print(f"Widget QA control: {error}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 130
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
