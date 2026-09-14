#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ ! -x .tools/swiftformat || ! -x .tools/swiftlint ]]; then
    echo "Run bash scripts/install-quality-tools.sh first." >&2
    exit 1
fi
[[ "$(.tools/swiftformat --version)" == "0.58.7" ]]
[[ "$(.tools/swiftlint version)" == "0.62.2" ]]
case "${1:-check}" in
    format) .tools/swiftformat Greminder Tests iOSTests Package.swift Packages/LocalLLM/Package.swift Packages/LocalLLM/Sources Packages/LocalLLM/Tests --cache ignore ;;
    check)
        python3 scripts/check-localizations.py
        .tools/swiftformat Greminder Tests iOSTests Package.swift Packages/LocalLLM/Package.swift Packages/LocalLLM/Sources Packages/LocalLLM/Tests --lint --cache ignore
        .tools/swiftlint lint --strict --no-cache
        ;;
    *) echo "Usage: bash scripts/quality.sh [check|format]" >&2; exit 2 ;;
esac
