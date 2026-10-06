# DDS Interoperability Report Comparator

`compare_junit_reports.py` compares JUnit XML reports produced by DDS vendor interoperability tests. It compares testcase presence and pass/fail/error status while ignoring runtime and verbose communication details by default.

# Requirements

- Python 3.9 or newer
- No external packages are required

# Basic Usage - porovnani vsech vysledku

- python compare_junit_reports.py --compare-all --show-difference
  nebo spust compare_all.bat

## Vystupy


### 1. Globální frekvence selhání
**Značka sekce:** `##Result for: Failure frequency across all XML reports`
**Hlavička:** `Failure frequency across all XML reports:`
- **Generuje:** [`print_failure_frequency_summary`](file:///d:/prog/polis/compare_junit_reports/compare_junit_reports.py#L271-L283)
- **Obsah:** Agregace stavů jednotlivých testů napříč **všemi** analyzovanými XML soubory.
- **Formát řádku:**
  ```text
  <suite> / <test> [<atributy>]: passed=X, failed=Y, errors=Z, skipped=W, total_failures=N
  ```
- **Pravidlo:** Zobrazují se pouze testy, které alespoň jednou selhaly (`failed > 0` nebo `errors > 0`), seřazené sestupně podle `total_failures`.

---

### 2. Opakované změny výsledků (nestabilní / flaky testy)
**Značka sekce:** `##Result for: Repeated testcase changes on the same location`
**Hlavička:** `Repeated testcase changes on the same location: <počet>`
- **Generuje:** [`_repeated_change_tests`](file:///d:/prog/polis/compare_junit_reports/compare_junit_reports.py#L240-L248) a [`render_compare_all`](file:///d:/prog/polis/compare_junit_reports/compare_junit_reports.py#L325-L330)
- **Obsah:** Přehled testů, u kterých došlo ke změně stavu (např. `passed` $\leftrightarrow$ `failure`) **více než 1×** v průběhu sledovaných porovnání.
- **Formát řádku:**
  ```text
  <suite> / <test> [<atributy>]: X comparisons
  ```
- Číslo udává, v kolika po sobě jdoucích dvojicích běhů tento test změnil výsledek.

---

### 3. Chronologická srovnání dvojic reportů
**Značka sekce:** `##Result for: Differences: <časové_razítko_A> -> <časové_razítko_B>`
**Hlavička:** `Differences: <časové_razítko_A> -> <časové_razítko_B>`
- **Generuje:** [`print_differences`](file:///d:/prog/polis/compare_junit_reports/compare_junit_reports.py#L207-L238)
- **Obsah:** Tento blok se opakuje pro **každou sousední dvojici** chronologicky seřazených reportů ($R_1 \to R_2$, $R_2 \to R_3$, atd.).
- **Segmentace uvnitř jedné dvojice:**
  1. **Odebrané testy:**
     ```text
     CHANGED: <suite> / <test>
     - first: (empty)
     + second: removed
     ```
  2. **Přidané testy:**
     ```text
     CHANGED: <suite> / <test>
     - first: removed
     + second: (empty)
     ```
  3. **Změny stavu:**
     ```text
     CHANGED: <suite> / <test>
     - <timestamp_A>: passed
     + <timestamp_B>: failure
     ```
  *(Pokud mezi dvěma běhy není žádný rozdíl, vypíše se `No testcase result differences.`)*

# Basic Usage - compare two files

Run the script from this directory:

```powershell
python compare_junit_reports.py
```

Without XML arguments, the script selects the two newest `junit_*.xml` files and compares them.

To compare specific reports:

```powershell
python compare_junit_reports.py first.xml second.xml
```

The first file is treated as the earlier run and the second file as the later run.

## Output Modes

Concise summary:

```powershell
python compare_junit_reports.py --simple
```

Show changed testcase outcomes as two-sided differences:

```powershell
python compare_junit_reports.py --show-differences
```

The output looks like this:

```text
CHANGED: vendor_a---vendor_b / testcase_name
- first: passed
+ second: failure
```

Machine-readable JSON:

```powershell
python compare_junit_reports.py --json
```

Default detailed report:

```powershell
python compare_junit_reports.py
```

## Compare All Reports

Compare every XML report with the next chronological report:

```powershell
python compare_junit_reports.py --compare-all --simple
```

For four reports, this creates comparisons for:

```text
report1 -> report2
report2 -> report3
report3 -> report4
```

`--compare-all` cannot be combined with explicit XML file arguments.

## Optional Comparison Details

Include testcase runtime changes:

```powershell
python compare_junit_reports.py --include-times
```

Include verbose failure and error details from the XML:

```powershell
python compare_junit_reports.py --include-details
```

These options can be combined with the output modes and `--compare-all`.

## Choosing Another Folder

Use `--directory` when the XML files are in another folder:

```powershell
python compare_junit_reports.py --directory path\to\reports --simple
```

The directory must contain at least two files matching `junit_*.xml`.

## Saved Output Files

Every successful comparison is printed to the console and saved as a text file in the directory of the first XML report. The filename format is:

```text
{mode}_{timestamp1}_{timestamp2}.txt
```

Examples:

```text
simple_2026-08-30-06_18_47_2026-08-30-16_15_12.txt
show-differences_2026-08-30-06_18_47_2026-08-30-16_15_12.txt
json_2026-08-30-06_18_47_2026-08-30-16_15_12.txt
```

The timestamps are extracted from the source filenames. Existing output `.txt` files are not considered XML input because only `junit_*.xml` files are selected.
