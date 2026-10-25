#!/usr/bin/env python3
"""Use the pinned Sparkle tools without exposing the release key in argv or files."""
import argparse
import base64
import hashlib
import os
import pathlib
import plistlib
import re
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET

from release_metadata import DOWNLOAD_ROOT, NS, ROOT, SPARKLE_NS, SPARKLE_VERSION, metadata, public_key, verify_signature

KEYCHAIN_ACCOUNT = "BeaverMeter.Release"


def find_tools(derived_data=None, override=None):
    candidates = []
    if override:
        candidates.append(pathlib.Path(override))
    if derived_data:
        candidates.extend(pathlib.Path(derived_data).glob("SourcePackages/artifacts/*/Sparkle"))
    for candidate in candidates:
        framework = candidate / "Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
        if not framework.exists():
            framework = candidate / "Sparkle.framework"
        info_path = framework / "Resources/Info.plist"
        if not info_path.exists():
            continue
        with info_path.open("rb") as stream:
            info = plistlib.load(stream)
        if info.get("CFBundleShortVersionString") != SPARKLE_VERSION:
            continue
        if all((candidate / "bin" / name).is_file() for name in ("sign_update", "generate_appcast")):
            return candidate / "bin"
    raise ValueError("Sparkle 2.10.0 distribution tools not found; resolve the pinned Xcode package or set BEAVERMETER_SPARKLE_TOOLS_ROOT")


def signing_input():
    key = os.environ.get("BEAVERMETER_SPARKLE_PRIVATE_KEY")
    if key is not None:
        key = key.strip()
        try:
            raw = base64.b64decode(key, validate=True)
        except ValueError as error:
            raise ValueError("BEAVERMETER_SPARKLE_PRIVATE_KEY is not valid base64") from error
        if len(raw) not in (32, 96):
            raise ValueError("Sparkle signing key must be a 32-byte seed or 96-byte legacy key")
        return ["--ed-key-file", "-"], key + "\n"
    if os.environ.get("GITHUB_ACTIONS") == "true":
        raise ValueError("Tagged CI releases require the BEAVERMETER_SPARKLE_PRIVATE_KEY Actions secret")
    return ["--account", KEYCHAIN_ACCOUNT], None


def run_signing(tool, arguments):
    key_arguments, key_stdin = signing_input()
    environment = dict(os.environ)
    environment.pop("BEAVERMETER_SPARKLE_PRIVATE_KEY", None)
    result = subprocess.run([str(tool), *key_arguments, *arguments], input=key_stdin,
                            text=True, capture_output=True, env=environment)
    if result.returncode:
        # Tool diagnostics can contain imported key material. Keep them out of logs.
        raise ValueError(f"{tool.name} failed; check the release key, Keychain access and signed application metadata")
    return result.stdout.strip()


def check_key(tools, key_path):
    public_key(key_path)
    with tempfile.NamedTemporaryFile(prefix="beavermeter-signing-check-") as stream:
        stream.write(b"BeaverMeter release signing key verification\n")
        stream.flush()
        signature = run_signing(tools / "sign_update", ["-p", stream.name])
        try:
            verify_signature(pathlib.Path(stream.name), signature, key_path)
        except (ValueError, subprocess.CalledProcessError) as error:
            raise ValueError("Release signing key does not match Config/SparklePublicKey.txt") from error


