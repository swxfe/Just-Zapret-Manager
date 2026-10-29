#!/bin/sh
set -eu
umask 077
project=$(CDPATH='' cd -P "$(dirname "$0")/.." && pwd)

# Host helpers, their offline regression tests and guest payloads are embedded here.
# No helper programs or downloaded code are generated in the source tree.
host_python() {
    python3 - "$project" "$@" <<'__JZM_HOST_PYTHON__'
import hashlib
import io
import json
import os
import re
import shutil
import socket
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest
import urllib.request
import zipfile
from contextlib import redirect_stdout
from pathlib import Path, PurePosixPath
from unittest.mock import patch

# Release discovery and verified archive extraction.
REPO = "https://github.com/stavultras/router-emulator"
API = "https://api.github.com/repos/stavultras/router-emulator/releases?per_page=100"
MAX_ASSET = 128 * 1024 * 1024
MAX_EXPANDED = 512 * 1024 * 1024


def select_assets(releases):
    stable = [r for r in releases if not r.get("draft") and not r.get("prerelease")]
    binary = None
    for release in stable:
        for asset in release.get("assets", []):
            found = re.fullmatch(r"Router-Emulator-(\d+\.\d+(?:\.\d+)?)-linux-x86_64\.tar\.gz", asset["name"])
            if found:
                binary = (release, asset, found[1].split(".")[:2])
                break
        if binary:
            break
    if not binary:
        raise ValueError("no stable Linux x86_64 release among the last 100 releases")
    for release in stable:
        for asset in release.get("assets", []):
            found = re.fullmatch(r"Router-Emulator-(\d+\.\d+(?:\.\d+)?)-presets\.zip", asset["name"])
            if found and found[1].split(".")[:2] == binary[2]:
                selected = [(binary[0], binary[1]), (release, asset)]
                for rel, item in selected:
                    expected = f"{REPO}/releases/download/{rel['tag_name']}/{item['name']}"
                    if item.get("browser_download_url") != expected or not re.fullmatch(r"v?\d+(?:\.\d+){1,2}", rel["tag_name"]):
                        raise ValueError("invalid asset URL or release tag")
                    if not 0 < item.get("size", 0) <= MAX_ASSET:
                        raise ValueError("invalid asset size")
                    if item.get("digest") and not re.fullmatch(r"sha256:[a-f0-9]{64}", item["digest"]):
                        raise ValueError("invalid asset digest")
                return selected
    raise ValueError("no matching presets archive for the latest binary release")


def verified(path, asset):
    if not path.is_file() or path.stat().st_size != asset["size"]:
        return False
    digest = asset.get("digest")
    if not digest:
        return False  # Without a published digest, do not trust a previously interrupted cache.
    with path.open("rb") as stream:
        actual = hashlib.sha256()
        for chunk in iter(lambda: stream.read(65536), b""):
            actual.update(chunk)
    return actual.hexdigest() == digest[7:]


def download(asset, folder):
    target = folder / asset["name"]
    if verified(target, asset):
        return target
    partial = target.with_suffix(target.suffix + ".part")
    for attempt in range(3):
        try:
            digest, count = hashlib.sha256(), 0
            request = urllib.request.Request(asset["browser_download_url"], headers={"User-Agent": "JZM-emulator-setup"})
            with urllib.request.urlopen(request, timeout=30) as response, partial.open("wb") as output:
                for chunk in iter(lambda: response.read(65536), b""):
                    count += len(chunk)
                    if count > asset["size"]:
                        raise ValueError("asset exceeds its published size")
                    output.write(chunk)
                    digest.update(chunk)
            if count != asset["size"] or (asset.get("digest") and asset["digest"][7:] != digest.hexdigest()):
                raise ValueError("asset size/SHA256 mismatch")
            os.replace(partial, target)
            return target
        except (OSError, ValueError):
            partial.unlink(missing_ok=True)
            if attempt == 2:
                raise
            time.sleep(1)
    raise AssertionError("unreachable")


def member_path(name, root):
    path = PurePosixPath(name)
    if path.is_absolute() or ".." in path.parts or "\\" in name or ":" in name:
        raise ValueError(f"unsafe archive member: {name!r}")
    parts = path.parts
    if parts and parts[0] == "Router-Emulator":
        parts = parts[1:]
    return root.joinpath(*parts)


def extract(archive, destination):
    # Extract only directories/regular files into a new private directory; reject all links/devices.
    total = 0
    if archive.name.endswith(".tar.gz"):
        with tarfile.open(archive, "r:gz") as source:
            for item in source:
                path = member_path(item.name, destination)
                if item.isdir():
                    path.mkdir(parents=True, exist_ok=True)
                    continue
                if not item.isfile():
                    raise ValueError(f"unsupported archive member: {item.name}")
                total += item.size
                if total > MAX_EXPANDED:
                    raise ValueError("archive too large")
                path.parent.mkdir(parents=True, exist_ok=True)
                with source.extractfile(item) as stream, path.open("xb") as output:
                    shutil.copyfileobj(stream, output)
                path.chmod(item.mode & 0o777)
    else:
        with zipfile.ZipFile(archive) as source:
            for item in source.infolist():
                path = member_path(item.filename, destination)
                mode = item.external_attr >> 16
                if stat.S_ISLNK(mode):
                    raise ValueError("symlink in presets ZIP")
                if item.is_dir():
                    path.mkdir(parents=True, exist_ok=True)
                    continue
                total += item.file_size
                if total > MAX_EXPANDED:
                    raise ValueError("archive too large")
                path.parent.mkdir(parents=True, exist_ok=True)
                with source.open(item) as stream, path.open("xb") as output:
                    shutil.copyfileobj(stream, output)


def install(root):
    headers = {"User-Agent": "JZM-emulator-setup", "Accept": "application/vnd.github+json"}
    token = os.environ.get("GITHUB_TOKEN")
    if token:
        headers["Authorization"] = "Bearer " + token
    with urllib.request.urlopen(urllib.request.Request(API, headers=headers), timeout=30) as response:
        data = response.read(8 * 1024 * 1024 + 1)
    if len(data) > 8 * 1024 * 1024:
        raise ValueError("release metadata too large")
    selected = select_assets(json.loads(data))
    downloads = root / "downloads"
    downloads.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".install-", dir=root) as temporary:
        staging = Path(temporary)
        for release, asset in selected:
            print(f"Downloading {release['tag_name']}: {asset['name']}", flush=True)
            extract(download(asset, downloads), staging)
        for name in ("emulator.sh", "qemu/qemu-system-aarch64", "tools/prepare-nand.sh", "presets/cudy-wr3000p-v1.ini"):
            if not (staging / name).is_file():
                raise ValueError(f"incomplete release: {name}")
        (root / ".jzm-release.json").unlink(missing_ok=True)
        shutil.copytree(staging, root, dirs_exist_ok=True)
    marker = root / ".jzm-release.json.tmp"
    marker.write_text(json.dumps([{"tag": r["tag_name"], "asset": a} for r, a in selected], indent=2) + "\n", encoding="utf-8")
    marker.replace(root / ".jzm-release.json")




# TAP/JSON reports.
def rows(path, prefix):
    if not path.is_file():
        return []
    result = []
    for line in path.read_text(encoding="utf-8").splitlines():
        status, name, seconds = line.split("\t")
        if status not in ("pass", "fail", "skip") or not seconds.isdigit():
            raise ValueError(f"invalid result row: {line!r}")
        result.append({"name": prefix + name, "status": status, "seconds": int(seconds)})
    return result


