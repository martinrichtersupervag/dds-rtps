#!/bin/bash
# ==============================================================================
# Helper script to run DDS-RTPS interoperability tests inside an isolated Docker container
# ==============================================================================
set -e

IMAGE_NAME="dds-rtps-tester"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cd "$SCRIPT_DIR"

# Check if Docker is installed
if ! command -v docker &> /dev/null; then
    echo "ERROR: 'docker' command not found. Please install Docker first."
    exit 1
fi

# Build Docker image if requested or if it does not exist
if [[ "$1" == "--build" ]] || [[ "$(docker images -q "$IMAGE_NAME" 2> /dev/null)" == "" ]]; then
    echo "==> Building Docker image: $IMAGE_NAME..."
    docker build -t "$IMAGE_NAME" .
    if [[ "$1" == "--build" ]]; then
        shift
    fi
fi

# Archive previous test results on host if present
archive_dir="$SCRIPT_DIR/archive_reports"
shopt -s nullglob
old_reports=("$SCRIPT_DIR"/*.xml "$SCRIPT_DIR"/*.xlsx "$SCRIPT_DIR"/index.html)
if [ ${#old_reports[@]} -gt 0 ]; then
    echo "==> Archiving previous test reports to archive_reports/..."
    mkdir -p "$archive_dir"
    mv "${old_reports[@]}" "$archive_dir/" 2>/dev/null || true
fi
shopt -u nullglob

echo "==> Running in isolated Docker container (bridge network, contained multicast)..."

# Run container:
# - Mount current directory to /workspace so test reports are saved to host
# - Default bridge network isolates multicast discovery (239.255.0.1) from local LAN
# - Passes any additional arguments directly to the container command
if [ $# -eq 0 ]; then
    docker run --rm -it \
        -v "$SCRIPT_DIR:/workspace" \
        -w /workspace \
        "$IMAGE_NAME" \
        /bin/bash
else
    docker run --rm -it \
        -v "$SCRIPT_DIR:/workspace" \
        -w /workspace \
        "$IMAGE_NAME" \
        "$@"
fi
