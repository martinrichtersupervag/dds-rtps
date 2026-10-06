"""Rendering layer – converts data structures to text output.

All functions operate on report_data types; no analysis logic here.
"""

from __future__ import annotations

import difflib
import json
from pathlib import Path
from typing import Any

from .file_registry import report_label
from .report_data import (
    CompareReport,
    ParallelGroupReport,
    ExplainParallelReport,
)


# ── helpers ───────────────────────────────────────────────────────────────────

def output_filename(first: Path, second: Path, mode: str) -> Path:
    return first.parent / f"{mode}_{report_label(str(first))}_{report_label(str(second))}.txt"


# ── single-comparison renderers ───────────────────────────────────────────────

def print_report(report: CompareReport, include_times: bool) -> None:
    first = Path(report.first_file).name
    second = Path(report.second_file).name
    print(f"##Result for: Comparing: {first} -> {second}")
    print(f"Comparing: {first} -> {second}")
    print(
        f"Cases: {report.first_count} -> {report.second_count} | "
        f"added: {len(report.added)}, removed: {len(report.removed)}, "
        f"changed: {len(report.changed)}"
    )
    if include_times:
        print("Timing differences are included.")
    for label in report.added:
        print(f"ADDED: {label}")
    for label in report.removed:
        print(f"REMOVED: {label}")
    for item in report.changed:
        print(f"CHANGED: {item.test}")
        for field, values in item.differences.items():
            if field == "detail":
                first_detail = values["first"] or "(none)"
                second_detail = values["second"] or "(none)"
                detail_diff = difflib.unified_diff(
                    first_detail.splitlines(), second_detail.splitlines(),
                    fromfile="first", tofile="second", lineterm="",
                )
                print("  detail:")
                print("\n".join(f"    {line}" for line in detail_diff))
            else:
                print(f"  {field}: {values['first']!r} -> {values['second']!r}")


def print_simple_report(report: CompareReport) -> None:
    first_label = report_label(report.first_file)
    second_label = report_label(report.second_file)
    print(f"##Result for: Comparison: {first_label} vs. {second_label}")
    same_count = report.first_count == report.second_count
    status_changes = sum("status" in item.differences for item in report.changed)
    print("Current comparison shows:")
    if same_count:
        print(f"- `{report.first_count:,}` testcases in both runs")
    else:
        print(
            f"- `{report.first_count:,}` testcases in the first run and "
            f"`{report.second_count:,}` in the second run"
        )
    print(f"- `{status_changes}` pass/fail status changes between runs")
    if status_changes:
        print(f"- The results for the same case differ {status_changes}x")
    else:
        print("- No diverse results in same case")
    print(f"- reports `{first_label}` vs. `{second_label}`")


def print_differences(report: CompareReport) -> None:
    """Compact two-sided diff of changed test outcomes."""
    first_label = report_label(report.first_file)
    second_label = report_label(report.second_file)
    print(f"##Result for: Differences: {first_label} -> {second_label}")
    print(f"Differences: {first_label} -> {second_label}")
    difference_count = (
        len(report.added) + len(report.removed)
        + sum("status" in item.differences for item in report.changed)
    )
    if not difference_count:
        print("No testcase result differences.")
        return
    for label in report.removed:
        print(f"CHANGED: {label}")
        print("- first: (empty)")
        print("+ second: removed")
    for label in report.added:
        print(f"CHANGED: {label}")
        print("- first: removed")
        print("+ second: (empty)")
    for item in report.changed:
        status = item.differences.get("status")
        if status is None:
            continue
        print(f"CHANGED: {item.test}")
        print(f"- {first_label}: {status['first']}")
        print(f"+ {second_label}: {status['second']}")


# ── aggregate failure frequency ───────────────────────────────────────────────

def print_failure_frequency_summary(files_summary: list[tuple[str, dict[str, int]]]) -> None:
    """Print aggregated failure counts from summarize_test_statuses()."""
    print("##Result for: Failure frequency across all XML reports")
    if not files_summary:
        print("Failure frequency across all XML reports: none")
        return
    print("Failure frequency across all XML reports:")
    for label, counts in files_summary:
        total_failures = counts.get("failure", 0) + counts.get("error", 0)
        print(
            f"  {label}: passed={counts.get('passed', 0)}, failed={counts.get('failure', 0)}, "
            f"errors={counts.get('error', 0)}, skipped={counts.get('skipped', 0)}, total_failures={total_failures}"
        )


