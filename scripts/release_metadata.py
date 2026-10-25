#!/usr/bin/env python3
"""Fail-closed validation of tagged builds, mounted DMGs and signed Sparkle assets."""
import argparse
import base64
import hashlib
import os
import pathlib
import plistlib
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPARKLE_VERSION = "2.10.0"
FEED_URL = "https://github.com/fusheng-ji/BeaverMeter/releases/latest/download/appcast.xml"
DOWNLOAD_ROOT = "https://github.com/fusheng-ji/BeaverMeter/releases/download"
SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
NS = {"sparkle": SPARKLE_NS}
MAGIC = {b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",
         b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"}
# The display version restarts at 1.0.0; previously distributed/local builds reached 36.
MINIMUM_RELEASE_BUILD = 37


def metadata(text):
    versions = re.findall(r"^\s*MARKETING_VERSION:\s*(\d+\.\d+\.\d+)\s*$", text, re.M)
    builds = re.findall(r"^\s*CURRENT_PROJECT_VERSION:\s*(\d+)\s*$", text, re.M)
    if len(versions) != 2 or len(set(versions)) != 1 or len(builds) != 2 or len(set(builds)) != 1:
        raise ValueError("App and Widget must have matching version and build numbers")
    return versions[0], int(builds[0])


def validate_build_progression(build, current_tag, tags, read_project):
    """Sparkle orders builds across the legacy 5.x and current 1.x display versions."""
    highest = MINIMUM_RELEASE_BUILD - 1
    for tag in tags:
        if tag == current_tag or not re.fullmatch(r"v\d+\.\d+\.\d+", tag):
            continue
        try:
            _, previous_build = metadata(read_project(tag))
        except (ValueError, subprocess.CalledProcessError) as error:
            raise ValueError(f"Cannot validate historical build metadata for {tag}") from error
        highest = max(highest, previous_build)
    if build <= highest:
        raise ValueError(f"Build number must exceed historical build {highest}")


def bool_value(value):
    return value is True or (isinstance(value, str) and value.lower() in ("yes", "true", "1"))


def public_key(path):
    text = path.read_text().strip()
    try:
        decoded = base64.b64decode(text, validate=True)
    except ValueError as error:
        raise ValueError("Sparkle public key must be valid base64") from error
    if len(decoded) != 32:
        raise ValueError("Sparkle public key must encode exactly 32 bytes")
    return text


def read_plist(bundle):
    with (bundle / "Contents/Info.plist").open("rb") as stream:
        return plistlib.load(stream)


def validate_update_settings(info, key, updates_enabled):
    if bool_value(info.get("BeaverMeterUpdatesEnabled")) != updates_enabled:
        raise ValueError("Updates must be enabled only in tagged release builds")
    if info.get("SUPublicEDKey") != key or info.get("SUFeedURL") != FEED_URL:
        raise ValueError("Release public key or fixed update feed URL does not match")
    for name in ("SURequireSignedFeed", "SUVerifyUpdateBeforeExtraction", "SUEnableAutomaticChecks"):
        if not bool_value(info.get(name)):
            raise ValueError(f"Required Sparkle security/check setting is disabled: {name}")
    for name in ("SUAutomaticallyUpdate", "SUAllowsAutomaticUpdates", "SUEnableSystemProfiling"):
        if name not in info or bool_value(info[name]):
            raise ValueError(f"Unexpected automatic download/install or profiling setting: {name}")
    if info.get("SUScheduledCheckInterval") != 43200 or info.get("SUSignedFeedFailureExpirationInterval") != 0:
        raise ValueError("Sparkle must check every 12 hours and never expire signature failures")


def validate_app(app, version, build, key=None, updates_enabled=True):
    key = key or public_key(ROOT / "Config/SparklePublicKey.txt")
    bundles = [(app, "io.github.fushengji.beavermeter"),
               (app / "Contents/PlugIns/BeaverMeterWidgetExtension.appex", "io.github.fushengji.beavermeter.widget")]
    for bundle, identifier in bundles:
        info = read_plist(bundle)
        if (info.get("CFBundleShortVersionString"), str(info.get("CFBundleVersion")), info.get("CFBundleIdentifier")) != (version, str(build), identifier):
            raise ValueError(f"Invalid release identity/version in {bundle}")
        if bundle == app:
            if not bool_value(info.get("BeaverMeterDirectInstall")):
                raise ValueError("Direct-install bootstrap is not enabled")
            validate_update_settings(info, key, updates_enabled)
    required = ["Helpers/BeaverMeterCollector", "Resources/collect_beaver_meter.sh",
                "Resources/configure_runtime.sh", "Resources/migrate_beavermeter_data.sh", "Resources/update_runtime.sh", "Resources/lib/install_common.sh",
                "Resources/lib/install_transaction.sh", "Resources/remote_codex_usage.py",
                "Resources/BrandAssets/beaver-standard.png", "Resources/ProviderAssets",
                "Resources/LICENSE", "Resources/THIRD_PARTY_NOTICES.md", "Frameworks/Sparkle.framework"]
    for resource in required:
        if not (app / "Contents" / resource).exists():
            raise ValueError(f"Missing runtime resource: {resource}")
    framework = app / "Contents/Frameworks/Sparkle.framework"
    for link in ("Versions/Current", "Resources", "Sparkle"):
        if not (framework / link).is_symlink():
            raise ValueError("Sparkle framework version symlinks were not preserved: " + link)
    with (framework / "Resources/Info.plist").open("rb") as stream:
        sparkle_info = plistlib.load(stream)
    if sparkle_info.get("CFBundleShortVersionString") != SPARKLE_VERSION:
        raise ValueError("Release must embed exactly Sparkle " + SPARKLE_VERSION)
    if (bundles[1][0] / "Contents/Frameworks/Sparkle.framework").exists():
        raise ValueError("Sparkle must only be embedded in the main application")
    for variant in ["standard", "newYear", "lunarNewYear", "lanternFestival", "dragonBoat",
                    "midAutumn", "programmerDay", "halloween", "christmas"]:
        for suffix in ["", "-template"]:
            if not (app / f"Contents/Resources/BrandAssets/beaver-{variant}{suffix}.png").exists():
                raise ValueError(f"Missing brand asset: {variant}{suffix}")
    binaries = set()
    for binary in app.rglob("*"):
        if binary.is_file() and binary.resolve() not in binaries:
            with binary.open("rb") as stream:
                header = stream.read(4)
            if header in MAGIC:
                subprocess.run(["/usr/bin/lipo", str(binary), "-verify_arch", "arm64", "x86_64"], check=True)
                subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(binary)], check=True)
                binaries.add(binary.resolve())
    if len(binaries) < 6:
        raise ValueError("App, Widget, collector, Sparkle and its installer helpers must be present")
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    identity = subprocess.run(["/usr/bin/codesign", "-d", "--verbose=2", str(app)], check=True, capture_output=True, text=True).stderr
    if "Signature=adhoc" not in identity or "Identifier=io.github.fushengji.beavermeter\n" not in identity:
        raise ValueError("Release app must have the fixed identity and ad-hoc signature")
    print(f"Validated {len(binaries)} universal signed executables, runtime resources and Sparkle settings")


