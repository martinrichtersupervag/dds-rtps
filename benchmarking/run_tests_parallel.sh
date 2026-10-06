#!/bin/bash
# ==============================================================================
# Run DDS-RTPS interoperability tests in PARALLEL Docker containers
#
# Analogous to GitHub Actions matrix - each pair (publisher x subscriber) runs
# concurrently in its own dedicated Docker container.
#
# Workflow:
#   1. Archives existing host reports to archive_reports/
#   2. Launches N Docker containers (default: 8) concurrently
#      - each container gets an isolated work-dir to prevent file overwrites
#   3. Collects all XML reports into $SCRIPT_DIR
#   4. Generates final XML, XLSX, and HTML reports
#
# Usage:
#   ./run_tests_parallel.sh [--jobs N] [--publishers p1,p2] [--subscribers s1,s2]
#   ./run_tests_parallel.sh                      # all x all, 8 concurrent jobs
#   ./run_tests_parallel.sh --jobs 4             # limit to 4 concurrent jobs
#   ./run_tests_parallel.sh --publishers connext_dds --subscribers dust_dds,eclipse_cyclone
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$SCRIPT_DIR"

IMAGE_NAME="dds-rtps-tester"
MAX_JOBS=8          # Default number of concurrent Docker containers

# -- Argument parsing ---------------------------------------------------------
FILTER_PUBLISHERS=""
FILTER_SUBSCRIBERS=""

usage() {
    echo "Usage: $0 [--jobs N] [--publishers p1,p2,...] [--subscribers s1,s2,...]"
    echo ""
    echo "  --jobs N           Maximum number of concurrent Docker containers (default: $MAX_JOBS)"
    echo "  --publishers LIST  Publisher filter (comma-separated substrings of exe name, or 'all')"
    echo "  --subscribers LIST Subscriber filter (comma-separated substrings of exe name, or 'all')"
    echo ""
    echo "Examples:"
    echo "  $0                                                   # all x all, 8 concurrent jobs"
    echo "  $0 --jobs 4                                          # limit to 4 concurrent jobs"
    echo "  $0 --publishers connext_dds --subscribers dust_dds   # single pair only"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --jobs|-j)        MAX_JOBS="$2"; shift 2 ;;
        --publishers|-p)  FILTER_PUBLISHERS="$2"; shift 2 ;;
        --subscribers|-s) FILTER_SUBSCRIBERS="$2"; shift 2 ;;
        --help|-h)        usage ;;
        *) echo "Unknown argument: $1"; usage ;;
    esac
done

# -- Docker check -------------------------------------------------------------
if ! command -v docker &>/dev/null; then
    echo "ERROR: 'docker' command not found. Please install Docker."
    exit 1
fi

# -- Build Docker image -------------------------------------------------------
if [[ "$(docker images -q "$IMAGE_NAME" 2>/dev/null)" == "" ]] || \
   ! docker run --rm "$IMAGE_NAME" which tshark &>/dev/null; then
    echo "==> Building Docker image: $IMAGE_NAME..."
    docker build -t "$IMAGE_NAME" -f "$SCRIPT_DIR/Dockerfile" "$REPO_ROOT"
fi

# Clean up any leftover temporary dds_net_* networks
docker network ls --filter "name=dds_net_" -q | xargs -r docker network rm >/dev/null 2>&1 || true

