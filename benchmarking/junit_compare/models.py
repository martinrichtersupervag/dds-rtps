"""Data model: TestResult and label helpers."""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from enum import Enum
from typing import Any


class RichStatus(str, Enum):
    """Refined outcome classification derived from the per-role result table."""
    # Test ran correctly and all roles matched expected outcome
    PASSED = "passed"
    # <skipped> where expected==produced for all roles (e.g. intentional INCOMPATIBLE_QOS)
    PASSED_AS_SKIPPED = "passed_as_skipped"
    # Vendor does not implement the feature -- test was not meaningfully run
    SKIPPED_UNSUPPORTED = "skipped_unsupported"
    # Other skipped patterns not covered above
    SKIPPED_OTHER = "skipped_other"
    # Vendor reports QoS incompatibility where it should not
    FAILURE_QOS_UNEXPECTED = "failure_qos_unexpected"
    # Vendor passes (OK) where the test expects a failure condition
    FAILURE_FALSE_PASS = "failure_false_pass"
    # Data delivery or content error
    FAILURE_DATA = "failure_data"
    # Ordering / timing QoS semantics violated
    FAILURE_ORDERING = "failure_ordering"
    # DDS infrastructure could not be initialised
    FAILURE_INFRASTRUCTURE = "failure_infrastructure"
    # Generic failure (mismatch not covered by other categories)
    FAILURE_OTHER = "failure_other"
    # System-level exception from the test framework
    ERROR = "error"


# Code sets used for classification
_UNSUPPORTED_CODES = {"SUB_UNSUPPORTED_FEATURE", "PUB_UNSUPPORTED_FEATURE"}
_DATA_CODES = {"DATA_NOT_CORRECT", "DATA_NOT_RECEIVED", "DATA_NOT_SENT"}
_ORDERING_CODES = {
    "ORDERED_ACCESS_INSTANCE", "ORDERED_ACCESS_TOPIC",
    "RECEIVING_FROM_ONE", "RECEIVING_FROM_BOTH", "DEADLINE_MISSED",
}
_INFRA_CODES = {
    "READER_NOT_CREATED", "WRITER_NOT_CREATED",
    "TOPIC_NOT_CREATED", "READER_NOT_MATCHED",
}

# Outcome rows type: list of (role, expected_code, produced_code)
OutcomeRow = tuple[str, str, str]


@dataclass(frozen=True)
class TestResult:
    suite: str
    name: str
    attributes: tuple[tuple[str, str], ...]
    status: str                            # raw JUnit tag: passed/failure/error/skipped
    rich_status: RichStatus                # refined semantic classification
    detail: str
    time: str
    outcome_rows: tuple[OutcomeRow, ...]   # per-role (role, expected, produced)

    @property
    def key(self) -> tuple[str, str, tuple[tuple[str, str], ...]]:
        return self.suite, self.name, self.attributes


# ── label helpers ──────────────────────────────────────────────────────────────

def test_label(result: TestResult) -> str:
    return key_label(result.key)


def key_label(key: tuple[str, str, tuple[tuple[str, str], ...]]) -> str:
    suite, name, attributes = key
    config = ", ".join(f"{k}={v}" for k, v in attributes)
    return f"{suite} / {name}" + (f" [{config}]" if config else "")


# kept as private aliases so internal callers that use _test_label / _key_label still work
_test_label = test_label
_key_label = key_label
