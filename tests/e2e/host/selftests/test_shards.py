import io
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import time
import unittest
from collections import Counter
from contextlib import redirect_stdout

from emulator_fixture import EmulatorFixture, PROJECT
import reports
import shards


class PlanTests(unittest.TestCase):
    def test_every_case_is_assigned_once_and_original_order_is_preserved(self):
        names = shards.case_names(PROJECT)
        self.assertEqual(len(names), 36)
        for count in (1, 2, 4, 8):
            with self.subTest(count=count):
                groups = shards.partition(names, count)
                self.assertEqual(len(groups), count)
                self.assertEqual(Counter(name for group in groups for name in group), Counter(names))
                for group in groups:
                    self.assertEqual(group, sorted(group, key=names.index))
                    self.assertTrue(group)
                    if "remove_packages" in group:
                        self.assertEqual(group[-1], "remove_packages")
                loads = [sum(shards.COSTS.get(name, 7) for name in group) for group in groups]
                self.assertLessEqual(max(loads) - min(loads), max(shards.COSTS.values()))

    def test_failed_latest_run_does_not_erase_successful_case_and_reset_timings(self):
        import tempfile
        with tempfile.TemporaryDirectory() as temporary:
            project = Path(temporary)
            reports_folder = project / ".test-tmp/e2e"
            good = reports_folder / "good"
            bad = reports_folder / "bad"
            (good / "guest").mkdir(parents=True)
            bad.mkdir()
            (good / "guest/resets.tsv").write_text("live_status\t7\n")
            (good / "report.json").write_text(json.dumps(
                {"success": True, "cases": [{"name": "router/live_status", "status": "pass", "seconds": 3}]}))
            (bad / "report.json").write_text(json.dumps({"success": False, "cases": []}))
            (reports_folder / "latest.txt").write_text(str(bad))
            self.assertEqual(shards.history(project), {"live_status": 10})

    def test_invalid_or_repeated_selections_cannot_execute_shell(self):
        for value in ("", "public_contract public_contract", "unknown", "public_contract; touch /tmp/injected"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                shards.selection(PROJECT, value)

    def test_auto_workers_respect_cpu_and_memory_and_explicit_values_are_bounded(self):
        self.assertEqual(shards.worker_count("auto", cpus=16, available=16 * 1024**3), 8)
        self.assertEqual(shards.worker_count("auto", cpus=2, available=16 * 1024**3), 1)
        self.assertEqual(shards.worker_count("auto", cpus=16, available=2 * 1024**3), 1)
        for value in ("", "0", "9", "-1", "2.5", "many"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                shards.worker_count(value, cpus=16, available=16 * 1024**3)
        with self.assertRaises(ValueError):
            shards.worker_count("4", cpus=16, available=2 * 1024**3)

    def test_missing_duplicate_unexpected_and_skipped_guest_cases_cannot_pass(self):
        import tempfile
        for rows in ("pass\tone\t0\n", "pass\tone\t0\npass\tone\t0\n",
                     "pass\tone\t0\npass\tother\t0\n", "pass\tone\t0\nskip\ttwo\t0\n"):
            with self.subTest(rows=rows), tempfile.TemporaryDirectory() as temporary:
                folder = Path(temporary)
                (folder / "guest").mkdir()
                (folder / "guest/complete").touch()
                (folder / "expected-cases.txt").write_text("one\ntwo\n")
                (folder / "guest/results.tsv").write_text(rows)
                with redirect_stdout(io.StringIO()):
                    result = reports.render(folder, 0)
                self.assertFalse(result["success"])


class ParallelRunnerTests(EmulatorFixture):
    def child_reports(self):
        root = next((self.root / ".test-tmp/e2e").glob("*/report.json")).parent
        return list(root.glob("shards/*/*/report.json"))

    def assert_children_stopped(self):
        for path in self.child_reports():
            pid = path.parent / "emulator.pid"
            if pid.exists():
                with self.assertRaises(ProcessLookupError):
                    os.kill(int(pid.read_text()), 0)

    def test_four_routers_cover_all_cases_once_with_private_flash_and_ports(self):
        self.env["E2E_WORKERS"] = "4"
        completed = self.run_fixture("success")
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        result = self.result()
        self.assertTrue(result["success"])
        self.assertEqual(result["coverage"]["expected"], 36)
        self.assertEqual(result["coverage"]["received"], 36)
        self.assertEqual(result["coverage"]["duplicates"], [])
        self.assertEqual(len(self.child_reports()), 4)
        for path in self.child_reports():
            self.assertEqual(Path((path.parent.parent / "latest.txt").read_text().strip()), path.parent)
        plan = json.loads(next((self.root / ".test-tmp/e2e").glob("*/plan.json")).read_text())
        self.assertEqual(len({row["port"] for row in plan}), 4)
        self.assertEqual(len({row["workspace"] for row in plan}), 4)
        self.assertTrue(all(not Path(row["workspace"]).exists() for row in plan))
        self.assert_children_stopped()

    def test_one_failed_router_fails_the_aggregate_without_losing_other_results(self):
        self.env["E2E_WORKERS"] = "2"
        # Corrupt just one worker's result while the other worker succeeds.
        mock = self.bin / "scp"
        script = mock.read_text().replace('if [ "$FAKE_MODE" = failure ]; then',
                                         'if [ "$FAKE_MODE" = failure ] && [ "$E2E_SSH_PORT" = "' +
                                         self.env["E2E_SSH_PORT"] + '" ]; then')
        mock.write_text(script)
        ssh = self.bin / "ssh"
        ssh.write_text(ssh.read_text().replace('[ "$FAKE_MODE" != failure ]',
                       '[ "$FAKE_MODE:$E2E_SSH_PORT" != "failure:' + self.env["E2E_SSH_PORT"] + '" ]'))
        completed = self.run_fixture("failure")
        self.assertNotEqual(completed.returncode, 0)
        result = self.result()
        self.assertFalse(result["success"])
        self.assertEqual(result["coverage"]["received"], 36)
        self.assertGreater(result["totals"]["pass"], 0)
        self.assertGreater(result["totals"]["fail"], 0)
        self.assertEqual(len(self.child_reports()), 2)
        self.assertEqual(sorted(json.loads(path.read_text())["success"] for path in self.child_reports()),
                         [False, True])
        self.assert_children_stopped()

    def test_busy_second_port_fails_before_starting_any_router(self):
        self.env["E2E_WORKERS"] = "2"
        with socket.socket() as busy:
            busy.bind(("127.0.0.1", int(self.env["E2E_SSH_PORT"]) + 1))
            completed = self.run_fixture("success")
        self.assertNotEqual(completed.returncode, 0)
        self.assertFalse(self.result()["success"])
        self.assertEqual(self.child_reports(), [])

    def test_missing_completion_in_any_router_cannot_pass_the_aggregate(self):
        self.env["E2E_WORKERS"] = "2"
        completed = self.run_fixture("incomplete")
        self.assertNotEqual(completed.returncode, 0)
        self.assertFalse(self.result()["success"])
        self.assertFalse(self.result()["guest_complete"])
        self.assertEqual(self.result()["coverage"]["received"], 36)
        self.assert_children_stopped()

    def test_another_runs_lock_is_preserved(self):
        self.env.update(E2E_WORKERS="2", FAKE_MODE="success")
        lock = self.root / ".emulator/.e2e.lock"
        lock.mkdir()
        (lock / "pid").write_text("foreign-owner")
        completed = subprocess.run(self.command(), env=self.env, capture_output=True, timeout=10)
        self.assertNotEqual(completed.returncode, 0)
        self.assertEqual((lock / "pid").read_text(), "foreign-owner")
        self.assertFalse(self.result()["success"])
        self.assertEqual(self.child_reports(), [])
        (lock / "pid").unlink()
        lock.rmdir()

    def test_term_collects_failure_reports_and_stops_every_emulator(self):
        self.env.update(E2E_WORKERS="2", FAKE_MODE="signal")
        process = subprocess.Popen(self.command(), env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 10
            plan = []
            while time.monotonic() < deadline:
                paths = list((self.root / ".test-tmp/e2e").glob("*/plan.json"))
                if paths:
                    try:
                        plan = json.loads(paths[0].read_text())
                    except json.JSONDecodeError:
                        pass
                if plan and all((Path(row["workspace"]) / "guest-entered").exists() for row in plan):
                    break
                self.assertIsNone(process.poll())
                time.sleep(.02)
            self.assertEqual(len(plan), 2)
            self.assertTrue(all((Path(row["workspace"]) / "guest-entered").exists() for row in plan))
            process.send_signal(signal.SIGTERM)
            out, error = process.communicate(timeout=15)
            self.assertEqual(process.returncode, 143, (out, error))
            self.assert_cleanup()
            self.assertFalse(self.result()["success"])
            self.assert_children_stopped()
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()
