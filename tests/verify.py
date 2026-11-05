#!/usr/bin/env python3
"""Build available editions and check their shared observable behavior.

Run from any directory. --only python,c selects editions. --overrides FILE
accepts a JSON mapping from language ID to build/run/env settings for isolated
toolchains. SQL has its own database integration instructions in index.html.
"""
from __future__ import annotations
import argparse
import csv
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = json.loads((ROOT / "manifest.json").read_text())
REFERENCE = json.loads((ROOT / "tests/reference.json").read_text())


def verify(entry: dict) -> dict:
    result = {"id": entry["id"], "language": entry["name"], "status": "untested", "checks": []}
    result["source_sha256"] = hashlib.sha256((ROOT / entry["source"]).read_bytes()).hexdigest()
    if entry.get("integration_required") or entry["id"] == "sql":
        result["reason"] = entry.get("integration_required", "Requires an explicitly configured PostgreSQL database; see SQL integration instructions.")
        return result
    env = dict(os.environ, LC_ALL="C", **entry.get("env", {}))
    build, command = entry.get("build"), entry["run"]
    executable = (build or command)[0]
    for prerequisite in entry.get("build_prerequisites", []):
        if not shutil.which(prerequisite, path=env.get("PATH")) and not env.get("FBC"):
            result["reason"] = f"Build prerequisite unavailable: {prerequisite}"
            return result
    if not shutil.which(executable, path=env.get("PATH")) and not (ROOT / executable).is_file():
        result["reason"] = f"Tool or executable unavailable: {executable}"
        return result
    try:
        if build:
            protected = {item["source"]: (ROOT / item["source"]).read_bytes()
                         for item in MANIFEST["languages"]}
            built = subprocess.run(build, cwd=ROOT, env=env, capture_output=True, text=True, timeout=180)
            for source, contents in protected.items():
                assert (ROOT / source).is_file() and (ROOT / source).read_bytes() == contents, \
                    f"build altered a source file: {source}"
            if built.returncode:
                raise AssertionError("build failed: " + (built.stdout + built.stderr)[-5000:])
        with tempfile.TemporaryDirectory(prefix="bessel-test-") as temporary:
            temp = Path(temporary)
            output = temp / "result.csv"

            def invoke(args: list[str], stdin: str = "", success: bool = True):
                process = subprocess.Popen(command + args, cwd=ROOT, env=env,
                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                try:
                    stdout, stderr = process.communicate(stdin, timeout=90)
                except subprocess.TimeoutExpired:
                    process.kill(); process.communicate()
                    raise AssertionError("program timed out")
                if success and process.returncode != 0:
                    raise AssertionError(f"unexpected exit {process.returncode}: {stderr[-3000:]}")
                if not success and process.returncode == 0:
                    raise AssertionError(f"accepted invalid invocation: {args}")
                if not success and not stderr.strip():
                    raise AssertionError("failure lacked a diagnostic on stderr")
                return process.pid, stdout, stderr

            def check_rows(expected: list[tuple[float, float]], parent_pid: int):
                with output.open() as stream:
                    reader = csv.DictReader(stream)
                    assert reader.fieldnames == ["x", "j0", "worker_pid"], reader.fieldnames
                    rows = list(reader)
                assert len(rows) == len(expected), (len(rows), len(expected))
                for row, (x, j0) in zip(rows, expected):
                    actual_x, actual_y = float(row["x"]), float(row["j0"])
                    assert math.isclose(actual_x, x, abs_tol=1e-13), (actual_x, x)
                    assert math.isfinite(actual_y) and abs(actual_y - j0) < REFERENCE["absolute_tolerance"], (x, actual_y, j0)
                    assert int(row["worker_pid"]) > 0 and int(row["worker_pid"]) != parent_pid, row
                return rows

            def passed(name): result["checks"].append(name)

            _, help_text, _ = invoke(["--help"])
            assert "usage" in help_text.lower()
            passed("help")
            expected = [(r["x"], float(r["j0"])) for r in REFERENCE["values"]]
            parent, _, _ = invoke(["examples/values.txt", str(output), "2"])
            rows = check_rows(expected, parent)
            result["observed_worker_pids"] = sorted({int(r["worker_pid"]) for r in rows})
            passed("reference values, order, CSV schema, child process IDs")
            parent, _, _ = invoke(["examples/values.txt", str(output), "1"])
            check_rows(expected, parent)
            passed("single-worker invocation")
            refs = dict(expected)
            parent, _, warnings = invoke(["examples/mixed.txt", str(output), "2"])
            check_rows([(x, refs[x]) for x in [0, 1, 5]], parent)
            assert any(word in warnings.lower() for word in ("warning", "skipping"))
            passed("invalid lines skipped with diagnostics")
            parent, _, _ = invoke(["-", str(output), "2"], "0\ninvalid\n1\n\n5\n")
            check_rows([(x, refs[x]) for x in [0, 1]], parent)
            passed("interactive/stdin and blank-line termination")
            for jobs in ("0", "17", "nonsense", "1.5"):
                invoke(["examples/values.txt", str(output), jobs], success=False)
            passed("invalid worker counts")
            invoke([str(temp / "missing.txt"), str(output), "2"], success=False)
            passed("missing input file")
            invoke(["examples/values.txt", str(temp), "2"], success=False)
            passed("unwritable output target (directory)")
            invoke(["-", str(output), "2"], "bad\nNaN\n\n", success=False)
            passed("no valid input")
            invoke(["-", str(output), "2", "extra"], success=False)
            passed("excess arguments")
            too_many = temp / "too-many.txt"
            too_many.write_text("0\n" * 4097)
            invoke([str(too_many), str(output), "2"], success=False)
            passed("input size bound")
        result["status"] = "passed"
    except (OSError, subprocess.SubprocessError, AssertionError, ValueError, KeyError) as error:
        result["status"] = "failed"
        result["reason"] = str(error)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--only", help="comma-separated language IDs")
    parser.add_argument("--require-all", action="store_true",
                        help="fail if any selected edition is unavailable or untested")
    parser.add_argument("--overrides", type=Path)
    parser.add_argument("--report", type=Path, default=ROOT / "tests/report.json")
    args = parser.parse_args()
    overrides = json.loads(args.overrides.read_text()) if args.overrides else {}
    selected = {name.strip() for name in args.only.split(",")} if args.only is not None else None
    if selected is not None:
        unknown = selected - {entry["id"] for entry in MANIFEST["languages"]}
        if unknown:
            parser.error("unknown language IDs: " + ", ".join(sorted(unknown)))
    for directory in ("build", "build/pascal", "build/ada", "build/fortran", "build/haskell"):
        (ROOT / directory).mkdir(exist_ok=True)
    results = []
    for original in MANIFEST["languages"]:
        if selected and original["id"] not in selected:
            continue
        entry = original | overrides.get(original["id"], {})
        result = verify(entry)
        results.append(result)
        print(f"{result['language']}: {result['status']} ({len(result['checks'])} checks)", flush=True)
        if "reason" in result: print("  " + result["reason"][:1200], flush=True)
    report = {"generated_utc": datetime.now(timezone.utc).isoformat(),
        "method": "Black-box execution against stored 80-digit reference values; process IDs checked against parent PID. No assertion of bitwise equality or relative speed.",
        "toolchains": "Some toolchains may be unpacked into /tmp through --overrides; no global installations are required.",
        "results": results}
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + "\n")
    return int(any(r["status"] == "failed" or
                   (args.require_all and r["status"] != "passed") for r in results))


if __name__ == "__main__":
    raise SystemExit(main())
