"""Partition the unchanged guest cases across isolated Cudy QEMU workspaces."""
from collections import Counter
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import sys
import tempfile
import time

import reports

# Approximate cold Cudy timings, including reset. History refines these on later runs.
COSTS = {"blockcheck_success": 15, "blockcheck_failure": 15, "blockcheck_int": 15,
         "blockcheck_term": 15, "blockcheck_hup": 15, "blockcheck_stopped": 24,
         "benchmark_preserves_state": 41, "flowseal": 31,
         "devices": 30, "hostlists": 24, "backup_roundtrip": 19, "settings": 18,
         "compound_groups": 23, "interrupted_transaction": 24, "uninstall_manager": 29,
         "service_cycle": 16, "networking": 14}


def case_names(project):
    source = (project / "tests/e2e/router/run.sh").read_text()
    found = re.search(r"^all_cases='([^']+)'$", source, re.MULTILINE)
    if found is None:
        raise ValueError("guest case manifest missing")
    names = found[1].split()
    if not names or len(names) != len(set(names)) or any(
            re.fullmatch(r"[a-z][a-z0-9_]*", name) is None for name in names):
        raise ValueError("invalid guest case manifest")
    return names


def selection(project, value=None):
    known = case_names(project)
    names = known if value is None else value.split()
    if not names or len(names) != len(set(names)) or not set(names) <= set(known):
        raise ValueError("E2E_CASES must contain unique known guest cases")
    return names


