import contextlib
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

from runner import Task, jobs, run


class RunnerTests(unittest.TestCase):
    def test_job_limit_is_explicit_and_validated(self):
        with patch.dict(os.environ, {"JZM_TEST_JOBS": "1"}):
            self.assertEqual(jobs(), 1)
        for invalid in ("", "0", "-1", "2.5", "many", "²"):
            with self.subTest(invalid=invalid), patch.dict(os.environ, {"JZM_TEST_JOBS": invalid}):
                with self.assertRaises(ValueError):
                    jobs()

    def test_independent_tasks_really_overlap(self):
        with tempfile.TemporaryDirectory(prefix="jzm runner overlap ") as temporary:
            code = (
                "from pathlib import Path; import sys,time; "
                "root=Path(sys.argv[1]); (root/sys.argv[2]).touch(); "
                "deadline=time.monotonic()+5\n"
                "while not (root/sys.argv[3]).exists() and time.monotonic()<deadline: time.sleep(.01)\n"
                "assert (root/sys.argv[3]).exists(), 'tasks were serialized'"
            )
            tasks = [Task(name, (sys.executable, "-c", code, temporary, name, other))
                     for name, other in (("one", "two"), ("two", "one"))]
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(run(tasks, workers=2), 0)

    def test_failure_preserves_diagnostics_and_does_not_drop_pending_tasks(self):
        tasks = [Task("failure", (sys.executable, "-c", "print('failure detail'); raise SystemExit(9)")),
                 Task("after", (sys.executable, "-c", "print('pending task ran')"))]
        for workers in (1, 2):
            with self.subTest(workers=workers), contextlib.redirect_stdout(io.StringIO()) as output:
                self.assertEqual(run(tasks, workers=workers), 1)
                self.assertIn("failure detail", output.getvalue())
                self.assertIn("failure: FAIL", output.getvalue())
                self.assertIn("pending task ran", output.getvalue())
                self.assertIn("after: PASS", output.getvalue())

    def test_signal_during_launch_cannot_lose_the_new_process(self):
        native_popen = subprocess.Popen
        children = []

        def launch(*args, **kwargs):
            child = native_popen(*args, **kwargs)
            children.append(child)
            os.kill(os.getpid(), signal.SIGTERM)
            return child

        task = Task("launch", (sys.executable, "-c", "import time; time.sleep(60)"))
        with patch("runner.subprocess.Popen", side_effect=launch):
            with self.assertRaises(SystemExit) as stopped:
                run([task], workers=1)
        self.assertEqual(stopped.exception.code, 143)
        self.assertEqual(len(children), 1)
        self.assertIsNotNone(children[0].poll())
        with self.assertRaises(ProcessLookupError):
            os.killpg(children[0].pid, 0)

    def test_signal_terminates_descendants_and_returns_signal_status(self):
        with tempfile.TemporaryDirectory(prefix="jzm runner signal ") as temporary:
            marker = Path(temporary) / "child"
            task = (
                "import pathlib,signal,subprocess,sys,time\n"
                "child=subprocess.Popen([sys.executable,'-c','import time; time.sleep(60)'])\n"
                "def stop(*args):\n"
                " child.wait(); sys.exit(143)\n"
                "signal.signal(signal.SIGTERM,stop)\n"
                "pathlib.Path(sys.argv[1]).write_text(str(child.pid))\n"
                "time.sleep(60)\n"
            )
            code = "from runner import Task,run; import sys; sys.exit(run([Task('signal', " + repr(
                (sys.executable, "-c", task, str(marker))) + ")], workers=1))"
            env = {**os.environ, "PYTHONPATH": str(Path(__file__).parent)}
            process = subprocess.Popen([sys.executable, "-c", code], env=env,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                deadline = time.monotonic() + 5
                while not marker.exists() and process.poll() is None and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(marker.exists())
                process.send_signal(signal.SIGTERM)
                output, error = process.communicate(timeout=8)
                self.assertEqual(process.returncode, 143, (output, error))
                with self.assertRaises(ProcessLookupError):
                    os.kill(int(marker.read_text()), 0)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate()


class CompiledEntryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="jzm ucode shim ")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.folder = Path(cls.temporary.name)
        cls.binary = cls.folder / "ucode"
        subprocess.run(["cc", "-O2", "-Wall", "-Wextra", "-Werror",
                        str(Path(__file__).with_name("ucode.c")), "-o", str(cls.binary)], check=True)
        cls.native = cls.folder / "native"
        cls.native.write_text("#!" + sys.executable + "\nimport json,sys; print(json.dumps(sys.argv[1:]))\n")
        cls.native.chmod(0o755)

    def invoke(self, args):
        env = {**os.environ, "JZM_TEST_NATIVE_UCODE": str(self.native),
               "JZM_TEST_MAIN_SOURCE": "/project with spaces/src/main.uc",
               "JZM_TEST_MAIN_BYTECODE": "/temporary with spaces/main.uc"}
        completed = subprocess.run([str(self.binary), *args], env=env, capture_output=True, check=True)
        return json.loads(completed.stdout)

    def test_entry_is_replaced_and_user_arguments_are_byte_exact(self):
        for entry in ("src/main.uc", "/project with spaces/src/main.uc"):
            for separator in ([], ["--"]):
                args = ["-S", "-L", "/project with spaces/src/lib", *separator, entry,
                        "--config", "config with spaces.json", "src/main.uc", "a\nb"]
                expected = args.copy()
                expected[3 + len(separator)] = "/temporary with spaces/main.uc"
                self.assertEqual(self.invoke(args), expected)

    def test_other_programs_and_compiler_invocations_are_unchanged(self):
        for args in (["-S", "-L", "/lib", "other.uc", "src/main.uc"],
                     ["-S", "-L", "/lib", "-c", "-o", "out.uc", "src/main.uc"],
                     ["-S", "-e", "print('src/main.uc')"],
                     ["-S", "-L", "/lib", "--"]):
            self.assertEqual(self.invoke(args), args)
