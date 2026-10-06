#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Work in current directory unless no xml files here and xml files exist in SCRIPT_DIR
shopt -s nullglob
current_xmls=(*.xml)
shopt -u nullglob

if [ ${#current_xmls[@]} -eq 0 ] && [ -d "$SCRIPT_DIR" ]; then
    shopt -s nullglob
    bench_xmls=("$SCRIPT_DIR"/*.xml)
    shopt -u nullglob
    if [ ${#bench_xmls[@]} -gt 0 ]; then
        cd "$SCRIPT_DIR"
    fi
fi

# Remove previously merged XML report and Excel report to avoid conflict
rm -f junit_interoperability_report.xml interoperability_report.xlsx

echo "[1/3] Merging XML reports into junit_interoperability_report.xml..."
reports_to_merge=()
shopt -s nullglob
for f in *.xml; do
    if [[ "$f" != "junit_interoperability_report.xml" && "$f" != junit_discovery_report* ]]; then
        reports_to_merge+=("$f")
    fi
done
shopt -u nullglob

if [ ${#reports_to_merge[@]} -eq 0 ]; then
    echo "ERROR: No JUnit XML test reports found to merge in $(pwd)!" >&2
    echo "Please check that upstream test execution jobs ran and produced test reports." >&2
    exit 1
fi

python3 -m junitparser merge "${reports_to_merge[@]}" junit_interoperability_report.xml

RUNNER_ARG=""
if [ -n "$1" ]; then
    RUNNER_ARG="--runner $1"
elif [ -f runner_env ]; then
    RUNNER_ARG="--runner $(cat runner_env | tr -d '\r\n')"
elif [ -f "$REPO_ROOT/runner_env" ]; then
    RUNNER_ARG="--runner $(cat "$REPO_ROOT/runner_env" | tr -d '\r\n')"
elif [ -n "$RUNNER_ENVIRONMENT" ]; then
    RUNNER_ARG="--runner $RUNNER_ENVIRONMENT"
fi

GEN_XLSX_SCRIPT="generate_xlsx_report.py"
if [ ! -f "$GEN_XLSX_SCRIPT" ]; then
    if [ -f "$REPO_ROOT/generate_xlsx_report.py" ]; then
        GEN_XLSX_SCRIPT="$REPO_ROOT/generate_xlsx_report.py"
    elif [ -f "/workspace/generate_xlsx_report.py" ]; then
        GEN_XLSX_SCRIPT="/workspace/generate_xlsx_report.py"
    fi
fi

echo "[2/3] Generating Excel report interoperability_report.xlsx using $GEN_XLSX_SCRIPT..."
python3 "$GEN_XLSX_SCRIPT" --input junit_interoperability_report.xml --output interoperability_report.xlsx $RUNNER_ARG

echo "[3/3] Generating HTML report index.html..."
if command -v xunit-viewer &> /dev/null; then
    xunit-viewer --results=./junit_interoperability_report.xml --output=./index.html
else
    npx -y xunit-viewer --results=./junit_interoperability_report.xml --output=./index.html
fi

echo "Done! Generated reports in $(pwd):"
ls -lh junit_interoperability_report.xml interoperability_report.xlsx index.html 2>/dev/null || true
