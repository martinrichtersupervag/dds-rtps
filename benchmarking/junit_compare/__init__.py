"""junit_compare – public API."""

from .models import TestResult
from .loader import load_results
from .file_registry import parse_filename_meta, choose_files, choose_all_files
from .analyzer import compare, summarize_test_statuses, summarize_all_statuses
from .report_data import (
    CompareReport,
    StatusSummaryRow,
    ExplainReport,
    ParallelGroupReport,
    ExplainParallelReport,
)
from .renderer import (
    print_report,
    print_simple_report,
    print_differences,
    print_failure_frequency_summary,
    output_filename,
)
from .explain import generate_explanation, generate_explain_parallel

__all__ = [
    "TestResult",
    "load_results",
    "parse_filename_meta",
    "choose_files",
    "choose_all_files",
    "compare",
    "summarize_test_statuses",
    "summarize_all_statuses",
    "CompareReport",
    "StatusSummaryRow",
    "ExplainReport",
    "ParallelGroupReport",
    "ExplainParallelReport",
    "print_report",
    "print_simple_report",
    "print_differences",
    "print_failure_frequency_summary",
    "output_filename",
    "generate_explanation",
    "generate_explain_parallel",
]
