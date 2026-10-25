#!/usr/bin/env python3
"""Frozen module-selection QA cases. Generates/verifies files only; never applies or opens UI."""

from __future__ import annotations

import argparse
import copy
from datetime import datetime, timedelta
import hashlib
import json
from pathlib import Path
import re
import sys
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

# Shared builders read only the checked-in synthetic source fixture.
import fixtures as synthetic

ROOT = Path(__file__).resolve().parents[2]
TEMPLATE = synthetic.TEMPLATE
OUTPUT = ROOT / ".build/widget-module-qa/fixtures"
CAPACITIES = {"small": 2, "medium": 4, "large": 6, "extra-large": 6}
PROVIDERS = synthetic.PROVIDERS
REFERENCE = synthetic.REFERENCE
NONE = "none"
PREFIX = "codex-workspace:"


def token_totals(total: int) -> dict:
    output = total // 5
    return {"totalTokens": total, "inputTokens": total - output, "cachedInputTokens": total // 10,
            "outputTokens": output, "reasoningTokens": output // 4, "sessionCount": 0 if total == 0 else 2}


def workspace_history(number: int) -> dict:
    values = [9100 * number, 15600 * number, 0, 12300 * number, 21800 * number, 6200 * number, 17350 * number]
    today = synthetic.NOW.replace(hour=0, minute=0, second=0)
    days = [{"date": (today + timedelta(days=index - 6)).isoformat(timespec="seconds").replace("+00:00", "Z"),
             "totals": token_totals(total)} for index, total in enumerate(values)]
    return synthetic.reading({"sourceID": f"synthetic-workspace-{number:02}", "timeZoneIdentifier": "GMT",
                              "days": days, "totals": token_totals(sum(values))})


def account_activity(number: int) -> dict:
    values = [9100, 15600, 0, 12300, 21800, 6200, 17350]
    last_day = synthetic.NOW.date() - timedelta(days=1)
    return synthetic.reading({
        "workspaceAccountIDHash": hashlib.sha256(f"synthetic-workspace:{number}".encode()).hexdigest(),
        "dailyUsage": [{"date": (last_day + timedelta(days=index - 6)).isoformat(), "tokens": value * number}
                       for index, value in enumerate(values)],
        "statsAsOf": last_day.isoformat(), "serviceGeneratedAt": REFERENCE}, source="accountAPI")


def make_snapshot(template: dict, workspace_count: int) -> dict:
    snapshot = synthetic.make_snapshot(template, workspace_count)
    for number, account in enumerate(snapshot["codexAccounts"].get("value", []), start=1):
        account["workspaceAccountIDHash"] = hashlib.sha256(f"synthetic-workspace:{number}".encode()).hexdigest()
        # Different legacy values prove that the API field wins, even when its
        # value is zero or unavailable. None of these values are parser output.
        account["tokens"] = synthetic.reading(token_totals(1_700_000 * number))
        account["history"] = workspace_history(number)
        account["tokenActivity"] = account_activity(number)
    # Deliberately keep the unrelated provider-wide readings from the frozen template.
    return snapshot


def daily_reading(data: dict | None) -> dict:
    data = data or synthetic.reading(None, "unavailable", "none", None)
    value = data.get("value")
    measured = datetime.fromisoformat(data["measuredAt"].replace("Z", "+00:00")) if data.get("measuredAt") else None
    if value is None and data["status"] == "ready" or (value and value.get("totalTokens", 0) < 0):
        return synthetic.reading(None, "unavailable", "none", None)
    if value is not None and data["source"] != "preview" and (measured is None or measured > synthetic.NOW
            or measured.astimezone(ZoneInfo("Europe/Berlin")).date() != synthetic.NOW.astimezone(ZoneInfo("Europe/Berlin")).date()):
        return synthetic.reading(None, "unavailable", "none", None)
    return data


def history_expectation(data: dict | None) -> dict:
    data = data or synthetic.reading(None, "unavailable", "none", None)
    history = data.get("value")
    try:
        zone_name = history["timeZoneIdentifier"] if history else "Europe/Berlin"
        zone = ZoneInfo(zone_name)
        valid_zone = history is not None
    except ZoneInfoNotFoundError:
        zone_name, zone, valid_zone = "Europe/Berlin", ZoneInfo("Europe/Berlin"), False
    measured = datetime.fromisoformat(data["measuredAt"].replace("Z", "+00:00")) if data.get("measuredAt") else None
    usable = history is not None and valid_zone and (data["source"] == "preview" or measured is not None and measured <= synthetic.NOW)
    usable = usable and data["status"] not in ("unavailable", "unauthenticated")
    state = synthetic.source_state(data)
    if not usable and (history is not None or data["status"] == "ready"):
        state = "warning"
    elif usable and data["source"] != "preview" and measured.astimezone(zone).date() != synthetic.NOW.astimezone(zone).date() and data["status"] != "stale" and data["source"] != "cache":
        state = synthetic.source_state({**data, "status": "stale", "source": "cache"})
    grouped: dict = {}
    for day in history.get("days", []) if usable else []:
        date = datetime.fromisoformat(day["date"].replace("Z", "+00:00"))
        if date <= synthetic.NOW:
            grouped.setdefault(date.astimezone(zone).date(), []).append(day["totals"]["totalTokens"])
    values = []
    today = synthetic.NOW.astimezone(zone).date()
    for offset in range(-6, 1):
        day_values = grouped.get(today + timedelta(days=offset), [])
        values.append(day_values[0] if day_values and len(set(day_values)) == 1 and min(day_values) >= 0 else None)
    if all(value is None for value in values) and data["status"] == "ready":
        state = "warning"
    return {"historyValues": values, "historyExpectedSeverity": state, "historyTimeZoneIdentifier": zone_name}


def account_activity_expectation(account: dict) -> dict:
    data = account["tokenActivity"]
    activity = data.get("value")
    days = (activity.get("dailyUsage") or []) if activity else []
    indexed = {}
    measured = datetime.fromisoformat(data["measuredAt"].replace("Z", "+00:00")) if data.get("measuredAt") else None
    invalid = False
    if activity is not None:
        invalid = (not account.get("workspaceAccountIDHash")
            or activity.get("workspaceAccountIDHash") != account.get("workspaceAccountIDHash")
            or activity.get("lifetimeTokens") is not None and activity["lifetimeTokens"] < 0
            or not days and activity.get("lifetimeTokens") is None
            or measured is None or measured > synthetic.NOW
            or data["source"] not in ("accountAPI", "cache", "preview"))
        for day in days:
            try:
                date = datetime.strptime(day["date"], "%Y-%m-%d").date()
                invalid = invalid or date.isoformat() != day["date"] or day["tokens"] < 0
                invalid = invalid or date in indexed and indexed[date] != day["tokens"]
                indexed[date] = day["tokens"]
            except (ValueError, KeyError):
                invalid = True
        invalid = invalid or data["status"] in ("unavailable", "unauthenticated")
    elif data["status"] == "ready":
        invalid = True
    if invalid:
        data = synthetic.reading(None, "unavailable", "none", None)
        activity, indexed = None, {}
    elif activity is not None and data["status"] == "ready" and (synthetic.NOW - measured).total_seconds() > 10800:
        data = {**data, "status": "stale", "source": "cache"}
    state = synthetic.source_state(data)
    history = None
    if indexed:
        latest = max(indexed)
        number, caption = indexed[latest], "tokens today"
        history = [indexed.get(latest + timedelta(days=offset)) for offset in range(-6, 1)]
    else:
        number = activity.get("lifetimeTokens") if activity else None
        caption = "tokens total" if number is not None else "tokens"
    return {"numericValue": number, "caption": caption, "expectedSeverity": state, "aggregationNote": None,
            "historyValues": history, "historyExpectedSeverity": state if history is not None else None,
            "historyTimeZoneIdentifier": None, "fetchedAtVisible": activity is not None and measured is not None}


def module_activity(snapshot: dict, item: dict, option: dict) -> dict:
    provider = item["provider"]
    if provider == "codex" and "tokenActivity" in option.get("account", {}):
        return account_activity_expectation(option["account"])
    if provider in ("codex", "claude"):
        account = option.get("account", {}) if provider == "codex" else {}
        data = daily_reading(account.get("tokens") if provider == "codex" else snapshot["claudeTokens"])
        history = account.get("history") if provider == "codex" else snapshot["claudeHistory"]
        return {"numericValue": data.get("value", {}).get("totalTokens"), "caption": "tokens today",
                "expectedSeverity": synthetic.source_state(data), "aggregationNote": None, **history_expectation(history)}
    if provider == "cursor":
        data = daily_reading(snapshot["cursorCosts"])
        value, caption = data.get("value", {}).get("todayCostUSD"), "actual charge today"
    else:
        data = snapshot["deepseekUsage"]
        totals = data.get("value", {})
        value = totals.get("monthTokens", totals.get("monthRequests"))
        caption = "tokens this month" if totals.get("monthTokens") is not None else "calls this month" if totals.get("monthRequests") is not None else "activity this month"
    return {"numericValue": value, "caption": caption, "expectedSeverity": synthetic.source_state(data),
            "aggregationNote": None, "historyValues": None, "historyExpectedSeverity": None, "historyTimeZoneIdentifier": None}


def workspace(number: int) -> str:
    return PREFIX + f"qa-workspace-{number:02}"


def options(snapshot: dict, providers: list[str]) -> list[dict]:
    accounts = snapshot["codexAccounts"].get("value", [])
    names = [a.get("workspaceName", a.get("displayName", "Workspace")).strip() for a in accounts]
    totals = {name.lower(): sum(other.lower() == name.lower() for other in names) for name in names}
    seen_names: dict[str, int] = {}
    result = []
    for provider in providers:
        if provider == "codex" and accounts:
            for account, name in zip(accounts, names):
                key = name.lower()
                seen_names[key] = seen_names.get(key, 0) + 1
                title = f"{seen_names[key]} · {name}" if totals[key] > 1 else name
                result.append({"id": PREFIX + account["id"], "provider": provider,
                               "name": title, "workspaceID": account["id"], "account": account})
        else:
            result.append({"id": "service:" + provider, "provider": provider,
                           "name": {"codex": "Codex", "claude": "Claude", "cursor": "Cursor", "deepseek": "DeepSeek"}[provider]})
    return result


def default_ids(snapshot: dict, providers: list[str]) -> list[str]:
    available = options(snapshot, providers)
    seen = set()
    first, extra = [], []
    for option in available:
        if option["provider"] not in seen:
            first.append(option["id"])
            seen.add(option["provider"])
        else:
            extra.append(option["id"])
    return (first + extra)[:6]


def expectations(contract: dict, family: str) -> dict:
    snapshot = contract["snapshot"]
    providers = [p for p in PROVIDERS if contract["settings"]["visibility"][p] == "shown"]
    available = {o["id"]: o for o in options(snapshot, providers)}
    selected = contract.get("selectedModuleIDs", default_ids(snapshot, providers))
    seen, items, activity_by_id = set(), [], {}
    for module_id in selected[:CAPACITIES[family]]:
        if module_id == NONE or module_id in seen:
            continue
        seen.add(module_id)
        option = available.get(module_id)
        missing_workspace = module_id.startswith(PREFIX) and bool(module_id[len(PREFIX):].strip()) and "codex" in providers
        legacy_missing = module_id == "service:codex" and "codex" in providers and bool(snapshot["codexAccounts"].get("value"))
        if option is None and not missing_workspace and not legacy_missing:
            continue
        unavailable = option is None
        if unavailable:
            option = {"id": module_id, "provider": "codex", "name": "Unavailable"}
            if missing_workspace:
                option["workspaceID"] = module_id[len(PREFIX):]
            data = synthetic.reading(None, "unavailable", "none", None)
            plan = None
        elif "account" in option:
            data = option["account"]["quota"]
            plan = option["account"].get("planName") or data.get("value", {}).get("planName")
        else:
            data = snapshot[{"codex": "codexQuota", "claude": "claudeQuota", "cursor": "cursorQuota", "deepseek": "deepseekUsage"}[option["provider"]]]
            if option["provider"] == "claude":
                data = synthetic.visible_claude(data)
            plan = data.get("value", {}).get("planName")
        quota = data.get("value", {})
        provider = option["provider"]
        secondary = next((w for w in quota.get("windows", []) if w.get("windowSeconds") in (18000, 604800)
                          and w.get("windowSeconds") != quota.get("windowSeconds")), None)
        numeric = quota.get("remaining") if provider == "cursor" else quota.get("remainingPercent")
        if provider == "deepseek":
            numeric = next((balance["amount"] for balance in quota.get("balances", [])), None)
        item = {key: option[key] for key in ("id", "provider", "name", "workspaceID") if key in option}
        item.update(planName=plan.strip() if isinstance(plan, str) and plan.strip() else None,
                    primaryNumericValue=numeric, primaryResetAt=quota.get("resetAt"),
                    primaryPeriod="Balance" if provider == "deepseek" else "Monthly" if provider == "cursor"
                    else "Weekly" if quota.get("windowSeconds") == 604800 else "5h" if quota.get("windowSeconds") == 18000 else "Quota",
                    secondaryNumericValue=secondary.get("remainingPercent") if secondary else None,
                    secondaryResetAt=secondary.get("resetAt") if secondary else None,
                    expectedSeverity=synthetic.source_state(data), expectedUnavailable=unavailable,
                    normalStatusIconVisible=False, expectedStatusIconVisible=synthetic.source_state(data) != "normal")
        items.append(item)
        if family in ("large", "extra-large"):
            activity_by_id[item["id"]] = module_activity(snapshot, item, option)
    activity = list(activity_by_id)
    # Density is the visible composition after slot truncation and filtering.
    # Four XL modules keep activity, but reserve the available height for quotas.
    allows_history = family == "extra-large" and len(items) != 4
    history = [item["id"] for item in items if activity_by_id.get(item["id"], {}).get("historyValues") is not None] if allows_history else []
    for item in items:
        item.update(activityVisible=item["id"] in activity, tokenHistoryVisible=item["id"] in history,
                    activity=activity_by_id.get(item["id"]))
    return {"maximumVisibleCards": CAPACITIES[family], "visibleCardCount": len(items),
            "isMultiWorkspace": sum("workspaceID" in item for item in items) > 1,
            "visibleItemIDs": [i["id"] for i in items], "visibleNames": [i["name"] for i in items],
            "visibleWorkspaceIDs": [i["workspaceID"] for i in items if "workspaceID" in i],
            "enabledProviders": providers, "overflowWorkspaceCount": 0, "overflowAnchorID": None,
            "items": items, "selectedSlotIDs": selected[:CAPACITIES[family]], "truncateBeforeFiltering": True,
            "activityVisible": bool(activity), "tokenHistoryVisible": bool(history),
            "activityModuleIDs": activity, "historyModuleIDs": history,
            "codexActivityPolicy": "workspace-only-no-global-fallback",
            "globalFooterVisible": False,
            "secondaryCountdownPolicy": "Hidden in Small; both windows expanded in other families when they fit.",
            "hiddenWidgetFields": ["resetCards", "resetCardExpiry", "cursorUsed", "cursorLimit", "automaticOverflow"]
                + (["dailyTokens"] if family in ("small", "medium") else [])
                + (["tokenHistory"] if not allows_history else [])}


def build_cases(template: dict) -> list[dict]:
    cases = []

    def add(case_id: str, selected: list[str] | None, snapshot: dict | None = None,
            providers: list | tuple = PROVIDERS, category: str = "module-selection", notes: str = "") -> None:
        contract = {"caseID": case_id, "snapshot": copy.deepcopy(snapshot or make_snapshot(template, 8)),
                    "settings": synthetic.settings(providers), "referenceDate": REFERENCE}
        if selected is not None:
            contract["selectedModuleIDs"] = selected
        cases.append({"contract": contract, "category": category, "notes": notes})

    add("default-six", None, notes="Unconfigured defaults reserve one module per service before extra workspaces.")
    order = [workspace(1), workspace(2), "service:claude", "service:cursor", "service:deepseek", workspace(3)]
    for count in range(1, 6):
        add(f"explicit-{count:02}", order[:count], category="explicit-count")
    priority = ["service:cursor", workspace(6), "service:claude", workspace(2), "service:deepseek", workspace(1)]
    add("ordered-six-priority", priority, notes="Also covers exactly six explicit modules; smaller families respect the first slots.")
    for mask in range(16):
        providers = [p for index, p in enumerate(PROVIDERS) if mask & (1 << index)]
        selected = [workspace(1) if p == "codex" else "service:" + p for p in providers]
        add(f"services-{mask:02}", selected, providers=providers, category="service-subset",
            notes="services-00 also covers explicit zero modules; never fall back to defaults.")
    add("no-auto-expand", [workspace(2)], make_snapshot(template, 20), notes="20 source accounts still produce one selected module.")
    add("missing-and-legacy", [PREFIX + "deleted", "service:codex", "service:claude", workspace(4), "service:cursor", "service:deepseek"],
        notes="Deleted workspace and legacy Codex service both remain Unavailable and occupy their original slots.")
    add("legacy-no-accounts", ["service:codex", "service:claude", "service:cursor", "service:deepseek"],
        make_snapshot(template, 0), notes="Legacy Codex service is valid only while no workspace records exist.")
    long = make_snapshot(template, 8)
    for account in long["codexAccounts"]["value"]:
        account["workspaceName"] = "Research workspace · Robotics, representation learning and distributed experiments"
        account["planName"] = "Business · Synthetic research subscription with an intentionally long label"
    long["claudeQuota"]["value"]["planName"] = "Claude Max 20x · Synthetic long label"
    long["cursorQuota"]["value"].update(planName="Enterprise · Synthetic long label", remaining=123456789.12)
    long["deepseekUsage"]["value"]["balances"] = [{"currency": "EUR", "amount": 9876543210.98}]
    long["cursorCosts"]["value"]["todayCostUSD"] = 1280000
    add("stress-long", order, long, notes="Duplicate long workspace names, long plans and long currency values; IDs remain distinct.")
    mixed = make_snapshot(template, 8)
    accounts = mixed["codexAccounts"]["value"]
    for window in synthetic.quota_windows(accounts[0]["quota"]["value"]):
        window["remainingPercent"] = 0
    for window in synthetic.quota_windows(accounts[1]["quota"]["value"]):
        window.pop("remainingPercent", None)
        window.pop("resetAt", None)
    mixed["cursorQuota"]["value"]["remaining"] = 0
    mixed["deepseekUsage"]["value"]["balances"] = []
    accounts[0]["tokens"] = synthetic.reading(token_totals(0))
    for day in accounts[0]["history"]["value"]["days"]:
        day["totals"] = token_totals(0)
    accounts[0]["history"]["value"]["totals"] = token_totals(0)
    for day in accounts[0]["tokenActivity"]["value"]["dailyUsage"]:
        day["tokens"] = 0
    # Legacy/missing workspace activity stays unknown beside a measured zero,
    # despite deliberately huge provider-wide readings.
    accounts[1].pop("tokens")
    accounts[1].pop("history")
    accounts[1].pop("tokenActivity")
    mixed["codexTokens"] = synthetic.reading(token_totals(9_999_999_999))
    for day in mixed["codexHistory"]["value"]["days"]:
        day["totals"] = token_totals(8_888_888_888)
    mixed["codexHistory"]["value"]["totals"] = token_totals(8_888_888_888 * 7)
    mixed["cursorCosts"]["value"]["todayCostUSD"] = 0
    mixed["claudeTokens"] = synthetic.reading(None, "unavailable", "none", None)
    accounts[2]["history"]["value"]["days"] = accounts[2]["history"]["value"]["days"][::2]
    accounts[2]["tokenActivity"]["value"]["dailyUsage"] = accounts[2]["tokenActivity"]["value"]["dailyUsage"][::2]
    add("stress-zero-unknown", order, mixed, notes="Workspace 1 measured zero and workspace 2 legacy/missing activity must never borrow huge global token/history readings; missing fields/days stay unknown.")
    failures = make_snapshot(template, 8)
    failures["codexAccounts"]["value"][0]["quota"].update(status="stale", source="cache", measuredAt=synthetic.timestamp(-600))
    failures["codexAccounts"]["value"][1]["quota"] = synthetic.reading(None, "unauthenticated", "none", None)
    failures["codexAccounts"]["value"][0]["tokens"].update(status="stale", source="cache", measuredAt=synthetic.timestamp(-600))
    failures["codexAccounts"]["value"][0]["history"].update(status="stale", source="cache", measuredAt=synthetic.timestamp(-600))
    failures["codexAccounts"]["value"][1]["tokens"] = synthetic.reading(None, "unauthenticated", "none", None)
    failures["codexAccounts"]["value"][1]["history"]["value"]["timeZoneIdentifier"] = "invalid/timezone"
    failures["codexAccounts"]["value"][0]["tokenActivity"].update(status="stale", source="cache", measuredAt=synthetic.timestamp(-600))
    failures["codexAccounts"]["value"][1]["tokenActivity"] = synthetic.reading(None, "unauthenticated", "none", None)
    failures["claudeQuota"] = synthetic.reading(None, "unauthenticated", "none", None)
    failures["cursorQuota"].update(status="stale", source="cache", measuredAt=synthetic.timestamp(-600))
    failures["codexTokens"].update(status="stale", source="cache", measuredAt=synthetic.timestamp(-600))
    failures["claudeTokens"].update(source="codexBarLocal", measuredAt=synthetic.timestamp(-86400))
    failures["cursorCosts"].update(source="cursorDashboard", measuredAt=synthetic.timestamp(-86400))
    failures["codexHistory"]["value"]["timeZoneIdentifier"] = "invalid/timezone"
    failures["deepseekUsage"] = synthetic.reading(None, "error", "none", None)
    add("stress-stale-login", order, failures, notes="Quota, current activity and history statuses remain independent.")
    add("slot-none", [NONE, workspace(1), "service:claude", "service:cursor", "service:deepseek", workspace(2)])
    add("slot-duplicate", [workspace(1), workspace(1), "service:claude", "service:cursor", "service:deepseek", workspace(2)])
    add("slot-hidden", ["service:cursor", workspace(2), "service:claude", "service:deepseek", workspace(1), workspace(3)],
        providers=["codex", "claude", "deepseek"], notes="Hidden first slot does not pull slot 3 into Small.")
    reordered = make_snapshot(template, 8)
    reordered["codexAccounts"]["value"].reverse()
    add("source-reordered", priority, reordered, notes="Compare ordered-six-priority: source account order changes but selected IDs do not.")
    stable = [workspace(1), "service:claude", "service:cursor", "service:deepseek"]
    add("stable-one", stable, make_snapshot(template, 1))
    add("stable-two", stable, make_snapshot(template, 2), notes="The same selected workspace ID survives the 1→2 account transition.")
    assert len(cases) == 35
    return cases


def validate(contract: dict) -> None:
    required = {"caseID", "snapshot", "settings", "referenceDate"}
    if not required <= set(contract) or set(contract) - required - {"selectedModuleIDs"}:
        raise ValueError("Unknown module QA contract keys")
    legacy = {key: value for key, value in contract.items() if key != "selectedModuleIDs"}
    synthetic.validate_contract(legacy)
    selected = contract.get("selectedModuleIDs")
    if selected is not None and (not isinstance(selected, list) or len(selected) > 6 or any(not isinstance(i, str) for i in selected)):
        raise ValueError("Explicit module slots must contain zero to six string IDs")


def generate(directory: Path) -> dict:
    if TEMPLATE.resolve() != (Path(__file__).resolve().parent / "Fixtures/reference-snapshot.json"):
        raise ValueError("Only the checked-in pure synthetic source fixture is accepted")
    template = synthetic.read_json(TEMPLATE)
    if template.get("generatedAt") != REFERENCE:
        raise ValueError("Synthetic source fixture date differs")
    if template["codexAccounts"]["source"] != "preview":
        raise ValueError("Synthetic template provenance is missing")
    records = []
    for entry in build_cases(template):
        contract = entry["contract"]
        validate(contract)
        path = f"cases/{contract['caseID']}.json"
        raw = synthetic.json_bytes(contract)
        synthetic.atomic_json(directory / path, contract)
        records.append({"caseID": contract["caseID"], "category": entry["category"], "notes": entry["notes"],
                        "file": path, "sha256": hashlib.sha256(raw).hexdigest(), "applicableFamilies": list(CAPACITIES),
                        "expectationsByFamily": {family: expectations(contract, family) for family in CAPACITIES}})
    manifest = {"schemaVersion": 1, "syntheticOnly": True, "referenceDate": REFERENCE, "caseCount": len(records),
        "cases": records, "capacities": CAPACITIES, "appearances": ["light", "dark"], "focusStates": ["focused", "unfocused"],
        "hostContract": {"requiredKeys": ["caseID", "snapshot", "settings", "referenceDate"],
                         "optionalKeys": ["selectedModuleIDs"], "snapshotSchemaVersion": 7, "dateEncoding": "ISO8601 UTC"},
        "moduleContract": {"noneID": NONE, "maximumModules": 6, "truncateBeforeFiltering": True,
                           "automaticExpansion": False, "automaticOverflow": False, "activityInsideModules": True,
                           "codexActivityPolicy": "workspace-only-no-global-fallback"},
        "provenance": {"template": str(TEMPLATE.relative_to(ROOT)), "templateSHA256": hashlib.sha256(TEMPLATE.read_bytes()).hexdigest(),
                       "generator": str(Path(__file__).relative_to(ROOT)), "productionDataRead": False},
        "supersedes": ".build/widget-desktop-qa/fixtures/manifest.json"}
    synthetic.atomic_json(directory / "manifest.json", manifest)
    rows = [{"caseID": r["caseID"], "family": f, "appearance": a, "focus": focus, "status": "pending", "screenshotPaths": []}
            for r in records for f in CAPACITIES for a in ("light", "dark") for focus in ("focused", "unfocused")]
    synthetic.atomic_json(directory.parent / "report.template.json", {"schemaVersion": 1, "status": "pending", "syntheticOnly": True,
        "referenceDate": REFERENCE, "manifestSHA256": hashlib.sha256(synthetic.json_bytes(manifest)).hexdigest(),
        "evidencePolicy": "Only actual WidgetKit host observations can pass. Generation/verification does not pass desktop acceptance.",
        "summary": {"total": len(rows), "pending": len(rows), "passed": 0, "failed": 0}, "records": rows})
    return manifest


def verify(directory: Path) -> dict:
    manifest = synthetic.read_json(directory / "manifest.json")
    assert manifest["schemaVersion"] == 1 and manifest["syntheticOnly"] is True
    assert manifest["capacities"] == CAPACITIES and manifest["caseCount"] == len(manifest["cases"]) == 35
    records = {r["caseID"]: r for r in manifest["cases"]}
    assert len(records) == 35
    for record in records.values():
        path = (directory / record["file"]).resolve()
        assert path.is_relative_to(directory / "cases")
        raw = path.read_bytes()
        assert hashlib.sha256(raw).hexdigest() == record["sha256"]
        contract = json.loads(raw)
        validate(contract)
        assert contract["caseID"] == record["caseID"] and record["applicableFamilies"] == list(CAPACITIES)
        for family, capacity in CAPACITIES.items():
            expected = expectations(contract, family)
            assert expected == record["expectationsByFamily"][family]
            assert expected["visibleCardCount"] <= capacity <= 6 and expected["overflowWorkspaceCount"] == 0
            allows_history = family == "extra-large" and expected["visibleCardCount"] != 4
            assert ("tokenHistory" in expected["hiddenWidgetFields"]) == (not allows_history)
            assert expected["historyModuleIDs"] == [
                item["id"] for item in expected["items"]
                if allows_history and item.get("activity") is not None
                and item["activity"]["historyValues"] is not None]
            assert expected["tokenHistoryVisible"] == bool(expected["historyModuleIDs"])
            assert all(item["tokenHistoryVisible"] == (item["id"] in expected["historyModuleIDs"])
                       for item in expected["items"])
            if family in ("large", "extra-large"):
                assert expected["activityModuleIDs"] == expected["visibleItemIDs"]
                assert all(i["activity"]["aggregationNote"] is None for i in expected["items"])
            else:
                assert not expected["activityModuleIDs"] and all(i["activity"] is None for i in expected["items"])
            assert expected["codexActivityPolicy"] == "workspace-only-no-global-fallback"
    for family, capacity in CAPACITIES.items():
        for count in range(7):
            case_id = "services-00" if count == 0 else "ordered-six-priority" if count == 6 else f"explicit-{count:02}"
            assert records[case_id]["expectationsByFamily"][family]["visibleCardCount"] == min(count, capacity)
    for case_id in ("slot-none", "slot-duplicate", "slot-hidden"):
        assert records[case_id]["expectationsByFamily"]["small"]["visibleCardCount"] == 1
    for count in range(1, 7):
        case_id = "ordered-six-priority" if count == 6 else f"explicit-{count:02}"
        xl = records[case_id]["expectationsByFamily"]["extra-large"]
        assert xl["activityVisible"] and xl["visibleCardCount"] == count
        assert xl["tokenHistoryVisible"] == (count != 4)
    # Selected slot count is not density: five slots can produce four modules,
    # while a None inside four selected slots can leave three visible modules.
    four = synthetic.read_json(directory / records["explicit-04"]["file"])
    five_slots = copy.deepcopy(four)
    five_slots["selectedModuleIDs"].insert(0, NONE)
    xl_four = expectations(five_slots, "extra-large")
    assert xl_four["visibleCardCount"] == 4 and not xl_four["tokenHistoryVisible"]
    three_visible = copy.deepcopy(four)
    three_visible["selectedModuleIDs"][1] = NONE
    xl_three = expectations(three_visible, "extra-large")
    assert xl_three["visibleCardCount"] == 3 and xl_three["tokenHistoryVisible"]
    assert all(records["no-auto-expand"]["expectationsByFamily"][f]["visibleCardCount"] == 1 for f in CAPACITIES)
    assert all(records["stable-one"]["expectationsByFamily"][f]["visibleItemIDs"] == records["stable-two"]["expectationsByFamily"][f]["visibleItemIDs"] for f in CAPACITIES)
    assert all(records["source-reordered"]["expectationsByFamily"][f]["visibleItemIDs"] == records["ordered-six-priority"]["expectationsByFamily"][f]["visibleItemIDs"] for f in CAPACITIES)
    assert all(i["expectedUnavailable"] and i["primaryNumericValue"] is None for i in records["missing-and-legacy"]["expectationsByFamily"]["small"]["items"])
    assert records["legacy-no-accounts"]["expectationsByFamily"]["small"]["items"][0]["expectedUnavailable"] is False
    zero_unknown = records["stress-zero-unknown"]["expectationsByFamily"]["extra-large"]["items"]
    assert zero_unknown[0]["activity"]["numericValue"] == 0
    assert zero_unknown[0]["activity"]["historyValues"] == [0] * 7
    assert zero_unknown[1]["activity"]["numericValue"] is None
    assert zero_unknown[1]["activity"]["historyValues"] == [None] * 7
    assert records["legacy-no-accounts"]["expectationsByFamily"]["large"]["items"][0]["activity"]["numericValue"] is None
    distinct = records["explicit-02"]["expectationsByFamily"]["large"]["items"]
    assert distinct[0]["activity"]["numericValue"] != distinct[1]["activity"]["numericValue"]
    assert all(f"services-{mask:02}" in records for mask in range(16))
    assert records["default-six"]["expectationsByFamily"]["large"]["visibleItemIDs"] == [
        workspace(1), "service:claude", "service:cursor", "service:deepseek", workspace(2), workspace(3)]
    report = synthetic.read_json(directory.parent / "report.template.json")
    assert len(report["records"]) == 560 and all(r["status"] == "pending" for r in report["records"])
    return manifest


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, default=OUTPUT)
    parser.add_argument("action", choices=("generate", "verify", "list"))
    args = parser.parse_args()
    directory = args.directory.resolve()
    if not directory.is_relative_to(ROOT / ".build"):
        parser.error("Output must stay under this repository's .build directory; production paths are not accepted")
    try:
        if args.action == "generate":
            generate(directory)
        manifest = verify(directory)
        if args.action == "list":
            print("\n".join(r["caseID"] for r in manifest["cases"]))
        else:
            print(f"Verified {manifest['caseCount']} synthetic module cases / 140 family expectations. All 560 desktop observations remain pending. {directory / 'manifest.json'}")
        return 0
    except (OSError, ValueError, KeyError, AssertionError) as error:
        print(f"Module fixture error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
