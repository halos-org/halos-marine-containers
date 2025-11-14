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
if command -v generate-container-packages >/dev/null 2>&1; then
    echo ""
    echo "=== Building container app packages ==="
    generate-container-packages "${REPO_ROOT}/apps" "$BUILD_DIR"
else
    echo ""
    echo "WARNING: container-packaging-tools not installed"
    echo "Install with: apt install container-packaging-tools"
    echo "Skipping container app package generation"
fi

# List built packages
echo ""
echo "=== Built packages ==="
ls -lh "$BUILD_DIR"/*.deb 2>/dev/null || echo "No .deb files found"

echo ""
echo "Build complete! Packages are in: $BUILD_DIR"
