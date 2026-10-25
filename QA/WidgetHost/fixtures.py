#!/usr/bin/env python3
"""Pure synthetic fixture helpers. The current CLI is module_fixtures.py.

The former 4/6/8/12 overflow generator is retired. These helpers never read
accounts, credentials, production snapshots or user settings.
"""
from __future__ import annotations
import copy
from datetime import datetime, timedelta
import json
import os
from pathlib import Path
import re
import tempfile

ROOT = Path(__file__).resolve().parents[2]
TEMPLATE = Path(__file__).resolve().parent / "Fixtures/reference-snapshot.json"
REFERENCE = "2026-09-22T12:00:00Z"
NOW = datetime.fromisoformat(REFERENCE.replace("Z", "+00:00"))
PROVIDERS = ("codex", "claude", "cursor", "deepseek")
STATUSES = {"ready", "stale", "unavailable", "unauthenticated", "error"}
SOURCES = {"codexBarLocal", "cursorDashboard", "accountAPI", "deepSeekPlatform", "cache", "preview", "none"}


def timestamp(seconds: int = 0) -> str:
    return (NOW + timedelta(seconds=seconds)).isoformat(timespec="seconds").replace("+00:00", "Z")


def json_bytes(value: object) -> bytes:
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2, allow_nan=False) + "\n").encode()


def read_json(path: Path) -> dict:
    return json.loads(path.read_text())


def atomic_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(prefix=f".{path.name}.", dir=path.parent, delete=False) as handle:
            temporary = Path(handle.name)
            handle.write(json_bytes(value))
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def reading(value: object | None, status: str = "ready", source: str = "preview",
            measured_offset: int | None = 0, message: str | None = None) -> dict:
    result = {"status": status, "source": source, "lastAttemptAt": REFERENCE}
    if value is not None:
        result["value"] = value
    if measured_offset is not None:
        result["measuredAt"] = timestamp(measured_offset)
    if message is not None:
        result["message"] = message
    return result


def weekly(provider: str, percent: float = 76, secondary: float = 99,
           reset_after: int = 6 * 86400 + 2 * 3600, plan: str | None = None) -> dict:
    label = "Codex" if provider == "codex" else "Claude"
    primary = {"label": f"{label} Week", "remainingPercent": percent,
               "resetAt": timestamp(reset_after), "windowSeconds": 604800,
               "detail": "Synthetic QA weekly allowance"}
    secondary_window = {"label": f"{label} 5h", "remainingPercent": secondary,
                        "resetAt": timestamp(4 * 3600 + 23 * 60), "windowSeconds": 18000,
                        "detail": "Synthetic QA five-hour allowance"}
    result = copy.deepcopy(primary)
    result["windows"] = [secondary_window, primary]
    if plan:
        result["planName"] = plan
    return result


def inventory(index: int) -> dict:
    return reading({"availableCount": index % 3 + 1, "observedAt": REFERENCE,
                    "batches": [{"id": f"qa-card-{index:02}", "count": index % 3 + 1,
                                 "startsAt": timestamp(-3600), "expiresAt": timestamp((index + 5) * 86400),
                                 "requiresLimit": False, "paused": False}]})


