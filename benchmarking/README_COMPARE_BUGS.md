# DDS Interoperability – Defect Taxonomy and Analysis Notes

> Based on real test data: 10 × `junit_interoperability_report-*-par16-*.xml`
> covering the 9×9 publish/subscribe matrix of DDS vendor implementations.
> Each testcase result contains a structured HTML table with `Expected Code` and
> `Code Produced` per participant role (Publisher_1, Subscriber_1, …).
>
> **Status:** fully implemented in `junit_compare/loader.py`, `models.py`,
> `report_data.py`, `analyzer.py`, and `html_report.py`.

---

## How the result table works

Every non-passing testcase carries a `message` attribute on its `<failure>` or
`<skipped>` XML element. The message contains an HTML table:

```html
<table>
  <tr><th/><th>Expected Code</th><th>Code Produced</th></tr>
  <tr><th>Publisher_1</th><th>INCOMPATIBLE_QOS</th><th>OK</th></tr>
  <tr><th>Subscriber_1</th><th>INCOMPATIBLE_QOS</th><th>INCOMPATIBLE_QOS</th></tr>
</table>
```

The **test passes** when *every role's* `Code Produced` matches its `Expected Code`.
The **XML tag** (`<failure>` vs `<skipped>`) encodes the framework's verdict, not
necessarily the semantic result — see anomalies below.