# ── explain_parallel text renderer ───────────────────────────────────────────

def render_explain_parallel(ep: ExplainParallelReport) -> str:
    """Convert ExplainParallelReport to a plain-text report string."""
    lines: list[str] = [
        "##Result for: Parallel-run explanation",
        "=" * 80,
        "ANALYSIS BY PARALLEL-RUN COUNT  (values normalised per single test-suite run)",
        "=" * 80,
        "",
    ]

    for grp in ep.groups:
        lines.extend([
            "=" * 80,
            f"PARALLEL RUNS: par{grp.parallel_count}   (number of runs in this group: {grp.run_count})",
            "=" * 80,
            "",
            "  -- FLAKY TESTS (inconsistent results across runs) " + "-" * 29,
            f"  Total unique tests in suite set: {grp.total_unique_tests:,}",
            f"  Flaky tests (pass in some runs, fail in others): {grp.flaky_count:,}  ({grp.flaky_pct:.1f} %)",
        ])

        if grp.flaky_count > 0:
            lines.append("")
            lines.append("  TOP flaky tests (most oscillating):")
            for row in grp.flaky_tests[:20]:
                lines.append(
                    f"    pass={row.pass_count:3}x  fail={row.fail_count:3}x  "
                    f"({row.fail_rate:5.1f}% fail rate)  {row.label}"
                )

            if grp.flaky_pub:
                lines.append("")
                lines.append("  Flaky Publishers (by number of flaky failures):")
                for pub, fail_raw in sorted(grp.flaky_pub.items(), key=lambda x: -x[1])[:5]:
                    n_tests = grp.flaky_pub_test_count[pub]
                    lines.append(
                        f"    - {pub:30}: {grp.norm(fail_raw):6.1f} flaky failures/run"
                        f"  (raw: {fail_raw}, {n_tests} flaky tests)"
                    )
                lines.append("  Flaky Subscribers:")
                for sub, fail_raw in sorted(grp.flaky_sub.items(), key=lambda x: -x[1])[:5]:
                    n_tests = grp.flaky_sub_test_count[sub]
                    lines.append(
                        f"    - {sub:30}: {grp.norm(fail_raw):6.1f} flaky failures/run"
                        f"  (raw: {fail_raw}, {n_tests} flaky tests)"
                    )

            lines.append("")
            lines.append("  Flaky areas (QoS / feature):")
            for feat, fail_raw in sorted(grp.flaky_feat.items(), key=lambda x: -x[1])[:10]:
                lines.append(
                    f"    - {feat:30}: {grp.norm(fail_raw):6.1f} flaky failures/run  (raw: {fail_raw})"
                )

        lines.append("")
        lines.extend([
            "  -- OVERALL STATISTICS " + "-" * 57,
            f"  Total failures  (avg/run): {grp.norm(grp.total_fail_raw):8.1f}  (raw: {grp.total_fail_raw})",
            f"  Total passed    (avg/run): {grp.norm(grp.total_pass_raw):8.1f}  (raw: {grp.total_pass_raw})",
            f"  Total skipped   (avg/run): {grp.norm(grp.total_skip_raw):8.1f}  (raw: {grp.total_skip_raw})",
            "",
        ])

        lines.append("  TOP failure areas (QoS / feature):")
        for feat, count in sorted(grp.feature_fails.items(), key=lambda x: -x[1])[:10]:
            lines.append(f"    - {feat:30}: {grp.norm(count):7.1f} failures/run  (raw: {count})")
        lines.append("")

        lines.append("  TOP failing Publishers (overall):")
        for pub, count in sorted(grp.pub_fails.items(), key=lambda x: -x[1])[:5]:
            lines.append(f"    - {pub:30}: {grp.norm(count):7.1f} failures/run  (raw: {count})")
        lines.append("  TOP failing Subscribers (overall):")
        for sub, count in sorted(grp.sub_fails.items(), key=lambda x: -x[1])[:5]:
            lines.append(f"    - {sub:30}: {grp.norm(count):7.1f} failures/run  (raw: {count})")
        lines.append("")

    if ep.ungrouped_files:
        lines.extend([
            "=" * 80,
            f"Files without parallel-count metadata ({len(ep.ungrouped_files)}) – excluded:",
        ])
        for p in ep.ungrouped_files:
            lines.append(f"  {Path(p).name}")

    return "\n".join(lines) + "\n"