def render(folder, exit_code):
    cases = rows(folder / "host.tsv", "host/") + rows(folder / "guest/results.tsv", "router/")
    totals = {key: sum(case["status"] == key for case in cases) for key in ("pass", "fail", "skip")}
    complete = (folder / "guest/complete").is_file()
    success = exit_code == 0 and totals["fail"] == 0 and complete
    report = {"success": success, "guest_complete": complete, "exit_code": exit_code, "totals": totals, "cases": cases}
    (folder / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    lines = ["TAP version 13", f"1..{len(cases)}"]
    for number, case in enumerate(cases, 1):
        verdict = "not ok" if case["status"] == "fail" else "ok"
        suffix = " # SKIP baseline recovery failed" if case["status"] == "skip" else ""
        lines.append(f"{verdict} {number} - {case['name']}{suffix}")
    (folder / "report.tap").write_text("\n".join(lines) + "\n", encoding="utf-8")
    summary = f"E2E {'PASS' if success else 'FAIL'}: {totals['pass']} passed, {totals['fail']} failed, {totals['skip']} skipped; guest complete: {complete}"
    (folder / "summary.txt").write_text(summary + "\n", encoding="utf-8")
    print(summary)
    return report



# Offline regression checks, using stand-ins for SSH and QEMU.
PROJECT = Path(sys.argv[1])
assets = sys.modules[__name__]
reports = assets

def asset(version, suffix, data=b"archive"):
    name = f"Router-Emulator-{version}-{suffix}"
    return {"name": name, "size": len(data), "digest": "sha256:" + hashlib.sha256(data).hexdigest(),
            "browser_download_url": f"{assets.REPO}/releases/download/v{version}/{name}"}


def release(version, *suffixes, **fields):
    return {"tag_name": "v" + version, "assets": [asset(version, suffix) for suffix in suffixes], **fields}


class LoaderTests(unittest.TestCase):
    def test_presets_only_release_uses_latest_compatible_binary(self):
        selected = assets.select_assets([release("4.1.1", "presets.zip"),
                                         release("4.1", "linux-x86_64.tar.gz", "presets.zip")])
        self.assertEqual([r["tag_name"] for r, _ in selected], ["v4.1", "v4.1.1"])

    def test_prereleases_and_other_preset_families_are_ignored(self):
        selected = assets.select_assets([release("5.0", "linux-x86_64.tar.gz", "presets.zip", prerelease=True),
                                         release("4.2", "presets.zip"),
                                         release("4.1", "linux-x86_64.tar.gz", "presets.zip")])
        self.assertEqual([r["tag_name"] for r, _ in selected], ["v4.1", "v4.1"])

    def test_missing_compatible_presets_fails(self):
        with self.assertRaises(ValueError):
            assets.select_assets([release("4.2", "linux-x86_64.tar.gz"), release("4.1", "presets.zip")])

    def test_untrusted_metadata_is_rejected(self):
        for field, value in (("size", assets.MAX_ASSET + 1), ("digest", "sha256:wrong"),
                             ("browser_download_url", "https://other.example/file")):
            with self.subTest(field=field), self.assertRaises(ValueError):
                entry = release("4.1", "linux-x86_64.tar.gz", "presets.zip")
                entry["assets"][0][field] = value
                assets.select_assets([entry])

    def test_tar_and_zip_have_the_same_normalized_root(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / "binary.tar.gz"
            with tarfile.open(archive, "w:gz") as stream:
                member = tarfile.TarInfo("Router-Emulator/emulator.sh")
                member.size = 4
                member.mode = 0o755
                stream.addfile(member, io.BytesIO(b"test"))
            presets = root / "presets.zip"
            with zipfile.ZipFile(presets, "w") as stream:
                stream.writestr("Router-Emulator/presets/board.ini", "[preset]")
            target = root / "extract"
            assets.extract(archive, target)
            assets.extract(presets, target)
            self.assertEqual((target / "emulator.sh").read_bytes(), b"test")
            self.assertTrue((target / "presets/board.ini").is_file())

    def test_archive_traversal_and_links_are_rejected(self):
        for name in ("../escape", "/escape", "Router-Emulator/../../escape", "C:/escape", "..\\escape"):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                archive = root / "bad.zip"
                with zipfile.ZipFile(archive, "w") as stream:
                    stream.writestr(name, "bad")
                with self.assertRaises(ValueError):
                    assets.extract(archive, root / "extract")
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / "bad.tar.gz"
            with tarfile.open(archive, "w:gz") as stream:
                member = tarfile.TarInfo("Router-Emulator/link")
                member.type = tarfile.SYMTYPE
                member.linkname = "/etc/passwd"
                stream.addfile(member)
            with self.assertRaises(ValueError):
                assets.extract(archive, root / "extract")

    def test_expansion_limit(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / "large.zip"
            with zipfile.ZipFile(archive, "w") as stream:
                stream.writestr("large", "12345")
            with patch.object(assets, "MAX_EXPANDED", 4), self.assertRaises(ValueError):
                assets.extract(archive, root / "extract")

    def test_download_reuses_verified_cache(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            metadata = asset("4.1", "presets.zip", b"valid")
            (root / metadata["name"]).write_bytes(b"valid")
            with patch.object(assets.urllib.request, "urlopen") as network:
                self.assertTrue(assets.download(metadata, root).is_file())
                network.assert_not_called()

    def test_corrupted_download_retries_without_publishing_partial_file(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            metadata = asset("4.1", "presets.zip", b"valid")
            (root / metadata["name"]).write_bytes(b"wrong")
            with patch.object(assets.urllib.request, "urlopen", side_effect=[io.BytesIO(b"wrong"), io.BytesIO(b"valid")]), \
                    patch.object(assets.time, "sleep"):
                self.assertEqual(assets.download(metadata, root).read_bytes(), b"valid")
            self.assertFalse(list(root.glob("*.part")))


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


class RunnerTests(unittest.TestCase):
    """Exercise orchestration using disposable command stand-ins, never a router or real SSH."""

    def setUp(self):
        self.shell = shutil.which("sh")
        if not self.shell:
            self.skipTest("POSIX sh unavailable")
        self.temporary = tempfile.TemporaryDirectory(prefix="jzm runner test ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for name in ("tests/e2e-emulator.sh",):
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(PROJECT / name, target)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.env = {**os.environ, "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
                    "FAKE_ROOT": self.root.as_posix(), "JZM_TEST_PYTHON": Path(sys.executable).as_posix(),
                    "E2E_OPENWRT_VERSION": "25.12.5", "E2E_BOOT_TIMEOUT": "2", "E2E_COMMAND_TIMEOUT": "15",
                    "GITHUB_TOKEN": ""}
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            self.env["E2E_SSH_PORT"] = str(listener.getsockname()[1])
        self.script("bin/uname", 'case "$1" in -s) echo Linux;; -m) echo x86_64;; esac\n')
        self.script("bin/python3", 'exec "$JZM_TEST_PYTHON" "$@"\n')
        if not shutil.which("setsid"):
            self.script("bin/setsid", 'exec "$@"\n')
        self.script("bin/ssh", '''
for argument in "$@"; do request=$argument; done
case "$request" in
    'echo ready') [ "$FAKE_MODE" != timeout ] && [ -f "$FAKE_ROOT/emulator-pid" ] || exit 255; echo ready;;
    'date -u -s '*" && JZM_E2E_GUEST=1 sh -s") cat > "$FAKE_ROOT/bootstrap-received"; test -s "$FAKE_ROOT/bootstrap-received";;
    'JZM_E2E_GUEST=1 sh /tmp/jzm-e2e-router.sh')
        touch "$FAKE_ROOT/guest-entered"
        if [ "$FAKE_MODE" = signal ]; then
            while kill -0 "$(cat "$FAKE_ROOT/emulator-pid")" 2>/dev/null; do sleep 0.1; done
        fi
        [ "$FAKE_MODE" != failure ];;
esac
''')
        self.script("bin/scp", '''
previous=''; last=''
for argument in "$@"; do previous=$last; last=$argument; done
case "$previous" in
    root@127.0.0.1:/tmp/jzm-e2e/report)
        mkdir -p "$last"
        if [ "$FAKE_MODE" = failure ]; then result=fail; else result=pass; fi
        printf '%s\\tfixture\\t0\\n' "$result" > "$last/results.tsv"
        [ "$FAKE_MODE" = incomplete ] || touch "$last/complete";;
esac
''')
        self.script(".emulator/emulator.sh", '''
printf '%s\\n' "$$" > "$FAKE_ROOT/emulator-pid"
while [ "$#" -gt 0 ]; do
    if [ "$1" = -n ]; then
        printf '%s\\n' "$2" > "$FAKE_ROOT/flash-path"
        printf changed > "$2/mt7981.mtd0.BL2.bin"
    fi
    shift
done
exec sleep 60
''')
        for name in (".emulator/qemu/qemu-system-aarch64", ".emulator/tools/prepare-nand.sh"):
            self.script(name, "exit 90\n")
        for name in (".emulator/presets/cudy-wr3000p-v1.ini", ".emulator/.jzm-release.json", "dist/just-zapret-manager.sh"):
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("fixture\n", encoding="utf-8")
        self.image = self.root / ".emulator/images/25.12.5/nand-wr3000p"
        self.image.mkdir(parents=True)
        for part in ("0.BL2", "1.u-boot-env", "2.Factory", "3.bdinfo", "4.FIP", "5.ubi"):
            (self.image / f"mt7981.mtd{part}.bin").write_text("pristine", encoding="utf-8")
        (self.image / ".jzm-ready").write_text("25.12.5", encoding="utf-8")

    def script(self, name, text):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(("#!/bin/sh\nset -eu\n" + text).encode())
        path.chmod(0o755)

    def command(self):
        return [self.shell, str(self.root / "tests/e2e-emulator.sh")]

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

    def test_happy_path_preserves_bootstrap_stdin_and_pristine_flash(self):
        completed = self.run_fixture("success")
        self.assertEqual(completed.returncode, 0, completed.stdout.decode(errors="replace") + completed.stderr.decode(errors="replace"))
        self.assertEqual((self.root / "bootstrap-received").read_bytes(), subprocess.check_output([self.shell, str(PROJECT / "tests/e2e-emulator.sh"), "payload", "bootstrap"], env=self.env))
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


action = sys.argv[2]
if action == "assets":
    try:
        install(Path(sys.argv[3]).resolve())
    except (OSError, ValueError, tarfile.TarError, zipfile.BadZipFile) as error:
        sys.exit(f"emulator-assets: {error}")
elif action == "report":
    render(Path(sys.argv[3]), int(sys.argv[4]))
elif action == "selftest":
    unittest.main(argv=["emulator-selftest"], verbosity=2)
else:
    sys.exit("unknown host utility action")
__JZM_HOST_PYTHON__
}

bootstrap_script() {
    cat <<'__JZM_BOOTSTRAP__'
#!/bin/sh
set -eu
[ "${JZM_E2E_GUEST:-}" = 1 ] && [ -f /etc/openwrt_release ] || exit 2
ubus call system board > /tmp/jzm-e2e-board.json
grep -q 'cudy,wr3000p-v1' /tmp/jzm-e2e-board.json
retry() {
    attempt=0
    until "$@"; do
        attempt=$((attempt + 1))
        [ "$attempt" -lt 3 ] || return 1
        sleep 2
    done
}
if command -v apk >/dev/null 2>&1; then
    retry apk update
    retry apk add ucode ucode-mod-fs curl ca-bundle unzip
else
    retry opkg update
    retry opkg install ucode ucode-mod-fs curl ca-bundle unzip
fi
ucode -S -e 'import * as fs from "fs"; assert(fs.stat("/etc/openwrt_release") != null);'
mkdir -p /tmp/jzm-e2e
printf '%s\n' 'Cudy WR3000P / isolated JZM E2E' > /tmp/jzm-e2e/guard
__JZM_BOOTSTRAP__
}

router_script() {
    cat <<'__JZM_ROUTER__'
#!/bin/sh
# Test functions are selected by the validated --case dispatcher below.
# shellcheck disable=SC2329
set -eu
umask 077
root=/tmp/jzm-e2e
conf=/etc/config/zapret
lock=/tmp/zapret-manager.zapret.lock
[ "${JZM_E2E_GUEST:-}" = 1 ] && [ -f "$root/guard" ] && [ -f /etc/openwrt_release ] || exit 2
jzm() { JZM_MODE='command' /usr/bin/jzm "$@"; }
reject() { if "$@"; then printf 'unexpected success: %s\n' "$*" >&2; return 1; fi; }
nfqws_pids() {
    # BusyBox -x matches argv[0] (the full path), unlike procps on the host.
    pgrep -f '^/opt/zapret/nfq/nfqws([[:space:]]|$)'
}
health() {
    attempts=0
    while [ "$attempts" -lt 20 ]; do
        if /etc/init.d/zapret running && nfqws_pids > "$root/pids"; then
            nft list table inet zapret > "$root/rules"
            grep -q 'chain ' "$root/rules"
            /etc/init.d/zapret enabled || { printf '%s\n' 'health: Zapret не включён в автозагрузку' >&2; return 1; }
            return 0
        fi
        sleep 1
        attempts=$((attempts + 1))
    done
    printf '%s\n' 'health: procd или процесс nfqws не готов за 20 секунд' >&2
    return 1
}
unchanged() { cmp "$root/before" "$conf"; health; [ ! -d "$lock" ]; }
baseline_files() {
    mode=$1
    index=0
    set -- "$conf" /opt/zapret/ipset/zapret-hosts-user.txt \
        /opt/zapret/ipset/zapret-hosts-user-exclude.txt /opt/zapret/ipset/zapret-hosts-google.txt \
        /etc/zapret-manager/state.json /etc/zapret-manager/devices.txt \
        /opt/zapret/init.d/openwrt/custom.d/20-jzm-exclude.sh
    for path do
        [ -f "$path" ] && [ ! -L "$path" ] || return 1
        if [ "$mode" = save ]; then cp -p "$path" "$root/baseline-files/$index" || return 1
        else cmp -s "$path" "$root/baseline-files/$index" || return 1; fi
        index=$((index + 1))
    done
    # Copy-on-write may change mtimes; compare permissions and ownership in addition to bytes.
    LC_ALL=C ls -ldn "$@" > "$root/baseline-metadata.raw" || return 1
    if [ "$mode" = save ]; then awk '{print $1, $3, $4}' "$root/baseline-metadata.raw" > "$root/baseline-files/metadata"
    else
        awk '{print $1, $3, $4}' "$root/baseline-metadata.raw" > "$root/baseline-current-metadata" || return 1
        cmp -s "$root/baseline-current-metadata" "$root/baseline-files/metadata"
    fi
}
baseline_running() {
    /etc/init.d/zapret running || return 1
    nfqws_pids > "$root/pids" || return 1
    nft list table inet zapret > "$root/rules" || return 1
    grep -q 'chain ' "$root/rules"
}
reset() {
    # A killed fault-injection worker must not affect the next independent case.
    if [ -f "$root/sync.original" ]; then cp -p "$root/sync.original" /opt/zapret/sync_config.sh; fi
    rm -f "$root/fail-sync" "$root/probe-entered"
    if [ -d "$lock" ]; then jzm recover; fi
    if ! cmp -s "$root/firewall" /etc/config/firewall; then
        cp -p "$root/firewall" /etc/config/firewall
        /etc/init.d/firewall restart
    fi
    if [ -f "$root/cron.absent" ]; then
        if [ -f /etc/crontabs/root ]; then rm /etc/crontabs/root; /etc/init.d/cron restart; fi
    elif ! cmp -s "$root/cron" /etc/crontabs/root; then
        cp -p "$root/cron" /etc/crontabs/root
        /etc/init.d/cron restart
    fi
    rm -f /etc/zapret-manager/offload.previous
    # Reapply the real backup only when managed files differ; keep every case's assertions intact.
    if ! baseline_files check; then jzm backup restore "$root/baseline.json"; fi
    if ! baseline_running; then jzm service restart; fi
    if ! /etc/init.d/zapret enabled; then jzm service enable; fi
    health
}
public_contract() {
    printf '0\n' | /usr/bin/jzm > "$root/menu"
    grep -q 'JZM · just-zapret-manager ' "$root/menu"
    grep -q 'v7' "$root/menu"
    reject /usr/bin/jzm status
    jzm version
    jzm doctor
}
packages_luci() {
    for package in zapret luci-app-zapret; do
        if command -v apk >/dev/null 2>&1; then apk info -e "$package"
        else opkg status "$package" | grep -q 'Status: .* installed'; fi
    done
    test -s /usr/share/luci/menu.d/luci-app-zapret.json
    test -s /www/luci-static/resources/view/zapret/settings.js
    curl --fail --max-time 10 http://127.0.0.1/luci-static/resources/view/zapret/settings.js > "$root/luci.js"
    test -s "$root/luci.js"
}
live_status() { jzm status; health; }
noop_preserves_process() {
    cp "$conf" "$root/before"
    nfqws_pids > "$root/noop-pids.before"
    ports=$(jzm config get NFQWS_PORTS_TCP)
    jzm config set NFQWS_PORTS_TCP "$ports"
    jzm source apply manager v7
    jzm backup restore "$root/baseline.json"
    unchanged
    nfqws_pids > "$root/noop-pids.after"
    cmp "$root/noop-pids.before" "$root/noop-pids.after"
}
preset_label() {
    jzm config get NFQWS_OPT > "$root/opts"
    [ "$(grep -c '^#v7$' "$root/opts")" -eq 1 ]
    [ "$(grep -c '^#' "$root/opts")" -eq 1 ]
    [ "$(jzm source show manager v7)" = "$(jzm config get NFQWS_OPT)" ]
    health
}
modified_label() {
    jzm source show manager v7 > "$root/original.opts"
    sed 's/^--filter-tcp=443$/--filter-tcp=444/' "$root/original.opts" > "$root/modified.opts"
    reject cmp -s "$root/original.opts" "$root/modified.opts"
    uci set "zapret.@main[0].NFQWS_OPT=$(cat "$root/modified.opts")"
    uci commit zapret
    printf '0\n' | /usr/bin/jzm > "$root/menu"
    grep -q 'v7 (изменена пользователем)' "$root/menu"
    health
}
invalid_ports() {
    nfqws_pids > "$root/reject-pids.before"
    cp "$conf" "$root/before"
    reject jzm config set NFQWS_PORTS_TCP 999999
    unchanged
    reject jzm config set NFQWS_PORTS_UDP 500-10
    nfqws_pids > "$root/reject-pids.after"
    cmp "$root/reject-pids.before" "$root/reject-pids.after"
    unchanged
}
invalid_strategy() {
    cp "$conf" "$root/before"
    reject jzm source apply manager missing-e2e-preset
    # This substitution must stay literal so the strategy validator can reject it.
    # shellcheck disable=SC2016
    printf '%s\n' '--filter-tcp=443' '--x=$(touch /tmp/jzm-e2e/injected)' > "$root/bad.txt"
    reject jzm strategy import "$root/bad.txt"
    [ ! -e "$root/injected" ]
    unchanged
}
service_cycle() {
    jzm service stop
    reject nfqws_pids
    jzm status | grep -q stopped
    jzm service start
    health
    jzm service restart
    health
}
autostart() {
    jzm service disable
    reject /etc/init.d/zapret enabled
    jzm service enable
    /etc/init.d/zapret enabled
}
settings() {
    jzm config set DISABLE_IPV6 1
    [ "$(jzm config get DISABLE_IPV6)" = 1 ]
    jzm config set NFQWS_PORTS_TCP 80,443,2000-3000
    [ "$(jzm config get NFQWS_PORTS_TCP)" = 80,443,2000-3000 ]
    health
}
hostlists() {
    jzm hosts user add EXAMPLE.COM example.com sub.example.com
    jzm hosts user show > "$root/hosts"
    [ "$(grep -c '^example.com$' "$root/hosts")" -eq 1 ]
    jzm hosts user remove example.com
    jzm hosts user show > "$root/hosts"
    reject grep -q '^example.com$' "$root/hosts"
    reject jzm hosts user add 'bad.example;touch /tmp/jzm-e2e/injected'
    [ ! -e "$root/injected" ]
    health
}
backup_roundtrip() {
    cp "$conf" "$root/before"
    jzm backup save "$root/roundtrip.json"
    jzm config set DISABLE_IPV6 1
    jzm hosts user add backup.example
    jzm backup restore "$root/roundtrip.json"
    unchanged
    jzm config get NFQWS_OPT | grep -q '^#v7$'
    reject jzm backup save "$root/roundtrip.json"
}
invalid_backup() {
    cp "$conf" "$root/before"
    printf '%s\n' '{"format":1,"profile":"wrong"}' > "$root/bad.json"
    reject jzm backup restore "$root/bad.json"
    unchanged
}
url_probe() {
    printf '%s\n' 'http://127.0.0.1/luci-static/resources/view/zapret/settings.js' > "$root/targets.txt"
    jzm test "$root/targets.txt" > "$root/probe.json"
    grep -q 'OK http://' "$root/probe.json"
    health
}
benchmark_preserves_state() {
    cp "$conf" "$root/before"
    jzm source show manager v7 > "$root/bench-catalog.txt"
    printf '%s\n' 'http://127.0.0.1/luci-static/resources/view/zapret/settings.js' > "$root/targets.txt"
    jzm service stop
    jzm benchmark "$root/targets.txt" "$root/bench-catalog.txt"
    cmp "$root/before" "$conf"
    reject nfqws_pids
    jzm service start
    jzm auto-best "$root/targets.txt" "$root/bench-catalog.txt"
    unchanged
}
compound_groups() {
    jzm source compose manager v7 Yv08 Dv1 Gv1
    jzm config get NFQWS_OPT > "$root/opts"
    for name in v7 Yv08 Dv1 Gv1; do [ "$(grep -c "^#$name\$" "$root/opts")" -eq 1 ]; done
    [ "$(grep -c '^--new$' "$root/opts")" -eq 4 ]
    health
    jzm source group manager base v3
    jzm config get NFQWS_OPT > "$root/opts"
    for name in v3 Yv08 Dv1 Gv1; do [ "$(grep -c "^#$name\$" "$root/opts")" -eq 1 ]; done
    reject grep -q '^#v7$' "$root/opts"
    health
}
flowseal() {
    jzm source refresh flowseal
    jzm source list flowseal > "$root/flowseal-names"
    name=$(sed -n '1p' "$root/flowseal-names")
    if grep -q '^general$' "$root/flowseal-names"; then name=general; fi
    alt9=$(grep -i '^general[_ (]*alt9[_ )]*$' "$root/flowseal-names" | head -n 1)
    if [ -n "$alt9" ]; then name=$alt9; fi
    [ -n "$name" ]
    jzm source apply flowseal "$name"
    jzm config get NFQWS_OPT > "$root/opts"
    [ "$(grep -c '^#' "$root/opts")" -eq 1 ]
    grep -q "^#$name\$" "$root/opts"
    [ "$(jzm source show flowseal "$name")" = "$(jzm config get NFQWS_OPT)" ]
    health
    jzm source group manager games Gv1
    jzm config get NFQWS_OPT > "$root/opts"
    grep -q "^#$name\$" "$root/opts"
    [ "$(grep -c '^#Gv1$' "$root/opts")" -eq 1 ]
    health
    jzm source remove manager games
    jzm config get NFQWS_OPT > "$root/opts"
    grep -q "^#$name\$" "$root/opts"
    reject grep -q '^#Gv1$' "$root/opts"
    health
}
devices() {
    jzm devices toggle 192.168.1.200
    jzm devices list | grep -q 'Исключён 192.168.1.200'
    sh -n /opt/zapret/init.d/openwrt/custom.d/20-jzm-exclude.sh
    nft list table inet zapret | grep -q '192.168.1.200'
    nft -a list chain inet zapret postrouting_hook > "$root/device-rules.before"
    jzm devices add 192.168.1.200
    jzm devices add 192.168.1.200
    (
        # shellcheck source=/dev/null
        . /opt/zapret/init.d/openwrt/custom.d/20-jzm-exclude.sh
        zapret_custom_firewall_nft
        zapret_custom_firewall_nft
    )
    nft -a list chain inet zapret postrouting_hook > "$root/device-rules.after"
    cmp "$root/device-rules.before" "$root/device-rules.after"
    jzm devices clear
    jzm devices remove 192.168.1.200
    jzm devices remove 192.168.1.200
    health
}
uninstall_manager() {
    jzm devices add 192.168.1.200
    jzm network quic on
    jzm backup save /etc/zapret-manager/backups/e2e-uninstall.json
    cp "$conf" "$root/uninstall-config.before"
    jzm uninstall manager
    test ! -e /usr/bin/jzm
    test ! -e /usr/bin/jzm.previous
    test ! -e /etc/zapret-manager
    test ! -e /opt/zapret/init.d/openwrt/custom.d/20-jzm-exclude.sh
    cmp "$root/uninstall-config.before" "$conf"
    reject uci -q get firewall.jzm_quic
    health
    JZM_MODE='command' sh /tmp/just-zapret-manager.sh manager-install
    test -x /usr/bin/jzm
}
networking() {
    uci export firewall > "$root/firewall-before"
    jzm network offload disable
    [ "$(uci get 'firewall.@defaults[0].flow_offloading')" = 0 ]
    jzm network offload restore
    uci export firewall > "$root/firewall-after"
    cmp "$root/firewall-before" "$root/firewall-after"
    jzm network quic on
    [ "$(uci get firewall.jzm_quic.name)" = JZM_Block_QUIC ]
    nft list ruleset | grep -q JZM_Block_QUIC
    jzm network quic off
    reject uci -q get firewall.jzm_quic
    health
}
schedule() {
    printf '%s\n' '7 1 * * * /bin/true # unrelated-e2e' >> /etc/crontabs/root
    cp /etc/crontabs/root "$root/cron-before"
    jzm source export manager e2e-catalog.txt
    printf '%s\n' 'http://127.0.0.1/' > "$root/targets.txt"
    hour=$((($(date +%H | sed 's/^0//') + 12) % 24))
    jzm schedule "$hour" "$root/targets.txt" /etc/zapret-manager/e2e-catalog.txt
    grep -q 'JZM_MODE=command.*# zapret-manager:zapret$' /etc/crontabs/root
    grep -q unrelated-e2e /etc/crontabs/root
    jzm schedule off
    cmp "$root/cron-before" /etc/crontabs/root
}
noop_update() {
    cp "$conf" "$root/before"
    jzm update-upstream > "$root/update"
    grep -q 'Новых версий нет' "$root/update"
    unchanged
}
manager_reinstall() {
    cp "$conf" "$root/before"
    cp /etc/zapret-manager/manager-config.json "$root/manager-before"
    jzm manager-install
    test -x /usr/bin/jzm
    test -x /usr/bin/jzm.previous
    cmp /usr/bin/jzm /usr/bin/jzm.previous
    cmp "$root/manager-before" /etc/zapret-manager/manager-config.json
    unchanged
}
busy_lock() {
    cp "$conf" "$root/before"
    mkdir "$lock"
    printf '%s\n' "$$" > "$lock/pid"
    trap 'rm -f "$lock/pid"; rmdir "$lock"' 0
    reject jzm config set DISABLE_IPV6 1
    reject jzm recover
    cmp "$root/before" "$conf"
    health
}
failed_download() {
    cp /etc/zapret-manager/manager.json "$root/cache-before"
    cp "$conf" "$root/before"
    mkdir -p "$root/fail-bin"
    printf '#!/bin/sh\nexit 22\n' > "$root/fail-bin/curl"
    chmod 755 "$root/fail-bin/curl"
    reject env PATH="$root/fail-bin:$PATH" JZM_MODE=command /usr/bin/jzm source refresh manager
    cmp "$root/cache-before" /etc/zapret-manager/manager.json
    unchanged
}
github_rate_limit() {
    cp /etc/zapret-manager/manager.json "$root/cache-before"
    cp "$conf" "$root/before"
    mkdir -p "$root/rate-bin"
    cat > "$root/rate-bin/curl" <<'EOF'
#!/bin/sh
set -eu
out='' headers=''
while [ "$#" -gt 0 ]; do
    case "$1" in
        --output) out=$2; shift 2;;
        --dump-header) headers=$2; shift 2;;
        *) shift;;
    esac
done
[ -n "$out" ] && [ -n "$headers" ]
printf 'HTTP/2 403\r\nX-RateLimit-Remaining: 0\r\n\r\n' > "$headers"
printf '{"message":"API rate limit exceeded for IP"}' > "$out"
printf '403'
EOF
    chmod 755 "$root/rate-bin/curl"
    for operation in source install; do
        if [ "$operation" = source ]; then set -- source refresh manager; else set -- install-upstream; fi
        reject env PATH="$root/rate-bin:$PATH" JZM_MODE=command /usr/bin/jzm "$@" > "$root/api-error" 2>&1
        grep -Fq 'Превышен лимит запросов GitHub API (60/час на ваш IP)' "$root/api-error"
        cmp "$root/cache-before" /etc/zapret-manager/manager.json
        unchanged
    done
}
blockcheck_restore() {
    cp "$conf" "$root/before"
    cp /etc/zapret-manager/state.json "$root/blockcheck-state"
    cp -p /opt/zapret/blockcheck.sh "$root/blockcheck.original"
    trap 'cp -p "$root/blockcheck.original" /opt/zapret/.blockcheck.restore; mv -f /opt/zapret/.blockcheck.restore /opt/zapret/blockcheck.sh' 0
    cat > /opt/zapret/.blockcheck.test <<'EOF'
#!/bin/sh
set -eu
if /etc/init.d/zapret running; then exit 90; fi
printf 'blockcheck ready\n'
IFS= read -r answer
[ "$answer" = ready ]
case "$(cat /tmp/jzm-e2e/blockcheck-mode)" in
    success) :;;
    failure) exit 23;;
    INT) kill -INT "$PPID"; exit 130;;
    TERM) kill -TERM "$PPID"; exit 143;;
    HUP) kill -HUP "$PPID"; exit 143;;
    *) exit 2;;
