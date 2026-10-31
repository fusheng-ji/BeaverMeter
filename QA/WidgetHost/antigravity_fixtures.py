#!/usr/bin/env python3
"""Wrap reviewed offline Antigravity snapshots for the isolated WidgetKit host.

No live snapshot, settings, account, collector or desktop operation is accessed.
The legacy 35-case matrix and its 560 pending observations are left untouched.
"""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
from pathlib import Path

from fixtures import atomic_json, json_bytes

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "screenshots/antigravity"
OUTPUT = ROOT / ".build/widget-antigravity-qa"
SCENARIOS = ("both-groups", "full-capacity", "unknown-and-zero", "reset-description", "spacing-stress")
PROVIDERS = ("codex", "claude", "cursor", "deepseek", "antigravity")
GROUPS = ("gemini", "claude-gpt")
MODULES = ["antigravity-group:" + group for group in GROUPS]
FAMILIES = {"small": 2, "medium": 4, "large": 6, "extra-large": 6}


def spacing_stress(snapshot: dict) -> dict:
    """Derived synthetic edge values; never changes the four reviewed source cases."""
    snapshot = copy.deepcopy(snapshot)
    prose = "Resets after the next scheduled weekly allocation window for this demonstration account"
    groups = snapshot["antigravityQuota"]["value"]["groups"]
    for group in groups:
        for window in group["windows"]:
            window.pop("resetAt", None)
            window["resetDescription"] = prose
            window["remainingPercent"] = (100 if group["id"] == "gemini" else
                0 if window.get("windowSeconds") == 18000 else None)
    account = snapshot["codexAccounts"]["value"][0]
    account["workspaceName"] = "Synthetic international research workspace with a deliberately long name"
    account["displayName"] = "qa@example.test · " + account["workspaceName"]
    account["planName"] = "Synthetic Enterprise Research Demonstration"
    quota = account["quota"]["value"]
    for window in [quota, *quota.get("windows", [])]:
        window["remainingPercent"] = None
        window["detail"] = "Synthetic unknown allowance, never a zero value"
        window.pop("resetAt", None)
        window["resetDescription"] = prose
    claude = snapshot["claudeQuota"]["value"]
    claude["planName"] = "Ultra"
    for window in [claude, *claude.get("windows", [])]:
        window["remainingPercent"] = 100
        window.pop("resetAt", None)
        window["resetDescription"] = prose
    cursor = snapshot["cursorQuota"]["value"]
    cursor.update(remaining=9_876_543_210.99, used=123_456_789.01, limit=10_000_000_000,
                  resetDescription=prose)
    cursor.pop("resetAt", None)
    snapshot["deepseekUsage"]["value"]["balances"] = [{"amount": 9_876_543_210.99, "currency": "CNY"}]
    return snapshot


def validate_snapshot(snapshot: dict) -> None:
    if snapshot.get("schemaVersion") != 8:
        raise ValueError("Antigravity QA requires an explicit schema-8 synthetic snapshot.")
    reading = snapshot.get("antigravityQuota", {})
    if reading.get("source") != "preview" or reading.get("status") != "ready":
        raise ValueError("Antigravity QA input must be an offline preview reading.")
    if [group["id"] for group in reading["value"]["groups"]] != list(GROUPS):
        raise ValueError("The two independent group identities differ from the reviewed fixtures.")

    def inspect(value):
        if isinstance(value, dict):
            for key, child in value.items():
                if key.lower() in {"access_token", "accesstoken", "refresh_token", "refreshtoken",
                                   "id_token", "idtoken", "cookie", "cookieheader", "password",
                                   "authorization", "sessiontoken"}:
                    raise ValueError("Credential fields are forbidden in synthetic QA input.")
                inspect(child)
        elif isinstance(value, list):
            for child in value:
                inspect(child)
    inspect(snapshot)


def expected_groups(snapshot: dict) -> list[dict]:
    result = []
    for group in snapshot["antigravityQuota"]["value"]["groups"]:
        known = [window for window in group["windows"] if window.get("remainingPercent") is not None]
        primary = min(known, key=lambda window: (window["remainingPercent"],
                      0 if window.get("windowSeconds") == 604800 else 1)) if known else {}
        percent = primary.get("remainingPercent")
        result.append({"id": "antigravity-group:" + group["id"],
                       "name": "Gemini" if group["id"] == "gemini" else "Claude/GPT",
                       "primaryPercent": percent,
                       "period": "Weekly" if primary.get("windowSeconds") == 604800 else
                           "5h" if primary.get("windowSeconds") == 18000 else "Quota",
                       "resetDescription": primary.get("resetDescription")})
    return result


