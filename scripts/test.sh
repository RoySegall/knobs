#!/usr/bin/env bash
# Runs the unit tests. Usage: scripts/test.sh [derived-data-dir] [extra xcodebuild args...]
# Parallel checkouts must pass their own derived-data dir, or builds lock each other out.
set -euo pipefail
cd "$(dirname "$0")/.."
derived="${1:-build/DerivedData.noindex}"
shift || true
xcodebuild test -scheme Knobs -destination 'platform=macOS,arch=arm64' -derivedDataPath "$derived" -quiet "$@"
