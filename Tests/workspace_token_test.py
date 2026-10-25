#!/usr/bin/env python3
"""Verify creator-only logs never become request-account usage, using synthetic files only.

Usage: python3 -B Tests/workspace_token_test.py --collector PATH/BeaverMeterCollector
Every fixture, cache and output is removed with its TemporaryDirectory. The child
gets a fixed environment, no remote source, and fixtures for all Codex endpoints.
Collector output is captured and never echoed, including on failure.
No request-account evidence fields are invented: creator_account_id is only the
thread creator. Legacy creator-based snapshot readings must also be cleared.
"""

from __future__ import annotations

import argparse
import base64
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
from zoneinfo import ZoneInfo


class IntegrationFailure(Exception):
    pass


def require(condition: bool, label: str) -> None:
    if not condition:
        raise IntegrationFailure(label)


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.write_text(json.dumps(value, sort_keys=True) + "\n", encoding="utf-8")
    path.chmod(0o600)


def append_records(path: Path, records: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with path.open("a", encoding="utf-8") as output:
        for record in records:
            output.write(json.dumps(record, sort_keys=True) + "\n")
    path.chmod(0o600)


def metadata(session: str, workspace: str, timestamp: str) -> dict:
    return {
        "type": "session_meta", "timestamp": timestamp,
        "payload": {"id": session, "session_id": session, "creator_account_id": workspace},
    }


def usage(session: str, response: str, count: int, timestamp: str) -> dict:
    return {
        "type": "token_usage_record", "timestamp": timestamp,
        "payload": {
            "session_id": session, "thread_id": session, "response_id": response,
            "usage": {"input_tokens": count, "cached_input_tokens": 0,
                      "output_tokens": 0, "reasoning_output_tokens": 0},
        },
    }


def workspace_hash(identity: str) -> str:
    return hashlib.sha256(identity.encode("utf-8")).hexdigest()


def accounts(snapshot: dict, label: str) -> dict[str, dict]:
    rows = snapshot.get("codexAccounts", {}).get("value")
    require(isinstance(rows, list) and len(rows) == 2, label + ": expected two workspaces")
    result = {row.get("workspaceAccountIDHash"): row for row in rows}
    require(set(result) == {workspace_hash("a"), workspace_hash("b")},
            label + ": verified workspace identities missing or duplicated")
    return {identity: result[workspace_hash(identity)] for identity in ("a", "b")}


def parsed_date(text: str) -> datetime:
    return datetime.fromisoformat(text.replace("Z", "+00:00"))


def check_unknown_usage(snapshot: dict, global_total: int, label: str) -> dict[str, dict]:
    rows = accounts(snapshot, label)
    for row in rows.values():
        for field in ("tokens", "history"):
            reading = row.get(field, {})
            require(isinstance(reading, dict) and reading.get("status") == "unavailable",
                    label + ": creator-only account activity is not explicitly unknown")
            require(reading.get("value") is None,
                    label + ": thread creator was incorrectly treated as request-account evidence")
    require(snapshot.get("schemaVersion") == 7, label + ": snapshot schema changed")
    require(snapshot.get("codexTokens", {}).get("value", {}).get("totalTokens") == global_total,
            label + ": provider summary was not preserved")
    require(snapshot.get("codexHistory", {}).get("value", {}).get("totals", {}).get("totalTokens") == global_total,
            label + ": provider history was not preserved")
    require(all(key in snapshot for key in (
        "cursorCosts", "cursorQuota", "codexQuota", "claudeTokens", "claudeQuota",
        "deepseekUsage", "claudeHistory", "claudeResetCards")), label + ": unrelated snapshot fields missing")
    encoded = json.dumps(snapshot)
    require("synthetic-access-never-print" not in encoded and "synthetic-refresh-never-print" not in encoded,
            label + ": fixture credential leaked into snapshot")
    return rows


def seed_legacy_creator_cache(snapshot: dict, home: Path) -> dict:
    """Seed the previous algorithm's snapshot shape, never request evidence."""
    seeded = json.loads(json.dumps(snapshot))
    global_history = seeded["codexHistory"]["value"]
    zone_name = global_history["timeZoneIdentifier"]
    source_zone = ZoneInfo(zone_name)
    today = parsed_date(seeded["generatedAt"]).astimezone(source_zone).date()

    def totals(count: int) -> dict:
        return {"totalTokens": count, "inputTokens": count, "cachedInputTokens": 0,
                "outputTokens": 0, "reasoningTokens": 0, "sessionCount": 0 if count == 0 else 1}

    for identity, row in accounts(seeded, "legacy cache setup").items():
        # These intentionally wrong values reflect creator A100 / B320. They
        # are only a migration fixture; no current record proves that billing.
        count = 100 if identity == "a" else 320
        source_id = workspace_hash("\0".join([
            "workspace-records-v1", row["workspaceAccountIDHash"], str(home), "", "", "", zone_name,
        ]))
        common = {"status": "ready", "source": "codexBarLocal", "measuredAt": seeded["generatedAt"],
                  "lastAttemptAt": seeded["generatedAt"], "message": "Legacy creator-based cached usage."}
        row["tokens"] = dict(common, value=totals(count))
        days = [{"date": day["date"], "totals": totals(count if
                 parsed_date(day["date"]).astimezone(source_zone).date() == today else 0)}
                for day in global_history["days"]]
        row["history"] = dict(common, value={"sourceID": source_id, "timeZoneIdentifier": zone_name,
                                            "days": days, "totals": totals(count)})
    return seeded


def quota_state(snapshot: dict, label: str) -> dict:
    return {
        "summary": snapshot["codexQuota"],
        "accounts": {identity: {key: row[key] for key in ("quota", "resetCards")}
                     for identity, row in accounts(snapshot, label).items()},
    }


def global_signature(snapshot: dict) -> dict:
    # The collector's change guard ignores refreshed attempt/measurement timestamps.
    return {field: {key: snapshot[field].get(key) for key in ("status", "source", "message", "value")}
            for field in ("codexTokens", "codexHistory")}


def run_collector(executable: Path, root: Path, env: dict[str, str], *, local: bool, label: str) -> dict:
    output = root / "output" / "beaver-meter-snapshot.json"
    command = [str(executable), "--output", str(output)]
    if local:
        command.append("--local-tokens")
    try:
        result = subprocess.run(command, cwd=root, env=env, stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=90, check=False)
    except subprocess.TimeoutExpired as error:
        raise IntegrationFailure(label + ": collector timed out") from error
    require(result.returncode == 0, label + ": collector exited unsuccessfully")
    require(output.is_file(), label + ": collector did not write a snapshot")
    return json.loads(output.read_text(encoding="utf-8"))


def integration(executable: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="beavermeter-workspace-token-test-", dir="/tmp") as temporary:
        root = Path(temporary).resolve()
        root.chmod(0o700)
        home, output = root / "home", root / "output"
        timestamp = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
        for folder in (home, output, root / "tmp", root / "cache", root / "config"):
            folder.mkdir(mode=0o700)
        claims = {"email": "workspace-fixture@example.test", "https://api.openai.com/auth": {
            "chatgpt_account_id": "a", "chatgpt_plan_type": "pro"}}
        payload = base64.urlsafe_b64encode(json.dumps(claims).encode()).decode().rstrip("=")
        write_json(home / "auth.json", {"tokens": {
            "access_token": "synthetic-access-never-print", "refresh_token": "synthetic-refresh-never-print",
            "account_id": "a", "id_token": "synthetic." + payload + ".synthetic"}})
        write_json(output / "beaver-meter-settings.json", {"visibility": {
            "codex": "shown", "claude": "hidden", "cursor": "hidden", "deepseek": "hidden"}})
        write_json(output / "beaver-meter-accounts.json", {"version": 1, "providers": [], "codexWorkspaces": [
            {"home": str(home), "workspaceAccountID": identity, "workspaceLabel": "Workspace " + identity.upper()}
            for identity in ("a", "b")]})
        quota = root / "quota-fixture.json"
        write_json(quota, {"account_id": "a", "plan_type": "pro", "rate_limit": {
            "primary_window": {"used_percent": 10, "limit_window_seconds": 604800, "reset_after_seconds": 3600},
            "secondary_window": {"used_percent": 20, "limit_window_seconds": 18000, "reset_after_seconds": 1800}}})
        cards = root / "cards-fixture.json"
        write_json(cards, {"availableCount": 0, "observedAt": timestamp, "batches": []})
        legacy = root / "legacy-zero-fixture.json"
        write_json(legacy, {"totalTokens": 0, "inputTokens": 0, "cachedInputTokens": 0,
                            "outputTokens": 0, "reasoningTokens": 0, "sessionCount": 0})
        env = {
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(root), "CFFIXED_USER_HOME": str(root),
            "TMPDIR": str(root / "tmp") + "/", "XDG_CONFIG_HOME": str(root / "config"),
            "XDG_CACHE_HOME": str(root / "cache"), "TZ": "UTC", "LANG": "en_US.UTF-8",
            "CODEX_HOME": str(home), "CODEX_USAGE_FIXTURE": str(quota), "CODEX_RESET_CARDS_FIXTURE": str(cards),
            "CODEX_LEGACY_TOKEN_FIXTURE": str(legacy), "CODEX_TOKEN_CACHE_ROOT": str(root / "cache"),
        }
        require(not any(key.startswith("CODEX_REMOTE") for key in env), "setup: remote source must be disabled")
        session_a, session_b = "synthetic-session-a", "synthetic-session-b"
        log_a = home / "sessions" / "fixture-a.jsonl"
        log_b = home / "sessions" / "fixture-b.jsonl"
        append_records(log_a, [metadata(session_a, "a", timestamp), usage(session_a, "response-a", 100, timestamp)])
        append_records(log_b, [metadata(session_b, "b", timestamp), usage(session_b, "response-b", 200, timestamp)])

        full = run_collector(executable, root, env, local=False, label="full refresh")
        check_unknown_usage(full, 300, "full refresh")
        unchanged_quota = quota_state(full, "full refresh")
        print("PASS full refresh: creator-only records keep all workspace activity unknown; global total 300")

        append_records(log_b, [usage(session_b, "response-b-append", 70, timestamp)])
        local = run_collector(executable, root, env, local=True, label="local refresh")
        check_unknown_usage(local, 370, "local refresh")
        require(quota_state(local, "local refresh") == unchanged_quota, "local refresh: quota or cards changed")
        print("PASS local refresh: appended creator-only usage stays unknown; global total 370")

        unscoped = home / "sessions" / "fixture-unattributed.jsonl"
        unknown_session = "synthetic-session-unattributed"
        append_records(unscoped, [usage(unknown_session, "response-unattributed", 50, timestamp)])
        unknown = run_collector(executable, root, env, local=True, label="unattributed refresh")
        check_unknown_usage(unknown, 420, "unattributed refresh")
        require(quota_state(unknown, "unattributed refresh") == unchanged_quota,
                "unattributed refresh: quota or cards changed")
        print("PASS unattributed refresh: no account allocation; global total 420")

        # A creator label added later is still not request-account evidence.
        append_records(unscoped, [metadata(unknown_session, "b", timestamp)])
        attributed = run_collector(executable, root, env, local=True, label="metadata-only refresh")
        check_unknown_usage(attributed, 420, "metadata-only refresh")
        require(global_signature(attributed) == global_signature(unknown),
                "metadata-only refresh: global values unexpectedly changed")
        require(quota_state(attributed, "metadata-only refresh") == unchanged_quota,
                "metadata-only refresh: quota or cards changed")
        print("PASS metadata-only refresh: adding creator metadata never creates request-account usage")

        # Clearing only these invalid account readings must pass the fast-path
        # guard even though both provider-wide totals remain identical.
        seeded = seed_legacy_creator_cache(attributed, home)
        require(global_signature(seeded) == global_signature(attributed),
                "legacy cache setup: global values unexpectedly changed")
        require([row["tokens"]["value"]["totalTokens"] for row in accounts(seeded, "legacy cache setup").values()]
                == [100, 320], "legacy cache setup: invalid creator-based readings were not seeded")
        write_json(output / "beaver-meter-snapshot.json", seeded)
        cleared = run_collector(executable, root, env, local=True, label="legacy cache cleanup")
        check_unknown_usage(cleared, 420, "legacy cache cleanup")
        require(global_signature(cleared) == global_signature(seeded),
                "legacy cache cleanup: global values unexpectedly changed")
        require(quota_state(cleared, "legacy cache cleanup") == unchanged_quota,
                "legacy cache cleanup: quota or cards changed")
        print("PASS legacy cache cleanup: invalid creator-based workspace values cleared with global/quota/cards unchanged")
    print("PASS workspace collector CLI integration")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--collector", required=True, type=Path, help="Explicit path to the freshly built collector executable")
    args = parser.parse_args()
    try:
        executable = args.collector.resolve(strict=True)
        require(executable.is_file() and executable.name == "BeaverMeterCollector" and os.access(executable, os.X_OK),
                "setup: expected an executable built BeaverMeterCollector")
        integration(executable)
        return 0
    except IntegrationFailure as error:
        print("FAIL " + str(error))
    except (OSError, ValueError, KeyError, TypeError):
        print("FAIL synthetic fixture setup or snapshot contract")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
