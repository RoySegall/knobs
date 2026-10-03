#!/usr/bin/env bash
# Regenerates the plugin registry and the Xcode project. Run after cloning.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/generate-registry.sh
xcodegen generate --quiet
