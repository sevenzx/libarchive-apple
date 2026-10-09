import copy
import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("source_lock", ROOT / "scripts/source_lock.py")
source_lock = importlib.util.module_from_spec(spec)
spec.loader.exec_module(source_lock)

class SourceLockTests(unittest.TestCase):
    def setUp(self):
        self.lock = json.loads((ROOT / "sources.lock.json").read_text())

    def test_rejects_shell_and_path_injection_versions(self):
        for value in ["latest", "../3.8.9", "3.8.9;id", "$(id)", "3.8.9\n", "v3.8.9", "03.8.9", "3.1000.0"]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                source_lock.validate_version(value)

    def test_rejects_moved_archive_even_with_valid_hash(self):
        self.lock["libarchive"]["url"] = "https://example.com/libarchive.tar.gz"
        with self.assertRaises(ValueError):
            source_lock.validate(self.lock)

    def test_version_url_mismatch_fails_before_download(self):
        self.lock["libarchive"]["version"] = "3.8.8"
        with self.assertRaises(ValueError):
            source_lock.validate(self.lock)

    def test_release_without_independent_digest_is_not_trusted(self):
        source = self.lock["libarchive"]
        release = {"tag_name": "v3.8.9", "assets": [{
            "name": "libarchive-3.8.9.tar.gz", "browser_download_url": source["url"]
        }]}
        with self.assertRaises(ValueError):
            source_lock.source_from_release("libarchive", "3.8.9", release)

    def test_prerelease_and_wrong_tag_are_rejected(self):
        source = self.lock["libarchive"]
        release = {"tag_name": "v3.8.9", "assets": [{
            "name": "libarchive-3.8.9.tar.gz", "browser_download_url": source["url"],
            "digest": "sha256:" + source["sha256"]
        }]}
        for mutation in [{"prerelease": True}, {"draft": True}, {"tag_name": "v3.8.8"}]:
            candidate = copy.deepcopy(release)
            candidate.update(mutation)
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                source_lock.source_from_release("libarchive", "3.8.9", candidate)

    def test_selected_release_digest_is_preserved(self):
        source = self.lock["libarchive"]
        release = {"tag_name": "v3.8.9", "assets": [{
            "name": "libarchive-3.8.9.tar.gz", "browser_download_url": source["url"],
            "digest": "sha256:" + source["sha256"]
        }]}
        self.assertEqual(source_lock.source_from_release("libarchive", "3.8.9", release), source)

if __name__ == "__main__":
    unittest.main()

