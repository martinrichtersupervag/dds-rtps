#!/bin/bash
# ==============================================================================
# Run DDS-RTPS interoperability tests in PARALLEL Docker containers
#
# Analogie GitHub Actions matrix – každý pár (publisher × subscriber) běží
# v samostatném Docker kontejneru souběžně.
#
# Workflow:
#   1. Archivuje stávající reporty z hostu do archive_reports/
#   2. Spustí N Docker kontejnerů (default: 8) souběžně
#      – každý dostane vlastní izolovaný work-dir, aby si nepřepisovaly soubory
#   3. Shromáždí všechny XML reporty do $SCRIPT_DIR
#   4. Vygeneruje finální XML, XLSX a HTML reporty
#
# Použití:
#   ./run_tests_parallel.sh [--jobs N] [--publishers p1,p2] [--subscribers s1,s2]
#   ./run_tests_parallel.sh                      # vše × vše, 8 souběhů
#   ./run_tests_parallel.sh --jobs 4             # omez na 4 souběhy
#   ./run_tests_parallel.sh --publishers connext_dds --subscribers dust_dds,eclipse_cyclone
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

IMAGE_NAME="dds-rtps-tester"
MAX_JOBS=8          # výchozí počet souběžných Docker kontejnerů

# ── argumentů parsování ─────────────────
FILTER_PUBLISHERS=""
FILTER_SUBSCRIBERS=""

usage() {
    echo "Použití: $0 [--jobs N] [--publishers p1,p2,...] [--subscribers s1,s2,...]"
    echo ""
    echo "  --jobs N           Maximální počet souběžných Docker kontejnerů (default: $MAX_JOBS)"
    echo "  --publishers LIST  Filtr publisherů (čárkou oddělené části názvu exe, nebo 'all')"
    echo "  --subscribers LIST Filtr subscriberů (čárkou oddělené sti názvu exe, nebo 'all')"
    echo ""
    echo "Příklady:"
    echo "  $0                                                   # vše × vše, 8 souběhů"
    echo "  $0 --jobs 4                                          # omez na 4 souběhy"
    echo "  $0 --publishers connext_dds --subscribers dust_dds   # jen 1 pár"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --jobs|-j)        MAX_JOBS="$2"; shift 2 ;;
        --publishers|-p)  FILTER_PUBLISHERS="$2"; shift 2 ;;
        --subscribers|-s) FILTER_SUBSCRIBERS="$2"; shift 2 ;;
        --help|-h)        usage ;;
        *) echo "Neznámý argument: $1"; usage ;;
    esac
done

# ── Docker kontrola ─────────────────────────────────
if ! command -v docker &>/dev/null; then
    echo "ERROR: 'docker' příkaz nenalezen. Nainstalujte Docker."
    exit 1
fi

# ── sestav image Docker ─────────────────────────
if [[ "$(docker images -q "$IMAGE_NAME" 2>/dev/null)" == "" ]] || \
   ! docker run --rm "$IMAGE_NAME" which tshark &>/dev/null; then
    echo "==> Sestavuji Docker image: $IMAGE_NAME..."
    docker build -t "$IMAGE_NAME" .
fi