Parsed by [`parse_outcome_rows()`](file:///d:/prog/polis/compare_junit_reports/junit_compare/loader.py)
and classified by [`classify_outcome()`](file:///d:/prog/polis/compare_junit_reports/junit_compare/loader.py).

---

## All result codes observed

| Code | Count (3 files) | Meaning |
|------|---------------:|---------|
| `OK` | 45 089 | Participant behaved as expected |
| `INCOMPATIBLE_QOS` | 25 689 | QoS policies are mutually incompatible |
| `SUB_UNSUPPORTED_FEATURE` | 3 969 | Subscriber's vendor does not implement this feature |
| `PUB_UNSUPPORTED_FEATURE` | 3 753 | Publisher's vendor does not implement this feature |
| `DATA_NOT_CORRECT` | 2 864 | Data received but content wrong |
| `DATA_NOT_RECEIVED` | 1 787 | Expected data never arrived |
| `READER_NOT_MATCHED` | 1 085 | Writer and reader did not discover each other |
| `RECEIVING_FROM_ONE` | 746 | Received from only one of multiple publishers |
| `RECEIVING_FROM_BOTH` | 694 | Received from both when only one was expected |
| `DEADLINE_MISSED` | 677 | Deadline QoS violated |
| `ORDERED_ACCESS_INSTANCE` | 490 | Ordered-access by instance violated |
| `ORDERED_ACCESS_TOPIC` | 485 | Ordered-access by topic violated |
| `DATA_NOT_SENT` | 47 | Writer failed to send data |
| `READER_NOT_CREATED` | 9 | DataReader creation failed |
| `TOPIC_NOT_CREATED` | 1 | Topic creation failed |
| `WRITER_NOT_CREATED` | 1 | DataWriter creation failed |

---

## RichStatus — defect taxonomy

Defined in [`RichStatus`](file:///d:/prog/polis/compare_junit_reports/junit_compare/models.py)
enum. Classification priority is applied top-to-bottom by `classify_outcome()`.

### `passed`
*Test ran and every role matched its expected outcome.*

The `<testcase>` has no child element (`<failure>` / `<skipped>` / `<error>`).
**Count (1 file): 1 479 (17.4 %)**

---

### `passed_as_skipped`
*Framework tagged the testcase as `<skipped>` but the outcome is semantically correct.*

**Rule:** `<skipped>` AND all roles satisfy `expected == produced` AND no `*_UNSUPPORTED_FEATURE`.

> **Example:** `expected=INCOMPATIBLE_QOS, produced=INCOMPATIBLE_QOS` — the vendor
> correctly detected the QoS mismatch. This is intended behaviour, not a skip.

**Count (1 file): 0\*** — in this dataset every skipped entry has at least one
`*_UNSUPPORTED_FEATURE` role, so the category is populated by future data.

---

### `skipped_unsupported`
*Vendor does not implement the tested feature — test was never meaningfully run.*

**Rule:** `<skipped>` AND any role produced `SUB_UNSUPPORTED_FEATURE` or `PUB_UNSUPPORTED_FEATURE`.

**Count (1 file): 2 037 (24.0 %)**

> These are **excluded** from all failure-rate and flaky-test calculations.
> A vendor that consistently skips a feature is not "flaky" — it is simply
> non-compliant with that optional capability.

---

### `skipped_other`
*Test skipped for an unclassified reason.*

**Rule:** `<skipped>` AND none of the above patterns match.

**Count (1 file): 0\*** — no such cases observed in current dataset.

---

### `failure_qos_unexpected`
*Vendor reports QoS incompatibility where the test expects successful communication.*

**Rule:** `<failure>` AND dominant mismatch `produced = INCOMPATIBLE_QOS`
(i.e. `expected ≠ INCOMPATIBLE_QOS`).

**Count (1 file): 3 320 (39.0 %) — largest single failure category**

Subcases observed:

| Expected | Produced | Interpretation |
|----------|----------|----------------|
| `OK` | `INCOMPATIBLE_QOS` | Vendor refuses a connection that should work |
| `DATA_NOT_RECEIVED` | `INCOMPATIBLE_QOS` | Expected delivery timeout, got QoS rejection |
| `READER_NOT_MATCHED` | `INCOMPATIBLE_QOS` | Expected discovery failure, got QoS rejection |
| `RECEIVING_FROM_ONE/BOTH` | `INCOMPATIBLE_QOS` | Expected partial delivery, got QoS rejection |
| `DEADLINE_MISSED` | `INCOMPATIBLE_QOS` | Expected deadline violation, got QoS rejection |
| `ORDERED_ACCESS_*` | `INCOMPATIBLE_QOS` | Expected ordering result, got QoS rejection |

---

### `failure_false_pass`
*Vendor communicates successfully where the test expects a failure.*

**Rule:** `<failure>` AND dominant mismatch `produced = OK`
(i.e. `expected ≠ OK`, e.g. `INCOMPATIBLE_QOS`, `READER_NOT_MATCHED`, `DATA_NOT_RECEIVED`).

**Count (1 file): 991 (11.7 %)**

> This is a real interoperability defect: the vendor ignored a QoS constraint
> or isolation boundary. Classic example:
> `expected=INCOMPATIBLE_QOS, produced=OK` — vendor accepted a connection
> it should have rejected.

---

### `failure_data`
*Connection established, but data content or delivery failed.*

**Rule:** `<failure>` AND dominant produced ∈ `{DATA_NOT_CORRECT, DATA_NOT_RECEIVED, DATA_NOT_SENT}`

**Count (1 file): 629 (7.4 %)**

| Produced | Count | Meaning |
|----------|------:|---------|
| `DATA_NOT_CORRECT` | 515 | Content integrity failure |
| `DATA_NOT_RECEIVED` | 98 | Delivery failure (timeout) |
| `DATA_NOT_SENT` | 16 | Writer-side send failure |

---

### `failure_ordering`
*QoS ordering or timing semantics violated.*

**Rule:** `<failure>` AND dominant produced ∈
`{ORDERED_ACCESS_INSTANCE, ORDERED_ACCESS_TOPIC, RECEIVING_FROM_ONE, RECEIVING_FROM_BOTH, DEADLINE_MISSED}`

**Count (1 file): 6 (0.1 %)** — rare but semantically distinct from QoS failures.

---

### `failure_infrastructure`
*DDS or test-framework infrastructure could not initialise.*

**Rule:** `<failure>` AND any produced ∈
`{READER_NOT_CREATED, WRITER_NOT_CREATED, TOPIC_NOT_CREATED, READER_NOT_MATCHED}`

**Count (1 file): 43 (0.5 %)**

> Not an interoperability defect — indicates environment or configuration
> problems. Should be tracked separately from protocol failures.

---

### `failure_other`
*Mismatch not covered by any of the categories above.*

Includes `<failure>` where all `expected == produced` (framework anomaly — the
framework reported failure even though every role matched its expectation).

**Count (1 file): 0** in current dataset.

---

### `error`
*Test framework raised a system-level exception.*

**Rule:** `<error>` XML tag present.

**Count (1 file): 0** in current dataset.

---

## Summary table — measured counts (1 file, 8 505 testcases)

| RichStatus | Count | % | Colour in HTML | Old JUnit status |
|---|---:|---:|---|---|
| `passed` | 1 479 | 17.4 % | 🟢 `#4ade80` | passed |
| `passed_as_skipped` | 0 | — | 🟩 `#86efac` | skipped |
| `skipped_unsupported` | 2 037 | 24.0 % | ⚫ `#94a3b8` | skipped |
| `skipped_other` | 0 | — | ⬛ `#64748b` | skipped |
| `failure_qos_unexpected` | 3 320 | 39.0 % | 🔴 `#f87171` | failure |
| `failure_false_pass` | 991 | 11.7 % | 🟠 `#fb923c` | failure |
| `failure_data` | 629 | 7.4 % | 🟡 `#fbbf24` | failure |
| `failure_infrastructure` | 43 | 0.5 % | 🟣 `#e879f9` | failure |
| `failure_ordering` | 6 | 0.1 % | 💜 `#a78bfa` | failure |
| `failure_other` | 0 | — | ⚫ `#94a3b8` | failure |
| `error` | 0 | — | ❤️ `#dc2626` | error |

> **Key insight:** Of the 8 505 testcases, only **1 479 (17.4%)** truly passed.
> **24.0%** were never run (vendor doesn't support the feature).
> The remaining **58.6%** are genuine failures — dominated by unexpected QoS
> incompatibilities (**39.0%**) and false passes (**11.7%**).

---

## Impact on flaky analysis

With the refined status model, **flakiness detection changes significantly**:

| Old behaviour | New behaviour |
|---|---|
| `skipped` counted toward flaky | `skipped_unsupported` **excluded** — consistent non-support ≠ flaky |
| `passed` = only JUnit `passed` tag | `passed` includes `passed_as_skipped` |
| flaky if `passed > 0 AND failure > 0` | flaky if `passed > 0 AND total_real_fail > 0` |
| all failures weighted equally | flaky breakdown separable by `RichStatus` category |

A test oscillating between `failure_qos_unexpected` and `failure_false_pass`
(vendor flip-flops between rejecting and accepting a connection) is a
**different and more severe defect** than one oscillating between `passed` and `failure_data`.

---

## Anomalies found

### A — `<skipped>` with `expected == produced` (all roles)
Occurs 478+ times per file. The vendor correctly detected the expected QoS
incompatibility, but the framework returned it via a `<skipped>` element.
**Reclassified as:** `passed_as_skipped` ✅

### B — `<failure>` with mixed-role results
Most failures are multi-role. One role may match (`expected == produced`) while
another does not. The **dominant mismatch type** drives the `RichStatus` category.

**Example:** `Publisher_1: INCOMPATIBLE_QOS→OK` (false pass) +
`Subscriber_1: INCOMPATIBLE_QOS→INCOMPATIBLE_QOS` (correct) → classified as
`failure_false_pass` because the dominant mismatch produced is `OK`.

### C — `skipped` with `INCOMPATIBLE_QOS → OK`
411 per-role occurrences: the test was skipped but the vendor actually
communicated where it shouldn't have.
**Verdict:** Suspicious — vendor bug possibly masked by the framework's skip verdict.
Currently classified as `skipped_other`.

### D — `failure` with `expected=DATA_NOT_RECEIVED, produced=INCOMPATIBLE_QOS`
The test expects a delivery timeout, but the vendor rejects the connection at
the QoS level instead. Classified as `failure_qos_unexpected` — the QoS
rejection prevents the delivery scenario from even starting.

---

## Implementation — where each piece lives

| Component | File | Responsibility |
|---|---|---|
| `RichStatus` enum | [`models.py`](file:///d:/prog/polis/compare_junit_reports/junit_compare/models.py) | 11-category classification enum + code-set constants |
| `OutcomeRow` type | [`models.py`](file:///d:/prog/polis/compare_junit_reports/junit_compare/models.py) | `tuple[role, expected, produced]` |
| `parse_outcome_rows()` | [`loader.py`](file:///d:/prog/polis/compare_junit_reports/junit_compare/loader.py) | Extracts per-role table from `message` HTML |
| `classify_outcome()` | [`loader.py`](file:///d:/prog/polis/compare_junit_reports/junit_compare/loader.py) | Maps `(xml_tag, rows)` → `RichStatus` |
| `TestResult.rich_status` | [`models.py`](file:///d:/prog/polis/compare_junit_reports/junit_compare/models.py) | Stored on every loaded test result |
| `TestResult.outcome_rows` | [`models.py`](file:///d:/prog/polis/compare_junit_reports/junit_compare/models.py) | Per-role `(role, expected, produced)` tuples |
| `StatusSummaryRow` | [`report_data.py`](file:///d:/prog/polis/compare_junit_reports/junit_compare/report_data.py) | `rich_counts` dict + semantic properties |
| `ParallelGroupReport.rich_status_totals` | [`report_data.py`](file:///d:/prog/polis/compare_junit_reports/junit_compare/report_data.py) | Raw counts per `RichStatus` for a group |
| `_aggregate_statuses()` | [`analyzer.py`](file:///d:/prog/polis/compare_junit_reports/junit_compare/analyzer.py) | Aggregates `rich_status` across all files |
| `_render_rich_status_summary()` | [`html_report.py`](file:///d:/prog/polis/compare_junit_reports/junit_compare/html_report.py) | Colour-coded HTML table per group tab |
| HTML output | `explain_parallel.html` | One tab per `parNN` group, "Result Classification" section per tab |