esac
EOF
    mv -f /opt/zapret/.blockcheck.test /opt/zapret/blockcheck.sh
    for mode in success failure INT TERM HUP; do
        printf '%s\n' "$mode" > "$root/blockcheck-mode"
        if [ "$mode" = success ]; then
            printf 'ready\n' | jzm blockcheck > "$root/blockcheck-output" 2>&1
        else
            printf 'ready\n' | reject jzm blockcheck > "$root/blockcheck-output" 2>&1
        fi
        grep -q 'blockcheck ready' "$root/blockcheck-output"
        cmp "$root/blockcheck-state" /etc/zapret-manager/state.json
        unchanged
    done
    jzm service stop
    jzm service disable
    printf 'success\n' > "$root/blockcheck-mode"
    printf 'ready\n' | jzm blockcheck
    reject /etc/init.d/zapret running
    reject /etc/init.d/zapret enabled
    reject nfqws_pids
    cmp "$root/before" "$conf"
    [ ! -d "$lock" ]
    jzm service enable
    jzm service start
    health
}
rollback_after_write() {
    cp "$conf" "$root/before"
    cp -p /opt/zapret/sync_config.sh "$root/sync.original"
    trap 'cp -p "$root/sync.original" /opt/zapret/sync_config.sh; rm -f "$root/fail-sync"' 0
    {
        printf '#!/bin/sh\n'
        printf 'if [ -f /tmp/jzm-e2e/fail-sync ]; then\n'
        printf '  uci get "zapret.@main[0].DISABLE_IPV6" > /tmp/jzm-e2e/observed-write\n'
        printf '  rm /tmp/jzm-e2e/fail-sync\n  exit 97\nfi\n'
        cat "$root/sync.original"
    } > "$root/sync.injected"
    cp "$root/sync.injected" /opt/zapret/sync_config.sh
    old=$(jzm config get DISABLE_IPV6)
    changed=$((1 - old))
    touch "$root/fail-sync"
    reject jzm config set DISABLE_IPV6 "$changed"
    [ "$(cat "$root/observed-write")" = "$changed" ]
    unchanged
}
interrupted_transaction() {
    cp "$conf" "$root/before"
    mkdir -p "$root/slow-bin"
    cat > "$root/slow-bin/curl" <<'EOF'
#!/bin/sh
touch /tmp/jzm-e2e/probe-entered
sleep 3
exit 22
EOF
    chmod 755 "$root/slow-bin/curl"
    printf '%s\n' '#probe' '--filter-tcp=443' '--dpi-desync=multisplit' > "$root/probe-catalog.txt"
    printf '%s\n' 'http://127.0.0.1/' > "$root/targets.txt"
    env PATH="$root/slow-bin:$PATH" JZM_MODE=command /usr/bin/jzm benchmark "$root/targets.txt" "$root/probe-catalog.txt" &
    job=$!
    trap 'kill -TERM "$job" 2>/dev/null || :; wait "$job" 2>/dev/null || :' 0
    attempts=0
    while [ ! -f "$root/probe-entered" ] && [ "$attempts" -lt 60 ]; do sleep 1; attempts=$((attempts + 1)); done
    test -f "$root/probe-entered"
    kill -TERM "$(cat "$lock/pid")"
    reject wait "$job"
    unchanged
}
remove_packages() {
    jzm remove
    reject nfqws_pids
    for package in zapret luci-app-zapret; do
        if command -v apk >/dev/null 2>&1; then reject apk info -e "$package"
        else
            opkg status "$package" > "$root/package-status" || :
            reject grep -q 'Status: .* installed' "$root/package-status"
        fi
    done
    test -x /usr/bin/jzm
    jzm version
    jzm status | grep -q 'not installed'
    jzm uninstall all
    test ! -e /usr/bin/jzm
    test ! -e /usr/bin/jzm.previous
    test ! -e /etc/zapret-manager
    test ! -e /etc/config/zapret
    test ! -e /opt/zapret
    reject nfqws_pids
    nft list table inet fw4 >/dev/null
    cmp "$root/network.before" /etc/config/network
    cmp "$root/dhcp.before" /etc/config/dhcp
    cmp "$root/dropbear.before" /etc/config/dropbear
}

