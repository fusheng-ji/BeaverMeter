#!/usr/bin/env python3
"""Summarize existing private WidgetKit spacing evidence, without desktop access.

Reads captures and NativeWidgetBounds JSON only. This script never captures,
applies cases, changes an observation's status or infers a visual-review pass.
"""
from __future__ import annotations

import argparse
import copy
from collections import Counter
from datetime import datetime, timezone
import hashlib
import html
import json
import math
import os
from pathlib import Path
import struct
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
DEFAULT_CAPTURE = ROOT / "screenshots/widget-spacing-native/2026-10-31/captures.json"
DEFAULT_MANIFEST = ROOT / ".build/widget-antigravity-qa/fixtures/manifest.json"
CASE_IDS = tuple("antigravity-" + name for name in (
    "both-groups", "full-capacity", "unknown-and-zero", "reset-description", "spacing-stress"))
FAMILIES = {"small": "systemSmall", "medium": "systemMedium", "large": "systemLarge", "extra-large": "systemExtraLarge"}
CAPACITY = {"small": 2, "medium": 4, "large": 6, "extra-large": 6}
THEMES = ("light", "dark")
LEVELS = {"full", "withoutActivityDetails", "withoutActivity", "withoutWindowReset", "withoutSubscription", "primaryOnly"}
GROUPS = ["antigravity-group:gemini", "antigravity-group:claude-gpt"]
FULL_MODULES = GROUPS + ["codex-workspace:demo-personal", "service:claude", "service:cursor", "service:deepseek"]
EPSILON = 0.000_001


def metadata(value):
    result = {}
    for piece in (value or "").split(";"):
        if ":" in piece:
            key, child = (part.strip() for part in piece.split(":", 1))
            if key and child:
                result[key] = child
    return result


def node_metadata(node):
    return metadata(node.get("label")) | metadata(node.get("value"))


def number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def rectangle(value):
    if not isinstance(value, dict) or any(not number(value.get(key)) for key in ("x", "y", "width", "height")):
        raise ValueError("Missing or non-finite actual rectangle")
    if value["width"] <= 0 or value["height"] <= 0:
        raise ValueError("Empty actual rectangle")
    return {key: float(value[key]) for key in ("x", "y", "width", "height")}


def edges(rect):
    return rect["x"], rect["y"], rect["x"] + rect["width"], rect["y"] + rect["height"]


def overflow(inner, outer):
    left, top, right, bottom = edges(inner)
    ol, ot, ore, ob = edges(outer)
    return {"left": max(0, ol - left), "top": max(0, ot - top),
            "right": max(0, right - ore), "bottom": max(0, bottom - ob)}


def close_rect(first, second, tolerance):
    return all(abs(first[key] - second[key]) <= tolerance + EPSILON for key in first)


def spacing_policy(family, count):
    outer = {"small": 10, "medium": 12, "large": 16, "extra-large": 16}[family]
    gap = {"small": 4, "medium": 6, "large": 8, "extra-large": 8}[family]
    horizontal = {"small": 12 if count == 1 else 8,
                  "medium": 12 if count == 1 else 10 if count <= 3 else 8,
                  "large": 16 if count == 1 else 12 if count <= 3 else 10,
                  "extra-large": 16 if count == 1 else 12}[family]
    vertical = {"small": 10 if count == 1 else 8, "medium": 10 if count <= 3 else 8,
                "large": 12 if count == 1 else 10 if count <= 3 else 8,
                "extra-large": 14 if count == 1 else 12 if count <= 4 else 10}[family]
    return {"outerPadding": outer, "cardGap": gap, "horizontal": horizontal, "vertical": vertical}


def row_sizes(family, count):
    columns = {"small": 1, "medium": count if count <= 3 else 2,
               "large": 1 if count <= 4 else 2,
               "extra-large": count if count <= 3 else 2 if count == 4 else 3}[family]
    return [min(columns, count - start) for start in range(0, count, columns)]


