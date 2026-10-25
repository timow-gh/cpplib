"""Turns the lcov trace file of the coverage preset into coverage.json and coverage-summary.md.

coverage.json is meant for tools and coding agents: per file line and branch coverage, the
uncovered line ranges and, for pull requests, whether the pull request changed the file.
coverage-summary.md is the human-readable summary that is also printed to the log. Uses the
standard library only, so the agent needs nothing but python3.
"""

import argparse
import json
import os
import sys
from dataclasses import dataclass, field

# Same thresholds as .github/workflows/ubuntu-coverage.yml.
GOOD_THRESHOLD = 80.0
FAIR_THRESHOLD = 70.0

SCHEMA_VERSION = 1


@dataclass
class FileCoverage:
    path: str
    # line -> execution count
    lines: dict = field(default_factory=dict)
    # (line, block, branch) -> taken count; lcov writes '-' for a branch that was never reached
    branches: dict = field(default_factory=dict)


def parse_lcov(info_path: str, source_root: str) -> list:
    """Reads an lcov trace file. Counts are summed, because a file may appear more than once."""
    files = {}
    current = None
    with open(info_path, encoding="utf-8") as info:
        for raw_line in info:
            record = raw_line.strip()
            if record.startswith("SF:"):
                path = relative_path(record[3:], source_root)
                current = files.setdefault(path, FileCoverage(path))
            elif record == "end_of_record":
                current = None
            elif current is None:
                continue
            elif record.startswith("DA:"):
                line, count = record[3:].split(",")[:2]
                current.lines[int(line)] = current.lines.get(int(line), 0) + int(count)
            elif record.startswith("BRDA:"):
                line, block, branch, taken = record[5:].split(",")[:4]
                key = (int(line), block, branch)
                current.branches[key] = current.branches.get(key, 0) + (0 if taken == "-" else int(taken))
    return sorted(files.values(), key=lambda coverage: coverage.path)


def relative_path(path: str, source_root: str) -> str:
    relative = os.path.relpath(path, source_root)
    return path if relative.startswith("..") else relative.replace(os.sep, "/")


def metric(hit: int, found: int) -> dict:
    percent = round(100.0 * hit / found, 2) if found else None
    return {"hit": hit, "found": found, "percent": percent}


def line_metric(coverage: FileCoverage) -> dict:
    return metric(sum(1 for count in coverage.lines.values() if count > 0), len(coverage.lines))


def branch_metric(coverage: FileCoverage) -> dict:
    return metric(sum(1 for taken in coverage.branches.values() if taken > 0), len(coverage.branches))


def sum_metrics(metrics: list) -> dict:
    return metric(sum(item["hit"] for item in metrics), sum(item["found"] for item in metrics))


def uncovered_ranges(coverage: FileCoverage) -> list:
    """Uncovered lines as [first, last] ranges.

    Lines without instrumentation (comments, braces) between two uncovered lines do not split a
    range, so a function that never ran is one range instead of one per statement.
    """
    ranges = []
    for line in sorted(coverage.lines):
        if coverage.lines[line] > 0:
            continue
        if ranges and not any(coverage.lines.get(between, 0) > 0 for between in range(ranges[-1][1] + 1, line)):
            ranges[-1][1] = line
        else:
            ranges.append([line, line])
    return ranges


def status_of(line_percent) -> str:
    if line_percent is None or line_percent < FAIR_THRESHOLD:
        return "Low"
    return "Good" if line_percent >= GOOD_THRESHOLD else "Fair"


def build_report(files: list, changed: set, commit: str, pull_request: str, baseline) -> dict:
    file_reports = []
    for coverage in files:
        file_reports.append({
            "path": coverage.path,
            "lines": line_metric(coverage),
            "branches": branch_metric(coverage),
            "uncovered_lines": uncovered_ranges(coverage),
            "changed": coverage.path in changed,
        })
    totals = {
        "lines": sum_metrics([report["lines"] for report in file_reports]),
        "branches": sum_metrics([report["branches"] for report in file_reports]),
    }
    changed_reports = [report for report in file_reports if report["changed"]]
    changed_totals = None
    if changed_reports:
        changed_totals = {
            "lines": sum_metrics([report["lines"] for report in changed_reports]),
            "branches": sum_metrics([report["branches"] for report in changed_reports]),
        }
    return {
        "schema": SCHEMA_VERSION,
        "commit": commit or None,
        "pull_request": int(pull_request) if pull_request else None,
        "status": status_of(totals["lines"]["percent"]),
        "thresholds": {"good": GOOD_THRESHOLD, "fair": FAIR_THRESHOLD},
        "totals": totals,
        "changed_totals": changed_totals,
        "baseline": None if baseline is None else {
            "commit": baseline.get("commit"),
            "totals": baseline.get("totals"),
        },
        "files": file_reports,
    }


