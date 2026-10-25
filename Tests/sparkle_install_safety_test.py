import importlib.util
import os
from pathlib import Path
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location("sparkle_install", Path(__file__).parent / "Integration/sparkle_install.py")
integration = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(integration)
KEY = "BEAVERMETER_SPARKLE_PRIVATE_KEY"


class IsolatedSigningTests(unittest.TestCase):
    def test_caller_key_is_removed_before_ordinary_children(self):
        with mock.patch.dict(os.environ, {KEY: "fixture-release-secret", "PATH": "/usr/bin"}, clear=True):
            self.assertEqual(integration.take_signing_key(), "fixture-release-secret")
            self.assertNotIn(KEY, os.environ)
            with integration.isolated_signing("fixture-ephemeral-secret"):
                self.assertEqual(os.environ[KEY], "fixture-ephemeral-secret")
                self.assertNotIn(KEY, integration.subprocess_environment())
            self.assertNotIn(KEY, os.environ)

    def test_explicit_child_environment_is_copied_and_scrubbed(self):
        original = {KEY: "fixture-release-secret", "PATH": "/usr/bin"}
        self.assertEqual(integration.subprocess_environment(original), {"PATH": "/usr/bin"})
        self.assertIn(KEY, original)

    def test_run_never_inherits_signing_material(self):
        with mock.patch.dict(os.environ, {KEY: "fixture-release-secret"}, clear=True), \
             mock.patch.object(integration.subprocess, "run") as run:
            integration.run("/usr/bin/true")
            self.assertNotIn(KEY, run.call_args.kwargs["env"])

    def test_failed_signing_scope_does_not_restore_a_removed_caller_key(self):
        with mock.patch.dict(os.environ, {KEY: "fixture-release-secret"}, clear=True):
            integration.take_signing_key()
            with self.assertRaises(RuntimeError):
                with integration.isolated_signing("fixture-ephemeral-secret"):
                    raise RuntimeError("fixture failure")
            self.assertNotIn(KEY, os.environ)


if __name__ == "__main__":
    unittest.main()
