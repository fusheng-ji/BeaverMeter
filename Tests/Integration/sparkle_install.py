#!/usr/bin/env python3
"""Opt-in Sparkle replacement/relaunch integration against two isolated real app copies.

Requires a built universal Release app, a GUI login session and npm packaging deps.
Signing can use the dedicated release key or --ephemeral-signing for isolated tests.
The fixture versions differ only in metadata; this verifies Sparkle's real
installer rather than release-to-release product/runtime behavior.
"""
import functools
import argparse
import contextlib
import http.server
import os
import pathlib
import plistlib
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import uuid
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from release_metadata import NS, SPARKLE_NS, bool_value, public_key
from sparkle_release import check_key, find_tools, run_signing


def subprocess_environment(environment=None):
    child = dict(os.environ if environment is None else environment)
    child.pop("BEAVERMETER_SPARKLE_PRIVATE_KEY", None)
    return child


def take_signing_key():
    # Hold a caller-supplied secret only in this process, outside all ordinary child environments.
    return os.environ.pop("BEAVERMETER_SPARKLE_PRIVATE_KEY", None)


def run(*arguments, **kwargs):
    kwargs["env"] = subprocess_environment(kwargs.get("env"))
    return subprocess.run([str(value) for value in arguments], check=True, **kwargs)


def bundle_info(app):
    with (app / "Contents/Info.plist").open("rb") as stream:
        return plistlib.load(stream)


def prepare_copy(source, destination, identifier, version, build, test_key=None):
    # ditto preserves framework version symlinks and all App/Widget/collector resources.
    run("/usr/bin/ditto", source, destination)
    for bundle, bundle_id in [(destination, identifier),
                             (destination / "Contents/PlugIns/BeaverMeterWidgetExtension.appex", identifier + ".widget")]:
        path = bundle / "Contents/Info.plist"
        with path.open("rb") as stream:
            info = plistlib.load(stream)
        info.update(CFBundleIdentifier=bundle_id, CFBundleVersion=str(build), CFBundleShortVersionString=version)
        if test_key is not None:
            info["SUPublicEDKey"] = test_key
        scheme = "beavermeter-test-" + identifier.rsplit(".", 1)[-1]
        info["BeaverMeterMenuURLScheme"] = scheme
        if bundle == destination:
            info["CFBundleURLTypes"] = [{"CFBundleURLName": identifier, "CFBundleURLSchemes": [scheme]}]
            info["BeaverMeterInteractionDemo"] = True
            info["BeaverMeterDirectInstall"] = False
            info["BeaverMeterUpdatesEnabled"] = "NO"
            info["SUEnableAutomaticChecks"] = False
            info["SUEnableSystemProfiling"] = False
            info["NSAppTransportSecurity"] = {"NSAllowsLocalNetworking": True}
            # All update settings, including mandatory signatures, remain copied from the release app.
        path.write_bytes(plistlib.dumps(info))
    run("/usr/bin/codesign", "--force", "--deep", "--sign", "-", "--timestamp=none", destination)
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", destination)


def scoped_processes(path):
    # Exact temporary executable path and current UID only. Never use killall/pkill.
    output = subprocess.check_output(["/bin/ps", "-axo", "pid=,uid=,command="], text=True)
    expected = os.path.realpath(path / "Contents/MacOS/BeaverMeter")
    for line in output.splitlines():
        fields = line.strip().split(None, 2)
        if len(fields) == 3 and fields[1] == str(os.getuid()):
            executable = fields[2].split(None, 1)[0]
            if os.path.realpath(executable) == expected:
                yield int(fields[0])


class QuietServer(http.server.SimpleHTTPRequestHandler):
    def log_message(self, format, *args):
        pass


@contextlib.contextmanager
def isolated_signing(private_key):
    if private_key is None:
        yield
        return
    previous = os.environ.pop("BEAVERMETER_SPARKLE_PRIVATE_KEY", None)
    try:
        os.environ["BEAVERMETER_SPARKLE_PRIVATE_KEY"] = private_key
        yield
    finally:
        os.environ.pop("BEAVERMETER_SPARKLE_PRIVATE_KEY", None)
        if previous is not None:
            os.environ["BEAVERMETER_SPARKLE_PRIVATE_KEY"] = previous


