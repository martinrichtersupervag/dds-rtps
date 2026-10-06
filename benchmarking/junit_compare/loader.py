"""Načítání XML JUnit reportů + klasifikace výsledků."""

from __future__ import annotations

import re
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any

from .models import (
    TestResult, RichStatus, OutcomeRow,
    _UNSUPPORTED_CODES, _DATA_CODES, _ORDERING_CODES, _INFRA_CODES,
)


# ── result-table parser ───────────────────────────────────────────────────────

_TABLE_ROW_RE = re.compile(
    r"<th>([^<]+)</th>\s*<th>([^<]+)</th>\s*<th>([^<]+)</th>"
)


def parse_outcome_rows(message: str) -> tuple[OutcomeRow, ...]:
    """Extract (role, expected_code, produced_code) tuples from the HTML table
    embedded in a <failure> or <skipped> message attribute."""
    rows = []
    for role, expected, produced in _TABLE_ROW_RE.findall(message):
        role = role.strip()
        if role in ("", "Expected Code"):
            continue
        rows.append((role, expected.strip(), produced.strip()))
    return tuple(rows)


# ── outcome classifier ────────────────────────────────────────────────────────

def classify_outcome(
    xml_tag: str,                    # "passed" | "failure" | "error" | "skipped"
    rows: tuple[OutcomeRow, ...],
) -> RichStatus:
    """Map (xml_tag, per-role rows) → RichStatus.

    Classification logic (in priority order):

    passed   → PASSED
    error    → ERROR
    skipped:
      any produced ∈ UNSUPPORTED  → SKIPPED_UNSUPPORTED
      all expected == produced    → PASSED_AS_SKIPPED   (intentional, correct behaviour)
      otherwise                   → SKIPPED_OTHER
    failure:
      any produced ∈ UNSUPPORTED  → SKIPPED_UNSUPPORTED  (framework mislabelled)
      mismatches = rows where expected != produced
        dominant produced = INCOMPATIBLE_QOS  → FAILURE_QOS_UNEXPECTED
        dominant produced = OK               → FAILURE_FALSE_PASS
        dominant produced ∈ DATA_CODES       → FAILURE_DATA
        dominant produced ∈ ORDERING_CODES   → FAILURE_ORDERING
        dominant produced ∈ INFRA_CODES      → FAILURE_INFRASTRUCTURE
        else                                 → FAILURE_OTHER
    """
    if xml_tag == "passed":
        return RichStatus.PASSED
    if xml_tag == "error":
        return RichStatus.ERROR

    produced_codes = {p for _, _, p in rows}

    if xml_tag == "skipped":
        if produced_codes & _UNSUPPORTED_CODES:
            return RichStatus.SKIPPED_UNSUPPORTED
        if all(e == p for _, e, p in rows):
            return RichStatus.PASSED_AS_SKIPPED
        return RichStatus.SKIPPED_OTHER

    # xml_tag == "failure"
    if produced_codes & _UNSUPPORTED_CODES:
        # framework labelled it failure but vendor simply doesn't support the feature
        return RichStatus.SKIPPED_UNSUPPORTED

    mismatches = [p for _, e, p in rows if e != p]
    if not mismatches:
        # all expected == produced but still marked as failure → framework anomaly
        return RichStatus.FAILURE_OTHER

    # dominant mismatch type
    from collections import Counter
    dominant = Counter(mismatches).most_common(1)[0][0]

    if dominant == "INCOMPATIBLE_QOS":
        return RichStatus.FAILURE_QOS_UNEXPECTED
    if dominant == "OK":
        return RichStatus.FAILURE_FALSE_PASS
    if dominant in _DATA_CODES:
        return RichStatus.FAILURE_DATA
    if dominant in _ORDERING_CODES:
        return RichStatus.FAILURE_ORDERING
    if dominant in _INFRA_CODES:
        return RichStatus.FAILURE_INFRASTRUCTURE
    return RichStatus.FAILURE_OTHER


# ── XML loader ────────────────────────────────────────────────────────────────

def load_results(path: Path) -> tuple[dict[str, str], dict[Any, TestResult]]:
    root = ET.parse(path).getroot()
    summary = dict(root.attrib)
    results: dict[Any, TestResult] = {}

    for suite in root.findall(".//testsuite"):
        suite_name = suite.get("name", "")
        for case in suite.findall("testcase"):
            attributes = tuple(
                sorted(
                    (key, value)
                    for key, value in case.attrib.items()
                    if key not in {"name", "time"}
                )
            )
            failure = case.find("failure")
            error = case.find("error")
            skipped = case.find("skipped")

            if failure is not None:
                xml_tag = "failure"
                detail = _node_detail(failure)
                outcome_rows = parse_outcome_rows(failure.get("message", ""))
            elif error is not None:
                xml_tag = "error"
                detail = _node_detail(error)
                outcome_rows = ()
            elif skipped is not None:
                xml_tag = "skipped"
                detail = _node_detail(skipped)
                outcome_rows = parse_outcome_rows(skipped.get("message", ""))
            else:
                xml_tag = "passed"
                detail = ""
                outcome_rows = ()

            rich_status = classify_outcome(xml_tag, outcome_rows)

            result = TestResult(
                suite=suite_name,
                name=case.get("name", ""),
                attributes=attributes,
                status=xml_tag,
                rich_status=rich_status,
                detail=detail,
                time=case.get("time", ""),
                outcome_rows=outcome_rows,
            )
            if result.key in results:
                raise ValueError(f"Duplicate testcase key in {path}: {result.key}")
            results[result.key] = result

    return summary, results


def _node_detail(node: ET.Element) -> str:
    text = "".join(node.itertext()).strip()
    message = node.get("message", "").strip()
    return f"{message}\n{text}".strip() if message and text else message or text