def feed_signature(data):
    # Sparkle signs the bytes before its final signature comment (SPUExtractSignedFeed).
    match = re.search(rb"<!-- sparkle-signatures:\nedSignature: ([A-Za-z0-9+/=]+)\nlength: ([0-9]+)\n-->\n?\Z", data)
    if match is None or b"<!-- sparkle-signatures:" in data[:match.start()]:
        raise ValueError("Appcast must contain one final Sparkle signature block")
    content = data[:match.start()]
    if int(match[2]) != len(content):
        raise ValueError("Appcast signed length does not match")
    return content, match[1].decode()


def verify_signature(path, signature, key_path):
    try:
        if len(base64.b64decode(signature, validate=True)) != 64:
            raise ValueError("Invalid Ed25519 signature length")
    except (ValueError, TypeError) as error:
        raise ValueError("Invalid Ed25519 release signature") from error
    environment = dict(os.environ)
    environment.pop("BEAVERMETER_SPARKLE_PRIVATE_KEY", None)
    subprocess.run(["/usr/bin/swift", "-module-cache-path", str(ROOT / ".build/sparkle-verifier-modules"),
                    str(ROOT / "scripts/verify_sparkle_signature.swift"),
                    str(key_path), str(path), signature], check=True, env=environment)


def validate_artifacts(directory, version, build, key_path):
    public_key(key_path)
    dmg_name = f"BeaverMeter-{version}-universal.dmg"
    names = [dmg_name, f"BeaverMeter-{version}-source.zip", "appcast.xml", "release-notes.md"]
    expected = set(names + ["SHA256SUMS"])
    actual = {path.name for path in directory.iterdir()}
    if actual != expected:
        raise ValueError("Tagged release must contain exactly DMG, source ZIP, appcast, release notes and SHA256SUMS")
    sums = {}
    for line in (directory / "SHA256SUMS").read_text().splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  ([^/]+)", line)
        if not match or match[2] in sums:
            raise ValueError("Invalid or duplicate checksum entry")
        sums[match[2]] = match[1]
    if set(sums) != set(names):
        raise ValueError("SHA256SUMS must cover all four release assets")
    for name in names:
        digest = hashlib.sha256()
        with (directory / name).open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
        if digest.hexdigest() != sums[name]:
            raise ValueError(f"Release checksum mismatch: {name}")
    content, signature = feed_signature((directory / "appcast.xml").read_bytes())
    with tempfile.NamedTemporaryFile(prefix="beavermeter-feed-", suffix=".xml") as stream:
        stream.write(content)
        stream.flush()
        verify_signature(pathlib.Path(stream.name), signature, key_path)
    feed = ET.fromstring(content)
    items = feed.findall("./channel/item")
    if len(items) != 1 or feed.findall(".//sparkle:deltas", NS):
        raise ValueError("Appcast must contain exactly the current stable item with no delta updates")
    item = items[0]
    if (item.findtext("sparkle:version", namespaces=NS), item.findtext("sparkle:shortVersionString", namespaces=NS)) != (str(build), version):
        raise ValueError("Appcast build/version must match the packaged application")
    if item.findtext("sparkle:minimumSystemVersion", namespaces=NS) != "14.0":
        raise ValueError("Appcast must require macOS 14.0")
    enclosure = item.find("enclosure")
    if enclosure is None or enclosure.get("url") != f"{DOWNLOAD_ROOT}/v{version}/{dmg_name}":
        raise ValueError("Update enclosure must use the immutable version-tag DMG URL")
    if enclosure.get("length") != str((directory / dmg_name).stat().st_size):
        raise ValueError("Appcast archive length must match the DMG")
    verify_signature(directory / dmg_name, enclosure.get(f"{{{SPARKLE_NS}}}edSignature"), key_path)
    notes = item.find("sparkle:releaseNotesLink", NS)
    if notes is None or notes.text != f"{DOWNLOAD_ROOT}/v{version}/release-notes.md":
        raise ValueError("Signed release notes must use the immutable version-tag URL")
    if notes.get(f"{{{SPARKLE_NS}}}length") != str((directory / "release-notes.md").stat().st_size):
        raise ValueError("Appcast release notes length does not match")
    verify_signature(directory / "release-notes.md", notes.get(f"{{{SPARKLE_NS}}}edSignature"), key_path)
    subprocess.run(["/usr/bin/unzip", "-t", str(directory / f"BeaverMeter-{version}-source.zip")], check=True, stdout=subprocess.DEVNULL)
    print("Validated all five release assets, checksums, immutable URLs and public-key signatures")


