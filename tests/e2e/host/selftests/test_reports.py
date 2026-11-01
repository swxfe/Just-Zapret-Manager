import io
import json
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
import reports

class ReportTests(unittest.TestCase):
    def render(self, root, code):
        with redirect_stdout(io.StringIO()):
            return reports.render(root, code)

    def test_guest_failure_and_skips_are_visible_in_both_formats(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "guest").mkdir()
            (root / "guest/complete").touch()
            (root / "host.tsv").write_text("pass\tboot\t4\n", encoding="utf-8")
            (root / "guest/results.tsv").write_text("fail\trollback\t2\nskip\tlater\t0\n", encoding="utf-8")
            result = self.render(root, 1)
            self.assertEqual(result["totals"], {"pass": 1, "fail": 1, "skip": 1})
            self.assertFalse(result["success"])
            self.assertIn("not ok 2 - router/rollback", (root / "report.tap").read_text())
            self.assertIn("# SKIP", (root / "report.tap").read_text())
            self.assertEqual(json.loads((root / "report.json").read_text()), result)

    def test_incomplete_guest_cannot_pass_even_with_zero_exit_status(self):
        with tempfile.TemporaryDirectory() as temporary:
            result = self.render(Path(temporary), 0)
            self.assertFalse(result["success"])
            self.assertFalse(result["guest_complete"])

    def test_success_requires_a_completed_guest_and_no_failures(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "guest").mkdir()
            (root / "guest/complete").touch()
            (root / "guest/results.tsv").write_text("pass\tstatus\t1\n", encoding="utf-8")
            self.assertTrue(self.render(root, 0)["success"])
