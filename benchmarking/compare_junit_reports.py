"""Compare JUnit interoperability reports.

With no file arguments, the two newest ``junit_*.xml`` files in the script's
directory are compared.
"""

from __future__ import annotations

import argparse
import io
import json
import sys
import xml.etree.ElementTree as ET
from contextlib import redirect_stdout
from pathlib import Path

from junit_compare.file_registry import parse_filename_meta
from junit_compare.analyzer import compare, summarize_test_statuses, _repeated_change_tests
from junit_compare.explain import generate_explanation, generate_explain_parallel
from junit_compare.file_registry import choose_files, choose_all_files
from junit_compare.html_report import generate_html_report
from junit_compare.renderer import (
    print_report,
    print_simple_report,
    print_differences,
    print_failure_frequency_summary,
    output_filename,
)


# ── render helpers ────────────────────────────────────────────────────────────

def render_compare_all(pairs, reports, args, files=None) -> int:
    first = pairs[0][0]
    last = pairs[-1][1]
    status_summary = summarize_test_statuses(files or []) if files is not None else []

    if args.as_json:
        mode = "json"
        payload = {
            "comparison_count": len(reports),
            "repeat_test_locations": _repeated_change_tests(reports),
            "status_counts_across_reports": {label: counts for label, counts in status_summary},
            "comparisons": [r.to_dict() for r in reports],
        }
        text = json.dumps(payload, indent=2)
    elif args.simple:
        mode = "simple"
        output = io.StringIO()
        with redirect_stdout(output):
            print("Current comparison shows:")
            if status_summary:
                print_failure_frequency_summary(status_summary)
            repeated = _repeated_change_tests(reports)
            if repeated:
                print("##Result for: Repeated testcase changes on the same location")
            print(f"- repeated testcase changes on the same location: {len(repeated)}")
            if repeated:
                for test, count in repeated.items():
                    print(f"  - {test}: {count} comparisons")
            for report in reports:
                print_simple_report(report)
        text = output.getvalue()
    elif args.show_differences:
        mode = "show-differences"
        output = io.StringIO()
        with redirect_stdout(output):
            if status_summary:
                print_failure_frequency_summary(status_summary)
                print()
            repeated = _repeated_change_tests(reports)
            if repeated:
                print("##Result for: Repeated testcase changes on the same location")
                print(f"Repeated testcase changes on the same location: {len(repeated)}")
                for test, count in repeated.items():
                    print(f"  {test}: {count} comparisons")
                print()
            for report in reports:
                print_differences(report)
                print()
        text = output.getvalue()
    else:
        mode = "report"
        output = io.StringIO()
        with redirect_stdout(output):
            if status_summary:
                print_failure_frequency_summary(status_summary)
                print()
            repeated = _repeated_change_tests(reports)
            if repeated:
                print("##Result for: Repeated testcase changes on the same location")
                print(f"Repeated testcase changes on the same location: {len(repeated)}")
                for test, count in repeated.items():
                    print(f"  {test}: {count} comparisons")
                print()
            for report in reports:
                print_report(report, args.include_times)
                print()
        text = output.getvalue()

    print(text, end="")
    output_path = output_filename(first, last, mode)
    try:
        output_path.write_text(text, encoding="utf-8")
    except OSError as error:
        print(f"Error writing output file {output_path}: {error}", file=sys.stderr)
        return 1
    print(f"Output written to: {output_path.name}")
    generate_explanation(first, last, reports, files)
    return 0


def render_and_save(report, first, second, args) -> int:
    if args.as_json:
        mode = "json"
        renderer = lambda: print(json.dumps(report.to_dict(), indent=2))
    elif args.simple:
        mode = "simple"
        renderer = lambda: print_simple_report(report)
    elif args.show_differences:
        mode = "show-differences"
        renderer = lambda: print_differences(report)
    else:
        mode = "report"
        renderer = lambda: print_report(report, args.include_times)

    output = io.StringIO()
    with redirect_stdout(output):
        renderer()
    text = output.getvalue()
    print(text, end="")
    output_path = output_filename(first, second, mode)
    try:
        output_path.write_text(text, encoding="utf-8")
    except OSError as error:
        print(f"Error writing output file {output_path}: {error}", file=sys.stderr)
        return 1
    print(f"Output written to: {output_path.name}")
    generate_explanation(first, second, [report], [first, second])
    return 0