cases='public_contract packages_luci live_status noop_preserves_process preset_label modified_label invalid_ports invalid_strategy service_cycle autostart settings hostlists backup_roundtrip invalid_backup url_probe benchmark_preserves_state compound_groups flowseal devices networking schedule noop_update manager_reinstall busy_lock failed_download github_rate_limit blockcheck_restore rollback_after_write interrupted_transaction uninstall_manager remove_packages'
case "${1:-}" in
--case)
    [ "$#" -eq 2 ]
    case " $cases " in *" $2 "*) "$2";; *) exit 2;; esac
    exit 0;;
--reset) set -x; reset; exit 0;;
'') ;;
*) exit 2;;
esac
mkdir -p "$root/report"
cp /etc/config/firewall "$root/firewall"
if [ -f /etc/crontabs/root ]; then cp -p /etc/crontabs/root "$root/cron"; else touch "$root/cron.absent"; fi
jzm backup save "$root/baseline.json"
# Normalize empty hooks once, then compare the complete restore set between cases.
jzm backup restore "$root/baseline.json" > "$root/report/baseline-setup.log" 2>&1
health
mkdir -p "$root/baseline-files"
baseline_files save
cp /etc/config/network "$root/network.before"
cp /etc/config/dhcp "$root/dhcp.before"
cp /etc/config/dropbear "$root/dropbear.before"
: > "$root/report/results.tsv"
failed=0
number=0
blocked=0
printf 'TAP version 13\n'
for name in $cases; do
    number=$((number + 1))
    if [ "$blocked" = 1 ]; then
        printf 'ok %s - %s # SKIP baseline recovery failed\n' "$number" "$name"
        printf 'skip\t%s\t0\n' "$name" >> "$root/report/results.tsv"
        continue
    fi
    start=$(date +%s)
    # A new shell keeps errexit effective; functions invoked inside an if lose it in POSIX sh.
    if sh "$0" --case "$name" > "$root/report/$name.log" 2>&1; then result=pass; verdict=ok
    else result=fail; verdict='not ok'; failed=1; fi
    printf '%s %s - %s\n' "$verdict" "$number" "$name"
    printf '%s\t%s\t%s\n' "$result" "$name" "$(($(date +%s) - start))" >> "$root/report/results.tsv"
    if [ "$result" = fail ]; then sed 's/^/# /' "$root/report/$name.log"; fi
    # Package removal is deliberately last; this flash copy is discarded by the host.
    [ "$name" != remove_packages ] || continue
    reset_start=$(date +%s)
    if ! sh "$0" --reset > "$root/report/$name.reset.log" 2>&1; then
        printf '# baseline recovery failed; remaining cases will be skipped\n'
        printf 'fail\t%s_reset\t0\n' "$name" >> "$root/report/results.tsv"
        failed=1; blocked=1
    fi
    printf '%s\t%s\n' "$name" "$(($(date +%s) - reset_start))" >> "$root/report/resets.tsv"
