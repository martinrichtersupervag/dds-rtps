#!/bin/bash
# ==============================================================================
# run_benchmark.sh - Repeatedly executes run_tests_parallel.sh and renames
#                    the resulting reports to include date, time, number of
#                    parallel jobs, and elapsed duration.
#
# Output filename format:
#   junit_interoperability_report-DDMMYYYY-HHMM-parN-SECONDSsec.xml
#   interoperability_report-DDMMYYYY-HHMM-parN-SECONDSsec.xlsx
#   index-DDMMYYYY-HHMM-parN-SECONDSsec.html
#
# Usage:
#   ./run_benchmark.sh [--runs N]
#   ./run_benchmark.sh           # default number of runs: 8
#   ./run_benchmark.sh --runs 3  # run 3x instead of 8
#
# The script executes:
#   N iterations with --jobs 16  (PHASE 1)
#   N iterations with --jobs 4   (PHASE 2)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

RUNS=8   # Default number of repetitions (for each --jobs group)

# -- Argument parsing ---------------------------------------------------------
usage() {
    echo "Usage: $0 [--runs N]"
    echo ""
    echo "  --runs N   Number of repetitions for each --jobs configuration (default: $RUNS)"
    echo ""
    echo "The script runs N iterations with --jobs 16 and N iterations with --jobs 4."
    echo "Resulting files are renamed and remain in the benchmarking directory."
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --runs|-r)  RUNS="$2"; shift 2 ;;
        --help|-h)  usage ;;
        *) echo "Unknown argument: $1"; usage ;;
    esac
done

if ! [[ "$RUNS" =~ ^[0-9]+$ ]] || [ "$RUNS" -lt 1 ]; then
    echo "ERROR: --runs must be a positive integer (provided: '$RUNS')"
    exit 1
fi

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

    local suffix="${dt}-par${jobs}-${elapsed}sec"

    safe_rename \
        "$SCRIPT_DIR/junit_interoperability_report.xml" \
        "$SCRIPT_DIR/junit_interoperability_report-${suffix}.xml"

    safe_rename \
        "$SCRIPT_DIR/interoperability_report.xlsx" \
        "$SCRIPT_DIR/interoperability_report-${suffix}.xlsx"

    safe_rename \
        "$SCRIPT_DIR/index.html" \
        "$SCRIPT_DIR/index-${suffix}.html"
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
echo "Resulting files in $SCRIPT_DIR:"
ls -1 \
    "$SCRIPT_DIR"/junit_interoperability_report-*.xml \
    "$SCRIPT_DIR"/interoperability_report-*.xlsx \
    "$SCRIPT_DIR"/index-*.html 2>/dev/null | sort \
    || echo "  (no files found)"
echo ""
