"""Bounded test processes with grouped output, timings and process-tree cleanup."""
from dataclasses import dataclass
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time


@dataclass(frozen=True)
class Task:
    name: str
    command: tuple[str, ...]


def jobs():
    value = os.environ.get("JZM_TEST_JOBS")
    if value is None:
        return min(4, os.cpu_count() or 1)
    if not value.isascii() or not value.isdecimal() or int(value) < 1:
        raise ValueError("JZM_TEST_JOBS must be a positive integer")
    return int(value)


def run(tasks, *, workers=None, cleanup_timeout=5):
    workers = jobs() if workers is None else workers
    if workers < 1:
        raise ValueError("workers must be positive")
    pending = iter(tasks)
    running = []
    failed = False
    started = time.monotonic()
    previous = {}
    launching = False
    deferred_signal = None

    def interrupted(signum, _frame):
        nonlocal deferred_signal
        if launching:
            # Popen may already have created a process but not returned its PID.
            deferred_signal = signum
            return
        raise SystemExit(128 + signum)

    def terminate():
        # A leader can exit before its descendants; always signal the whole session.
        for process, *_ in running:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        deadline = time.monotonic() + cleanup_timeout
        while any(process.poll() is None for process, *_ in running) and time.monotonic() < deadline:
            time.sleep(0.02)
        for process, *_ in running:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()

    try:
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            previous[sig] = signal.signal(sig, interrupted)
        with tempfile.TemporaryDirectory(prefix="jzm-tests-") as temporary:
            index = 0
            exhausted = False
            while running or not exhausted:
                while len(running) < workers and not exhausted:
                    task = next(pending, None)
                    if task is None:
                        exhausted = True
                        break
                    log = Path(temporary) / str(index)
                    index += 1
                    launching = True
                    try:
                        with log.open("wb") as output:
                            process = subprocess.Popen(task.command, stdout=output, stderr=subprocess.STDOUT,
                                                       start_new_session=True)
                        running.append((process, task, log, time.monotonic()))
                    finally:
                        launching = False
                    if deferred_signal is not None:
                        raise SystemExit(128 + deferred_signal)
                completed = False
                for item in running[:]:
                    process, task, log, start = item
                    result = process.poll()
                    if result is None:
                        continue
                    # Keep an entire suite's diagnostics together, including failures.
                    print(log.read_text(errors="replace"), end="", flush=True)
                    print(f"{task.name}: {'PASS' if result == 0 else 'FAIL'} "
                          f"({time.monotonic() - start:.2f}s)", flush=True)
                    failed |= result != 0
                    running.remove(item)
                    completed = True
                if running and not completed:
                    time.sleep(0.02)
    finally:
        # Ignore repeated interrupts while fixtures restore their state.
        for sig in previous:
            signal.signal(sig, signal.SIG_IGN)
        terminate()
        for sig, handler in previous.items():
            signal.signal(sig, handler)
    print(f"tests: {'FAIL' if failed else 'PASS'} ({time.monotonic() - started:.2f}s, "
          f"{workers} workers)", flush=True)
    return int(failed)