done
printf '1..%s\n' "$number"
touch "$root/report/complete"
exit "$failed"
__JZM_ROUTER__
}

setup_emulator() {
    emulator=$project/.emulator
    version=${E2E_OPENWRT_VERSION:-25.12.5}
    fail() { printf 'emulator-setup: %s\n' "$*" >&2; exit 1; }
    need() { command -v "$1" >/dev/null 2>&1 || fail "нужна команда $1 (см. readme.md)"; }
    [ "$(uname -s):$(uname -m)" = Linux:x86_64 ] || fail 'нужен Linux x86_64 или WSL2; Git Bash не запускает Linux QEMU'
    case "$version" in ''|*[!0-9.]*|.*|*..*|*.) fail 'E2E_OPENWRT_VERSION: укажите точный релиз, например 25.12.5';; esac
    need python3
    need bash
    mkdir -p "$emulator"
    lock=$emulator/.setup.lock
    mkdir "$lock" 2>/dev/null || fail "подготовка уже идёт: $lock"
    trap 'rc=$?; trap - 0 INT TERM HUP; rmdir "$lock" 2>/dev/null || :; exit "$rc"' 0
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    if [ ! -x "$emulator/qemu/qemu-system-aarch64" ] ||
       [ ! -f "$emulator/tools/prepare-nand.sh" ] ||
       [ ! -f "$emulator/presets/cudy-wr3000p-v1.ini" ] ||
       [ ! -f "$emulator/.jzm-release.json" ]; then
        host_python assets "$emulator"
    else
        printf '%s\n' 'Router Emulator: используется локальная установка, загрузка не нужна.'
    fi
    image=$emulator/images/$version/nand-wr3000p
    ready=yes
    [ -f "$image/.jzm-ready" ] || ready=no
    for part in 0.BL2 1.u-boot-env 2.Factory 3.bdinfo 4.FIP 5.ubi; do
        [ -s "$image/mt7981.mtd$part.bin" ] || ready=no
    done
    if [ "$ready" = yes ]; then
        printf 'OpenWrt %s: готовый чистый образ %s\n' "$version" "$image"
        exit 0
    fi
    need wget
    need sha256sum
    if ! command -v ubinize >/dev/null 2>&1 && [ ! -x /usr/sbin/ubinize ] && [ ! -x /sbin/ubinize ]; then
        fail 'нужен ubinize из mtd-utils'
    fi
    mkdir -p "$(dirname "$image")"
    rm -f "$image/.jzm-ready"
    # Release packages omit the QEMU source chip table: pass the preset's geometry explicitly.
    bash "$emulator/tools/prepare-nand.sh" --flash-type nand --flash-id c8017f7f7f --flash-mb 128 \
        cudy_wr3000p-v1 "$version" "$image" </dev/null
    for part in 0.BL2 1.u-boot-env 2.Factory 3.bdinfo 4.FIP 5.ubi; do
        [ -s "$image/mt7981.mtd$part.bin" ] || fail "неполный образ: mtd$part"
    done
    printf '%s\n' "$version" > "$image/.jzm-ready"
    printf 'Готово: Cudy WR3000P v1 / OpenWrt %s\n' "$version"
}

