import base64
import hashlib
import importlib.util
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import release_metadata
import sparkle_release


class ReleaseMetadataTests(unittest.TestCase):
    @staticmethod
    def project(version, build):
        return f"MARKETING_VERSION: {version}\nCURRENT_PROJECT_VERSION: {build}\n" * 2

    def test_display_version_reset_keeps_build_ordering_across_legacy_tags(self):
        projects = {"v5.4.0": self.project("5.4.0", 35),
                    "v5.5.0": self.project("5.5.0", 36)}
        release_metadata.validate_build_progression(37, "v1.0.0", projects, projects.__getitem__)
        for build in [1, 35, 36]:
            with self.subTest(build=build), self.assertRaises(ValueError):
                release_metadata.validate_build_progression(build, "v1.0.0", projects, projects.__getitem__)

    def test_build_floor_applies_without_legacy_tags_and_future_builds_must_increase(self):
        with self.assertRaises(ValueError):
            release_metadata.validate_build_progression(36, "v1.0.0", [], lambda _: "")
        release_metadata.validate_build_progression(37, "v1.0.0", [], lambda _: "")
        projects = {"v5.4.0": self.project("5.4.0", 35),
                    "v1.0.0": self.project("1.0.0", 37),
                    "v1.0.1": self.project("1.0.1", 38)}
        release_metadata.validate_build_progression(38, "v1.0.1", projects, projects.__getitem__)
        with self.assertRaises(ValueError):
            release_metadata.validate_build_progression(37, "v1.0.1", projects, projects.__getitem__)

    def test_unreadable_stable_tag_fails_closed_but_nonrelease_tags_are_ignored(self):
        with self.assertRaisesRegex(ValueError, "historical build metadata"):
            release_metadata.validate_build_progression(37, "v1.0.0", ["v5.4.0"], lambda _: "invalid")
        read = mock.Mock(side_effect=AssertionError("must not inspect nonrelease tags"))
        release_metadata.validate_build_progression(37, "v1.0.0", ["v1.0.0", "v4.3", "test-only"], read)

    def test_matching_metadata(self):
        self.assertEqual(release_metadata.metadata("""
        MARKETING_VERSION: 5.5.0
        CURRENT_PROJECT_VERSION: 36
        MARKETING_VERSION: 5.5.0
        CURRENT_PROJECT_VERSION: 36
        """), ("5.5.0", 36))

    def test_mismatched_version_or_build_cannot_release(self):
        for text in ["MARKETING_VERSION: 5.5.0\nCURRENT_PROJECT_VERSION: 36\n",
                     "MARKETING_VERSION: 5.5.0\nMARKETING_VERSION: 5.6.0\nCURRENT_PROJECT_VERSION: 36\nCURRENT_PROJECT_VERSION: 36\n",
                     "MARKETING_VERSION: 5.5.0\nMARKETING_VERSION: 5.5.0\nCURRENT_PROJECT_VERSION: 36\nCURRENT_PROJECT_VERSION: 35\n"]:
            with self.assertRaises(ValueError):
                release_metadata.metadata(text)

    def valid_settings(self):
        return dict(BeaverMeterUpdatesEnabled="YES", SUPublicEDKey="public", SUFeedURL=release_metadata.FEED_URL,
                    SURequireSignedFeed=True, SUVerifyUpdateBeforeExtraction=True, SUEnableAutomaticChecks=True,
                    SUAutomaticallyUpdate=False, SUAllowsAutomaticUpdates=False, SUEnableSystemProfiling=False,
                    SUScheduledCheckInterval=43200, SUSignedFeedFailureExpirationInterval=0)

    def test_release_settings_are_fail_closed(self):
        settings = self.valid_settings()
        release_metadata.validate_update_settings(settings, "public", True)
        for key, value in [("SUPublicEDKey", "wrong"), ("SUFeedURL", "https://other.example/feed.xml"),
                           ("SURequireSignedFeed", False), ("SUVerifyUpdateBeforeExtraction", False),
                           ("SUAutomaticallyUpdate", True), ("SUAllowsAutomaticUpdates", True),
                           ("SUSignedFeedFailureExpirationInterval", 1728000), ("SUScheduledCheckInterval", 60),
                           ("BeaverMeterUpdatesEnabled", "NO")]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                release_metadata.validate_update_settings(dict(settings, **{key: value}), "public", True)

    def test_local_app_cannot_enable_production_updates(self):
        with self.assertRaises(ValueError):
            release_metadata.validate_update_settings(self.valid_settings(), "public", False)
        settings = self.valid_settings()
        settings["BeaverMeterUpdatesEnabled"] = "NO"
        release_metadata.validate_update_settings(settings, "public", False)

    def test_appcast_requires_a_single_signature_and_exact_length(self):
        data = b"<rss/>\n"
        suffix = b"<!-- sparkle-signatures:\nedSignature: " + base64.b64encode(b"s" * 64) + b"\nlength: 7\n-->\n"
        self.assertEqual(release_metadata.feed_signature(data + suffix), (data, base64.b64encode(b"s" * 64).decode()))
        for invalid in [data, data + suffix + b"extra", data + suffix.replace(b"length: 7", b"length: 6"), data + suffix + suffix]:
            with self.assertRaises(ValueError):
                release_metadata.feed_signature(invalid)

    def test_public_key_validation(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = pathlib.Path(temporary) / "public.txt"
            for invalid in ["", "not base64", base64.b64encode(b"k" * 31).decode()]:
                path.write_text(invalid)
                with self.assertRaises(ValueError):
                    release_metadata.public_key(path)
            valid = base64.b64encode(b"k" * 32).decode()
            path.write_text(valid + "\n")
            self.assertEqual(release_metadata.public_key(path), valid)

    def create_artifacts(self, directory, mutate=lambda text: text):
        signature = base64.b64encode(b"s" * 64).decode()
        (directory / "BeaverMeter-5.5.0-universal.dmg").write_bytes(b"dmg")
        (directory / "BeaverMeter-5.5.0-source.zip").write_bytes(b"zip")
        (directory / "release-notes.md").write_bytes(b"notes")
        xml = mutate(f'''<rss xmlns:sparkle="{release_metadata.SPARKLE_NS}"><channel><item>
<sparkle:version>36</sparkle:version><sparkle:shortVersionString>5.5.0</sparkle:shortVersionString>
<sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
<enclosure url="{release_metadata.DOWNLOAD_ROOT}/v5.5.0/BeaverMeter-5.5.0-universal.dmg" length="3" sparkle:edSignature="{signature}"/>
<sparkle:releaseNotesLink sparkle:length="5" sparkle:edSignature="{signature}">{release_metadata.DOWNLOAD_ROOT}/v5.5.0/release-notes.md</sparkle:releaseNotesLink>
</item></channel></rss>''').encode()
        xml += f"<!-- sparkle-signatures:\nedSignature: {signature}\nlength: {len(xml)}\n-->\n".encode()
        (directory / "appcast.xml").write_bytes(xml)
        names = ["BeaverMeter-5.5.0-universal.dmg", "BeaverMeter-5.5.0-source.zip", "appcast.xml", "release-notes.md"]
        (directory / "SHA256SUMS").write_text("".join(f"{hashlib.sha256((directory / name).read_bytes()).hexdigest()}  {name}\n" for name in names))

    def test_artifact_metadata_and_all_signatures_are_checked(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = pathlib.Path(temporary)
            self.create_artifacts(directory)
            with mock.patch.object(release_metadata, "public_key"), mock.patch.object(release_metadata, "verify_signature") as verify, mock.patch.object(subprocess, "run"):
                release_metadata.validate_artifacts(directory, "5.5.0", 36, pathlib.Path("public.txt"))
                self.assertEqual(verify.call_count, 3)

    def test_corrupt_or_wrong_release_assets_fail(self):
        mutations = [lambda xml: xml.replace("/v5.5.0/", "/latest/"),
                     lambda xml: xml.replace("<sparkle:version>36", "<sparkle:version>35"),
                     lambda xml: xml.replace('length="3"', 'length="4"'),
                     lambda xml: xml.replace("14.0", "13.0"),
                     lambda xml: xml.replace("</item>", "<sparkle:deltas/></item>"),
                     lambda xml: xml.replace("</channel>", "<item/></channel>")]
        for mutate in mutations:
            with tempfile.TemporaryDirectory() as temporary:
                directory = pathlib.Path(temporary)
                self.create_artifacts(directory, mutate)
                with mock.patch.object(release_metadata, "public_key"), mock.patch.object(release_metadata, "verify_signature"), self.assertRaises(ValueError):
                    release_metadata.validate_artifacts(directory, "5.5.0", 36, pathlib.Path("public.txt"))
        with tempfile.TemporaryDirectory() as temporary:
            directory = pathlib.Path(temporary)
            self.create_artifacts(directory)
            (directory / "release-notes.md").write_bytes(b"tampered")
            with mock.patch.object(release_metadata, "public_key"), self.assertRaises(ValueError):
                release_metadata.validate_artifacts(directory, "5.5.0", 36, pathlib.Path("public.txt"))

    def test_unexpected_or_missing_assets_fail(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = pathlib.Path(temporary)
            self.create_artifacts(directory)
            (directory / "unwanted.delta").write_bytes(b"")
            with mock.patch.object(release_metadata, "public_key"), self.assertRaises(ValueError):
                release_metadata.validate_artifacts(directory, "5.5.0", 36, pathlib.Path("public.txt"))


class SparkleSigningTests(unittest.TestCase):
    def test_ci_requires_signing_secret(self):
        with mock.patch.dict("os.environ", {"GITHUB_ACTIONS": "true"}, clear=True), self.assertRaises(ValueError):
            sparkle_release.signing_input()

    def test_local_uses_only_dedicated_keychain_account(self):
        with mock.patch.dict("os.environ", {}, clear=True):
            self.assertEqual(sparkle_release.signing_input(), (["--account", "BeaverMeter.Release"], None))

    def test_private_key_is_stdin_only_and_child_environment_is_clean(self):
        key = base64.b64encode(b"s" * 32).decode()
        with mock.patch.dict("os.environ", {"BEAVERMETER_SPARKLE_PRIVATE_KEY": key}, clear=True), mock.patch.object(subprocess, "run", return_value=mock.Mock(returncode=0, stdout="signature")) as run:
            self.assertEqual(sparkle_release.run_signing(pathlib.Path("sign_update"), ["-p", "archive.dmg"]), "signature")
            self.assertEqual(run.call_args.args[0], ["sign_update", "--ed-key-file", "-", "-p", "archive.dmg"])
            self.assertEqual(run.call_args.kwargs["input"], key + "\n")
            self.assertNotIn("BEAVERMETER_SPARKLE_PRIVATE_KEY", run.call_args.kwargs["env"])

    def test_invalid_secrets_fail_before_the_tool_runs_and_without_echoing_key(self):
        for key in ["SECRET not base64", base64.b64encode(b"bad-size").decode()]:
            with mock.patch.dict("os.environ", {"BEAVERMETER_SPARKLE_PRIVATE_KEY": key}, clear=True), mock.patch.object(subprocess, "run") as run:
                with self.assertRaises(ValueError) as error:
                    sparkle_release.run_signing(pathlib.Path("sign_update"), ["archive.dmg"])
                self.assertNotIn(key, str(error.exception))
                run.assert_not_called()

    def test_tools_are_version_pinned(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            info = root / "Sparkle.framework/Resources/Info.plist"
            info.parent.mkdir(parents=True)
            (root / "bin").mkdir()
            for name in ("sign_update", "generate_appcast"):
                (root / "bin" / name).touch()
            for version in ["2.9.6", "2.10.1"]:
                info.write_bytes(plistlib.dumps({"CFBundleShortVersionString": version}))
                with self.assertRaises(ValueError):
                    sparkle_release.find_tools(override=root)
            info.write_bytes(plistlib.dumps({"CFBundleShortVersionString": "2.10.0"}))
            self.assertEqual(sparkle_release.find_tools(override=root), root / "bin")

    def test_signing_errors_never_print_tool_output(self):
        with mock.patch.dict("os.environ", {}, clear=True), mock.patch.object(subprocess, "run", return_value=mock.Mock(returncode=1, stdout="secret material", stderr="secret material")):
            with self.assertRaises(ValueError) as error:
                sparkle_release.run_signing(pathlib.Path("sign_update"), ["archive.dmg"])
            self.assertNotIn("secret material", str(error.exception))


if __name__ == "__main__":
    unittest.main()
