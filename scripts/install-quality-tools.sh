#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .tools
task_temp=$(mktemp -d)
trap 'rm -rf "$task_temp"' EXIT

install_tool() {
    local name="$1" url="$2" checksum="$3"
    curl --fail --location --retry 3 "$url" --output "$task_temp/$name.zip"
    printf '%s  %s\n' "$checksum" "$task_temp/$name.zip" | shasum -a 256 --check
    mkdir -p "$task_temp/$name"
    unzip -q "$task_temp/$name.zip" -d "$task_temp/$name"
    cp "$task_temp/$name/$name" ".tools/$name"
    chmod +x ".tools/$name"
}

install_tool swiftformat \
    https://github.com/nicklockwood/SwiftFormat/releases/download/0.58.7/swiftformat.zip \
    7e43f8e14e2089eeb83d6958ce162ffa90c9330f3f309ca054693614b2b1b241
install_tool swiftlint \
    https://github.com/realm/SwiftLint/releases/download/0.62.2/portable_swiftlint.zip \
    79625bece2716395d955d34a5993e6c948ef57d0256abe5538aaab82f2ad6b68
.tools/swiftformat --version
.tools/swiftlint version

