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
#                      [--jobs J1,J2,...] [--publishers p1,p2] [--subscribers s1,s2]
#   ./run_benchmark.sh           # default: 8 runs for --jobs 16, then 8 runs for --jobs 4
#   ./run_benchmark.sh --jobs 8  # run for --jobs 8 only
#   ./run_benchmark.sh --jobs 32,16,8,4 --runs 2
#   --batch B overrides the automatically assigned batch number
#            (default: highest existing results/runX + 1)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$SCRIPT_DIR"

RUNS=8   # Default number of repetitions (for each --jobs value)
RUNNER="self-hosted"   # self-hosted | ubuntu
BATCH=""               # test suite run number (auto-assigned when empty)
JOBS_LIST=()           # List of parallel job configurations (e.g. 16, 4)
FILTER_PUBLISHERS=""   # Publisher filter passed to run_tests_parallel.sh
FILTER_SUBSCRIBERS=""  # Subscriber filter passed to run_tests_parallel.sh
RUN_RETRIES="${RUN_RETRIES:-1}"   # Whole-run repeats when a run is incomplete (missing pairs)
INCOMPLETE_RUNS=()      # Descriptions of runs that stayed incomplete

# -- Argument parsing ---------------------------------------------------------
usage() {
    echo "Usage: $0 [--runs N] [--runner self-hosted|ubuntu] [--batch B]"
    echo "                 [--jobs J1,J2,...] [--publishers p1,p2,...] [--subscribers s1,s2,...]"
    echo ""
    echo "  --runs N           Number of repetitions for each --jobs configuration (default: $RUNS)"
    echo "  --runner R         Where the tests run: self-hosted | ubuntu (default: $RUNNER)"
    echo "  --batch B          Test suite run number (default: highest results/runX + 1)"
    echo "  --jobs|-j LIST     Jobs list (comma or space separated, e.g. '32,16,8,4' or '8', default: '16 4')"
    echo "  --publishers|-p L  Publisher filter (passed to run_tests_parallel.sh)"
    echo "  --subscribers|-s L Subscriber filter (passed to run_tests_parallel.sh)"
    echo ""
    echo "Resulting files are renamed and stored in benchmarking/results/runB/."
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --runs|-r)        RUNS="$2"; shift 2 ;;
        --runner)         RUNNER="$2"; shift 2 ;;
        --batch|-b)       BATCH="$2"; shift 2 ;;
        --jobs|-j)        IFS=',' read -ra TOKENS <<< "$2"; JOBS_LIST+=("${TOKENS[@]}"); shift 2 ;;
        --publishers|-p)  FILTER_PUBLISHERS="$2"; shift 2 ;;
        --subscribers|-s) FILTER_SUBSCRIBERS="$2"; shift 2 ;;
        --help|-h)        usage ;;
        *) echo "Unknown argument: $1"; usage ;;
    esac
done

if [ ${#JOBS_LIST[@]} -eq 0 ]; then
    JOBS_LIST=(16 4)
fi

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
    local t_start
    local rc attempt=0
    local -a parallel_cmd=("$SCRIPT_DIR/run_tests_parallel.sh" --jobs "$jobs")
    if [ -n "$FILTER_PUBLISHERS" ]; then
        parallel_cmd+=(--publishers "$FILTER_PUBLISHERS")
    fi
    if [ -n "$FILTER_SUBSCRIBERS" ]; then
        parallel_cmd+=(--subscribers "$FILTER_SUBSCRIBERS")
    fi

    while true; do
        dt=$(date +%d%m%Y-%H%M)   # DDMMYYYY-HHMM at start time

        echo ""
        echo "================================================================"
        echo "  Run ${run_idx}/${total_runs}  (--jobs ${jobs})   [${dt}]"
        [ "$attempt" -gt 0 ] && echo "  (repeat ${attempt}/${RUN_RETRIES} - previous attempt was incomplete)"
        echo "================================================================"

        t_start=$(date +%s)
        rc=0
        bash "${parallel_cmd[@]}" || rc=$?

        if [ "$rc" -eq 0 ]; then
            break
        elif [ "$rc" -eq 3 ]; then
            # Incomplete: some pairs have no result even after per-pair retries
            if [ "$attempt" -lt "$RUN_RETRIES" ]; then
                attempt=$(( attempt + 1 ))
                echo "  WARNING: run ${run_idx}/${total_runs} (--jobs ${jobs}) incomplete - repeating whole run."
                continue
            fi
            echo "  ERROR: run ${run_idx}/${total_runs} (--jobs ${jobs}) stayed INCOMPLETE."
            INCOMPLETE_RUNS+=("run ${run_idx}/${total_runs} --jobs ${jobs} [${dt}]: $(paste -sd' ' "$SCRIPT_DIR/.parallel_logs/missing_pairs.txt" 2>/dev/null)")
            break
        else
            echo "  ERROR: run_tests_parallel.sh failed with exit code ${rc}."
            exit "$rc"
        fi
    done

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
echo "  Jobs configurations: ${JOBS_LIST[*]}"
echo "  Number of runs per job config: ${RUNS}"
if [ -n "$FILTER_PUBLISHERS" ]; then
    echo "  Publishers filter: ${FILTER_PUBLISHERS}"
fi
if [ -n "$FILTER_SUBSCRIBERS" ]; then
    echo "  Subscribers filter: ${FILTER_SUBSCRIBERS}"
fi
echo "=================================================================="

GLOBAL_START=$(date +%s)
phase_num=1

for jobs_cfg in "${JOBS_LIST[@]}"; do
    echo ""
    echo "------------------------------------------------------------------"
    echo "  PHASE ${phase_num}: ${RUNS} repetitions with --jobs ${jobs_cfg}"
    echo "------------------------------------------------------------------"
    for i in $(seq 1 "$RUNS"); do
        run_once "$jobs_cfg" "$i" "$RUNS"
    done
    phase_num=$(( phase_num + 1 ))
done

GLOBAL_END=$(date +%s)
GLOBAL_ELAPSED=$(( GLOBAL_END - GLOBAL_START ))
TOTAL_RUNS=$(( RUNS * ${#JOBS_LIST[@]} ))

echo ""
echo "=================================================================="
echo "  Total benchmark completed in ${GLOBAL_ELAPSED}s"
echo "  Total runs: ${TOTAL_RUNS}  (${RUNS}x each for jobs: ${JOBS_LIST[*]})"
echo "=================================================================="
if [ ${#INCOMPLETE_RUNS[@]} -gt 0 ]; then
    echo ""
    echo "  !!! ${#INCOMPLETE_RUNS[@]} INCOMPLETE RUN(S) - results are NOT comparable:"
    for r in "${INCOMPLETE_RUNS[@]}"; do
        echo "      - $r"
    done
else
    echo "  All runs complete (every run covered all pairs)."
fi
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
if [ ${#INCOMPLETE_RUNS[@]} -gt 0 ]; then exit 1; fi
