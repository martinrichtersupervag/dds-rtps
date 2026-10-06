#!/bin/bash
# ==============================================================================
# run_benchmark.sh - Repeatedly executes run_tests_parallel.sh and renames
#                    the resulting reports to include date, time, number of
#                    parallel jobs, and elapsed duration.
#
# Output filename format:
#   junit_interoperability_report-DDMMYYYY-HHMM-parN-SECONDSsec-RUNNER-runB.xml
#   interoperability_report-DDMMYYYY-HHMM-parN-SECONDSsec-RUNNER-runB.xlsx
#   index-DDMMYYYY-HHMM-parN-SECONDSsec-RUNNER-runB.html
#   RUNNER = self-hosted | ubuntu (ubuntu = GitHub-hosted)
#   B      = test suite run (batch) number = ordinal number of this invocation
#
# All files of one batch are stored in results/runB/ (next to this script).
# After the last run the analysis (compare_junit_reports.py) is executed over
# the files of this batch and its outputs are saved to the same directory:
#   explain_parallel-RUNNER-runB.{txt,html,log}
#   compare-RUNNER-runB.log
#
# Usage:
#   ./run_benchmark.sh [--runs N] [--runner self-hosted|ubuntu] [--batch B]
#   ./run_benchmark.sh           # default number of runs: 8, runner self-hosted
#   ./run_benchmark.sh --runs 3  # run 3x instead of 8
#   --batch B overrides the automatically assigned batch number
#            (default: highest existing results/runX + 1)
#
# The script executes:
#   N iterations with --jobs 16  (PHASE 1)
#   N iterations with --jobs 4   (PHASE 2)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$SCRIPT_DIR"

RUNS=8   # Default number of repetitions (for each --jobs group)
RUNNER="self-hosted"   # self-hosted | ubuntu
BATCH=""               # test suite run number (auto-assigned when empty)

# -- Argument parsing ---------------------------------------------------------
usage() {
    echo "Usage: $0 [--runs N] [--runner self-hosted|ubuntu] [--batch B]"
    echo ""
    echo "  --runs N      Number of repetitions for each --jobs configuration (default: $RUNS)"
    echo "  --runner R    Where the tests run: self-hosted | ubuntu (default: $RUNNER)"
    echo "  --batch B     Test suite run number (default: highest results/runX + 1)"
    echo ""
    echo "The script runs N iterations with --jobs 16 and N iterations with --jobs 4."
    echo "Resulting files are renamed and stored in benchmarking/results/runB/."
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --runs|-r)  RUNS="$2"; shift 2 ;;
        --runner)   RUNNER="$2"; shift 2 ;;
        --batch|-b) BATCH="$2"; shift 2 ;;
        --help|-h)  usage ;;
        *) echo "Unknown argument: $1"; usage ;;
    esac
done

if ! [[ "$RUNS" =~ ^[0-9]+$ ]] || [ "$RUNS" -lt 1 ]; then
    echo "ERROR: --runs must be a positive integer (provided: '$RUNS')"
    exit 1
fi

if [[ "$RUNNER" != "self-hosted" && "$RUNNER" != "ubuntu" ]]; then
    echo "ERROR: --runner must be 'self-hosted' or 'ubuntu' (provided: '$RUNNER')"
    exit 1
fi

# -- Test suite run (batch) number and results directory ----------------------
RESULTS_ROOT="$SCRIPT_DIR/results"
mkdir -p "$RESULTS_ROOT"

if [ -z "$BATCH" ]; then
    BATCH=1
    for d in "$RESULTS_ROOT"/run*/; do
        [ -d "$d" ] || continue
        n="$(basename "$d")"; n="${n#run}"
        if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge "$BATCH" ]; then
            BATCH=$(( n + 1 ))
        fi
    done
fi

if ! [[ "$BATCH" =~ ^[0-9]+$ ]] || [ "$BATCH" -lt 1 ]; then
    echo "ERROR: --batch must be a positive integer (provided: '$BATCH')"
    exit 1
fi

RESULTS_DIR="$RESULTS_ROOT/run${BATCH}"
BATCH_TAG="${RUNNER}-run${BATCH}"
mkdir -p "$RESULTS_DIR"

# -- Rename without overwriting -----------------------------------------------
# Moves $1 to $2; if $2 already exists, appends _2, _3, ...
safe_rename() {
    local src="$1"
    local dst="$2"
    if [ ! -f "$src" ]; then
        echo "  WARNING: '$src' does not exist, skipping."
        return 0
    fi
    if [ ! -f "$dst" ]; then
        mv "$src" "$dst"
        echo "  -> $(basename "$dst")"
    else
        local ext="${dst##*.}"
        local base="${dst%.*}"
        local n=2
        while [ -f "${base}_${n}.${ext}" ]; do
            n=$(( n + 1 ))
        done
        mv "$src" "${base}_${n}.${ext}"
        echo "  -> $(basename "${base}_${n}.${ext}") (collision: added suffix _${n})"
    fi
}

