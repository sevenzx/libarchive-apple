import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

class PackagingTests(unittest.TestCase):
    def test_wrong_version_cannot_overwrite_or_relabel_an_existing_artifact(self):
        lock = json.loads((ROOT / "sources.lock.json").read_text())
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            framework = output / "LibraArchive.xcframework"
            framework.mkdir()
            wrong = json.loads(json.dumps(lock))
            wrong["libarchive"]["version"] = "3.8.8"
            wrong["libarchive"]["url"] = wrong["libarchive"]["url"].replace("3.8.9", "3.8.8")
            (framework / "sources.lock.json").write_text(json.dumps(wrong))
            archive = output / "LibraArchive.xcframework.zip"
            archive.write_bytes(b"known-good-artifact")
            result = subprocess.run([
                sys.executable, str(ROOT / "scripts/package.py"),
                "--lock", str(ROOT / "sources.lock.json"), "--output", str(output)
            ], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("does not match", result.stderr)
            self.assertEqual(archive.read_bytes(), b"known-good-artifact")
            self.assertFalse((output / "artifact.json").exists())

if __name__ == "__main__":
    unittest.main()

