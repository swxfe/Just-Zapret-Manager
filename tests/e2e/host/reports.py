import json
from collections import Counter

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
    coverage = None
    manifest = folder / "expected-cases.txt"
    if manifest.is_file():
        expected = manifest.read_text().split()
        actual = [row["name"].removeprefix("router/") for row in cases if row["name"].startswith("router/")]
        coverage = {"expected": len(expected), "received": len(actual),
                    "missing": sorted(set(expected) - set(actual)),
                    "unexpected": sorted(set(actual) - set(expected)),
                    "duplicates": sorted(name for name, count in Counter(actual).items() if count > 1)}
        if not expected or len(expected) != len(set(expected)) or Counter(expected) != Counter(actual):
            cases.append({"name": "host/guest_coverage", "status": "fail", "seconds": 0})
    totals = {key: sum(case["status"] == key for case in cases) for key in ("pass", "fail", "skip")}
    complete = (folder / "guest/complete").is_file()
    success = exit_code == 0 and totals["fail"] == 0 and totals["skip"] == 0 and complete
    report = {"success": success, "guest_complete": complete, "exit_code": exit_code, "totals": totals, "cases": cases, "coverage": coverage}
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
