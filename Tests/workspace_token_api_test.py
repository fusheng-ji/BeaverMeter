#!/usr/bin/env python3
"""Integrate the account-profile token API using temporary JWTs and fixtures only.

Run: python3 -B Tests/workspace_token_api_test.py --collector PATH/BeaverMeterCollector
The child environment is an explicit whitelist. No real credentials, network,
production snapshot, or provider configuration is used. Child output is never echoed.
"""

from __future__ import annotations

import argparse
import base64
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import tempfile

from workspace_token_test import (
    IntegrationFailure, accounts, append_records, metadata, quota_state, require,
    run_collector, usage, workspace_hash, write_json,
)


def jwt(payload: dict) -> str:
    def encode(value: dict) -> str:
        return base64.urlsafe_b64encode(json.dumps(value, sort_keys=True).encode()).decode().rstrip("=")
    return encode({"alg": "none", "typ": "JWT"}) + "." + encode(payload) + ".synthetic-signature"


def write_auth(home: Path, identity: str, now: datetime, *, access_claim: str | None = None) -> list[str]:
    def claims(scope: str) -> dict:
        return {"sub": "synthetic-user", "email": "fixture@example.test", "exp": int(now.timestamp()) + 86_400,
                "https://api.openai.com/auth": {"chatgpt_account_id": scope, "chatgpt_plan_type": "plus"}}
    access = jwt(claims(access_claim or identity))
    identity_token = jwt(claims(identity))
    refresh = "synthetic-refresh-never-export-" + identity
    write_json(home / "auth.json", {"tokens": {
        "access_token": access, "id_token": identity_token, "refresh_token": refresh, "account_id": identity}})
    return [access, identity_token, refresh]


def write_profile(directory: Path, identity: str, count: int, date: str) -> None:
    write_json(directory / (workspace_hash(identity) + ".json"), {
        "stats": {"daily_usage_buckets": [{"start_date": date, "tokens": count}],
                  "lifetime_tokens": count + 1000},
        "metadata": {"stats_as_of": date, "stats_error": None},
    })


def check_globals(snapshot: dict, today: int, history: int, label: str, secrets: list[str]) -> None:
    require(snapshot.get("schemaVersion") == 7, label + ": snapshot schema changed")
    require(snapshot.get("codexTokens", {}).get("value", {}).get("totalTokens") == today,
            label + ": global current-day counters changed incorrectly")
    require(snapshot.get("codexHistory", {}).get("value", {}).get("totals", {}).get("totalTokens") == history,
            label + ": global history counters changed incorrectly")
    require(all(field in snapshot for field in ("cursorCosts", "cursorQuota", "codexQuota", "claudeTokens",
                "claudeQuota", "deepseekUsage", "claudeHistory", "claudeResetCards")),
            label + ": unrelated snapshot fields missing")
    encoded = json.dumps(snapshot)
    require(not any(secret in encoded for secret in secrets), label + ": synthetic credential leaked into snapshot")


def check_activity(snapshot: dict, expected: dict[str, int], date: str, label: str) -> dict[str, dict]:
    rows = accounts(snapshot, label)
    result = {}
    for identity, count in expected.items():
        reading = rows[identity].get("tokenActivity", {})
        require(reading.get("status") == "ready" and reading.get("source") == "accountAPI",
                label + ": official token activity status or source differs")
        value = reading.get("value", {})
        require(value.get("workspaceAccountIDHash") == workspace_hash(identity),
                label + ": activity was attached to the wrong workspace")
        require(value.get("dailyUsage") == [{"date": date, "tokens": count}],
                label + ": dated API buckets were changed, filled, or mixed with local counters")
        require(value.get("statsAsOf") == date and value.get("lifetimeTokens") == count + 1000,
                label + ": API cutoff or lifetime count differs")
        require(set(value) == {"workspaceAccountIDHash", "dailyUsage", "lifetimeTokens", "statsAsOf"},
                label + ": unsupported token breakdown or session metrics invented")
        for local_field in ("tokens", "history"):
            require(rows[identity].get(local_field, {}).get("value") is None,
                    label + ": creator-only local records became request-account usage")
        result[identity] = reading
    return result


