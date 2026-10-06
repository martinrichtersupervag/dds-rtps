"""Datové struktury pro výstupy analýzy.

Každá dataclass odpovídá jednomu "pohledu" na data.
Renderer ani explain moduly neprodukují text přímo –
nejprve naplní tyto struktury, teprve pak renderer generuje výstup.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from .models import RichStatus


# ── výsledky jednoho srovnání dvou reportů ────────────────────────────────────

@dataclass
class ChangedTest:
    """Jeden testcase, jehož výsledek se mezi dvěma reporty lišil."""
    test: str
    differences: dict[str, dict[str, str]]   # field -> {first, second}


@dataclass
class CompareReport:
    """Výstup funkce compare() – srovnání dvou XML souborů."""
    first_file: str
    second_file: str
    first_summary: dict[str, str]
    second_summary: dict[str, str]
    first_count: int
    second_count: int
    added: list[str]
    removed: list[str]
    changed: list[ChangedTest]

    def to_dict(self) -> dict[str, Any]:
        """Zpětná kompatibilita – vrátí původní dict formát."""
        return {
            "first": {"file": self.first_file, "summary": self.first_summary},
            "second": {"file": self.second_file, "summary": self.second_summary},
            "counts": {"first": self.first_count, "second": self.second_count},
            "added": self.added,
            "removed": self.removed,
            "changed": [
                {"test": c.test, "differences": c.differences}
                for c in self.changed
            ],
        }

    @staticmethod
    def from_dict(d: dict[str, Any]) -> "CompareReport":
        return CompareReport(
            first_file=d["first"]["file"],
            second_file=d["second"]["file"],
            first_summary=d["first"]["summary"],
            second_summary=d["second"]["summary"],
            first_count=d["counts"]["first"],
            second_count=d["counts"]["second"],
            added=d["added"],
            removed=d["removed"],
            changed=[
                ChangedTest(test=c["test"], differences=c["differences"])
                for c in d["changed"]
            ],
        )


# ── per-test aggregated statistics ──────────────────────────────────────────

@dataclass
class StatusSummaryRow:
    """RichStatus counts for one test label aggregated across N files."""
    label: str
    # dict RichStatus -> count across all files
    rich_counts: dict[RichStatus, int] = field(default_factory=dict)

    def add(self, rs: RichStatus) -> None:
        self.rich_counts[rs] = self.rich_counts.get(rs, 0) + 1

    # ── semantic groupings ────────────────────────────────────────────────────

    @property
    def passed(self) -> int:
        """Truly passed (includes passed_as_skipped)."""
        return (
            self.rich_counts.get(RichStatus.PASSED, 0)
            + self.rich_counts.get(RichStatus.PASSED_AS_SKIPPED, 0)
        )

    @property
    def skipped_unsupported(self) -> int:
        return self.rich_counts.get(RichStatus.SKIPPED_UNSUPPORTED, 0)

    @property
    def total_real_fail(self) -> int:
        """All genuine failures (excludes unsupported-skips)."""
        return sum(
            v for rs, v in self.rich_counts.items()
            if rs not in (
                RichStatus.PASSED, RichStatus.PASSED_AS_SKIPPED,
                RichStatus.SKIPPED_UNSUPPORTED, RichStatus.SKIPPED_OTHER,
            )
        )

    # legacy compat for code that still reads .failure / .error / .skipped
    @property
    def failure(self) -> int:
        return sum(
            v for rs, v in self.rich_counts.items()
            if rs.value.startswith("failure")
        )

    @property
    def error(self) -> int:
        return self.rich_counts.get(RichStatus.ERROR, 0)

    @property
    def skipped(self) -> int:
        return (
            self.rich_counts.get(RichStatus.SKIPPED_UNSUPPORTED, 0)
            + self.rich_counts.get(RichStatus.SKIPPED_OTHER, 0)
        )

    @property
    def total_fail(self) -> int:   # legacy compat
        return self.failure + self.error

    @property
    def is_flaky(self) -> bool:
        """Flaky = passed in some runs, genuinely failed in others.
        Unsupported-skips are excluded (consistent, not flaky).
        """
        return self.passed > 0 and self.total_real_fail > 0

    @property
    def fail_rate(self) -> float:
        total = self.passed + self.total_real_fail
        return self.total_real_fail / total * 100 if total else 0.0


# ── explain report (časová řada srovnání) ─────────────────────────────────────

@dataclass
class ExplainReport:
    """Agregovaný výsledek generate_explanation()."""
    first_label: str
    last_label: str
    comparison_count: int
    xml_file_count: int

    total_unique_tests: int
    perm_pass_count: int
    perm_fail_count: int
    mixed_count: int

    truly_flaky: list[tuple[str, int]]     # (test_label, change_count)
    partially_flaky: list[tuple[str, int]]

    feature_fails: dict[str, int]          # feature -> raw fail count
    pub_fails: dict[str, int]              # publisher -> raw fail count
    sub_fails: dict[str, int]              # subscriber -> raw fail count


# ── explain_parallel report ───────────────────────────────────────────────────

@dataclass
class FlakyTestRow:
    """Jeden flaky test v rámci skupiny paralelních běhů."""
    label: str
    pass_count: int
    fail_count: int

    @property
    def fail_rate(self) -> float:
        total = self.pass_count + self.fail_count
        return self.fail_count / total * 100 if total else 0.0


@dataclass
class ParallelGroupReport:
    """Statistics for one group of files sharing the same par-count."""
    parallel_count: int
    run_count: int
    file_paths: list[str]

    # raw totals across all files in group
    total_fail_raw: int
    total_pass_raw: int
    total_skip_raw: int
    total_unique_tests: int

    # rich-status totals: RichStatus -> raw count (sum across all files)
    rich_status_totals: dict[RichStatus, int]

    # flaky
    flaky_tests: list[FlakyTestRow]
    flaky_pub: dict[str, int]
    flaky_sub: dict[str, int]
    flaky_pub_test_count: dict[str, int]
    flaky_sub_test_count: dict[str, int]
    flaky_feat: dict[str, int]

    # overall failure breakdowns (raw)
    feature_fails: dict[str, int]
    pub_fails: dict[str, int]
    sub_fails: dict[str, int]

    def norm(self, value: int) -> float:
        return value / self.run_count if self.run_count else 0.0

    @property
    def flaky_count(self) -> int:
        return len(self.flaky_tests)

    @property
    def flaky_pct(self) -> float:
        return self.flaky_count / self.total_unique_tests * 100 if self.total_unique_tests else 0.0

    def rich_norm(self, rs: RichStatus) -> float:
        """Normalised (per-run average) count for a given RichStatus."""
        return self.norm(self.rich_status_totals.get(rs, 0))


@dataclass
class ExplainParallelReport:
    """Výstup generate_explain_parallel() – skupiny dle par-count."""
    groups: list[ParallelGroupReport]      # seřazeno dle parallel_count
    ungrouped_files: list[str]             # soubory bez nového formátu názvu