case "${1:-run}" in
    setup) [ "$#" -eq 1 ] || exit 2; setup_emulator; exit;;
    selftest) [ "$#" -eq 1 ] || exit 2; host_python selftest; exit;;
    payload)
        [ "$#" -eq 2 ] || exit 2
        case "$2" in bootstrap) bootstrap_script;; router) router_script;; *) exit 2;; esac
        exit;;
    run) [ "$#" -eq 0 ] || { [ "$#" -eq 1 ] || exit 2; shift; };;
    *) printf '%s\n' 'usage: e2e-emulator.sh [run|setup|selftest]' >&2; exit 2;;
esac

emulator=$project/.emulator
version=${E2E_OPENWRT_VERSION:-25.12.5}
boot_timeout=${E2E_BOOT_TIMEOUT:-60}
command_timeout=${E2E_COMMAND_TIMEOUT:-1800}
port=${E2E_SSH_PORT:-8022}
run=$(date -u +%Y%m%dT%H%M%SZ)-$$
reports=$project/.test-tmp/e2e
report=$reports/$run
mkdir -p "$report"
printf 'E2E logs: %s\n' "$report"
: > "$report/host.tsv"
EMU_PID=''
STAGE_PID=''
runtime=''
owned_lock=0
ssh_ready=0
guest_started=0
active=''
record() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$report/host.tsv"; }
remote_limit() {
    limit=$1; shift
    timeout --kill-after=5 "$limit" ssh -F /dev/null -T \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null \
        -o BatchMode=yes -o IdentityAgent=none -o ConnectTimeout=2 \
        -o ServerAliveInterval=5 -o ServerAliveCountMax=3 -p "$port" root@127.0.0.1 "$@"
}
remote() { remote_limit "$command_timeout" "$@"; }
copy_to() {
    # Dropbear images may not include SFTP; legacy SCP works before package bootstrap.
    timeout --kill-after=5 60 scp -F /dev/null -O -q \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null \
        -o BatchMode=yes -o IdentityAgent=none -o ConnectTimeout=2 -P "$port" "$1" "root@127.0.0.1:$2"
}
collect() {
    timeout --kill-after=2 20 scp -F /dev/null -O -q -r \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null \
        -o BatchMode=yes -o IdentityAgent=none -o ConnectTimeout=2 -P "$port" \
        root@127.0.0.1:/tmp/jzm-e2e/report "$report/guest"
}
stop_emulator() {
    [ -n "$EMU_PID" ] || return 0
    # The upstream launcher waits for QEMU without forwarding signals. setsid gives both our own PGID.
    kill -TERM "$EMU_PID" 2>/dev/null || :
    kill -TERM "-$EMU_PID" 2>/dev/null || :
    attempt=0
    while kill -0 "-$EMU_PID" 2>/dev/null && [ "$attempt" -lt 5 ]; do
        sleep 1
        attempt=$((attempt + 1))
    done
    kill -KILL "-$EMU_PID" 2>/dev/null || :
    kill -KILL "$EMU_PID" 2>/dev/null || :
    wait "$EMU_PID" 2>/dev/null || :
    EMU_PID=''
}
finish() {
    rc=$?
    trap - 0 INT TERM HUP
    set +e
    if [ -n "$active" ]; then record fail "$active" 0; fi
    if [ -n "$STAGE_PID" ]; then
        kill -TERM "$STAGE_PID" 2>/dev/null || :
        kill -TERM "-$STAGE_PID" 2>/dev/null || :
    fi
    if [ "$guest_started" = 1 ]; then
        if ! collect > "$report/collect.log" 2>&1; then record fail collect_guest_reports 0; rc=1; fi
        if [ ! -f "$report/guest/complete" ]; then record fail guest_suite_incomplete 0; rc=1; fi
    fi
    if [ "$ssh_ready" = 1 ]; then
        # Diagnostics must not hold up process cleanup when the guest is unresponsive.
        remote_limit 15 'uname -a; cat /etc/openwrt_release; ubus call system board; JZM_MODE=command /usr/bin/jzm status; uci show zapret; pgrep -a nfqws; nft list ruleset; logread | tail -n 150; df -h' \
            > "$report/diagnostics.log" 2>&1 || :
    fi
    stop_emulator
    if [ -n "$runtime" ]; then
        case "$runtime" in /tmp/jzm-e2e.*) rm -rf -- "$runtime";; esac
    fi
    if [ "$owned_lock" = 1 ]; then
        rm -f "$emulator/.e2e.lock/pid"
        if ! rmdir "$emulator/.e2e.lock"; then record fail cleanup_lock 0; rc=1; fi
    fi
    if ! host_python report "$report" "$rc"; then
        record fail render_report 0
        rc=1
        # A missing Python installation still leaves a report explaining the failed preflight.
        awk -F '\t' 'BEGIN {print "TAP version 13"} {n++; print ($1=="fail"?"not ok":"ok"),n,"-",$2} END {print "1.."n}' \
            "$report/host.tsv" > "$report/report.tap"
        printf '%s\n' '{"success":false,"error":"report generator unavailable; see host.tsv and logs"}' > "$report/report.json"
        printf '%s\n' 'E2E FAIL: report generator unavailable' | tee "$report/summary.txt"
    fi
    printf '%s\n' "$report" > "$reports/latest.txt"
    printf 'Отчёты: %s\n' "$report"
    exit "$rc"
}
trap finish 0
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
stage() {
    name=$1; shift
    active=$name
    start=$(date +%s)
    printf 'E2E: %s ...\n' "$name"
    # wait is interrupted immediately by signals; a synchronous SSH could defer the trap for minutes.
    # Background lists otherwise receive /dev/null, losing the bootstrap script supplied on stdin.
    exec 3<&0
    "$@" > "$report/$name.log" 2>&1 <&3 &
    STAGE_PID=$!
    exec 3<&-
    if wait "$STAGE_PID"; then
        record pass "$name" "$(($(date +%s) - start))"
        active=''
        STAGE_PID=''
    else
        code=$?
        record fail "$name" "$(($(date +%s) - start))"
        active=''
        STAGE_PID=''
        cat "$report/$name.log" >&2
        return "$code"
    fi
}
preflight() {
    [ "$#" -eq 0 ] || return 2
    if [ "$(uname -s):$(uname -m)" != Linux:x86_64 ]; then
        printf '%s\n' 'E2E: нужен Linux x86_64 или WSL2. Git Bash не исполняет Linux QEMU.' >&2
        return 1
    fi
    for tool in python3 bash ssh scp setsid timeout; do
        command -v "$tool" >/dev/null 2>&1 || { printf 'E2E: нужна команда %s\n' "$tool" >&2; return 1; }
    done
    for value in "$boot_timeout" "$command_timeout" "$port"; do
        case "$value" in ''|*[!0-9]*) printf '%s\n' 'E2E: таймауты и порт должны быть целыми числами' >&2; return 1;; esac
        [ "$value" -gt 0 ] && [ "$value" -le 65535 ] || return 1
    done
    case "$version" in ''|*[!0-9.]*|.*|*..*|*.) return 1;; esac
    test -s "$project/dist/just-zapret-manager.sh" || return 1
    python3 - "$port" <<'PY'
