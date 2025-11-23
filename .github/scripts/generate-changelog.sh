#!/bin/bash
set -euo pipefail

# This script is called by the shared workflow but intentionally does NOT
# generate/overwrite the changelog. The marine-container-store package
# uses its committed store/debian/changelog as the canonical version source.
#
# To release a new store package version:
# 1. Update store/debian/changelog with new version and changes
# 2. Commit and push to main
#
# The VERSION file is a meta/bundle version for git tags only,
# not used for the store package version.

echo "Using committed store/debian/changelog (not generating)"
echo "Store package version: $(head -1 store/debian/changelog | grep -oP '\(\K[^)]+' || echo 'unknown')"
