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
    result = reports.render(Path(sys.argv[3]), int(sys.argv[4]))
    # 10 means a valid report with failed assertions, distinct from rendering errors.
    sys.exit(0 if result["success"] else 10)
elif action == "parallel":
    import shards
    try:
        sys.exit(shards.main(project))
    except (OSError, ValueError) as error:
        sys.exit(f"E2E: {error}")
elif action == "case-list":
    import os
    import shards
    print(" ".join(shards.selection(project, os.environ.get("E2E_CASES"))))
elif action == "selftest":
    sys.path.insert(0, str(project / "tests/setup"))
    suite = unittest.defaultTestLoader.discover(str(project / "tests/e2e/host/selftests"))
    sys.path.insert(0, str(project / "tests/support"))
    from runner import Task, run

    def cases(tests):
        for test in tests:
            if isinstance(test, unittest.TestSuite):
                yield from cases(test)
            else:
                yield test

    tasks = [Task(test.id(), (sys.executable, "-B", str(Path(__file__)), str(project),
                             "selftest-case", test.id())) for test in cases(suite)]
    sys.exit(run(tasks))
elif action == "selftest-case":
    sys.path.insert(0, str(project / "tests/setup"))
    sys.path.insert(0, str(project / "tests/e2e/host/selftests"))
    suite = unittest.defaultTestLoader.loadTestsFromName(sys.argv[3])
    sys.exit(not unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful())
else:
    sys.exit("unknown host utility action")