def format_metric(value: dict) -> str:
    if value["percent"] is None:
        return "-"
    return f"{value['percent']:.1f}% ({value['hit']}/{value['found']})"


def format_change(current: dict, baseline_totals, name: str) -> str:
    if not baseline_totals or current["percent"] is None or baseline_totals[name]["percent"] is None:
        return "-"
    return f"{current['percent'] - baseline_totals[name]['percent']:+.2f}"


def format_ranges(ranges: list) -> str:
    if not ranges:
        return "-"
    parts = [str(first) if first == last else f"{first}-{last}" for first, last in ranges]
    return ", ".join(parts)


def render_summary(report: dict) -> str:
    totals = report["totals"]
    baseline_totals = report["baseline"]["totals"] if report["baseline"] else None
    lines = [f"## Coverage Report ({report['status']})", ""]
    if baseline_totals:
        commit = (report["baseline"]["commit"] or "")[:12]
        lines += [
            f"| Metric | Coverage | main ({commit}) | Change |",
            "|--------|----------|------|--------|",
        ]
        for name, title in (("lines", "Lines"), ("branches", "Branches")):
            lines.append(f"| **{title}** | {format_metric(totals[name])} | "
                         f"{format_metric(baseline_totals[name])} | {format_change(totals[name], baseline_totals, name)} |")
    else:
        lines += ["| Metric | Coverage |", "|--------|----------|"]
        lines.append(f"| **Lines** | {format_metric(totals['lines'])} |")
        lines.append(f"| **Branches** | {format_metric(totals['branches'])} |")

    changed = [file for file in report["files"] if file["changed"]]
    if changed:
        lines += ["", "### Files changed by the pull request", "",
                  "| File | Lines | Branches | Uncovered lines |", "|------|-------|----------|-----------------|"]
        for file in changed:
            lines.append(f"| `{file['path']}` | {format_metric(file['lines'])} | "
                         f"{format_metric(file['branches'])} | {format_ranges(file['uncovered_lines'])} |")
    lines += ["", "_This check is informational and won't block the pull request._", ""]
    return "\n".join(lines)


def read_changed_files(path) -> set:
    if not path:
        return set()
    with open(path, encoding="utf-8") as changed:
        return {line.strip() for line in changed if line.strip()}


def read_baseline(path):
    if not path:
        return None
    with open(path, encoding="utf-8") as baseline:
        data = json.load(baseline)
    if data.get("schema") != SCHEMA_VERSION:
        print(f"[warning] The baseline uses schema {data.get('schema')}, expected {SCHEMA_VERSION}; no comparison")
        return None
    return data


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--info", required=True, help="lcov trace file (coverage_filtered.info)")
    parser.add_argument("--source-root", required=True, help="repository root; paths are made relative to it")
    parser.add_argument("--output-directory", required=True)
    parser.add_argument("--commit", default="")
    parser.add_argument("--pull-request", default="")
    parser.add_argument("--changed-files", help="file with one changed path per line, relative to the root")
    parser.add_argument("--baseline", help="coverage.json of main to compare with")
    args = parser.parse_args()

    files = parse_lcov(args.info, os.path.abspath(args.source_root))
    if not files:
        print(f"[error] {args.info} contains no coverage data")
        return 1
    report = build_report(files, read_changed_files(args.changed_files), args.commit, args.pull_request,
                          read_baseline(args.baseline))
    summary = render_summary(report)

    os.makedirs(args.output_directory, exist_ok=True)
    with open(os.path.join(args.output_directory, "coverage.json"), "w", encoding="utf-8", newline="\n") as output:
        json.dump(report, output, indent=2)
        output.write("\n")
    with open(os.path.join(args.output_directory, "coverage-summary.md"), "w", encoding="utf-8", newline="\n") as output:
        output.write(summary)
    print(summary)
    return 0


if __name__ == "__main__":
    sys.exit(main())