def validate_dmg(dmg, version, build, key, updates_enabled):
    subprocess.run(["/usr/bin/hdiutil", "verify", str(dmg)], check=True)
    with tempfile.TemporaryDirectory(prefix="beavermeter-dmg-check-") as temporary:
        mount = pathlib.Path(temporary) / "volume"
        mount.mkdir()
        subprocess.run(["/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", str(mount), str(dmg)], check=True)
        try:
            if not (mount / "Applications").is_symlink() or (mount / "Applications").readlink() != pathlib.Path("/Applications"):
                raise ValueError("DMG must contain the Applications drag-install link")
            if sorted(path.name for path in mount.glob("*.app")) != ["BeaverMeter.app"]:
                raise ValueError("DMG must contain exactly the complete BeaverMeter application")
            validate_app(mount / "BeaverMeter.app", version, build, key, updates_enabled)
        finally:
            subprocess.run(["/usr/bin/hdiutil", "detach", str(mount)], check=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--tag")
    parser.add_argument("--app", type=pathlib.Path)
    parser.add_argument("--dmg", type=pathlib.Path)
    parser.add_argument("--artifacts", type=pathlib.Path)
    parser.add_argument("--local", action="store_true")
    parser.add_argument("--public-key", type=pathlib.Path, default=ROOT / "Config/SparklePublicKey.txt")
    args = parser.parse_args()
    version, build = metadata((ROOT / "project.yml").read_text())
    if args.tag:
        if args.tag != "v" + version:
            raise ValueError("Release tag does not match project.yml")
        if subprocess.check_output(["git", "rev-parse", args.tag + "^{commit}"], cwd=ROOT).strip() != subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT).strip():
            raise ValueError("Release tag must identify this checkout")
        tags = subprocess.check_output(["git", "tag", "--list", "v*"], cwd=ROOT, text=True).splitlines()
        validate_build_progression(build, args.tag, tags, lambda tag:
            subprocess.check_output(["git", "show", tag + ":project.yml"], cwd=ROOT, text=True))
    if args.app or args.dmg:
        key = public_key(args.public_key)
        if args.app:
            validate_app(args.app, version, build, key, not args.local)
        if args.dmg:
            validate_dmg(args.dmg, version, build, key, not args.local)
    if args.artifacts:
        if args.local:
            raise ValueError("Local builds cannot produce a production appcast")
        validate_artifacts(args.artifacts, version, build, args.public_key)
    if not (args.app or args.dmg or args.artifacts):
        print(version)


if __name__ == "__main__":
    main()
