"""Exercise cleanup boundaries through the public Make targets."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[2]


class CleanTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="jzm-make-test-")
        self.addCleanup(self.temporary.cleanup)
        self.project = Path(self.temporary.name)
        shutil.copyfile(PROJECT / "Makefile", self.project / "Makefile")
        for name in ("src", "tools", "tests", ".emulator"):
            (self.project / name).mkdir()
        self.source = self.project / "src/main.uc"
        self.source.write_text("source sentinel")
        self.firmware = self.project / ".emulator/firmware"
        self.firmware.write_text("cached firmware sentinel")
        self.env = {key: value for key, value in os.environ.items()
                    if key not in {"MAKEFLAGS", "MFLAGS", "MAKELEVEL", "MAKEOVERRIDES", "MAKEFILES"}}

    def make(self, *args, cwd=None):
        return subprocess.run(["make", "--no-print-directory", *args],
                              cwd=cwd or self.project, env=self.env,
                              text=True, capture_output=True, timeout=10)

    def generated(self):
        for name in ("dist", ".test-tmp", ".build-tmp"):
            folder = self.project / name
            folder.mkdir()
            (folder / "generated").write_text("generated sentinel")

    def test_clean_removes_outputs_idempotently_and_preserves_sources_and_emulator(self):
        self.generated()
        for _ in range(2):
            result = self.make("clean")
            self.assertEqual(result.returncode, 0, result.stderr)
            for name in ("dist", ".test-tmp", ".build-tmp"):
                self.assertFalse((self.project / name).exists())
            self.assertEqual(self.source.read_text(), "source sentinel")
            self.assertEqual(self.firmware.read_text(), "cached firmware sentinel")

    def test_clean_unlinks_generated_directory_symlinks_without_following_them(self):
        outside = self.project / "outside"
        outside.mkdir()
        sentinel = outside / "keep"
        sentinel.write_text("external sentinel")
        for name in ("dist", ".test-tmp", ".build-tmp"):
            (self.project / name).symlink_to(outside, target_is_directory=True)
        result = self.make("clean")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sentinel.read_text(), "external sentinel")
        for name in ("dist", ".test-tmp", ".build-tmp"):
            self.assertFalse((self.project / name).is_symlink())

    def test_clean_cannot_race_with_build_or_test_goals(self):
        self.generated()
        for args in (("-j8", "clean", "bundle"), ("-j8", "test-e2e", "clean")):
            with self.subTest(args=args):
                result = self.make(*args)
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue((self.project / "dist/generated").exists())
                self.assertEqual(self.source.read_text(), "source sentinel")

    def test_active_emulator_lock_prevents_clean(self):
        self.generated()
        lock = self.project / ".emulator/.e2e.lock"
        lock.mkdir()
        result = self.make("clean")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(lock.is_dir())
        self.assertTrue((self.project / ".test-tmp/generated").exists())

    def test_makefile_from_another_directory_cannot_clean_that_directory(self):
        caller = self.project / "caller"
        caller.mkdir()
        (caller / "dist").mkdir()
        sentinel = caller / "dist/keep"
        sentinel.write_text("caller sentinel")
        result = self.make("-f", str(self.project / "Makefile"), "clean", cwd=caller)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(sentinel.read_text(), "caller sentinel")
