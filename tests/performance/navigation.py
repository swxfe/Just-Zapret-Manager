from collections import Counter
from pathlib import Path
import json
import os
import subprocess
import sys
import time

config, preload = sys.argv[1:]
project = Path.cwd()
root = os.environ['ZM_TEST_ROOT']
log = Path(preload).with_name('ui-reads.log')
cycle = ('3\n2\n1\nn\np\n0\n0\n0\n'  # strategy editor, pagination and return
         '1\n0\n'                       # package submenu
         '6\n1\n\n0\n'                 # view configuration
         '5\n1\n1\n\n0\n0\n'           # view hostlist
         '6\n8\n0\n\n0\n'              # view devices
         '6\n9\n0\n\n0\n'              # view firewall status
         '2\n0\n7\n0\n')                # service and backup navigation
rounds = 50
env = {**os.environ, 'JZM_CONFIG': config, 'LD_PRELOAD': preload,
       'JZM_FORBID_FORK': '1', 'JZM_READ_LOG': str(log)}
env.pop('JZM_MODE', None)
release = Path(root) / 'etc/openwrt_release'
release.write_text("DISTRIB_ARCH='test_arch'\n")
readonly_env = {**env, 'JZM_FORBID_WRITES': '1'}
readonly = subprocess.run(['ucode', '-S', '-L', str(project / 'src/lib'), 'tests/performance/read-only.uc', config],
                          env=readonly_env, capture_output=True, timeout=5)
assert readonly.returncode == 0, readonly.stderr.decode(errors='replace')
log.unlink(missing_ok=True)
env['JZM_FORBID_WRITES'] = '1'
start = time.monotonic()
result = subprocess.run(['ucode', '-S', '-L', str(project / 'src/lib'), str(project / 'src/main.uc')],
                        input=(cycle * rounds + '0\n').encode(), env=env, capture_output=True, timeout=15)
elapsed = time.monotonic() - start
assert result.returncode == 0, result.stderr.decode(errors='replace')
assert 'Ошибка:'.encode() not in result.stdout, result.stdout.decode(errors='replace')
assert result.stdout.count('JZM · Собрать стратегию'.encode()) == rounds * 2
reads = Counter(log.read_text().splitlines())
# Configuration is read once through libuci and once as raw text for 'show'.
assert reads[root + '/etc/config/zapret'] <= 2, reads
for path, count in reads.items():
    if path != root + '/etc/config/zapret':
        assert count <= 1, (path, count, reads)
assert reads[root + '/etc/zapret-manager/assets/catalogs/flowseal.json'] == 1, reads
print(f'performance: {rounds} navigation cycles, zero fork/popen, managed inputs read once; '
      f'{elapsed * 1000 / rounds:.2f} ms/cycle on this host')
