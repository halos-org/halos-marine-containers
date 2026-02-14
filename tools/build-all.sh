#!/bin/bash
# Build all packages (marine-container-store + container apps)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${REPO_ROOT}/build"

echo "Building all marine packages..."
echo "Repository root: $REPO_ROOT"
echo "Build directory: $BUILD_DIR"

# Clean build directory
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Build marine-container-store package
echo ""
echo "=== Building marine-container-store package ==="
cd "${REPO_ROOT}/store"
dpkg-buildpackage -us -uc -b
mv ../marine-container-store_*.deb "$BUILD_DIR/"
mv ../marine-container-store_*.buildinfo "$BUILD_DIR/" 2>/dev/null || true
mv ../marine-container-store_*.changes "$BUILD_DIR/" 2>/dev/null || true

# Clean up intermediate files
cd "$REPO_ROOT"
rm -f marine-container-store_*.deb marine-container-store_*.buildinfo marine-container-store_*.changes

# Build container app packages using container-packaging-tools
if command -v uvx >/dev/null 2>&1; then
    echo ""
    echo "=== Building container app packages ==="

    # Determine tools source: local path, git ref, or default
    TOOLS_PATH="${CONTAINER_TOOLS_PATH:-}"
    TOOLS_REF="${CONTAINER_TOOLS_REF:-}"
    if [ -n "$TOOLS_PATH" ]; then
        TOOLS_SOURCE="$TOOLS_PATH"
        echo "Using local container-packaging-tools from: $TOOLS_PATH"
    elif [ -n "$TOOLS_REF" ]; then
        TOOLS_SOURCE="git+https://github.com/halos-org/container-packaging-tools.git@${TOOLS_REF}"
        echo "Using container-packaging-tools ref: $TOOLS_REF"
    else
        TOOLS_SOURCE="git+https://github.com/halos-org/container-packaging-tools.git"
        echo "Using container-packaging-tools from main branch"
    fi

    for app_dir in "${REPO_ROOT}/apps"/*; do
        if [ -d "$app_dir" ]; then
            app_name=$(basename "$app_dir")
            echo "Building package for: $app_name"
            if ! uvx --from "$TOOLS_SOURCE" \
                     generate-container-packages -o "$BUILD_DIR" --prefix marine "$app_dir"; then
                echo "ERROR: Failed to build package for $app_name" >&2
                exit 1
            fi
        fi
    done
else
    echo ""
    echo "WARNING: uvx not installed"
    echo "Install with: pip install uv"
    echo "Skipping container app package generation"
fi

# List built packages
echo ""
echo "=== Built packages ==="
ls -lh "$BUILD_DIR"/*.deb 2>/dev/null || echo "No .deb files found"

echo ""
echo "Build complete! Packages are in: $BUILD_DIR"
