#!/usr/bin/env python3
"""Compare uploaded source contents with git archive without extracting ZIP paths."""
import argparse
import pathlib
import stat
import subprocess
import tempfile
import zipfile

from release_metadata import ROOT, metadata


def entry_type(entry):
    kind = stat.S_IFMT(entry.external_attr >> 16)
    if kind == 0:
        kind = stat.S_IFDIR if entry.is_dir() else stat.S_IFREG
    if kind not in (stat.S_IFREG, stat.S_IFDIR, stat.S_IFLNK):
        raise ValueError("Source archive contains an unsupported file type")
    if (kind == stat.S_IFDIR) != entry.is_dir():
        raise ValueError("Source archive directory mode does not match its path")
    return kind


def entries(archive):
    result = {}
    for entry in archive.infolist():
        name = entry.filename
        parts = name.rstrip("/").split("/")
        if (name.startswith("/") or "\\" in name or
                any(part in ("", ".", "..") for part in parts) or name in result):
            raise ValueError("Source archive contains an unsafe or duplicate path")
        if entry.flag_bits & 1:
            raise ValueError("Source archive must not contain encrypted entries")
        entry_type(entry)
        result[name] = entry
    return result


def compare_source_archives(uploaded_path, expected_path):
    with zipfile.ZipFile(uploaded_path) as uploaded, zipfile.ZipFile(expected_path) as expected:
        actual_entries, expected_entries = entries(uploaded), entries(expected)
        if actual_entries.keys() != expected_entries.keys():
            raise ValueError("Source archive paths do not match the release tag")
        for name, expected_entry in expected_entries.items():
            entry = actual_entries[name]
            actual_mode, expected_mode = entry.external_attr >> 16, expected_entry.external_attr >> 16
            # Ignore ZIP compression, timestamps and non-executable permission variations.
            # Preserve directory, executable and symlink semantics from the tagged source.
            if (entry_type(entry) != entry_type(expected_entry) or
                    bool(actual_mode & 0o111) != bool(expected_mode & 0o111) or
                    entry.file_size != expected_entry.file_size or
                    uploaded.read(entry) != expected.read(expected_entry)):
                raise ValueError("Source archive contents or file types do not match the release tag: " + name)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("archive", type=pathlib.Path)
    parser.add_argument("tag")
    args = parser.parse_args()
    version, _ = metadata((ROOT / "project.yml").read_text())
    if args.tag != "v" + version:
        raise ValueError("Source archive tag does not match project.yml")
    with tempfile.TemporaryDirectory(prefix="beavermeter-source-check-") as temporary:
        expected = pathlib.Path(temporary) / "expected.zip"
        with expected.open("wb") as stream:
            subprocess.run(["git", "archive", "--format=zip", f"--prefix=BeaverMeter-{version}/", args.tag],
                           cwd=ROOT, stdout=stream, check=True)
        compare_source_archives(args.archive, expected)
    print("Validated source archive contents against the exact release tag")


if __name__ == "__main__":
    main()