# ── archivace reportů předchozích ─────
archive_dir="$SCRIPT_DIR/archive_reports"
shopt -s nullglob
old_reports=("$SCRIPT_DIR"/*.xml "$SCRIPT_DIR"/*.xlsx "$SCRIPT_DIR"/index.html \
             "$SCRIPT_DIR"/discovery_report*.json "$SCRIPT_DIR"/discovery_summary.json \
             "$SCRIPT_DIR"/timestamp)
if [ ${#old_reports[@]} -gt 0 ]; then
    echo "==> [1] Archivuji předchozí reporty do archive_reports/..."
    mkdir -p "$archive_dir"
    mv "${old_reports[@]}" "$archive_dir/" 2>/dev/null || true
fi
shopt -u nullglob
rm -f "$SCRIPT_DIR/timestamp"

# ── zjisti executables dostupné ──────
mapfile -t ALL_EXES < <(find "$SCRIPT_DIR/executables" -type f -name '*shape_main_linux' | sort)

if [ ${#ALL_EXES[@]} -eq 0 ]; then
    echo "ERROR: Žádné *shape_main_linux executables nenalezeny v $SCRIPT_DIR/executables/"
    echo "       Rozbalte je nejprve (viz README)."
    exit 1
fi

# Filtrování podle --publishers / --subscribers
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
    # Exportuj pes nameref – kompatibilní s bash 4.3+
    eval "${result_var}=($(printf '"%s" ' "${result[@]+"${result[@]}"}") )"
}

filter_exes PUBLISHERS "$FILTER_PUBLISHERS"
filter_exes SUBSCRIBERS "$FILTER_SUBSCRIBERS"

if [ ${#PUBLISHERS[@]} -eq 0 ]; then
    echo "ERROR: Žádný publisher neodpovídá filtru: '$FILTER_PUBLISHERS'"
    exit 1
fi
if [ ${#SUBSCRIBERS[@]} -eq 0 ]; then
    echo "ERROR: Žádný subscriber neodpovídá filtru: '$FILTER_SUBSCRIBERS'"
    exit 1
fi

# ── společné nastavení ─────────────
WORK_ROOT="$SCRIPT_DIR/.parallel_workdirs"
LOG_DIR="$SCRIPT_DIR/.parallel_logs"
rm -rf "$WORK_ROOT" "$LOG_DIR"
mkdir -p "$WORK_ROOT" "$LOG_DIR"

# ── sestav seznam párů všech ──────────────────────────────
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
echo "==> [2] Spouštím $TOTAL párů testů (max $MAX_JOBS souběžně)..."
pub_names=$(printf '%s ' "${PUBLISHERS[@]}" | xargs -n1 basename | sed 's/_shape_main_linux//' | tr '\n' ' ')
sub_names=$(printf '%s ' "${SUBSCRIBERS[@]}" | xargs -n1 basename | sed 's/_shape_main_linux//' | tr '\n' ' ')
echo "        Publisheři (${#PUBLISHERS[@]}): $pub_names"
echo "        Subscribeři (${#SUBSCRIBERS[@]}): $sub_names"
echo ""

# ── funkce pro spuštění jednoho páru ──────────────────────────────────────────
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

    # Izolovaný work-dir pro výstupy tohoto páru
    local work_dir="$WORK_ROOT/${pair_label}"
    mkdir -p "$work_dir"

    local output_xml="junit_report-${pair_label}.xml"
    local extra_args=""
    if [[ "${sub_name,,}" == *opendds* && "${pub_name,,}" == *connext_dds* ]]; then
        extra_args="--periodic-announcement 5000"
    fi

    # Spusť Docker kontejner:
    #   /repo  = $SCRIPT_DIR read-only (skripty, Python soubory, executables)
    #   /workspace = work_dir read-write (výstupní XML soubory per-pár)
    docker run --rm \
        --cap-add=NET_ADMIN \
        --cap-add=NET_RAW \
        --user "$(id -u):$(id -g)" \
        -e PYTHONDONTWRITEBYTECODE=1 \
        -v "${SCRIPT_DIR}:/repo:ro" \
        -v "${work_dir}:/workspace" \
        -w /workspace \
        "$IMAGE_NAME" \
        /bin/bash -c "python3 /repo/interoperability_report.py \
            -P /repo/executables/$(basename "$pub_exe") \
            -S /repo/executables/$(basename "$sub_exe") \
            -o /workspace/$output_xml \
            $extra_args" \
        > "$log_file" 2>&1
    local exit_code=$?

    if [ $exit_code -eq 0 ]; then
        echo "  ✓ [$idx/$TOTAL] $pair_label"
    else
        echo "  ✗ [$idx/$TOTAL] $pair_label (exit=$exit_code) — log: .parallel_logs/${pair_label}.log"
    fi

    # Zkopíruj XML report do SCRIPT_DIR
    if [ -f "$work_dir/$output_xml" ]; then
        cp "$work_dir/$output_xml" "$SCRIPT_DIR/$output_xml"
    fi
}

# ── paralelní spuštění throttlingem s 
RUNNING_PIDS=()

wait_for_slot() {
    # Čekej, dokud je obsazeno MAX_JOBS slotů
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

# Počkej na všechny zbývající procesy
wait

# ── úklid dočasných work-dirů ──
rm -rf "$WORK_ROOT"

# ── generuj reporty finální ─
ELAPSED=$(( $(date +%s) - START_TIME ))
echo ""
echo "==> [3] Všechny páry dokončeny za ${ELAPSED}s. Generuji finální reporty..."

shopt -s nullglob
found_xmls=("$SCRIPT_DIR"/junit_report-*.xml)
shopt -u nullglob

if [ ${#found_xmls[@]} -eq 0 ]; then
    echo "ERROR: Žádné JUnit XML reporty nebyly vygenerovány! Zkontrolujte logy v $LOG_DIR/"
    exit 1
fi

docker run --rm \
    --user "$(id -u):$(id -g)" \
    -e PYTHONDONTWRITEBYTECODE=1 \
    -v "$SCRIPT_DIR:/workspace" \
    -w /workspace \
    "$IMAGE_NAME" \
    /bin/bash -c "./generate_reports.sh"

echo ""
echo "==> [4] Hotovo! Vygenerované reporty v $SCRIPT_DIR:"
ls -lh "$SCRIPT_DIR"/junit_interoperability_report.xml \
        "$SCRIPT_DIR"/interoperability_report.xlsx \
        "$SCRIPT_DIR"/index.html 2>/dev/null || true
echo ""
echo "    Logy jednotlivých párů: $LOG_DIR/"
