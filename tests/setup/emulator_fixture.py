import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

PROJECT = Path(__file__).resolve().parents[2]

class EmulatorFixture(unittest.TestCase):
    def setUp(self):
        self.shell = shutil.which("sh")
        if not self.shell:
            self.skipTest("POSIX sh unavailable")
        self.temporary = tempfile.TemporaryDirectory(prefix="jzm runner test ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        shutil.copytree(PROJECT / "tests/e2e", self.root / "tests/e2e", ignore=shutil.ignore_patterns("__pycache__"))
        for name in ("emulator.sh", "router-bootstrap.sh"):
            target = self.root / "tests/setup" / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(PROJECT / "tests/setup" / name, target)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.env = {**os.environ, "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
                    "FAKE_ROOT": self.root.as_posix(), "JZM_TEST_PYTHON": Path(sys.executable).as_posix(),
                    "E2E_OPENWRT_VERSION": "25.12.5", "E2E_BOOT_TIMEOUT": "2", "E2E_COMMAND_TIMEOUT": "15",
                    "GITHUB_TOKEN": ""}
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            self.env["E2E_SSH_PORT"] = str(listener.getsockname()[1])
        self.mock("bin/uname", "uname.sh")
        self.mock("bin/python3", "python3.sh")
        if not shutil.which("setsid"):
            self.mock("bin/setsid", "setsid.sh")
        self.mock("bin/ssh", "ssh.sh")
        self.mock("bin/scp", "scp.sh")
        self.mock(".emulator/emulator.sh", "launcher.sh")
        for name in (".emulator/qemu/qemu-system-aarch64", ".emulator/tools/prepare-nand.sh"):
            self.mock(name, "unavailable.sh")
        for name in (".emulator/presets/cudy-wr3000p-v1.ini", ".emulator/.jzm-release.json", "dist/just-zapret-manager.sh"):
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("fixture\n", encoding="utf-8")
        self.image = self.root / ".emulator/images/25.12.5/nand-wr3000p"
        self.image.mkdir(parents=True)
        for part in ("0.BL2", "1.u-boot-env", "2.Factory", "3.bdinfo", "4.FIP", "5.ubi"):
            (self.image / f"mt7981.mtd{part}.bin").write_text("pristine", encoding="utf-8")
        (self.image / ".jzm-ready").write_text("25.12.5", encoding="utf-8")

    def mock(self, name, source):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(PROJECT / "tests/mocks/e2e" / source, path)
        path.chmod(0o755)

    def command(self):
        return [self.shell, str(self.root / "tests/e2e/run.sh")]

    def assert_cleanup(self):
        self.assertFalse((self.root / ".emulator/.e2e.lock").exists())
        self.assertEqual((self.image / "mt7981.mtd0.BL2.bin").read_text(), "pristine")
        if (self.root / "emulator-pid").exists():
            pid = (self.root / "emulator-pid").read_text().strip()
            check = subprocess.run([self.shell, "-c", 'kill -0 "$1" 2>/dev/null', "jzm-test", pid], env=self.env)
            self.assertNotEqual(check.returncode, 0, "emulator process leaked")

    def result(self):
        files = list((self.root / ".test-tmp/e2e").glob("*/report.json"))
        self.assertEqual(len(files), 1)
        return json.loads(files[0].read_text(encoding="utf-8"))

    def run_fixture(self, mode):
        self.env["FAKE_MODE"] = mode
        completed = subprocess.run(self.command(), env=self.env, capture_output=True, timeout=30)
        self.assert_cleanup()
        return completed
