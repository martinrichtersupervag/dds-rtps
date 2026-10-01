#!/bin/bash
# ==============================================================================
# run_benchmark.sh – opakovaně spouští run_tests_parallel.sh a přejmenovvá
#                    výsledné reporty tak, aby obsahovaly datum, čas, počet
#                    paralelních procesů a dobu trvání.
#
# Formát výsledného názvu:
#   junit_interoperability_report-DDMMYYYY-HHMM-parN-SECONDSsec.xml
#   interoperability_report-DDMMYYYY-HHMM-parN-SECONDSsec.xlsx
#   index-DDMMYYYY-HHMM-parN-SECONDSsec.html
#
# Použití:
#   ./run_benchmark.sh [--runs N]
#   ./run_benchmark.sh           # výchozí počet běhů: 8
#   ./run_benchmark.sh --runs 3  # spustit 3× místo 8
#
# Skript spustí:
#   N iterací s --jobs 16   (FÁZE 1)
#   N iterací s --jobs 4    (FÁZE 2)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

RUNS=8   # výchozí počet opakovní (pro každou skupinu --jobs)

# ── parsování argumentů ──────────────────────────────────────────
usage() {
    echo "Použití: $0 [--runs N]"
    echo ""
    echo "  --runs N   Počet opakování pro každou konfiguraci --jobs (default: $RUNS)"
    echo ""
    echo "Skript spustí N iterací s --jobs 16 a N iterací s --jobs 4."
    echo "Výsledné soubory jsou přejmenovány a zůstávají v adresáři repozitáře."
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --runs|-r)  RUNS="$2"; shift 2 ;;
        --help|-h)  usage ;;
        *) echo "Neznámý argument: $1"; usage ;;
    esac
done

if ! [[ "$RUNS" =~ ^[0-9]+$ ]] || [ "$RUNS" -lt 1 ]; then
    echo "ERROR: --runs musí být kladné celé číslo (zadáno: '$RUNS')"
    exit 1
fi

# ── přejmenování bez přepsání ─────────────
# Přesune $1 na $2; pokud $2 již existuje, přidá _2, _3, …
safe_rename() {
    local src="$1"
    local dst="$2"
    if [ ! -f "$src" ]; then
        echo "  VAROVNÍ: '$src' neexistuje, přeskakuji."
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
        echo "  -> $(basename "${base}_${n}.${ext}") (kolize: přidán suffix _${n})"
    fi
}

# ── jeden run + přejmenování výstup ─────────────────────────────────────────
run_once() {
    local jobs="$1"
    local run_idx="$2"
    local total_runs="$3"

    local dt
    dt=$(date +%d%m%Y-%H%M)   # DDMMYYYY-HHMM v okamžiku startu

    echo ""
    echo "================================================================"
    echo "  Behu ${run_idx}/${total_runs}  (--jobs ${jobs})   [${dt}]"
    echo "================================================================"

    local t_start
    t_start=$(date +%s)

    bash "$SCRIPT_DIR/run_tests_parallel.sh" --jobs "$jobs"

    local t_end
    t_end=$(date +%s)
    local elapsed=$(( t_end - t_start ))

    echo ""
    echo "  Beh dokoncen za ${elapsed}s."

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

# ── smyčka hlavní ─────────────────────────
echo ""
echo "=================================================================="
echo "  run_benchmark.sh – benchmark test suite"
echo "  Pocet behu: ${RUNS}x s --jobs 16  +  ${RUNS}x s --jobs 4"
echo "=================================================================="

GLOBAL_START=$(date +%s)

echo ""
echo "------------------------------------------------------------------"
echo "  FAZE 1: ${RUNS} opakovani s --jobs 16"
echo "------------------------------------------------------------------"
for i in $(seq 1 "$RUNS"); do
    run_once 16 "$i" "$RUNS"
done

echo ""
echo "------------------------------------------------------------------"
echo "  FAZE 2: ${RUNS} opakovani s --jobs 4"
echo "------------------------------------------------------------------"
for i in $(seq 1 "$RUNS"); do
    run_once 4 "$i" "$RUNS"
done

GLOBAL_END=$(date +%s)
GLOBAL_ELAPSED=$(( GLOBAL_END - GLOBAL_START ))
TOTAL_RUNS=$(( RUNS * 2 ))

echo ""
echo "=================================================================="
echo "  Celkovy benchmark dokoncen za ${GLOBAL_ELAPSED}s"
echo "  Celkem behu: ${TOTAL_RUNS}  (${RUNS}x par16 + ${RUNS}x par4)"
echo "=================================================================="
echo ""
echo "Vysledne soubory v $SCRIPT_DIR:"
ls -1 \
    "$SCRIPT_DIR"/junit_interoperability_report-*.xml \
    "$SCRIPT_DIR"/interoperability_report-*.xlsx \
    "$SCRIPT_DIR"/index-*.html 2>/dev/null | sort \
    || echo "  (zadne soubory nenalezeny)"
echo ""