# -- Single run + output renaming ---------------------------------------------
run_once() {
    local jobs="$1"
    local run_idx="$2"
    local total_runs="$3"

    local dt
    dt=$(date +%d%m%Y-%H%M)   # DDMMYYYY-HHMM at start time

    echo ""
    echo "================================================================"
    echo "  Run ${run_idx}/${total_runs}  (--jobs ${jobs})   [${dt}]"
    echo "================================================================"

    local t_start
    t_start=$(date +%s)

    bash "$SCRIPT_DIR/run_tests_parallel.sh" --jobs "$jobs"

    local t_end
    t_end=$(date +%s)
    local elapsed=$(( t_end - t_start ))

    echo ""
    echo "  Run completed in ${elapsed}s."

    local suffix="${dt}-par${jobs}-${elapsed}sec-${BATCH_TAG}"

    # Compatibility copy: keep the original (unrenamed) report files in the
    # repository root, as produced by the GitHub Actions workflow.
    for f in junit_interoperability_report.xml interoperability_report.xlsx index.html; do
        if [ -f "$SCRIPT_DIR/$f" ]; then
            cp -f "$SCRIPT_DIR/$f" "$REPO_ROOT/$f"
        fi
    done

    safe_rename \
        "$SCRIPT_DIR/junit_interoperability_report.xml" \
        "$RESULTS_DIR/junit_interoperability_report-${suffix}.xml"

    safe_rename \
        "$SCRIPT_DIR/interoperability_report.xlsx" \
        "$RESULTS_DIR/interoperability_report-${suffix}.xlsx"

    safe_rename \
        "$SCRIPT_DIR/index.html" \
        "$RESULTS_DIR/index-${suffix}.html"
}

# -- Main loop ----------------------------------------------------------------
echo ""
echo "=================================================================="
echo "  run_benchmark.sh - benchmark test suite"
echo "  Number of runs: ${RUNS}x with --jobs 16  +  ${RUNS}x with --jobs 4"
echo "=================================================================="

GLOBAL_START=$(date +%s)

echo ""
echo "------------------------------------------------------------------"
echo "  PHASE 1: ${RUNS} repetitions with --jobs 16"
echo "------------------------------------------------------------------"
for i in $(seq 1 "$RUNS"); do
    run_once 16 "$i" "$RUNS"
done

echo ""
echo "------------------------------------------------------------------"
echo "  PHASE 2: ${RUNS} repetitions with --jobs 4"
echo "------------------------------------------------------------------"
for i in $(seq 1 "$RUNS"); do
    run_once 4 "$i" "$RUNS"
done

GLOBAL_END=$(date +%s)
GLOBAL_ELAPSED=$(( GLOBAL_END - GLOBAL_START ))
TOTAL_RUNS=$(( RUNS * 2 ))

echo ""
echo "=================================================================="
echo "  Total benchmark completed in ${GLOBAL_ELAPSED}s"
echo "  Total runs: ${TOTAL_RUNS}  (${RUNS}x par16 + ${RUNS}x par4)"
echo "=================================================================="
echo ""
echo "Resulting files in $RESULTS_DIR:"
ls -1 \
    "$RESULTS_DIR"/junit_interoperability_report-*.xml \
    "$RESULTS_DIR"/interoperability_report-*.xlsx \
    "$RESULTS_DIR"/index-*.html 2>/dev/null | sort \
    || echo "  (no files found)"
echo ""

# -- Analysis of this batch (compare_junit_reports.py) ------------------------
# Works only on files of the current batch (--batch) located in results/runB/.
# Outputs (explain_parallel-RUNNER-runB.{txt,html,log}) are saved next to them.
PYTHON_BIN="$(command -v python3 || command -v python || true)"
if [ -z "$PYTHON_BIN" ]; then
    echo "WARNING: python not found, skipping batch analysis."
else
    echo "=================================================================="
    echo "  Analysis of batch ${BATCH} (${RUNNER}) in $RESULTS_DIR"
    echo "=================================================================="
    "$PYTHON_BIN" "$SCRIPT_DIR/compare_junit_reports.py" \
        --directory "$RESULTS_DIR" --batch "$BATCH" \
        --explain-parallel --html 2>&1 \
        | tee "$RESULTS_DIR/explain_parallel-${BATCH_TAG}.log" \
        || echo "WARNING: explain-parallel analysis failed."

    # Run-to-run comparison needs at least two reports in the batch
    # (the comparison also writes its own compare_*.txt / explain_*.txt files)
    "$PYTHON_BIN" "$SCRIPT_DIR/compare_junit_reports.py" \
        --directory "$RESULTS_DIR" --batch "$BATCH" \
        --compare-all --show-differences 2>&1 \
        | tee "$RESULTS_DIR/compare-${BATCH_TAG}.log" \
        || echo "WARNING: compare-all analysis failed."
fi
echo ""
