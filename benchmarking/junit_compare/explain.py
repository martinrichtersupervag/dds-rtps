"""junit_compare – explain output generators."""

from __future__ import annotations

import re
import sys
from pathlib import Path

from .file_registry import report_label
from .loader import load_results
from .models import _test_label
from .analyzer import (
    summarize_test_statuses,
    build_explain_parallel_report,
)
from .renderer import output_filename, render_explain_parallel
from .report_data import CompareReport


# ── explain (time-series of comparisons) ─────────────────────────────────────

def generate_explanation(
    first: Path,
    last: Path,
    reports: list[CompareReport],
    files: list[Path] | None = None,
) -> Path | None:
    first_label = report_label(str(first))
    last_label = report_label(str(last))
    output_path = output_filename(first, last, "explain")

    test_changes: dict[str, int] = {}
    for r in reports:
        for item in r.changed:
            if "status" in item.differences:
                test_changes[item.test] = test_changes.get(item.test, 0) + 1

    if len(reports) > 1:
        truly_flaky = [(t, c) for t, c in test_changes.items() if c >= 3]
        partially_flaky = [(t, c) for t, c in test_changes.items() if c == 2]
    else:
        truly_flaky = []
        partially_flaky = []
        if reports:
            for item in reports[0].changed:
                diff = item.differences.get("status")
                if diff:
                    f, s = diff["first"], diff["second"]
                    if {f, s} <= {"passed", "failure", "error"}:
                        truly_flaky.append((item.test, 1))
                    else:
                        partially_flaky.append((item.test, 1))

    truly_flaky.sort(key=lambda x: (-x[1], x[0]))
    partially_flaky.sort(key=lambda x: (-x[1], x[0]))

    lines: list[str] = [
        "##Result for: Explanation and Analysis",
        f"Truly flaky tests: {len(truly_flaky)}",
        f"Partially flaky tests: {len(partially_flaky)}",
        "",
        "=" * 80,
        "SUMMARY AND STATISTICS",
        "=" * 80,
        f"- Period analysed: {first_label} -> {last_label}",
        f"- Number of comparisons: {len(reports)}",
    ]

    if files:
        lines.append(f"- Number of XML reports analysed: {len(files)}")
        status_summary = summarize_test_statuses(files)
        all_test_labels: set[str] = set()
        for f in files:
            _, res = load_results(f)
            for r in res.values():
                all_test_labels.add(_test_label(r))

        total_unique_tests = len(all_test_labels)
        perm_fail = sum(
            1 for _, c in status_summary
            if c.get("passed", 0) == 0 and (c.get("failure", 0) or c.get("error", 0))
        )
        mixed = sum(
            1 for _, c in status_summary
            if c.get("passed", 0) > 0 and (c.get("failure", 0) or c.get("error", 0))
        )
        perm_pass = total_unique_tests - len(status_summary)
        pass_pct = (perm_pass / total_unique_tests * 100) if total_unique_tests else 0
        fail_pct = (perm_fail / total_unique_tests * 100) if total_unique_tests else 0
        mixed_pct = (mixed / total_unique_tests * 100) if total_unique_tests else 0

        lines.extend([
            f"- Total unique tests across all suites: {total_unique_tests:,}",
            f"- Always-passing tests (100% pass): {perm_pass:,} ({pass_pct:.1f} %)",
            f"- Always-failing tests (100% fail): {perm_fail:,} ({fail_pct:.1f} %)",
            f"- Mixed-result tests (pass in some, fail in others): {mixed:,} ({mixed_pct:.1f} %)",
        ])

    if truly_flaky:
        lines.extend([
            "",
            "=" * 80,
            "TRULY FLAKY TESTS",
            "=" * 80,
        ])
        for t, c in truly_flaky:
            lines.append(f"  [{c}x status change] {t}")

    if partially_flaky:
        lines.extend([
            "",
            "=" * 80,
            "PARTIALLY FLAKY TESTS",
            "=" * 80,
        ])
        for t, c in partially_flaky:
            lines.append(f"  [{c}x status change] {t}")

    if files:
        lines.extend([
            "",
            "=" * 80,
            "TOP FAILURE AREAS BY QOS / FEATURE",
            "=" * 80,
        ])
        feature_fails: dict[str, int] = {}
        for label, counts in status_summary:
            total_fail = counts.get("failure", 0) + counts.get("error", 0)
            m = re.search(r"/ rtps_test_suite_\d+_Test_([A-Za-z0-9]+)_\d+", label)
            feat = m.group(1) if m else "Other"
            feature_fails[feat] = feature_fails.get(feat, 0) + total_fail

        for feat, count in sorted(feature_fails.items(), key=lambda x: -x[1])[:10]:
            lines.append(f"  - {feat:20}: {count:5} failures")

        lines.extend([
            "",
            "=" * 80,
            "FAILURE RATE BY DDS IMPLEMENTATION (PUBLISHER / SUBSCRIBER)",
            "=" * 80,
        ])
        pub_fails: dict[str, int] = {}
        sub_fails: dict[str, int] = {}
        for label, counts in status_summary:
            total_fail = counts.get("failure", 0) + counts.get("error", 0)
            m = re.match(r"\s*([^-]+-[^-]+)---([^-]+-[^\s]+)\s+/", label)
            if m:
                pub, sub = m.group(1), m.group(2)
                pub_fails[pub] = pub_fails.get(pub, 0) + total_fail
                sub_fails[sub] = sub_fails.get(sub, 0) + total_fail

        lines.append("  TOP failing Publishers:")
        for pub, count in sorted(pub_fails.items(), key=lambda x: -x[1])[:5]:
            lines.append(f"    - {pub:25}: {count:5} failures")
        lines.append("  TOP failing Subscribers:")
        for sub, count in sorted(sub_fails.items(), key=lambda x: -x[1])[:5]:
            lines.append(f"    - {sub:25}: {count:5} failures")

    text = "\n".join(lines) + "\n"
    try:
        output_path.write_text(text, encoding="utf-8")
        print(f"Explanation written to: {output_path.name}")
        return output_path
    except OSError as error:
        print(f"Error writing explanation file {output_path}: {error}", file=sys.stderr)
        return None


# ── explain_parallel ──────────────────────────────────────────────────────────

def generate_explain_parallel(
    files: list[Path],
    output_dir: Path | None = None,
    name_tag: str = "",
) -> Path | None:
    """Group files by par-count, run analysis, save output."""
    if not files:
        print("No XML files provided for explain_parallel.", file=sys.stderr)
        return None

    ep = build_explain_parallel_report(files)

    if not ep.groups and ep.ungrouped_files:
        print(
            "No files with the new filename format found – cannot group by parallel count.",
            file=sys.stderr,
        )
        return None

    text = render_explain_parallel(ep)

    dest_dir = output_dir or (files[0].parent if files else Path("."))
    output_path = dest_dir / f"explain_parallel{name_tag}.txt"
    try:
        output_path.write_text(text, encoding="utf-8")
        print(f"Parallel explanation written to: {output_path.name}")
        return output_path
    except OSError as error:
        print(f"Error writing explain_parallel file {output_path}: {error}", file=sys.stderr)
        return None
