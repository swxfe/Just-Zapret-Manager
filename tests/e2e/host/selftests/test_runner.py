import shutil
import subprocess
import time

from emulator_fixture import EmulatorFixture, PROJECT


class RunnerTests(EmulatorFixture):
    def test_happy_path_preserves_bootstrap_stdin_and_pristine_flash(self):
        completed = self.run_fixture("success")
        self.assertEqual(completed.returncode, 0, completed.stdout.decode(errors="replace") + completed.stderr.decode(errors="replace"))
        self.assertEqual((self.root / "bootstrap-received").read_bytes(), subprocess.check_output([self.shell, str(PROJECT / "tests/e2e/run.sh"), "payload", "bootstrap"], env=self.env))
        self.assertTrue(self.result()["success"])

    def test_guest_failure_still_collects_reports_and_kills_emulator(self):
        self.assertNotEqual(self.run_fixture("failure").returncode, 0)
        self.assertTrue(self.result()["guest_complete"])
        self.assertGreater(self.result()["totals"]["fail"], 0)

    def test_missing_completion_marker_is_not_reported_as_success(self):
        self.assertNotEqual(self.run_fixture("incomplete").returncode, 0)
        self.assertFalse(self.result()["success"])

    def test_missing_emulator_requires_explicit_setup(self):
        shutil.rmtree(self.root / ".emulator")
        self.env["FAKE_MODE"] = "success"
        completed = subprocess.run(self.command(), env=self.env, capture_output=True, timeout=30)
        self.assertNotEqual(completed.returncode, 0)
        self.assertFalse((self.root / ".emulator").exists(), "runner silently recreated emulator")
        self.assertFalse(self.result()["success"])

    def test_boot_timeout_is_bounded_and_reported(self):
        self.assertNotEqual(self.run_fixture("timeout").returncode, 0)
        self.assertIn({"name": "host/ssh_ready", "status": "fail"},
                      [{"name": c["name"], "status": c["status"]} for c in self.result()["cases"]])

    def test_term_interrupts_wait_and_cleans_up(self):
        self.env["FAKE_MODE"] = "signal"
        process = subprocess.Popen(self.command(), env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 15
            while not (self.root / "guest-entered").exists() and time.monotonic() < deadline:
                if process.poll() is not None:
                    self.fail("runner exited before entering guest stage")
                time.sleep(0.05)
            self.assertTrue((self.root / "guest-entered").exists())
            pid = (self.root / ".emulator/.e2e.lock/pid").read_text().strip()
            subprocess.run([self.shell, "-c", 'kill -TERM "$1"', "jzm-test", pid], env=self.env, check=True)
            process.communicate(timeout=15)
            self.assertNotEqual(process.returncode, 0)
            self.assert_cleanup()
            self.assertFalse(self.result()["success"])
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()
