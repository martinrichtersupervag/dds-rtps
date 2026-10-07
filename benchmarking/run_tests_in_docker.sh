#!/bin/bash
# ==============================================================================
# Run DDS-RTPS interoperability tests inside an isolated Docker container
# Workflow:
#   1. Archives any existing reports from host into archive_reports/
#   2. Starts Docker container
#   3. Runs the test suite inside the container
#   4. Generates XML, XLSX, and HTML reports
#   5. Exits and cleans up Docker container automatically
# ==============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

IMAGE_NAME="dds-rtps-tester"

# Check if Docker is installed
if ! command -v docker &> /dev/null; then
    echo "ERROR: 'docker' command not found. Please install Docker first."
    exit 1
fi

# 1. Archive previous test reports from host if present
archive_dir="$SCRIPT_DIR/archive_reports"
shopt -s nullglob
old_reports=("$REPO_ROOT"/*.xml "$REPO_ROOT"/*.xlsx "$REPO_ROOT"/index.html "$REPO_ROOT"/discovery_report*.json "$REPO_ROOT"/discovery_summary.json "$REPO_ROOT"/timestamp \
             "$SCRIPT_DIR"/*.xml "$SCRIPT_DIR"/*.xlsx "$SCRIPT_DIR"/index.html "$SCRIPT_DIR"/discovery_report*.json "$SCRIPT_DIR"/discovery_summary.json "$SCRIPT_DIR"/timestamp)
if [ ${#old_reports[@]} -gt 0 ]; then
    echo "==> [1/4] Archiving previous test reports to archive_reports/..."
    mkdir -p "$archive_dir"
    mv "${old_reports[@]}" "$archive_dir/" 2>/dev/null || true
fi
shopt -u nullglob
rm -f "$REPO_ROOT/timestamp" "$SCRIPT_DIR/timestamp"

# 2. Build Docker image if not present or missing tshark
if [[ "$(docker images -q "$IMAGE_NAME" 2> /dev/null)" == "" ]] || ! docker run --rm "$IMAGE_NAME" which tshark &> /dev/null; then
    echo "==> [2/4] Building Docker image: $IMAGE_NAME..."
    docker build -t "$IMAGE_NAME" -f "$SCRIPT_DIR/Dockerfile" "$REPO_ROOT"
fi

# Determine test arguments: default to all executables under ./executables
if [ $# -eq 0 ]; then
    TEST_CMD="./discovery/run_tests.sh -i ./executables"
else
    TEST_CMD="./discovery/run_tests.sh $*"
fi

# Create dedicated isolated Docker network to prevent cross-container multicast leakage
NET_ID=$(tr -dc 'a-z0-9' < /proc/sys/kernel/random/uuid 2>/dev/null | head -c 8 || echo $RANDOM)
DOCKER_NET="dds_net_${$}_${NET_ID}"
docker network create "$DOCKER_NET" >/dev/null

cleanup_network() {
    docker network rm "$DOCKER_NET" >/dev/null 2>&1 || true
}
trap cleanup_network EXIT INT TERM

echo "==> [3/4] Running tests inside Docker container ($IMAGE_NAME, network: $DOCKER_NET)..."
echo "    Command: $TEST_CMD"

# 3. Run container, execute tests, generate reports, and automatically terminate container (--rm)
#    --cap-add=NET_ADMIN and NET_RAW allow tshark to capture discovery traffic inside the container
docker run --rm \
    --network "$DOCKER_NET" \
    --cap-add=NET_ADMIN \
    --cap-add=NET_RAW \
    --user "$(id -u):$(id -g)" \
    -e PYTHONDONTWRITEBYTECODE=1 \
    -v "$REPO_ROOT:/workspace" \
    -w /workspace \
    "$IMAGE_NAME" \
    /bin/bash -c "$TEST_CMD; ./benchmarking/generate_reports.sh"

echo ""
echo "==> [4/4] Docker container finished and closed."
echo "==> Generated reports in $REPO_ROOT:"
ls -lh "$REPO_ROOT"/junit_interoperability_report.xml "$REPO_ROOT"/junit_discovery_report*.xml "$REPO_ROOT"/discovery_report*.json "$REPO_ROOT"/interoperability_report.xlsx "$REPO_ROOT"/index.html 2>/dev/null || true
