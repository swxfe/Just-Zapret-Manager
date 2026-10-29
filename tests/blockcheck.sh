#!/bin/sh
set -eu
# Exercise terminal job control rather than approximating it with a stdin pipe.
python3 - "$1" <<'PY'
import os
from pathlib import Path
import pty
import select
import signal
import sys
import time

config = sys.argv[1]
home = Path(os.environ['ZM_HOME'])
root = Path(os.environ['ZM_TEST_ROOT'])
script = root / 'opt/zapret/blockcheck.sh'
lock = root / 'tmp/zapret-manager.zapret.lock'
paths = [root / 'etc/config/zapret', root / 'etc/zapret-manager/state.json',
         root / 'opt/zapret/ipset/zapret-hosts-user.txt']
before = {path: path.read_bytes() if path.exists() else None for path in paths}
state = root / 'state'
enabled = root / 'enabled'
original = (state.exists(), enabled.exists())
passed = 0

def flag(path, value):
    if value:
        path.touch()
    else:
        path.unlink(missing_ok=True)

def session(entry, mode):
    pid, master = pty.fork()
    if pid == 0:
        os.environ['JZM_MODE'] = 'command'
        os.execvp('sh', ['sh', str(entry), '--config', config, 'blockcheck'])
    output = b''
    sent = False
    reaped = False
    deadline = time.monotonic() + 15
    try:
        while time.monotonic() < deadline:
            ready, _, _ = select.select([master], [], [], 0.05)
            if ready:
                try:
                    output += os.read(master, 65536)
                except OSError:
                    pass  # EIO is the normal PTY close on Linux.
            if b'JZM_BLOCKCHECK_READY' in output and not sent:
                sent = True
                if mode == 'INT':
                    os.write(master, b'\x03')
                elif mode in ('TERM', 'HUP'):
                    os.killpg(pid, getattr(signal, 'SIG' + mode))
                else:
                    os.write(master, b'ready\n')
            child, status = os.waitpid(pid, os.WNOHANG | os.WUNTRACED)
            if child:
                assert not os.WIFSTOPPED(status), ('terminal job stopped', status, output)
                reaped = True
                code = os.waitstatus_to_exitcode(status)
                assert (code == 0) == (mode == 'success'), (mode, code, output)
                if mode != 'missing':
                    assert sent, ('never reached terminal input', output)
                return
        raise AssertionError(('blockcheck timed out', mode, output))
    finally:
        if not reaped:
            os.killpg(pid, signal.SIGKILL)
            os.waitpid(pid, 0)
        os.close(master)

try:
    for entry in (home / 'src/launcher.sh', home / 'dist/just-zapret-manager.sh'):
        for running in (True, False):
            for mode in ('missing', 'success', 'failure', 'INT', 'TERM', 'HUP'):
                flag(state, running)
                flag(enabled, not running)
                script.unlink(missing_ok=True)
                if mode != 'missing':
                    script.write_text('''#!/bin/sh
set -eu
[ ! -f "$ZM_TEST_ROOT/state" ]
[ -t 0 ] && [ -t 1 ]
trap 'exit 130' INT
trap 'exit 143' TERM HUP
printf 'changed by blockcheck\\n' > "$ZM_TEST_ROOT/etc/config/zapret"
printf 'JZM_BLOCKCHECK_READY\\n'
IFS= read -r answer
[ "$answer" = ready ]
''' + ('exit 23\n' if mode == 'failure' else 'exit 0\n'))
                session(entry, mode)
                assert state.exists() == running, ('running state', entry, mode)
                assert enabled.exists() == (not running), ('enabled state', entry, mode)
                assert not lock.exists(), ('leaked lock', entry, mode)
                for path, content in before.items():
                    actual = path.read_bytes() if path.exists() else None
                    assert actual == content, ('snapshot not restored', path, entry, mode)
                passed += 1
finally:
    script.unlink(missing_ok=True)
    flag(state, original[0])
    flag(enabled, original[1])
print(f'blockcheck: {passed} foreground PTY and restoration checks passed')
PY