# ── CLI ───────────────────────────────────────────────────────────────────────

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("first", nargs="?", type=Path, help="Earlier XML report")
    parser.add_argument("second", nargs="?", type=Path, help="Later XML report")
    parser.add_argument("--directory", type=Path, help="Directory from which to select the two newest reports")
    parser.add_argument("--include-times", action="store_true", help="Report testcase runtime changes")
    parser.add_argument("--include-details", action="store_true", help="Compare verbose failure/error details")
    parser.add_argument("--simple", action="store_true", help="Print a concise comparison summary")
    parser.add_argument(
        "--show-differences",
        "--show-difference",
        action="store_true",
        dest="show_differences",
        help="Show changed testcase outcomes as two-sided differences",
    )
    parser.add_argument("--compare-all", action="store_true", help="Compare every report with the next chronological report")
    parser.add_argument("--json", action="store_true", dest="as_json", help="Write the comparison as JSON")
    parser.add_argument(
        "--explain-parallel",
        action="store_true",
        dest="explain_parallel",
        help=(
            "Group all XML reports by parallel-run count and print per-run-normalised "
            "error statistics (publisher/subscriber breakdown)"
        ),
    )
    parser.add_argument(
        "--html",
        action="store_true",
        dest="html",
        help="Generate a self-contained HTML report (explain_parallel.html) in addition to text output",
    )
    parser.add_argument(
        "--batch",
        type=int,
        default=None,
        help="Only use reports of this test suite run (batch) number (the -runN part of the filename)",
    )
    parser.add_argument(
        "--name-tag",
        default=None,
        help="Suffix for explain_parallel.{txt,html} (default: -<runner>-run<N> derived from --batch)",
    )
    args = parser.parse_args()

    try:
        directory = args.directory or Path(__file__).parent
        name_tag = args.name_tag
        if name_tag is None:
            name_tag = ""
            if args.batch is not None:
                batch_files = choose_all_files(directory, args.batch)
                meta = parse_filename_meta(batch_files[0]) if batch_files else None
                runner = (meta or {}).get("runner")
                name_tag = f"-{runner}" if runner else ""
                name_tag += f"-run{args.batch}"
        if args.explain_parallel and (args.first or args.second):
            parser.error("--explain-parallel cannot be combined with explicit XML reports")
        if args.explain_parallel:
            files = choose_all_files(directory, args.batch)
            generate_explain_parallel(files, name_tag=name_tag)
            if args.html:
                generate_html_report(files, name_tag=name_tag)
            return 0
        if args.compare_all and (args.first or args.second):
            parser.error("--compare-all cannot be combined with explicit XML reports")
        if args.compare_all:
            files = choose_all_files(directory, args.batch)
            if len(files) < 2:
                raise ValueError(f"Need at least two junit_*.xml files in {directory}")
            pairs = list(zip(files, files[1:]))
            reports = [
                compare(first, second, args.include_times, args.include_details)
                for first, second in pairs
            ]
            if render_compare_all(pairs, reports, args, files):
                return 1
            if args.html:
                generate_html_report(files, reports=reports, name_tag=name_tag)
        elif args.first or args.second:
            if not (args.first and args.second):
                parser.error("provide both first and second XML reports")
            pairs = [(args.first, args.second)]
            for first, second in pairs:
                report = compare(first, second, args.include_times, args.include_details)
                if render_and_save(report, first, second, args):
                    return 1
        else:
            first, second = choose_files(directory, args.batch)
            report = compare(first, second, args.include_times, args.include_details)
            if render_and_save(report, first, second, args):
                return 1
    except (ET.ParseError, OSError, ValueError) as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())