def safe_artifact(raw, capture_directory):
    if not isinstance(raw, str) or not raw:
        raise ValueError("Missing evidence path")
    candidate = Path(raw)
    if not candidate.is_absolute():
        candidate = ROOT / candidate if (ROOT / candidate).exists() else capture_directory / candidate
    candidate = candidate.resolve()
    if not candidate.is_relative_to(capture_directory.resolve()):
        raise ValueError("Evidence path is outside the isolated native capture directory")
    if not candidate.is_file():
        raise ValueError("Evidence file is missing: " + candidate.name)
    return candidate


def fingerprint(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def repository_path(path):
    return str(path.relative_to(ROOT)) if path.is_relative_to(ROOT) else str(path)


def png_dimensions(path):
    with path.open("rb") as source:
        header = source.read(24)
    if len(header) != 24 or header[:8] != b"\x89PNG\r\n\x1a\n" or header[12:16] != b"IHDR":
        raise ValueError("Screenshot has no PNG IHDR")
    width, height = struct.unpack(">II", header[16:24])
    if not width or not height:
        raise ValueError("Empty PNG")
    return width, height


def validate_manifest(path):
    manifest = json.loads(path.read_text())
    if manifest.get("syntheticOnly") is not True or manifest.get("snapshotSchemaVersion") != 8 or manifest.get("caseCount") != 5:
        raise ValueError("Expected the five-case synthetic schema-8 manifest")
    records = manifest.get("cases", [])
    if len(records) != 5 or {record.get("caseID") for record in records} != set(CASE_IDS):
        raise ValueError("The native spacing matrix must contain exactly the five approved cases")
    for record in records:
        expected = FULL_MODULES if record["caseID"] in {"antigravity-full-capacity", "antigravity-spacing-stress"} else GROUPS
        if record.get("selectedModuleIDs") != expected:
            raise ValueError("Unexpected module selection for " + record["caseID"])
        case_path = (path.parent / record["file"]).resolve()
        if not case_path.is_relative_to((path.parent / "cases").resolve()) or fingerprint(case_path) != record["sha256"]:
            raise ValueError("Synthetic case provenance/hash mismatch")
    return {record["caseID"]: record for record in records}


def validate_geometry(window, case, family, expected_ids, issues):
    """Recompute geometry from actual frames instead of trusting pass flags."""
    actual = window["actualWindow"]
    scale = actual.get("backingScale")
    if not number(scale) or scale < 1:
        raise ValueError("Missing actual display backing scale")
    tolerance = 1 / scale
    if actual.get("scaleSource") != "NSScreen.backingScaleFactor" or actual.get("isOnscreen") is not True:
        issues.append("Actual onscreen display/window provenance is missing")
    if not number(actual.get("tolerancePoints")) or abs(actual["tolerancePoints"] - tolerance) > EPSILON or actual.get("tolerancePhysicalPixels") != 1:
        issues.append("Bounds evidence does not use exactly one physical pixel tolerance")
    ax_frame = rectangle(actual.get("axFrame"))
    cg_frame = rectangle(actual.get("cgFrame"))
    if not close_rect(ax_frame, cg_frame, 2):
        issues.append("AX and CG window frames do not identify the same actual window")
    cards = case.get("cards", [])
    if [card.get("identifier") for card in cards] != ["WidgetQA.card." + item for item in expected_ids]:
        issues.append("Visible card order/count differs from the selected modules and capacity")
    if not cards:
        raise ValueError("No actual card frames")
    policy = spacing_policy(family, len(expected_ids))
    tree = case.get("visibleAXTree", [])
    by_id = {node.get("nodeID"): node for node in tree}
    if len(by_id) != len(tree):
        issues.append("Visible AX tree has duplicate node IDs")
    levels, sources, leaf_types = Counter(), Counter(), Counter()
    card_rows, all_leaves = [], []
    maximum_pixels = 0.0
    for card in cards:
        frame = rectangle(card.get("bounds"))
        if max(overflow(frame, cg_frame).values()) > tolerance + EPSILON:
            issues.append("Card is outside the actual CG window")
        card_node = by_id.get(card.get("nodeID"), {})
        if card_node.get("identifier") != card.get("identifier") or not close_rect(rectangle(card_node.get("bounds")), frame, tolerance):
            issues.append("Card frame/identity differs from the visible AX tree")
        insets = card.get("safeInsets", {})
        if any(not number(insets.get(key)) or abs(insets[key] - policy[key]) > EPSILON for key in ("horizontal", "vertical")):
            issues.append("Card safe insets differ from the fixed approved spacing policy")
            raise ValueError("Invalid safe inset metadata")
        safe = {"x": frame["x"] + insets["horizontal"], "y": frame["y"] + insets["vertical"],
                "width": frame["width"] - 2 * insets["horizontal"], "height": frame["height"] - 2 * insets["vertical"]}
        safe = rectangle(safe)
        if not close_rect(rectangle(card.get("safeRect")), safe, tolerance):
            issues.append("Reported safe rectangle differs from the measured card inset")
        leaves = card.get("leaves", [])
        logos = [leaf for leaf in leaves if leaf.get("identifier") == "WidgetQA.leaf.logo"]
        if len(logos) != 1 or not any(leaf.get("role") == "AXStaticText" or str(leaf.get("identifier", "")).startswith("WidgetQA.leaf.text") for leaf in leaves):
            issues.append("Card has no unique actual logo and text leaves")
        level, source = card.get("chosenDetailLevel"), card.get("chosenDetailLevelSource")
        if level not in LEVELS:
            issues.append("Card has no recognized selected detail level")
        if source == "visible-logo":
            if len(logos) != 1 or node_metadata(logos[0]).get("detailLevel") != level:
                issues.append("Selected level is not evidenced by one visible logo")
        elif source == "fit-group":
            fits = card.get("fitNodes", [])
            if len(fits) != 1 or node_metadata(fits[0]).get("detailLevel") != level:
                issues.append("Selected level is not evidenced by one fit group")
        else:
            issues.append("Missing actual selected-detail source")
        levels[str(level)] += 1
        sources[str(source)] += 1
        for leaf in leaves:
            leaf_frame = rectangle(leaf.get("bounds"))
            physical = {key: value * scale for key, value in overflow(leaf_frame, safe).items()}
            maximum_pixels = max(maximum_pixels, *physical.values())
            if max(physical.values()) > 1 + EPSILON or leaf.get("insideSafeRect") is not True:
                issues.append("Actual text/logo/status leaf exceeds the one-physical-pixel safe rectangle")
            reported = leaf.get("overflowPhysicalPixels", {})
            if any(not number(reported.get(key)) or abs(reported[key] - value) > EPSILON for key, value in physical.items()):
                issues.append("Reported leaf overflow differs from actual frame recomputation")
            actual_leaf = by_id.get(leaf.get("nodeID"), {})
            if actual_leaf.get("parentNodeID") != leaf.get("parentNodeID") or not close_rect(rectangle(actual_leaf.get("bounds")), leaf_frame, tolerance):
                issues.append("Leaf frame/parent differs from the visible AX tree")
            parent, visited = leaf.get("parentNodeID"), set()
            while parent is not None and parent not in visited:
                visited.add(parent)
                ancestor = by_id.get(parent, {})
                if str(ancestor.get("identifier", "")).startswith("WidgetQA.card."):
                    break
                parent = ancestor.get("parentNodeID")
            if parent != card.get("nodeID"):
                issues.append("Leaf does not belong to its nearest actual card ancestor")
            leaf_type = "logo" if leaf.get("identifier") == "WidgetQA.leaf.logo" else "status" if leaf.get("identifier") == "WidgetQA.leaf.status" else "text"
            leaf_types[leaf_type] += 1
            all_leaves.append(leaf)
        card_rows.append({"moduleID": card.get("identifier", "").removeprefix("WidgetQA.card."),
                          "bounds": frame, "safeRect": safe, "leafCount": len(leaves),
                          "chosenDetailLevel": level, "chosenDetailLevelSource": source})
    # Adjacent card boundaries directly measure gaps; no inferred Widget edge.
    rows = []
    for card in sorted(card_rows, key=lambda item: (item["bounds"]["y"], item["bounds"]["x"])):
        if rows and abs(rows[-1][0]["bounds"]["y"] - card["bounds"]["y"]) <= tolerance + EPSILON:
            rows[-1].append(card)
        else:
            rows.append([card])
    if [len(row) for row in rows] != row_sizes(family, len(expected_ids)):
        issues.append("Actual card rows differ from the approved family/count layout")
    gaps = []
    for row in rows:
        row.sort(key=lambda card: card["bounds"]["x"])
        for left, right in zip(row, row[1:]):
            gap = right["bounds"]["x"] - edges(left["bounds"])[2]
            gaps.append({"axis": "horizontal", "points": gap})
    for upper, lower in zip(rows, rows[1:]):
        gap = min(card["bounds"]["y"] for card in lower) - max(edges(card["bounds"])[3] for card in upper)
        gaps.append({"axis": "vertical", "points": gap})
    if any(abs(gap["points"] - policy["cardGap"]) > tolerance + EPSILON for gap in gaps):
        issues.append("Actual adjacent card gap differs from the fixed spacing policy")
    union = {"x": min(card["bounds"]["x"] for card in card_rows), "y": min(card["bounds"]["y"] for card in card_rows)}
    union["width"] = max(edges(card["bounds"])[2] for card in card_rows) - union["x"]
    union["height"] = max(edges(card["bounds"])[3] for card in card_rows) - union["y"]
    uleft, utop, uright, ubottom = edges(union)
    wl, wt, wr, wb = edges(cg_frame)
    return {"windowID": actual.get("id"), "actualWindowFrame": cg_frame, "backingScale": scale,
            "tolerancePhysicalPixels": 1, "cardCount": len(cards), "leafCount": len(all_leaves),
            "leafTypes": dict(leaf_types), "detailLevels": dict(levels), "detailLevelSources": dict(sources),
            "maxLeafOverflowPhysicalPixels": maximum_pixels, "expectedSpacingPolicy": policy,
            "actualCardRows": [len(row) for row in rows], "actualAdjacentGaps": gaps, "cards": card_rows,
            "observedCGWindowToCardUnionInsets": {"left": uleft - wl, "top": utop - wt, "right": wr - uright, "bottom": wb - ubottom},
            "outerPaddingValidation": "not-inferred: CG window includes system shadow; no independently measured visual Widget edge"}


def validate_capture(capture, record, capture_directory):
    case_id, family, appearance = capture["caseID"], capture["family"], capture["appearance"]
    issues, artifacts = [], {}
    result = {"caseID": case_id, "family": family, "appearance": appearance,
              "observedAt": capture.get("observedAt"), "visualReviewStatus": "not-evaluated"}
    try:
        for key in ("screenshot", "desktopScreenshot", "accessibility", "boundsEvidence"):
            path = safe_artifact(capture.get(key), capture_directory)
            artifacts[key] = {"path": repository_path(path), "sha256": fingerprint(path)}
        result["artifacts"] = artifacts
        evidence = json.loads(safe_artifact(capture["boundsEvidence"], capture_directory).read_text())
        if evidence.get("scope") != "private-widgetkit-qa-bounds" or evidence.get("kind") != "BeaverMeterWidgetQA" or evidence.get("readOnly") is not True or evidence.get("status") != "passed":
            issues.append("Bounds report does not establish a passed private read-only native observation")
        windows = evidence.get("windows", [])
        if len(windows) != 1:
            raise ValueError("Expected exactly one actual QA window in the bounds evidence")
        window = windows[0]
        if window.get("title") != "BeaverMeter QA" or window.get("status") != "passed" or window.get("violations"):
            issues.append("Actual private QA window has unresolved bounds violations")
        cases = window.get("cases", [])
        if len(cases) != 1 or cases[0].get("caseID") != case_id:
            raise ValueError("Actual visible case differs from the capture record")
        case = cases[0]
        expected_environment = {"kind": "BeaverMeterWidgetQA", "family": FAMILIES[family],
                                "colorScheme": appearance, "widgetRenderingMode": "fullColor"}
        capture_environment = metadata(capture.get("actualEnvironment"))
        for source in (case.get("environment", {}), node_metadata(case.get("node", {})), capture_environment):
            if any(source.get(key) != value for key, value in expected_environment.items()):
                issues.append("Actual private kind/family/appearance/fullColor metadata does not match")
        if capture_environment.get("QA caseID") != case_id or case.get("node", {}).get("identifier") != "WidgetQA.case." + case_id:
            issues.append("Actual private case identity is missing")
        if capture.get("desktopFocused") is not True:
            issues.append("Desktop-focused matrix observation is not confirmed")
        expected_ids = record["selectedModuleIDs"][:CAPACITY[family]]
        geometry = validate_geometry(window, case, family, expected_ids, issues)
        result["geometry"] = geometry
        if capture.get("windowID") != geometry["windowID"] or not close_rect(rectangle(capture.get("bounds")), geometry["actualWindowFrame"], 1 / geometry["backingScale"]):
            issues.append("Capture and bounds evidence do not reference the same actual window frame")
        width, height = png_dimensions(safe_artifact(capture["screenshot"], capture_directory))
        frame = geometry["actualWindowFrame"]
        if abs(width - frame["width"] * geometry["backingScale"]) > 1 or abs(height - frame["height"] * geometry["backingScale"]) > 1:
            issues.append("Actual-window PNG dimensions differ from the measured window at its backing scale")
        result["screenshotPixels"] = {"width": width, "height": height}
        png_dimensions(safe_artifact(capture["desktopScreenshot"], capture_directory))
    except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError) as error:
        issues.append(str(error))
    result["issues"] = list(dict.fromkeys(issues))
    result["geometryStatus"] = "passed" if not issues else "failed"
    return result