def outputs() -> dict[Path, object]:
    preview_manifest = json.loads((SOURCE / "manifest.json").read_text())
    if preview_manifest.get("previewOnly") is not True:
        raise ValueError("Source manifest must explicitly identify offline previews.")
    records = []
    generated: dict[Path, object] = {}
    reference = None
    for scenario in SCENARIOS:
        source_scenario = "full-capacity" if scenario == "spacing-stress" else scenario
        source = SOURCE / (source_scenario + ".json")
        raw = source.read_bytes()
        snapshot = json.loads(raw)
        if scenario == "spacing-stress":
            snapshot = spacing_stress(snapshot)
        validate_snapshot(snapshot)
        reference = reference or snapshot["generatedAt"]
        if snapshot["generatedAt"] != reference:
            raise ValueError("All synthetic cases must share the frozen reference date.")
        selection = MODULES + (["codex-workspace:demo-personal", "service:claude", "service:cursor",
                                "service:deepseek"] if source_scenario == "full-capacity" else [])
        previews = [record for record in preview_manifest["records"] if record["scenario"] == source_scenario]
        coverage = {(record["family"], record["appearance"]) for record in previews}
        if coverage != {(family, theme) for family in FAMILIES for theme in ("light", "dark")}:
            raise ValueError("Source preview matrix lacks four-family/two-appearance coverage.")
        if len(previews) != 8 or any(record["selectedModuleIDs"] != selection for record in previews):
            raise ValueError("Source preview module selection differs from the reviewed module IDs.")
        case_id = "antigravity-" + scenario
        case = {"caseID": case_id, "snapshot": snapshot, "referenceDate": reference,
                "settings": {"visibility": {provider: "shown" if source_scenario == "full-capacity"
                             or provider == "antigravity" else "hidden" for provider in PROVIDERS}},
                "selectedModuleIDs": selection}
        filename = "cases/" + case_id + ".json"
        generated[OUTPUT / "fixtures" / filename] = case
        record = {"caseID": case_id, "file": filename,
                        "sha256": hashlib.sha256(json_bytes(case)).hexdigest(),
                        "sourceFixture": str(source.relative_to(ROOT)),
                        "sourceSHA256": hashlib.sha256(raw).hexdigest(),
                        "applicableFamilies": list(FAMILIES),
                        "selectedModuleIDs": selection, "expectedGroups": expected_groups(snapshot)}
        if scenario == "spacing-stress":
            record["derivedSyntheticScenario"] = "spacing-stress-v1"
            record["sourcePreviewIsStressEvidence"] = False
        records.append(record)
    manifest = {"schemaVersion": 1, "snapshotSchemaVersion": 8, "syntheticOnly": True,
                "referenceDate": reference, "caseCount": len(records), "cases": records}
    generated[OUTPUT / "fixtures/manifest.json"] = manifest
    observations = [{"caseID": record["caseID"], "family": family, "appearance": theme,
                     "status": "pending", "screenshot": None, "observedAt": None,
                     "actualRenderingMode": None, "desktopFocused": None,
                     "notes": None}
                    for record in records for family in FAMILIES for theme in ("light", "dark")]
    generated[OUTPUT / "report.template.json"] = {
        "schemaVersion": 1, "scope": "antigravity-native-widgetkit", "status": "pending",
        "syntheticOnly": True, "primaryCaseID": "antigravity-both-groups",
        "observationCount": len(observations), "observations": observations,
        "legacyMatrixUpdated": False}
    return generated


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("generate", "verify"))
    arguments = parser.parse_args()
    generated = outputs()
    for path, value in generated.items():
        if arguments.operation == "generate":
            atomic_json(path, value)
        elif path.read_bytes() != json_bytes(value):
            raise ValueError("Generated Antigravity QA file differs: " + str(path))
    action = "Generated" if arguments.operation == "generate" else "Verified"
    print(f"{action} five schema-8 Antigravity QA cases; 40 native observations remain pending.")


if __name__ == "__main__":
    main()
