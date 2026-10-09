import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("assemble", ROOT / "scripts/assemble.py")
assemble = importlib.util.module_from_spec(spec)
spec.loader.exec_module(assemble)

class AssembleTests(unittest.TestCase):
    def test_selects_existing_non_pic_or_pic_objects_without_nesting_archives(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            library = root / "libarchive"
            (library / ".libs").mkdir(parents=True)
            (library / "archive_read.o").touch()
            (library / ".libs/archive_write.o").touch()
            (library / "archive_read.lo").write_text("non_pic_object='archive_read.o'\npic_object='none'\n")
            (library / "archive_write.lo").write_text("non_pic_object='none'\npic_object='.libs/archive_write.o'\n")
            self.assertEqual(assemble.object_paths(root), [
                (library / "archive_read.o").resolve(), (library / ".libs/archive_write.o").resolve()
            ])

    def test_rejects_object_paths_outside_the_build(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "build"
            (root / "libarchive").mkdir(parents=True)
            (root.parent / "outside.o").touch()
            (root / "libarchive/archive_read.lo").write_text("non_pic_object='../../outside.o'\n")
            with self.assertRaises(ValueError):
                assemble.object_paths(root)

    def test_empty_or_missing_object_sets_cannot_make_a_release(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(ValueError):
                assemble.object_paths(directory)
            library = Path(directory) / "libarchive"
            library.mkdir()
            (library / "archive_read.lo").write_text("non_pic_object='missing.o'\n")
            with self.assertRaises(ValueError):
                assemble.object_paths(directory)

if __name__ == "__main__":
    unittest.main()
