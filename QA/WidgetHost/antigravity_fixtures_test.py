"""Pure negative/provenance checks; no apply, app launch or production reads."""
import copy
import hashlib
import unittest

import antigravity_fixtures as qa
from fixtures import json_bytes


class AntigravityFixturesTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.generated = qa.outputs()
        cls.manifest = cls.generated[qa.OUTPUT / "fixtures/manifest.json"]

    def test_five_cases_and_all_native_observations_stay_pending(self):
        report = self.generated[qa.OUTPUT / "report.template.json"]
        self.assertEqual(self.manifest["caseCount"], 5)
        self.assertEqual(report["observationCount"], 40)
        self.assertTrue(all(item["status"] == "pending" and item["screenshot"] is None
                            for item in report["observations"]))
        self.assertFalse(report["legacyMatrixUpdated"])

    def test_original_four_case_bytes_are_unchanged(self):
        expected = {
            "antigravity-both-groups": "101d8adc20c2e1a81433f3eb82674f5f3ac8587b1fa8d6dc1b4e69d15f5e032b",
            "antigravity-full-capacity": "436377ad0ad49f8b72bcbd70daaf23bafee4efbf65081ca112cc5d0d3f5bfee3",
            "antigravity-unknown-and-zero": "6e6b931bff30320280029f2ec8d920f8c38706c226fdbbc3440809b77f96d0b0",
            "antigravity-reset-description": "ec9b08a35d207f86d6fb9971b8b67a173cb1f92681af58c67dd000f1c69352a7",
        }
        actual = {record["caseID"]: record["sha256"] for record in self.manifest["cases"]}
        self.assertEqual({key: actual[key] for key in expected}, expected)
        self.assertEqual(self.generated[qa.OUTPUT / "report.template.json"]["primaryCaseID"],
                         "antigravity-both-groups")

    def test_spacing_stress_is_synthetic_full_capacity_with_edge_values(self):
        record = next(record for record in self.manifest["cases"] if record["caseID"].endswith("spacing-stress"))
        case = self.generated[qa.OUTPUT / "fixtures" / record["file"]]
        snapshot = case["snapshot"]
        self.assertEqual(record["derivedSyntheticScenario"], "spacing-stress-v1")
        self.assertFalse(record["sourcePreviewIsStressEvidence"])
        self.assertEqual(len(case["selectedModuleIDs"]), 6)
        self.assertEqual(set(case["settings"]["visibility"].values()), {"shown"})
        self.assertEqual([group["primaryPercent"] for group in record["expectedGroups"]], [100, 0])
        account = snapshot["codexAccounts"]["value"][0]
        self.assertGreater(len(account["workspaceName"]), 60)
        self.assertIsNone(account["quota"]["value"]["remainingPercent"])
        self.assertTrue(all(window["remainingPercent"] is None for window in account["quota"]["value"]["windows"]))
        self.assertGreater(snapshot["cursorQuota"]["value"]["remaining"], 9_000_000_000)
        balance = snapshot["deepseekUsage"]["value"]["balances"][0]
        self.assertEqual(balance["currency"], "CNY")
        self.assertGreater(balance["amount"], 9_000_000_000)
        for group in snapshot["antigravityQuota"]["value"]["groups"]:
            for window in group["windows"]:
                self.assertNotIn("resetAt", window)
                self.assertGreater(len(window["resetDescription"]), 80)

    def test_all_five_provider_switches_and_group_selection_are_explicit(self):
        for record in self.manifest["cases"]:
            case = self.generated[qa.OUTPUT / "fixtures" / record["file"]]
            self.assertEqual(set(case["settings"]["visibility"]), set(qa.PROVIDERS))
            self.assertEqual(case["selectedModuleIDs"][:2], qa.MODULES)
            self.assertEqual(hashlib.sha256(json_bytes(case)).hexdigest(), record["sha256"])
            self.assertEqual(case["snapshot"]["schemaVersion"], 8)

    def test_unknown_and_zero_remain_distinct(self):
        record = next(record for record in self.manifest["cases"] if record["caseID"].endswith("unknown-and-zero"))
        self.assertIsNone(record["expectedGroups"][0]["primaryPercent"])
        self.assertEqual(record["expectedGroups"][1]["primaryPercent"], 0)

    def test_reset_prose_has_no_invented_timestamp(self):
        record = next(record for record in self.manifest["cases"] if record["caseID"].endswith("reset-description"))
        case = self.generated[qa.OUTPUT / "fixtures" / record["file"]]
        for group in case["snapshot"]["antigravityQuota"]["value"]["groups"]:
            for window in group["windows"]:
                self.assertNotIn("resetAt", window)
                self.assertTrue(window["resetDescription"])

    def test_live_source_legacy_schema_and_credentials_are_rejected(self):
        record = self.manifest["cases"][0]
        original = self.generated[qa.OUTPUT / "fixtures" / record["file"]]["snapshot"]
        for mutate in (lambda snapshot: snapshot.update(schemaVersion=7),
                       lambda snapshot: snapshot["antigravityQuota"].update(source="antigravityLocal"),
                       lambda snapshot: snapshot.update(access_token="synthetic-forbidden")):
            snapshot = copy.deepcopy(original)
            mutate(snapshot)
            with self.assertRaises(ValueError):
                qa.validate_snapshot(snapshot)


if __name__ == "__main__":
    unittest.main()