def main():
    supplied_signing_key = take_signing_key()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=pathlib.Path)
    parser.add_argument("tools", type=pathlib.Path)
    parser.add_argument("--ephemeral-signing", action="store_true",
                        help="Sign isolated copies with a temporary test key; never access the release Keychain")
    parser.add_argument("--renumbering", action="store_true",
                        help="Test the display-version reset from 5.5.0/36 to 1.0.0/37")
    args = parser.parse_args()
    if sys.platform != "darwin":
        raise ValueError("Requires a GUI macOS session")
    source = args.source.resolve()
    tools_root = args.tools.resolve()
    tools = find_tools(override=tools_root)
    key_path = ROOT / "Config/SparklePublicKey.txt"
    key = public_key(key_path)
    source_info = bundle_info(source)
    if source_info.get("SUPublicEDKey") != key:
        raise ValueError("Source app must contain the committed public update key")
    if not all(bool_value(source_info.get(name)) for name in ("SUVerifyUpdateBeforeExtraction", "SURequireSignedFeed")):
        raise ValueError("Source app must require archive and feed signatures")
    if not args.ephemeral_signing:
        with isolated_signing(supplied_signing_key):
            check_key(tools, key_path)
    framework_dir = tools_root / "Sparkle.xcframework/macos-arm64_x86_64"
    if not framework_dir.exists():
        framework_dir = tools_root
    identifier = "io.github.fushengji.beavermeter.sparkle-test." + uuid.uuid4().hex
    server = None
    app_process = None
    with tempfile.TemporaryDirectory(prefix="beavermeter-sparkle-install-") as temporary:
        stage = pathlib.Path(temporary).resolve()
        private_test_key = None if args.ephemeral_signing else supplied_signing_key
        if args.ephemeral_signing:
            private_path, public_path = stage / "test.private-key", stage / "test-public.txt"
            run("/usr/bin/swift", "-module-cache-path", ROOT / ".build/sparkle-test-modules",
                ROOT / "Tests/Integration/MakeSparkleTestKey.swift", private_path, public_path)
            private_test_key = private_path.read_text().strip()
            key_path = public_path
            key = public_key(public_path)
            with isolated_signing(private_test_key):
                check_key(tools, public_path)
        target = stage / "installed/BeaverMeter.app"
        next_app = stage / "next/BeaverMeter.app"
        server_dir = stage / "feed"
        server_dir.mkdir()
        version = source_info["CFBundleShortVersionString"]
        major, minor, patch = map(int, version.split("."))
        next_version = f"{major}.{minor}.{patch + 1}"
        build = int(source_info["CFBundleVersion"])
        if args.renumbering:
            if (version, build) != ("1.0.0", 37):
                raise ValueError("Renumbering test requires the 1.0.0/37 candidate")
            version, build, next_version = "5.5.0", 36, "1.0.0"
        prepare_copy(source, target, identifier, version, build, key)
        prepare_copy(source, next_app, identifier, next_version, build + 1, key)
        # A private fixture data file proves replacing the app leaves data beside it intact.
        data_dir = stage / "Application Support/BeaverMeter"
        data_dir.mkdir(parents=True)
        sentinel = data_dir / "preserved-data.json"
        sentinel.write_bytes(b'{"fixture":"keep this data"}\n')
        preserved = sentinel.read_bytes()
        try:
            handler = functools.partial(QuietServer, directory=str(server_dir))
            server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            prefix = f"http://127.0.0.1:{server.server_port}/"
            run("node", ROOT / "scripts/packaging/create_dmg.mjs", next_app, server_dir,
                "--no-code-sign", "--dmg-title=BeaverMeter Test")
            dmg_name = f"BeaverMeter {next_version}.dmg"
            note_name = pathlib.Path(dmg_name).with_suffix(".md").name
            (server_dir / note_name).write_text("# Isolated real BeaverMeter update integration test\n")
            with isolated_signing(private_test_key):
                run_signing(tools / "generate_appcast", ["--maximum-deltas", "0", "--maximum-versions", "1",
                            "--download-url-prefix", prefix, "--release-notes-url-prefix", prefix,
                            "-o", str(server_dir / "appcast.xml"), str(server_dir)])
            feed = ET.parse(server_dir / "appcast.xml")
            if feed.find("./channel/item/enclosure") is None or feed.find("./channel/item/sparkle:releaseNotesLink", NS) is None:
                raise ValueError("Integration appcast is missing its signed update or release notes")
            harness_app = stage / "SparkleInstallHarness.app"
            (harness_app / "Contents/MacOS").mkdir(parents=True)
            harness = harness_app / "Contents/MacOS/SparkleInstallHarness"
            harness_info = {"CFBundleIdentifier": identifier + ".harness", "CFBundleName": "SparkleInstallHarness",
                            "CFBundleExecutable": "SparkleInstallHarness", "CFBundleVersion": "1",
                            "CFBundleShortVersionString": "1.0.0", "CFBundlePackageType": "APPL",
                            "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True}}
            (harness_app / "Contents/Info.plist").write_bytes(plistlib.dumps(harness_info))
            run("/usr/bin/xcrun", "clang", "-fobjc-arc", "-F", framework_dir, "-framework", "AppKit",
                "-framework", "Sparkle", "-Wl,-rpath," + str(framework_dir),
                ROOT / "Tests/Integration/SparkleInstallHarness.m", "-o", harness)
            run("/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", harness_app)
            # Both copies explicitly run the app's existing interaction-demo mode.
            with (stage / "target-app.log").open("wb") as app_log:
                app_process = subprocess.Popen([str(target / "Contents/MacOS/BeaverMeter"), "--interaction-demo"],
                                               stdout=app_log, stderr=app_log, env=subprocess_environment())
                time.sleep(3)
                if app_process.poll() is not None:
                    raise ValueError("Isolated demo application exited before the update test")
                # Rejections exercise Sparkle itself while the old demo app keeps running.
                signed_feed = (server_dir / "appcast.xml").read_bytes()
                (server_dir / "bad-feed.xml").write_bytes(signed_feed.replace(b"BeaverMeter", b"XeaverMeter", 1))
                run(harness, target, prefix + "bad-feed.xml", stage / "bad-feed-result.json", build, "bad-feed", timeout=130)
                run(harness, target, prefix + "missing-appcast.xml", stage / "network-result.json", build, "network", timeout=130)
                run(harness, target, prefix + "appcast.xml", stage / "cancel-result.json", build, "cancel-download", timeout=130)
                archive = server_dir / dmg_name
                archive_backup = stage / "original.dmg"
                shutil.copyfile(archive, archive_backup)
                with archive.open("r+b") as stream:
                    stream.seek(100)
                    original_byte = stream.read(1)
                    stream.seek(100)
                    stream.write(bytes([original_byte[0] ^ 1]))
                run(harness, target, prefix + "appcast.xml", stage / "corrupt-result.json", build, "bad-archive", timeout=130)
                shutil.copyfile(archive_backup, archive)
                run(harness, target, prefix + "appcast.xml", stage / "result.json", build + 1, "install", timeout=130)
            time.sleep(1)
            if not list(scoped_processes(target)):
                raise ValueError("Sparkle reported a relaunch but the updated demo application is not running")
            if sentinel.read_bytes() != preserved:
                raise ValueError("External fixture data changed during application replacement")
            run("/usr/bin/codesign", "--verify", "--deep", "--strict", target)
            for nested in [target, target / "Contents/PlugIns/BeaverMeterWidgetExtension.appex"]:
                if bundle_info(nested).get("CFBundleVersion") != str(build + 1):
                    raise ValueError("App and Widget did not both update")
            for resource in ["Helpers/BeaverMeterCollector", "Frameworks/Sparkle.framework", "Resources/configure_runtime.sh"]:
                if not (target / "Contents" / resource).exists():
                    raise ValueError("Whole-app update lost a runtime component: " + resource)
            print(f"PASS: real Sparkle signed DMG replacement/relaunch {version} ({build}) → {next_version} ({build + 1}); whole bundle and isolated data preserved")
        finally:
            if server:
                server.shutdown()
                server.server_close()
            for pid in list(scoped_processes(target)):
                try:
                    os.kill(pid, 15)
                except ProcessLookupError:
                    pass
            if app_process:
                try:
                    app_process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    app_process.kill()
                    app_process.wait()
            # LaunchServices may discover embedded extensions when relaunching the test app.
            # Unregister only the two temporary test extension paths, never production Widgets.
            for test_bundle in [target, next_app]:
                extension = test_bundle / "Contents/PlugIns/BeaverMeterWidgetExtension.appex"
                subprocess.run(["/usr/bin/pluginkit", "-r", str(extension)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            register = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
            for test_bundle in [target, next_app, stage / "SparkleInstallHarness.app"]:
                subprocess.run([register, "-u", str(test_bundle)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            # The generated domain is unique to this test; never touch production defaults.
            for domain in [identifier, identifier + ".harness"]:
                subprocess.run(["/usr/bin/defaults", "delete", domain], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                for base in [pathlib.Path.home() / "Library/Caches", pathlib.Path.home() / "Library/Application Support"]:
                    test_cache = base / domain
                    if test_cache.exists():
                        shutil.rmtree(test_cache)


if __name__ == "__main__":
    main()