def summarize(captures_path, manifest_path):
    approved = validate_manifest(manifest_path)
    raw = captures_path.read_bytes()
    captures = json.loads(raw)
    if not isinstance(captures, list):
        raise ValueError("captures.json must be a capture-record array")
    expected = {(case, family, theme) for case in CASE_IDS for family in FAMILIES for theme in THEMES}
    seen, results, invalid = Counter(), [], []
    for capture in captures:
        if not isinstance(capture, dict):
            invalid.append("Non-object capture record")
            continue
        key = tuple(capture.get(field) for field in ("caseID", "family", "appearance"))
        if key not in expected:
            invalid.append("Unexpected capture matrix key: " + repr(key))
            continue
        seen[key] += 1
        results.append(validate_capture(capture, approved[key[0]], captures_path.parent))
    duplicates = [{"caseID": key[0], "family": key[1], "appearance": key[2], "count": count}
                  for key, count in seen.items() if count != 1]
    missing = [{"caseID": case, "family": family, "appearance": theme}
               for case in CASE_IDS for family in FAMILIES for theme in THEMES if (case, family, theme) not in seen]
    geometry_failures = sum(result["geometryStatus"] != "passed" for result in results)
    complete = len(captures) == 40 and not missing and not duplicates and not invalid
    geometry_passed = complete and not geometry_failures
    level_counts, source_counts, leaf_types = Counter(), Counter(), Counter()
    card_count = leaf_count = 0
    for result in results:
        geometry = result.get("geometry", {})
        card_count += geometry.get("cardCount", 0)
        leaf_count += geometry.get("leafCount", 0)
        level_counts.update(geometry.get("detailLevels", {}))
        source_counts.update(geometry.get("detailLevelSources", {}))
        leaf_types.update(geometry.get("leafTypes", {}))
    return {"schemaVersion": 1, "scope": "native-widget-spacing-validation", "syntheticOnly": True,
            "generatedAt": datetime.now(timezone.utc).isoformat(),
            "status": "geometry-complete" if geometry_passed else "failed-geometry" if geometry_failures or invalid or duplicates else "pending-native-captures",
            "geometryStatus": "passed" if geometry_passed else "failed" if geometry_failures or invalid or duplicates else "pending",
            "visualReview": {"status": "not-evaluated", "source": None,
                             "note": "Visual review is recorded separately; never inferred from geometry, capture status or gallery generation."},
            "captures": {"path": repository_path(captures_path), "sha256": hashlib.sha256(raw).hexdigest()},
            "fixtureManifest": {"path": repository_path(manifest_path), "sha256": fingerprint(manifest_path)},
            "expectedObservationCount": 40, "capturedObservationCount": len(captures),
            "uniqueExpectedObservationCount": len(seen), "geometryPassedObservationCount": len(results) - geometry_failures,
            "geometryFailedObservationCount": geometry_failures, "missing": missing, "duplicates": duplicates, "invalidRecords": invalid,
            "totalCards": card_count, "totalLeaves": leaf_count, "leafTypes": dict(leaf_types),
            "detailLevels": dict(level_counts), "detailLevelSources": dict(source_counts),
            "maxLeafOverflowPhysicalPixels": max((result.get("geometry", {}).get("maxLeafOverflowPhysicalPixels", 0) for result in results), default=0),
            "outerPaddingStatus": "not measured against a visual Widget edge; CG-window margins are recorded without subtracting an assumed shadow",
            "observations": results}