def worker_count(value, *, cpus=None, available=None):
    if cpus is None:
        cpus = len(os.sched_getaffinity(0))
    if available is None:
        available = next(int(line.split()[1]) * 1024 for line in
                         Path("/proc/meminfo").read_text().splitlines() if line.startswith("MemAvailable:"))
    # Each board has 512 MB RAM plus private NAND/work buffers. Leave 1 GB for the host.
    memory_limit = max(1, (available - 1024**3) // (1536 * 1024**2))
    if value == "auto":
        return max(1, min(8, cpus // 2, memory_limit))
    if not value.isascii() or not value.isdecimal() or not 1 <= int(value) <= 8:
        raise ValueError("E2E_WORKERS must be auto or an integer from 1 to 8")
    count = int(value)
    if count > memory_limit:
        raise ValueError(f"E2E_WORKERS={count}: insufficient available RAM; limit is {memory_limit}")
    return count


def partition(names, count, costs=None):
    costs = {**COSTS, **(costs or {})}
    groups = [[] for _ in range(min(count, len(names)))]
    loads = [0] * len(groups)
    order = {name: index for index, name in enumerate(names)}
    for name in sorted(names, key=lambda name: -costs.get(name, 7)):
        target = min(range(len(groups)), key=lambda index: (loads[index], index))
        groups[target].append(name)
        loads[target] += costs.get(name, 7)
    return [sorted(group, key=order.get) for group in groups]


def history(project):
    folder = project / ".test-tmp/e2e"
    # A failed/interrupted run must not erase useful timings from the last complete run.
    candidates = sorted(folder.glob("*/report.json"), key=lambda path: path.stat().st_mtime, reverse=True)
    for path in candidates:
        try:
            previous = path.parent
            result = json.loads(path.read_text())
            if not result.get("success"):
                continue
            resets = {}
            paths = [previous / "guest/resets.tsv", *previous.glob("shards/*/*/guest/resets.tsv")]
            for reset_path in paths:
                if reset_path.exists():
                    for line in reset_path.read_text().splitlines():
                        name, seconds = line.split("\t")
                        resets[name] = int(seconds)
            costs = {row["name"].removeprefix("router/"):
                     max(1, row["seconds"]) + resets.get(row["name"].removeprefix("router/"), 3)
                     for row in result["cases"] if row["name"].startswith("router/") and row["status"] == "pass"}
            if costs:
                return costs
        except (OSError, ValueError, KeyError, TypeError):
            continue
    return {}


def workspace(project, folder, artifacts):
    # Only immutable emulator inputs are shared. The launcher's work/ and every flash stay private.
    (folder / "tests/setup").mkdir(parents=True)
    shutil.copytree(project / "tests/e2e", folder / "tests/e2e",
                    ignore=shutil.ignore_patterns("__pycache__"))
    for name in ("emulator.sh", "router-bootstrap.sh"):
        shutil.copyfile(project / "tests/setup" / name, folder / "tests/setup" / name)
    emulator = folder / ".emulator"
    emulator.mkdir()
    shutil.copy2(project / ".emulator/emulator.sh", emulator / "emulator.sh")
    for name in ("qemu", "tools", "presets", "images", ".jzm-release.json", "VERSION"):
        source = project / ".emulator" / name
        if source.exists():
            (emulator / name).symlink_to(source, target_is_directory=source.is_dir())
    (folder / "dist").symlink_to(project / "dist", target_is_directory=True)
    (folder / ".test-tmp").mkdir()
    artifacts.mkdir(parents=True)
    (folder / ".test-tmp/e2e").symlink_to(artifacts, target_is_directory=True)


def merge(folder, plans, code):
    host, guest, resets = [], [], []
    complete = True
    for plan in plans:
        label = f"worker-{plan['number']}"
        try:
            matches = list((folder / "shards" / label).glob("*/report.json"))
            if len(matches) != 1:
                raise ValueError("expected one worker report")
            child = matches[0].parent
            data = json.loads(matches[0].read_text())
            host.extend(f"{row['status']}\t{label}/{row['name']}\t{row['seconds']}\n"
                        for row in reports.rows(child / "host.tsv", ""))
            host.append(f"{'pass' if data['success'] else 'fail'}\t{label}/result\t0\n")
            child_guest = reports.rows(child / "guest/results.tsv", "")
            guest.extend(f"{row['status']}\t{row['name']}\t{row['seconds']}\n" for row in child_guest)
            reset_log = child / "guest/resets.tsv"
            if reset_log.exists():
                resets.append(reset_log.read_text())
            complete &= data["guest_complete"]
            if Counter(row["name"] for row in child_guest) != Counter(plan["cases"]):
                host.append(f"fail\t{label}/coverage\t0\n")
        except (OSError, ValueError, KeyError, TypeError):
            complete = False
            host.append(f"fail\t{label}/missing_report\t0\n")
    (folder / "host.tsv").write_text("".join(host))
    (folder / "guest").mkdir(exist_ok=True)
    (folder / "guest/results.tsv").write_text("".join(guest))
    (folder / "guest/resets.tsv").write_text("".join(resets))
    if complete and plans:
        (folder / "guest/complete").touch()
    return reports.render(folder, code)


def main(project):
    sys.path.insert(0, str(project / "tests/support"))
    from runner import Task, run

    names = case_names(project)
    count = min(worker_count(os.environ.get("E2E_WORKERS", "auto")), len(names))
    groups = partition(names, count, history(project))
    port = int(os.environ.get("E2E_SSH_PORT", "8022"))
    if not 1 <= port <= 65536 - count:
        raise ValueError("E2E_SSH_PORT range overflows")
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    folder = project / ".test-tmp/e2e" / f"{stamp}-parallel-{os.getpid()}"
    folder.mkdir(parents=True)
    (folder / "expected-cases.txt").write_text("\n".join(names) + "\n")
    print(f"E2E: {count} isolated routers, {len(names)} guest cases; logs: {folder}", flush=True)
    lock = project / ".emulator/.e2e.lock"
    owned = False
    plans = []
    code = 1
    previous = {}
    started = time.monotonic()

    def interrupted(signum, _frame):
        raise SystemExit(128 + signum)

    try:
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            previous[sig] = signal.signal(sig, interrupted)
        lock.mkdir()
        owned = True
        (lock / "pid").write_text(str(os.getpid()) + "\n")
        # Fail before any boot if even one requested port is already in use.
        reserved = []
        try:
            for index in range(count):
                listener = socket.socket()
                reserved.append(listener)
                listener.bind(("127.0.0.1", port + index))
        finally:
            for listener in reserved:
                listener.close()
        with tempfile.TemporaryDirectory(prefix="jzm-e2e-workers-") as temporary:
            tasks = []
            for index, cases in enumerate(groups):
                label = f"worker-{index + 1}"
                work = Path(temporary) / label
                workspace(project, work, folder / "shards" / label)
                plans.append({"number": index + 1, "port": port + index,
                              "workspace": str(work), "cases": cases})
                command = ("env", "E2E_WORKERS=1", f"E2E_WORKSPACE={work}",
                           f"E2E_SSH_PORT={port + index}", f"E2E_CASES={' '.join(cases)}",
                           f"E2E_BOOT_TIMEOUT={os.environ.get('E2E_BOOT_TIMEOUT', '90')}",
                           "sh", str(work / "tests/e2e/run.sh"))
                tasks.append(Task(label, command))
            (folder / "plan.json").write_text(json.dumps(plans, indent=2) + "\n")
            # Guests can need 20s collection + 15s diagnostics + 5s shutdown after TERM.
            code = run(tasks, workers=count, cleanup_timeout=50)
    except SystemExit as error:
        code = error.code if isinstance(error.code, int) else 1
    except (OSError, ValueError) as error:
        print(f"E2E: {error}", file=sys.stderr)
        (folder / "orchestrator-error.txt").write_text(str(error) + "\n")
    finally:
        for sig in previous:
            signal.signal(sig, signal.SIG_IGN)
        try:
            result = merge(folder, plans, code)
            (folder / "timing.json").write_text(json.dumps(
                {"seconds": round(time.monotonic() - started, 2), "workers": count}) + "\n")
            (folder.parent / "latest.txt").write_text(str(folder) + "\n")
        finally:
            if owned:
                (lock / "pid").unlink()
                lock.rmdir()
            for sig, handler in previous.items():
                signal.signal(sig, handler)
    print(f"E2E: {time.monotonic() - started:.2f}s; reports: {folder}", flush=True)
    return code if code else int(not result["success"])