def make_snapshot(template: dict, workspace_count: int) -> dict:
    snapshot = copy.deepcopy(template)
    snapshot["schemaVersion"] = 7
    snapshot["generatedAt"] = REFERENCE
    accounts = []
    for index in range(workspace_count):
        number = index + 1
        name = f"Workspace {number}"
        plan = "Pro" if number % 2 else "Business"
        accounts.append({"id": f"qa-workspace-{number:02}", "homeID": f"qa-home-{number:02}",
                         "accountName": f"member-{number}@example.test", "workspaceName": name,
                         "displayName": f"member-{number}@example.test · {name}", "planName": plan,
                         "quota": reading(weekly("codex", percent=max(0, 100 - number * 7),
                                                 secondary=max(0, 100 - number * 3),
                                                 reset_after=(number + 1) * 86400)),
                         "resetCards": inventory(number)})
    snapshot["codexAccounts"] = reading(accounts)
    snapshot["codexQuota"] = copy.deepcopy(accounts[0]["quota"]) if accounts else reading(weekly("codex"))
    snapshot["claudeQuota"] = reading(weekly("claude", 74, 99, 3 * 86400 + 22 * 3600, "Claude Max 20x"))
    snapshot["claudeResetCards"] = inventory(20)
    snapshot["cursorQuota"] = reading({"planName": "Enterprise", "label": "Cursor Monthly",
                                       "used": 667.94, "limit": 790, "remaining": 122.06,
                                       "remainingPercent": 122.06 / 790 * 100,
                                       "resetAt": timestamp(8 * 86400 + 8 * 3600),
                                       "windowSeconds": 31 * 86400,
                                       "detail": "Synthetic QA monthly allowance; not an inferred subscription"})
    balance = snapshot["deepseekUsage"]["value"]
    balance["balances"] = [{"currency": "USD", "amount": 18.76}]
    snapshot["deepseekUsage"] = reading(balance)
    return snapshot


def settings(providers: tuple | list) -> dict:
    return {"visibility": {provider: "shown" if provider in providers else "hidden" for provider in PROVIDERS}}


def quota_windows(quota: dict):
    yield quota
    yield from quota.get("windows", [])


def source_state(data: dict) -> str:
    if data["status"] == "unauthenticated":
        return "warning"
    if data["status"] == "stale" or data["source"] == "cache":
        measured = datetime.fromisoformat(data.get("measuredAt", REFERENCE).replace("Z", "+00:00"))
        return "critical" if (NOW - measured).total_seconds() >= 10800 else "warning"
    return {"ready": "normal", "error": "critical", "unavailable": "warning"}[data["status"]]


def visible_claude(data: dict) -> dict:
    # Match the shared, measured-time visibility boundary, not wall-clock now.
    if data["status"] == "unauthenticated":
        return reading(None, "unauthenticated", "none", None)
    if data.get("value") is not None and data["source"] != "preview":
        measured = data.get("measuredAt")
        age = (NOW - datetime.fromisoformat(measured.replace("Z", "+00:00"))).total_seconds() if measured else 1800
        if age >= 1800:
            return reading(None, "unavailable", "none", None)
    return data


def validate_contract(case: dict) -> None:
    if set(case) != {"caseID", "snapshot", "settings", "referenceDate"}:
        raise ValueError("Case must use exactly the QA host contract keys.")
    if not re.fullmatch(r"[a-z0-9-]+", case["caseID"]):
        raise ValueError("Unsafe case identifier.")
    if case["referenceDate"] != REFERENCE or case["snapshot"]["schemaVersion"] != 7:
        raise ValueError("Unexpected frozen date or snapshot schema.")
    if set(case["settings"]["visibility"]) != set(PROVIDERS):
        raise ValueError("Every provider must have an explicit visibility switch.")
    if not all(value in ("shown", "hidden") for value in case["settings"]["visibility"].values()):
        raise ValueError("QA fixtures cannot use auto provider discovery.")

    def inspect(value):
        if isinstance(value, dict):
            if "status" in value and "source" in value:
                if value["status"] not in STATUSES or value["source"] not in SOURCES:
                    raise ValueError("Unknown UsageValue enum in fixture.")
            for key, child in value.items():
                if key.lower() in {"access_token", "accesstoken", "refresh_token", "refreshtoken", "id_token", "idtoken",
                                   "cookie", "cookieheader", "password", "authorization", "sessiontoken"}:
                    raise ValueError("Credential field is forbidden in a fixture.")
                inspect(child)
        elif isinstance(value, list):
            for child in value:
                inspect(child)
    inspect(case)
    json_bytes(case)