def notes_for_version(version):
    changelog = (ROOT / "CHANGELOG.md").read_text()
    match = re.search(r"^## \[" + re.escape(version) + r"\][^\n]*\n(.*?)(?=^## \[|\Z)", changelog,
                                    re.M | re.S)
    if not match:
        match = re.search(r"^## \[Unreleased\][^\n]*\n(.*?)(?=^## \[|\Z)", changelog,
                                        re.M | re.S)
    changes = match[1].strip() if match else "See CHANGELOG.md in the source archive."
    return f"""# BeaverMeter {version}

{changes}

## Install / 安装

Download **BeaverMeter-{version}-universal.dmg**, drag BeaverMeter to Applications (or your home Applications folder), then open it. Supports macOS 14+ on Apple Silicon and Intel. No Xcode, XcodeGen or Homebrew is required.

下载 DMG，将 BeaverMeter 拖入 Applications（或用户目录下的 Applications）后打开。支持 Apple Silicon、Intel 和 macOS 14+，无需开发工具。

This build is ad-hoc signed and is not notarized. macOS may require confirmation in System Settings → Privacy & Security. Follow [Apple's instructions](https://support.apple.com/en-us/102445).

此版本未获得 Apple 公证，首次打开可能需要在系统设置 → 隐私与安全中确认。

Install this Sparkle-enabled release manually once; future stable updates download, verify, install and restart inside the app after you click Update. Your usage data and preferences are preserved.

首次手动安装此版本后，后续稳定版本可在应用内点击 Update 下载、校验、安装并重启，保留使用数据与设置。

Developers: **BeaverMeter-{version}-source.zip** contains the same tagged source. Verify all downloads against **SHA256SUMS**. See docs/RELEASE_POLICY.md in the source archive.
"""


def generate(tools, directory, version, build, key_path):
    check_key(tools, key_path)
    dmg_name = f"BeaverMeter-{version}-universal.dmg"
    # Only the current DMG goes into the generator's input; source ZIPs are not updates.
    with tempfile.TemporaryDirectory(prefix="beavermeter-appcast-") as temporary:
        stage = pathlib.Path(temporary)
        shutil.copy2(directory / dmg_name, stage / dmg_name)
        note_name = pathlib.Path(dmg_name).with_suffix(".md").name
        (stage / note_name).write_text(notes_for_version(version))
        prefix = f"{DOWNLOAD_ROOT}/v{version}/"
        run_signing(tools / "generate_appcast", ["--maximum-deltas", "0", "--maximum-versions", "1",
                    "--versions", str(build), "--download-url-prefix", prefix,
                    "--release-notes-url-prefix", prefix, "-o", str(stage / "appcast.xml"), str(stage)])
        parser = ET.XMLParser(target=ET.TreeBuilder(insert_comments=True))
        feed = ET.fromstring((stage / "appcast.xml").read_bytes(), parser=parser)
        items = feed.findall("./channel/item")
        if len(items) != 1:
            raise ValueError("Sparkle generator did not produce exactly one current item")
        notes = items[0].find("sparkle:releaseNotesLink", NS)
        if notes is None or not notes.get(f"{{{SPARKLE_NS}}}edSignature"):
            raise ValueError("Sparkle generator did not sign the Markdown release notes")
        notes.text = prefix + "release-notes.md"
        ET.register_namespace("sparkle", SPARKLE_NS)
        # Finalize filenames and URLs before the final feed signature. Notes bytes stay unchanged.
        (directory / "appcast.xml").write_bytes(ET.tostring(feed, encoding="utf-8", xml_declaration=True) + b"\n")
        shutil.copy2(stage / note_name, directory / "release-notes.md")
        run_signing(tools / "sign_update", [str(directory / "appcast.xml")])
    names = [dmg_name, f"BeaverMeter-{version}-source.zip", "appcast.xml", "release-notes.md"]
    lines = []
    for name in names:
        digest = hashlib.sha256()
        with (directory / name).open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
        lines.append(f"{digest.hexdigest()}  {name}\n")
    (directory / "SHA256SUMS").write_text("".join(lines))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--derived-data", type=pathlib.Path)
    parser.add_argument("--tools-root", default=os.environ.get("BEAVERMETER_SPARKLE_TOOLS_ROOT"))
    parser.add_argument("--public-key", type=pathlib.Path, default=ROOT / "Config/SparklePublicKey.txt")
    parser.add_argument("--check-key", action="store_true")
    parser.add_argument("--output", type=pathlib.Path)
    args = parser.parse_args()
    tools = find_tools(args.derived_data, args.tools_root)
    if args.check_key:
        check_key(tools, args.public_key)
        print("Release signing key matches the committed public key")
    elif args.output:
        version, build = metadata((ROOT / "project.yml").read_text())
        generate(tools, args.output, version, build, args.public_key)
    else:
        parser.error("Specify --check-key or --output")


if __name__ == "__main__":
    main()
