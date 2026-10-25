"""Workspace provenance protocol tests use synthetic session records only."""

import importlib.util
import json
import os
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "remote_codex_usage.py"
SPEC = importlib.util.spec_from_file_location("remote_codex_workspace_usage", SCRIPT)
SCANNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SCANNER)


class RemoteCodexWorkspaceUsageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(os.path.realpath(self.temp.name))
        self.path = self.root / "sessions" / "synthetic.jsonl"
        self.path.parent.mkdir()
        self.now = datetime(2026, 10, 1, 12, tzinfo=timezone.utc).timestamp()
        self.start = self.now - 12 * 3600
        self.end = self.start + 86400

    def metadata(self, session, creator, timestamp="2026-10-01T09:00:00Z"):
        return {"type": "session_meta", "timestamp": timestamp, "payload": {
            "session_id": session, "id": session, "creator_account_id": creator,
            "creator_user_id": "private-user-never-export", "instructions": "private-session-never-export",
        }}

    def usage(self, response, session, tokens=100, thread=None):
        return {"type": "token_usage_record", "timestamp": "2026-10-01T10:00:00Z", "payload": {
            "response_id": response, "session_id": session,
            "thread_id": session if thread is None else thread,
            "usage": {"input_tokens": tokens, "output_tokens": 0},
        }}

    def append(self, *records):
        with self.path.open("a", encoding="utf-8") as handle:
            for record in records:
                handle.write(json.dumps(record) + "\n")
        os.utime(self.path, (self.now, self.now))

    def scan(self, previous=None, cutoff=None):
        request = {"files": {}, "scopeContexts": {}}
        if previous:
            request["files"] = {key: value["offset"] for key, value in previous["files"].items()}
            request["scopeContexts"] = {key: {
                "sessionScopes": value["sessionScopes"],
                "conflictedSessions": value["conflictedSessions"],
            } for key, value in previous["files"].items()}
        return SCANNER.scan(str(self.root), self.start, self.end, self.now if cutoff is None else cutoff, request)

    def records(self, result):
        return [record for delta in result["files"].values() for record in delta["records"]]

    def test_parent_child_and_copied_history_match_explicit_session_identity(self):
        self.append(self.metadata("parent", " WORKSPACE-A "), self.usage("a", "parent", 100),
                    self.metadata("child", "workspace-b"), self.usage("b", "child", 200),
                    self.usage("copied-parent", "parent", 50))
        result = self.scan()
        records = self.records(result)
        self.assertTrue(result["complete"])
        self.assertEqual([item["creatorWorkspaceHash"] for item in records],
                         [SCANNER.digest("workspace-a"), SCANNER.digest("workspace-b"), SCANNER.digest("workspace-a")])
        self.assertTrue(all("workspaceHash" not in item and "workspaceScopeEvidence" not in item for item in records))
        self.assertEqual(sum(item["inputTokens"] for item in records), 350)
        encoded = json.dumps(result)
        for private in ["WORKSPACE-A", "workspace-b", "private-user-never-export", "private-session-never-export",
                        "creator_account_id", "copied-parent", str(self.root)]:
            self.assertNotIn(private, encoded)

    def test_missing_mismatched_and_conflicting_scope_remain_unknown(self):
        self.append(self.usage("missing", "no-metadata", 1), self.metadata("parent", "workspace-a"),
                    self.usage("mismatch", "parent", 2, thread="other-thread"),
                    self.metadata("conflict", "workspace-a"), self.usage("conflict", "conflict", 3),
                    self.metadata("conflict", "workspace-b"))
        result = self.scan()
        self.assertEqual(sum(item["inputTokens"] for item in self.records(result)), 6)
        self.assertTrue(all("creatorWorkspaceHash" not in item for item in self.records(result)))
        delta = next(iter(result["files"].values()))
        self.assertEqual(delta["conflictedSessions"], [SCANNER.digest("conflict")])

    def test_incremental_append_reuses_only_hashed_provenance_context(self):
        self.append(self.metadata("session", "workspace-a"), self.usage("first", "session"))
        first = self.scan()
        self.append(self.usage("second", "session", 70))
        second = self.scan(first)
        self.assertEqual(len(self.records(second)), 1)
        self.assertEqual(self.records(second)[0]["inputTokens"], 70)
        self.assertEqual(self.records(second)[0]["creatorWorkspaceHash"], SCANNER.digest("workspace-a"))

    def test_later_conflict_is_reported_for_cached_records_and_new_records(self):
        self.append(self.metadata("session", "workspace-a"), self.usage("first", "session"))
        first = self.scan()
        self.append(self.metadata("session", "workspace-b"), self.usage("second", "session", 70))
        second = self.scan(first)
        delta = next(iter(second["files"].values()))
        # The Swift consumer uses this persisted conflict to invalidate prior creator diagnostics.
        self.assertEqual(delta["conflictedSessions"], [SCANNER.digest("session")])
        self.assertNotIn("creatorWorkspaceHash", self.records(second)[0])

    def test_future_metadata_does_not_assign_earlier_usage_until_cutoff(self):
        self.append(self.metadata("session", "workspace-a", timestamp="2026-10-01T18:00:00Z"),
                    self.usage("one", "session"))
        first = self.scan()
        self.assertNotIn("creatorWorkspaceHash", self.records(first)[0])
        second = self.scan(first, cutoff=self.start + 20 * 3600)
        self.assertEqual(self.records(second)[0]["creatorWorkspaceHash"], SCANNER.digest("workspace-a"))

    def test_truncation_discards_previous_session_context(self):
        self.append(self.metadata("session", "workspace-a"), self.usage("first", "session"))
        first = self.scan()
        self.path.write_text(json.dumps(self.usage("replacement", "session", 1)) + "\n", encoding="utf-8")
        os.utime(self.path, (self.now, self.now))
        second = self.scan(first)
        delta = next(iter(second["files"].values()))
        self.assertTrue(delta["reset"])
        self.assertEqual(delta["sessionScopes"], {})
        self.assertNotIn("creatorWorkspaceHash", self.records(second)[0])


if __name__ == "__main__":
    unittest.main()