def integration(executable: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="beavermeter-workspace-token-api-test-", dir="/tmp") as temporary:
        root = Path(temporary).resolve()
        root.chmod(0o700)
        home_a, home_b = root / "home-a", root / "home-b"
        output, profiles = root / "output", root / "profile-fixtures"
        for folder in (home_a, home_b, output, profiles, root / "tmp", root / "cache", root / "config"):
            folder.mkdir(mode=0o700)
        now = datetime.now(timezone.utc).replace(microsecond=0)
        timestamp = now.isoformat().replace("+00:00", "Z")
        yesterday = (now - timedelta(days=1)).date().isoformat()
        earlier = (now - timedelta(days=2)).isoformat().replace("+00:00", "Z")
        secrets = write_auth(home_a, "a", now) + write_auth(home_b, "b", now)
        write_json(output / "beaver-meter-settings.json", {"visibility": {
            "codex": "shown", "claude": "hidden", "cursor": "hidden", "deepseek": "hidden"}})
        write_json(output / "beaver-meter-accounts.json", {
            "version": 1, "providers": [{"id": "codex", "codexProfileHomePaths": [str(home_b)]}],
            "codexWorkspaces": [
                {"home": str(home), "workspaceAccountID": identity, "workspaceLabel": "Workspace " + identity.upper()}
                for home, identity in ((home_a, "a"), (home_b, "b"))]})
        quota = root / "quota-fixture.json"
        # Each credential's own default account can use this quota shape without
        # an override. The API ledger's independent values must not alter it.
        write_json(quota, {"plan_type": "plus", "rate_limit": {
            "primary_window": {"used_percent": 10, "limit_window_seconds": 604800, "reset_after_seconds": 3600},
            "secondary_window": {"used_percent": 20, "limit_window_seconds": 18000, "reset_after_seconds": 1800}}})
        cards = root / "cards-fixture.json"
        write_json(cards, {"availableCount": 2, "observedAt": timestamp, "batches": []})
        legacy = root / "legacy-zero-fixture.json"
        write_json(legacy, {"totalTokens": 0, "inputTokens": 0, "cachedInputTokens": 0,
                            "outputTokens": 0, "reasoningTokens": 0, "sessionCount": 0})
        for identity, count in (("a", 111), ("b", 222)):
            write_profile(profiles, identity, count, yesterday)
        env = {
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(root), "CFFIXED_USER_HOME": str(root),
            "TMPDIR": str(root / "tmp") + "/", "XDG_CONFIG_HOME": str(root / "config"),
            "XDG_CACHE_HOME": str(root / "cache"), "TZ": "UTC", "LANG": "en_US.UTF-8",
            "CODEX_HOME": str(home_a), "CODEX_USAGE_FIXTURE": str(quota), "CODEX_RESET_CARDS_FIXTURE": str(cards),
            "CODEX_LEGACY_TOKEN_FIXTURE": str(legacy), "CODEX_TOKEN_CACHE_ROOT": str(root / "cache"),
            "CODEX_WORKSPACE_TOKENS_FIXTURE": str(profiles),
        }
        require(not any(key.startswith("CODEX_REMOTE") for key in env), "setup: remote source must be disabled")
        # Both local sessions intentionally share the ambient tree. Its global
        # today total remains 300 while the account API returns unrelated 111/222.
        session_a, session_b = "synthetic-api-session-a", "synthetic-api-session-b"
        log_a, log_b = home_a / "sessions/a.jsonl", home_a / "sessions/b.jsonl"
        append_records(log_a, [metadata(session_a, "a", timestamp), usage(session_a, "response-a", 100, timestamp)])
        append_records(log_b, [metadata(session_b, "b", timestamp), usage(session_b, "response-b", 200, timestamp)])

        full = run_collector(executable, root, env, local=False, label="API full refresh")
        baseline = check_activity(full, {"a": 111, "b": 222}, yesterday, "API full refresh")
        check_globals(full, 300, 300, "API full refresh", secrets)
        rows = accounts(full, "API full refresh")
        require(all(row["quota"]["status"] == "ready" and row["resetCards"]["status"] == "ready"
                    and row["resetCards"].get("value", {}).get("availableCount") == 2 for row in rows.values()),
                "API full refresh: independent quota or card reading failed")
        unchanged_quota = quota_state(full, "API full refresh")
        print("PASS API full refresh: independent accountAPI values retain their exact service date; global total 300")

        # A local-only refresh must preserve the published API reading rather
        # than reload changed fixtures or overwrite it with local Unknown.
        write_profile(profiles, "a", 333, yesterday)
        write_profile(profiles, "b", 444, yesterday)
        local = run_collector(executable, root, env, local=True, label="API local refresh")
        require(check_activity(local, {"a": 111, "b": 222}, yesterday, "API local refresh") == baseline,
                "API local refresh: published official reading was modified")
        check_globals(local, 300, 300, "API local refresh", secrets)
        require(quota_state(local, "API local refresh") == unchanged_quota, "API local refresh: quota or cards changed")
        print("PASS API local refresh: official readings survive local Unknown and are not fetched again")

        append_records(log_b, [usage(session_b, "response-b-earlier-day", 70, earlier)])
        appended = run_collector(executable, root, env, local=True, label="API earlier-day local refresh")
        require(check_activity(appended, {"a": 111, "b": 222}, yesterday, "API earlier-day local refresh") == baseline,
                "API earlier-day local refresh: local history leaked into the account API ledger")
        check_globals(appended, 300, 370, "API earlier-day local refresh", secrets)
        require(quota_state(appended, "API earlier-day local refresh") == unchanged_quota,
                "API earlier-day local refresh: quota or cards changed")
        print("PASS API earlier-day refresh: only global history changes; account dates and values stay independent")

        for identity, count in (("a", 111), ("b", 222)):
            write_profile(profiles, identity, count, yesterday)
        secrets += write_auth(home_a, "a", now, access_claim="b")
        mismatched = run_collector(executable, root, env, local=False, label="API JWT mismatch")
        mismatch_rows = accounts(mismatched, "API JWT mismatch")
        rejected = mismatch_rows["a"].get("tokenActivity", {})
        require(rejected.get("status") == "unauthenticated" and rejected.get("value") is None,
                "API JWT mismatch: unsafe identity retained or borrowed an API reading")
        check_activity(mismatched, {"b": 222}, yesterday, "API JWT mismatch")
        check_globals(mismatched, 300, 370, "API JWT mismatch", secrets)
        require(mismatch_rows["a"]["quota"]["status"] == "ready",
                "API JWT mismatch: token API failure polluted the separate quota reading")
        print("PASS API JWT mismatch: invalid account is rejected without stale or sibling usage; other account stays ready")
    print("PASS workspace token API CLI integration")


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