import socket, sys
with socket.socket() as listener:
    listener.bind(("127.0.0.1", int(sys.argv[1])))
PY
}
wait_ssh() {
    deadline=$(($(date +%s) + boot_timeout))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        kill -0 "$EMU_PID" 2>/dev/null || { cat "$report/emulator.log" >&2; return 1; }
        remaining=$((deadline - $(date +%s)))
        [ "$remaining" -gt 0 ] || break
        limit=2
        [ "$remaining" -ge 2 ] || limit=$remaining
        if remote_limit "$limit" 'echo ready' > "$report/ssh-last.log" 2>&1; then
            grep -q '^ready$' "$report/ssh-last.log" && return 0
        fi
        sleep 1
    done
    printf 'SSH не готов за %s секунд. UART: %s/console/\n' "$boot_timeout" "$report" >&2
    cat "$report/ssh-last.log" >&2 || :
    return 1
}
require_emulator() {
    for file in "$emulator/emulator.sh" "$emulator/qemu/qemu-system-aarch64" "$emulator/.jzm-release.json" \
        "$emulator/presets/cudy-wr3000p-v1.ini" "$emulator/images/$version/nand-wr3000p/.jzm-ready"; do
        [ -s "$file" ] || { printf '%s\n' 'Эмулятор не подготовлен: выполните just emulator-setup' >&2; return 1; }
    done
}
stage preflight preflight "$@"
stage emulator_ready require_emulator
active=acquire_lock
mkdir "$emulator/.e2e.lock" 2>/dev/null || { printf 'Другой E2E уже запущен: %s/.e2e.lock\n' "$emulator" >&2; exit 1; }
owned_lock=1
printf '%s\n' "$$" > "$emulator/.e2e.lock/pid"
active=''
active=copy_pristine_flash
runtime=$(mktemp -d /tmp/jzm-e2e.XXXXXX)
mkdir "$runtime/flash"
cp -Rp "$emulator/images/$version/nand-wr3000p/." "$runtime/flash/"
bootstrap_script > "$runtime/bootstrap.sh"
router_script > "$runtime/router.sh"
record pass copy_pristine_flash 0
active=launch_emulator
# Positional parameters are expanded by the session's shell, not by this launcher.
# shellcheck disable=SC2016
QEMU_BIN=$emulator/qemu/qemu-system-aarch64 setsid sh -c 'cd "$1" && exec ./emulator.sh -P cudy-wr3000p-v1 -w user -l user -u none -o "lan-forwards=$6:22" -n "$2" -S "$3" -m "$4" -L "$5"' \
    jzm-emulator "$emulator" "$runtime/flash" "$runtime/console.sock" "$runtime/monitor.sock" "$report/console" "$port" \
    > "$report/emulator.log" 2>&1 </dev/null &
EMU_PID=$!
record pass launch_emulator 0
active=''
stage ssh_ready wait_ssh
ssh_ready=1
# Fresh flash has no persisted clock; HTTPS certificate verification needs host UTC.
stage guest_bootstrap remote "date -u -s '@$(date +%s)' && JZM_E2E_GUEST=1 sh -s" < "$runtime/bootstrap.sh"
stage upload_manager copy_to "$project/dist/just-zapret-manager.sh" /tmp/just-zapret-manager.sh
# Installation is an internal command too; public positional arguments remain forbidden.
stage install_manager remote 'JZM_MODE=command sh /tmp/just-zapret-manager.sh manager-install && test -x /usr/bin/jzm'
stage install_zapret_luci remote 'JZM_MODE=command /usr/bin/jzm install-upstream'
stage refresh_manager_catalog remote 'JZM_MODE=command /usr/bin/jzm source refresh manager'
stage apply_v7 remote 'JZM_MODE=command /usr/bin/jzm source apply manager v7'
stage upload_suite copy_to "$runtime/router.sh" /tmp/jzm-e2e-router.sh
guest_started=1
stage router_suite remote 'JZM_E2E_GUEST=1 sh /tmp/jzm-e2e-router.sh'
cat "$report/router_suite.log"
