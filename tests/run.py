"""Run independent suites concurrently; each owns its temporary router."""
from contextlib import contextmanager
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

from support.runner import Task, jobs, run


@contextmanager
def compiled_entry():
    # Rebuild with this run's ucode version. Never reuse stale bytecode.
    if os.environ.get("JZM_TEST_COMPILE", "1") == "0":
        yield
        return
    native = shutil.which("ucode")
    if native is None:
        sys.exit("tests: ucode unavailable")
    project = Path.cwd()
    with tempfile.TemporaryDirectory(prefix="jzm-bytecode-") as temporary:
        folder = Path(temporary)
        binary = folder / "bin"
        binary.mkdir()
        bytecode = folder / "main.uc"
        subprocess.run([native, "-S", "-L", str(project / "src/lib"), "-c", "-o",
                        str(bytecode), "src/main.uc"], check=True)
        subprocess.run(["cc", "-O2", "-Wall", "-Wextra", "-Werror", "tests/support/ucode.c",
                        "-o", str(binary / "ucode")], check=True)
        changes = {"JZM_TEST_NATIVE_UCODE": native, "JZM_TEST_MAIN_SOURCE": str(project / "src/main.uc"),
                   "JZM_TEST_MAIN_BYTECODE": str(bytecode),
                   "PATH": str(binary) + os.pathsep + os.environ["PATH"]}
        previous = {key: os.environ.get(key) for key in changes}
        os.environ.update(changes)
        try:
            yield
        finally:
            for key, value in previous.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value


def main():
    # Start the longest suites first. Integration cases retain their lifecycle order.
    tasks = [
        Task("integration", ("sh", "tests/integration/run.sh")),
        Task("emulator", ("sh", "tests/e2e/run.sh", "selftest")),
        Task("check", ("sh", "tools/check.sh")),
        Task("transactions", ("sh", "tests/safety/transactions.sh")),
        Task("uninstall", ("sh", "tests/safety/uninstall.sh")),
        Task("http", ("sh", "tests/http/run.sh")),
        Task("packages", ("sh", "tests/integration/packages.sh")),
        Task("unit", ("sh", "tests/unit/run.sh")),
        Task("runner", (sys.executable, "-B", "-m", "unittest", "discover", "-s", "tests/support")),
    ]
    try:
        workers = jobs()
        with compiled_entry():
            return run(tasks, workers=workers)
    except ValueError as error:
        sys.exit(str(error))


if __name__ == "__main__":
    sys.exit(main())
