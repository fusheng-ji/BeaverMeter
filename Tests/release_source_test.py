import pathlib
import stat
import sys
import tempfile
import unittest
import warnings
import zipfile

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "scripts"))
from verify_release_source import compare_source_archives


class ReleaseSourceTests(unittest.TestCase):
    def archive(self, path, items, compression=zipfile.ZIP_STORED):
        with zipfile.ZipFile(path, "w", compression=compression) as archive:
            for name, content, mode in items:
                info = zipfile.ZipInfo(name)
                info.external_attr = mode << 16
                info.compress_type = compression
                archive.writestr(info, content)

    def test_contents_match_despite_compression_and_ordinary_permission_metadata(self):
        with tempfile.TemporaryDirectory() as temporary:
            expected, actual = (pathlib.Path(temporary) / name for name in ("expected.zip", "actual.zip"))
            self.archive(expected, [("BeaverMeter-1.0.1/main.swift", b"source", 0)])
            self.archive(actual, [("BeaverMeter-1.0.1/main.swift", b"source", stat.S_IFREG | 0o644)], zipfile.ZIP_DEFLATED)
            compare_source_archives(actual, expected)

    def test_missing_extra_changed_or_executable_sources_fail(self):
        original = [("BeaverMeter-1.0.1/run.sh", b"source", stat.S_IFREG | 0o755)]
        changed = [[], original + [("BeaverMeter-1.0.1/extra", b"extra", 0)],
                   [(original[0][0], b"change", original[0][2])],
                   [(original[0][0], b"source", stat.S_IFREG | 0o644)]]
        with tempfile.TemporaryDirectory() as temporary:
            expected, actual = (pathlib.Path(temporary) / name for name in ("expected.zip", "actual.zip"))
            self.archive(expected, original)
            for items in changed:
                with self.subTest(items=items):
                    self.archive(actual, items)
                    with self.assertRaises(ValueError):
                        compare_source_archives(actual, expected)

    def test_symlink_cannot_be_replaced_by_regular_file_with_same_contents(self):
        with tempfile.TemporaryDirectory() as temporary:
            expected, actual = (pathlib.Path(temporary) / name for name in ("expected.zip", "actual.zip"))
            self.archive(expected, [("BeaverMeter-1.0.1/link", b"target", stat.S_IFLNK | 0o777)])
            self.archive(actual, [("BeaverMeter-1.0.1/link", b"target", stat.S_IFREG | 0o777)])
            with self.assertRaises(ValueError):
                compare_source_archives(actual, expected)

    def test_special_file_types_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            expected, actual = (pathlib.Path(temporary) / name for name in ("expected.zip", "actual.zip"))
            self.archive(expected, [("BeaverMeter-1.0.1/main", b"source", 0)])
            self.archive(actual, [("BeaverMeter-1.0.1/main", b"source", stat.S_IFIFO | 0o644)])
            with self.assertRaises(ValueError):
                compare_source_archives(actual, expected)

    def test_explicit_directory_types_must_match_path_suffix(self):
        with tempfile.TemporaryDirectory() as temporary:
            expected, actual = (pathlib.Path(temporary) / name for name in ("expected.zip", "actual.zip"))
            for name, content, wrong_mode in [
                    ("BeaverMeter-1.0.1/main", b"source", stat.S_IFDIR | 0o644),
                    ("BeaverMeter-1.0.1/folder/", b"", stat.S_IFREG | 0o644)]:
                with self.subTest(name=name):
                    self.archive(expected, [(name, content, 0)])
                    self.archive(actual, [(name, content, wrong_mode)])
                    with self.assertRaisesRegex(ValueError, "directory mode"):
                        compare_source_archives(actual, expected)

    def test_unsafe_and_duplicate_paths_fail_without_extracting(self):
        with tempfile.TemporaryDirectory() as temporary:
            expected, actual = (pathlib.Path(temporary) / name for name in ("expected.zip", "actual.zip"))
            self.archive(expected, [("BeaverMeter-1.0.1/main", b"source", 0)])
            for name in ["../outside", "/absolute", "BeaverMeter-1.0.1/../outside", "BeaverMeter-1.0.1\\main", "BeaverMeter-1.0.1//main"]:
                self.archive(actual, [(name, b"source", 0)])
                with self.subTest(name=name), self.assertRaises(ValueError):
                    compare_source_archives(actual, expected)
            with warnings.catch_warnings():
                warnings.simplefilter("ignore", UserWarning)
                self.archive(actual, [("BeaverMeter-1.0.1/main", b"source", 0)] * 2)
            with self.assertRaises(ValueError):
                compare_source_archives(actual, expected)


if __name__ == "__main__":
    unittest.main()