def gallery(report, output_directory):
    def link(path):
        absolute = Path(path) if Path(path).is_absolute() else ROOT / path
        return html.escape(os.path.relpath(absolute, output_directory), quote=True)

    records = {(record["caseID"], record["family"], record["appearance"]): record for record in report["observations"]}
    captures_path = Path(report["captures"]["path"])
    if not captures_path.is_absolute():
        captures_path = ROOT / captures_path
    sections = []
    for case in CASE_IDS:
        tiles = []
        for family in FAMILIES:
            for theme in THEMES:
                record = records.get((case, family, theme))
                label = html.escape(f"{family} · {theme}")
                if record is None:
                    tiles.append(f'<article><h3>{label}</h3><p class="pending">Native capture pending</p></article>')
                    continue
                artifacts = record.get("artifacts", {})
                image = artifacts.get("screenshot", {}).get("path")
                preview = (f'<a href="{link(image)}"><img loading="lazy" src="{link(image)}" alt="Actual desktop WidgetKit capture: {html.escape(case)} {label}"></a>' if image else '<p>Window PNG unavailable</p>')
                links = " · ".join(f'<a href="{link(artifacts[key]["path"])}">{name}</a>' for key, name in (
                    ("screenshot", "Actual window"), ("desktopScreenshot", "Desktop region"),
                    ("boundsEvidence", "Bounds JSON"), ("accessibility", "AX JSON")) if key in artifacts)
                geometry = record.get("geometry", {})
                details = html.escape(f'{geometry.get("cardCount", 0)} cards · {geometry.get("leafCount", 0)} leaves · max overflow {geometry.get("maxLeafOverflowPhysicalPixels", 0):g} physical px')
                levels = html.escape(", ".join(f"{key}: {value}" for key, value in geometry.get("detailLevels", {}).items()))
                problems = "".join(f"<li>{html.escape(issue)}</li>" for issue in record.get("issues", []))
                tiles.append(f'<article><h3>{label}</h3>{preview}<p><strong>Geometry: {record["geometryStatus"]}</strong> · Visual review is recorded separately</p><p>{details}<br>{levels}</p><p>{links}</p>' + (f'<ul class="failed">{problems}</ul>' if problems else "") + '</article>')
        sheet = captures_path.parent / ("contact-sheet-" + case + ".png")
        overview = f'<p><a href="{link(str(sheet))}">Open this case’s four-size × light/dark contact sheet</a></p>' if sheet.is_file() else ""
        sections.append(f'<section><h2>{html.escape(case)}</h2>{overview}<div class="grid">{"".join(tiles)}</div></section>')
    separate = []
    for filename, label in (("visual-review.json", "Separate visual review"), ("report.json", "Acceptance report")):
        path = captures_path.parent / filename
        if path.is_file():
            separate.append(f'<a href="{link(str(path))}">{label}</a>')
    separate_links = " · ".join(separate)
    return '''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>BeaverMeter native Widget spacing evidence</title><style>
:root{color-scheme:light dark;font:15px/1.5 system-ui,sans-serif}body{margin:0 auto;padding:28px;max-width:1600px}h1{font-size:28px}h2{margin-top:36px;font-size:21px}h3{margin:0 0 12px;font-size:16px}.grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:18px}article{border:1px solid #8886;border-radius:12px;padding:16px;min-width:0}img{display:block;max-width:100%;max-height:440px;width:auto;height:auto;margin:0 auto;background:#7771}p{margin:10px 0}.pending{color:#aa6a00}.failed{color:#bd4034}a{color:inherit}code{overflow-wrap:anywhere}@media(max-width:740px){body{padding:16px}.grid{grid-template-columns:1fr}}
</style><body><h1>Native Widget spacing evidence</h1>''' + f'''
<p><strong>{report["capturedObservationCount"]}/40 native captures; {report["geometryPassedObservationCount"]} geometry checks passed. Visual review is recorded separately.</strong></p>
<p>Actual private <code>BeaverMeterWidgetQA</code> desktop windows, five synthetic cases × four sizes × light/dark. Each linked bounds report records the actual CG/AX window, cards, visible text/logo/status leaves and parent IDs. Geometry is recomputed with one physical pixel tolerance using the display's measured backing scale.</p>
<p>AX frames are layout frames, not glyph ink. CG windows include system shadow; this report does not infer the visual Widget edge or certify outer padding from an assumed shadow. Visual acceptance is recorded independently after image inspection. This geometry-only gallery performs no UI actions and does not change capture statuses or infer an external visual result.</p>
<p><a href="spacing-summary.json">Machine-readable spacing summary</a> · <a href="{link(report["captures"]["path"])}">Original capture index</a></p>
<p>{separate_links}</p>
''' + "".join(sections) + '</body></html>\n'


