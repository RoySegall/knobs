#!/usr/bin/env bash
# Builds knobs-render and runs it. Usage: scripts/render.sh [--derived dir] <knobs-render args...>
# Example: scripts/render.sh in.heic out.jpg --size 1200 dehaze.amount=60
set -euo pipefail
cd "$(dirname "$0")/.."
derived="build/DerivedData"
if [[ "${1:-}" == "--derived" ]]; then derived="$2"; shift 2; fi
xcodebuild build -scheme Knobs -destination 'platform=macOS,arch=arm64' -derivedDataPath "$derived" -quiet >&2
"$derived/Build/Products/Debug/knobs-render" "$@"
