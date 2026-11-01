from pathlib import Path
import sys
import tarfile
import unittest
import zipfile

import assets
import reports

project = Path(sys.argv[1])
action = sys.argv[2]
if action == "assets":
    try:
        assets.install(Path(sys.argv[3]).resolve())
    except (OSError, ValueError, tarfile.TarError, zipfile.BadZipFile) as error:
        sys.exit(f"emulator-assets: {error}")
elif action == "report":
    reports.render(Path(sys.argv[3]), int(sys.argv[4]))
elif action == "selftest":
    sys.path.insert(0, str(project / "tests/setup"))
    suite = unittest.defaultTestLoader.discover(str(project / "tests/e2e/host/selftests"))
    sys.exit(not unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful())
else:
    sys.exit("unknown host utility action")