class SelfTests(unittest.TestCase):
    @staticmethod
    def synthetic_geometry():
        tree, cards = [], []
        for index, module in enumerate(GROUPS):
            card_id = index * 3 + 1
            frame = {"x": 18, "y": 18 + index * 74, "width": 144, "height": 70}
            leaves = []
            for offset, role, identifier, x, width in ((1, "AXUnknown", "WidgetQA.leaf.logo", 26, 12),
                                                        (2, "AXStaticText", None, 42, 60)):
                leaf = {"nodeID": card_id + offset, "parentNodeID": card_id, "role": role,
                        "bounds": {"x": x, "y": frame["y"] + 8, "width": width, "height": 14},
                        "insideSafeRect": True, "overflowPhysicalPixels": dict.fromkeys(("left", "top", "right", "bottom"), 0)}
                if identifier:
                    leaf.update(identifier=identifier, label="QA logo; detailLevel: full")
                leaves.append(leaf)
                tree.append(leaf)
            card = {"nodeID": card_id, "parentNodeID": 0, "identifier": "WidgetQA.card." + module,
                    "bounds": frame, "safeInsets": {"horizontal": 8, "vertical": 8},
                    "safeRect": {"x": 26, "y": frame["y"] + 8, "width": 128, "height": 54},
                    "chosenDetailLevel": "full", "chosenDetailLevelSource": "visible-logo", "leaves": leaves}
            tree.append(card)
            cards.append(card)
        window = {"actualWindow": {"id": 123, "backingScale": 2, "scaleSource": "NSScreen.backingScaleFactor",
                  "isOnscreen": True, "tolerancePoints": 0.5, "tolerancePhysicalPixels": 1,
                  "axFrame": {"x": 0, "y": 0, "width": 180, "height": 180},
                  "cgFrame": {"x": 0, "y": 0, "width": 180, "height": 180}}}
        return window, {"cards": cards, "visibleAXTree": tree}

    def test_physical_pixel_limit(self):
        safe = rectangle({"x": 10, "y": 8, "width": 80, "height": 64})
        self.assertEqual(max(overflow({"x": 9.5, "y": 8, "width": 80.5, "height": 64}, safe).values()) * 2, 1)
        self.assertGreater(max(overflow({"x": 9.49, "y": 8, "width": 80.51, "height": 64}, safe).values()) * 2, 1)

    def test_metadata_value_authority(self):
        self.assertEqual(node_metadata({"label": "kind: BeaverMeterWidgetQA; colorScheme: light", "value": "colorScheme: dark"}),
                         {"kind": "BeaverMeterWidgetQA", "colorScheme": "dark"})

    def test_policy_and_rows(self):
        self.assertEqual(spacing_policy("large", 6), {"outerPadding": 16, "cardGap": 8, "horizontal": 10, "vertical": 8})
        self.assertEqual([row_sizes(family, CAPACITY[family]) for family in FAMILIES], [[1, 1], [2, 2], [2, 2, 2], [3, 3]])

    def test_bad_geometry_rejected(self):
        for value in ({"x": 0, "y": 0, "width": 0, "height": 10}, {"x": float("nan"), "y": 0, "width": 10, "height": 10}):
            with self.assertRaises(ValueError):
                rectangle(value)

    def test_evidence_path_isolated(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            (folder / "local.json").write_text("{}")
            self.assertEqual(safe_artifact("local.json", folder), (folder / "local.json").resolve())
            with self.assertRaises(ValueError):
                safe_artifact(str(Path(__file__).resolve()), folder)

    def test_gallery_never_declares_visual_pass(self):
        report = {"observations": [], "capturedObservationCount": 0, "geometryPassedObservationCount": 0,
                  "captures": {"path": str(DEFAULT_CAPTURE)}}
        result = gallery(report, DEFAULT_CAPTURE.parent)
        self.assertIn("Visual review is recorded separately", result)
        self.assertNotIn("Visual review remains pending", result)
        self.assertEqual(result.count("Native capture pending"), 40)

    def test_actual_geometry_recomputation(self):
        window, case = self.synthetic_geometry()
        issues = []
        result = validate_geometry(window, case, "small", GROUPS, issues)
        self.assertEqual(issues, [])
        self.assertEqual((result["cardCount"], result["leafCount"]), (2, 4))
        self.assertEqual(result["actualAdjacentGaps"], [{"axis": "vertical", "points": 4.0}])
        self.assertTrue(result["outerPaddingValidation"].startswith("not-inferred:"))

    def test_claimed_pass_cannot_hide_actual_leaf_overflow(self):
        window, original = self.synthetic_geometry()
        case = copy.deepcopy(original)
        leaf = case["cards"][0]["leaves"][0]
        leaf["bounds"]["x"] = 25.4
        # copy.deepcopy retains the shared actual-tree leaf identity here.
        issues = []
        result = validate_geometry(window, case, "small", GROUPS, issues)
        self.assertGreater(result["maxLeafOverflowPhysicalPixels"], 1)
        self.assertTrue(any("exceeds" in issue for issue in issues))
        self.assertTrue(any("recomputation" in issue for issue in issues))

    def test_selected_level_and_parent_are_verified(self):
        window, case = self.synthetic_geometry()
        case["cards"][0]["chosenDetailLevel"] = "primaryOnly"
        case["cards"][0]["leaves"][1]["parentNodeID"] = None
        issues = []
        validate_geometry(window, case, "small", GROUPS, issues)
        self.assertTrue(any("visible logo" in issue for issue in issues))
        self.assertTrue(any("nearest actual card" in issue for issue in issues))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--captures", type=Path, default=DEFAULT_CAPTURE)
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--require-complete", action="store_true", help="Exit 2 unless all 40 geometry observations pass; visual review is not evaluated")
    parser.add_argument("--self-test", action="store_true", help="Pure metadata/geometry/path/gallery tests, without capture inputs")
    arguments = parser.parse_args()
    if arguments.self_test:
        result = unittest.TextTestRunner(verbosity=1).run(unittest.defaultTestLoader.loadTestsFromTestCase(SelfTests))
        return 0 if result.wasSuccessful() else 1
    captures_path = arguments.captures.resolve()
    output = (arguments.output_dir or captures_path.parent).resolve()
    output.mkdir(parents=True, exist_ok=True)
    report = summarize(captures_path, arguments.manifest.resolve())
    (output / "spacing-summary.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    (output / "index.html").write_text(gallery(report, output))
    print(json.dumps({"status": report["status"], "captured": report["capturedObservationCount"], "expected": 40,
                      "geometryPassed": report["geometryPassedObservationCount"], "cards": report["totalCards"],
                      "leaves": report["totalLeaves"], "visualReview": "not-evaluated", "gallery": str(output / "index.html")}))
    return 2 if arguments.require_complete and report["geometryStatus"] != "passed" else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError) as error:
        print("Offline spacing evidence: " + str(error), file=sys.stderr)
        sys.exit(2)