# -- Archive previous reports -------------------------------------------------
archive_dir="$SCRIPT_DIR/archive_reports"
shopt -s nullglob
old_reports=("$SCRIPT_DIR"/*.xml "$SCRIPT_DIR"/*.xlsx "$SCRIPT_DIR"/index.html \
             "$SCRIPT_DIR"/discovery_report*.json "$SCRIPT_DIR"/discovery_summary.json \
             "$SCRIPT_DIR"/timestamp)
if [ ${#old_reports[@]} -gt 0 ]; then
    echo "==> [1] Archiving previous reports to archive_reports/..."
    mkdir -p "$archive_dir"
    mv "${old_reports[@]}" "$archive_dir/" 2>/dev/null || true
fi
shopt -u nullglob
rm -f "$SCRIPT_DIR/timestamp"

# -- Discover available executables -------------------------------------------
EXE_DIR="$REPO_ROOT/executables"
if [ ! -d "$EXE_DIR" ] && [ -d "$SCRIPT_DIR/executables" ]; then
    EXE_DIR="$SCRIPT_DIR/executables"
fi

mapfile -t ALL_EXES < <(find "$EXE_DIR" -type f -name '*shape_main_linux' 2>/dev/null | sort)

if [ ${#ALL_EXES[@]} -eq 0 ]; then
    echo "ERROR: No *shape_main_linux executables found in $EXE_DIR/"
    echo "       Please extract them first (see README)."
    exit 1
fi

# Filter by --publishers / --subscribers
filter_exes() {
    local result_var="$1"
    local filter="$2"
    local -a result=()
    if [[ -z "$filter" || "$filter" == "all" ]]; then
        result=("${ALL_EXES[@]}")
    else
        IFS=',' read -ra tokens <<< "$filter"
        for exe in "${ALL_EXES[@]}"; do
            for tok in "${tokens[@]}"; do
                tok="$(echo "$tok" | tr -d '[:space:]')"
                if [[ "$(basename "$exe")" == *"$tok"* ]]; then
                    result+=("$exe")
                    break
                fi
            done
        done
    fi
    # Export via nameref - compatible with bash 4.3+
    eval "${result_var}=($(printf '"%s" ' "${result[@]+"${result[@]}"}") )"
}

filter_exes PUBLISHERS "$FILTER_PUBLISHERS"
filter_exes SUBSCRIBERS "$FILTER_SUBSCRIBERS"

if [ ${#PUBLISHERS[@]} -eq 0 ]; then
    echo "ERROR: No publishers match filter: '$FILTER_PUBLISHERS'"
    exit 1
fi
if [ ${#SUBSCRIBERS[@]} -eq 0 ]; then
    echo "ERROR: No subscribers match filter: '$FILTER_SUBSCRIBERS'"
    exit 1
fi

# -- Common setup -------------------------------------------------------------
WORK_ROOT="$SCRIPT_DIR/.parallel_workdirs"
LOG_DIR="$SCRIPT_DIR/.parallel_logs"
rm -rf "$WORK_ROOT" "$LOG_DIR"
mkdir -p "$WORK_ROOT" "$LOG_DIR"

# -- Build list of all pairs --------------------------------------------------
declare -a PAIRS_PUB=()
declare -a PAIRS_SUB=()
for pub in "${PUBLISHERS[@]}"; do
    for sub in "${SUBSCRIBERS[@]}"; do
        PAIRS_PUB+=("$pub")
        PAIRS_SUB+=("$sub")
    done
done

TOTAL=${#PAIRS_PUB[@]}
echo ""
echo "==> [2] Running $TOTAL test pairs (max $MAX_JOBS concurrently)..."
pub_names=$(printf '%s ' "${PUBLISHERS[@]}" | xargs -n1 basename | sed 's/_shape_main_linux//' | tr '\n' ' ')
sub_names=$(printf '%s ' "${SUBSCRIBERS[@]}" | xargs -n1 basename | sed 's/_shape_main_linux//' | tr '\n' ' ')
echo "        Publishers (${#PUBLISHERS[@]}): $pub_names"
echo "        Subscribers (${#SUBSCRIBERS[@]}): $sub_names"
echo ""

# -- Function to run a single pair --------------------------------------------
run_pair() {
    local idx="$1"
    local pub_exe="$2"
    local sub_exe="$3"

    local pub_name
    pub_name=$(basename "$pub_exe" _shape_main_linux)
    local sub_name
    sub_name=$(basename "$sub_exe" _shape_main_linux)
    local pair_label="${pub_name}---${sub_name}"
    local log_file="$LOG_DIR/${pair_label}.log"

    # Isolated work-dir for this pair's outputs
    local work_dir="$WORK_ROOT/${pair_label}"
    mkdir -p "$work_dir"

    local output_xml="junit_report-${pair_label}.xml"
    local extra_args=""
    if [[ "${sub_name,,}" == *opendds* && "${pub_name,,}" == *connext_dds* ]]; then
        extra_args="--periodic-announcement 5000"
    fi

    # Dedicated isolated Docker network for this pair (prevents multicast cross-talk)
    local rand_id
    rand_id=$(tr -dc 'a-z0-9' < /proc/sys/kernel/random/uuid 2>/dev/null | head -c 8 || echo $RANDOM)
    local pair_net="dds_net_${idx}_${rand_id}"
    docker network create "$pair_net" >/dev/null 2>&1 || true

    local pub_container_path="/repo/executables/$(basename "$pub_exe")"
    if [ ! -f "$REPO_ROOT/executables/$(basename "$pub_exe")" ] && [ -f "$SCRIPT_DIR/executables/$(basename "$pub_exe")" ]; then
        pub_container_path="/benchmarking/executables/$(basename "$pub_exe")"
    fi
    local sub_container_path="/repo/executables/$(basename "$sub_exe")"
    if [ ! -f "$REPO_ROOT/executables/$(basename "$sub_exe")" ] && [ -f "$SCRIPT_DIR/executables/$(basename "$sub_exe")" ]; then
        sub_container_path="/benchmarking/executables/$(basename "$sub_exe")"
    fi

    # Run Docker container:
    #   /repo  = $REPO_ROOT read-only (scripts, Python files, executables)
    #   /benchmarking = $SCRIPT_DIR read-only
    #   /workspace = work_dir read-write (per-pair output XML files)
    docker run --rm \
        --network "$pair_net" \
        --cap-add=NET_ADMIN \
        --cap-add=NET_RAW \
        --user "$(id -u):$(id -g)" \
        -e PYTHONDONTWRITEBYTECODE=1 \
        -v "${REPO_ROOT}:/repo:ro" \
        -v "${SCRIPT_DIR}:/benchmarking:ro" \
        -v "${work_dir}:/workspace" \
        -w /workspace \
        "$IMAGE_NAME" \
        /bin/bash -c "python3 /repo/interoperability_report.py \
            -P \"$pub_container_path\" \
            -S \"$sub_container_path\" \
            -o /workspace/$output_xml \
            $extra_args" \
        > "$log_file" 2>&1
    local exit_code=$?

    # Clean up dedicated Docker network
    docker network rm "$pair_net" >/dev/null 2>&1 || true

    if [ $exit_code -eq 0 ]; then
        echo "  [PASS] [$idx/$TOTAL] $pair_label"
    else
        echo "  [FAIL] [$idx/$TOTAL] $pair_label (exit=$exit_code) - log: .parallel_logs/${pair_label}.log"
    fi

    # Copy XML report to SCRIPT_DIR
    if [ -f "$work_dir/$output_xml" ]; then
        cp "$work_dir/$output_xml" "$SCRIPT_DIR/$output_xml"
    fi
}

# -- Parallel execution with throttling ---------------------------------------
RUNNING_PIDS=()

cleanup_parallel() {
    echo ""
    echo "==> Interrupted by user. Terminating running containers and removing temporary networks..."
    for pid in "${RUNNING_PIDS[@]+"${RUNNING_PIDS[@]}"}"; do
        kill "$pid" 2>/dev/null || true
    done
    docker network ls --filter "name=dds_net_" -q | xargs -r docker network rm >/dev/null 2>&1 || true
    rm -rf "$WORK_ROOT" 2>/dev/null || true
    exit 1
}
trap cleanup_parallel INT TERM

wait_for_slot() {
    # Wait while MAX_JOBS slots are occupied
    while true; do
        local alive=()
        for pid in "${RUNNING_PIDS[@]+"${RUNNING_PIDS[@]}"}"; do
            kill -0 "$pid" 2>/dev/null && alive+=("$pid")
        done
        RUNNING_PIDS=("${alive[@]+"${alive[@]}"}")
        [ ${#RUNNING_PIDS[@]} -lt "$MAX_JOBS" ] && break
        sleep 0.5
    done
}

START_TIME=$(date +%s)

for i in "${!PAIRS_PUB[@]}"; do
    wait_for_slot
    idx=$((i + 1))
    run_pair "$idx" "${PAIRS_PUB[$i]}" "${PAIRS_SUB[$i]}" &
    RUNNING_PIDS+=("$!")
done

# Wait for all remaining background processes
wait

# -- Clean up temporary work-dirs ---------------------------------------------
rm -rf "$WORK_ROOT"

# -- Generate final reports ---------------------------------------------------
ELAPSED=$(( $(date +%s) - START_TIME ))
echo ""
echo "==> [3] All pairs completed in ${ELAPSED}s. Generating final reports..."

shopt -s nullglob
found_xmls=("$SCRIPT_DIR"/junit_report-*.xml)
shopt -u nullglob

if [ ${#found_xmls[@]} -eq 0 ]; then
    echo "ERROR: No JUnit XML reports were generated! Check logs in $LOG_DIR/"
    exit 1
fi

docker run --rm \
    --user "$(id -u):$(id -g)" \
    -e PYTHONDONTWRITEBYTECODE=1 \
    -v "$REPO_ROOT:/workspace" \
    -v "$SCRIPT_DIR:/benchmarking" \
    -w /benchmarking \
    "$IMAGE_NAME" \
    /bin/bash -c "/benchmarking/generate_reports.sh"

echo ""
echo "==> [4] Done! Generated reports in $SCRIPT_DIR:"
ls -lh "$SCRIPT_DIR"/junit_interoperability_report.xml \
        "$SCRIPT_DIR"/interoperability_report.xlsx \
        "$SCRIPT_DIR"/index.html 2>/dev/null || true
echo ""
echo "    Logs for individual pairs: $LOG_DIR/"
