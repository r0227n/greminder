#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product GreminderDesktop
APP_PATH="$PWD/Build/greminder.app"
# A case-insensitive volume otherwise retains the old directory spelling.
python3 - "$PWD/Build" <<'RENAME'
import pathlib, sys, uuid
root = pathlib.Path(sys.argv[1])
if root.exists():
    names = {item.name for item in root.iterdir()}
    if 'Greminder.app' in names and 'greminder.app' not in names:
        temporary = root / ('.greminder-rename-' + str(uuid.uuid4()) + '.app')
        (root / 'Greminder.app').rename(temporary)
        temporary.rename(root / 'greminder.app')
RENAME
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp .build/debug/GreminderDesktop "$APP_PATH/Contents/MacOS/greminder"
for bundle in .build/debug/*.bundle; do
    ditto "$bundle" "$APP_PATH/Contents/Resources/$(basename "$bundle")"
done
ditto Greminder/Resources/AppLocalizations "$APP_PATH/Contents/Resources"
python3 - "$APP_PATH" <<'PY'
import plistlib, pathlib, sys
destination = pathlib.Path(sys.argv[1]) / 'Contents' / 'Info.plist'
with destination.open('wb') as stream:
    plistlib.dump({'CFBundleExecutable': 'greminder', 'CFBundleName': 'greminder',
                  'CFBundleDisplayName': 'greminder',
                  'CFBundleIdentifier': 'com.example.greminder.preview',
                  'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1',
                  'CFBundleShortVersionString': '0.1.0', 'LSMinimumSystemVersion': '26.0',
                  'NSHighResolutionCapable': True, 'CFBundleLocalizations': ['en', 'ja'], 'CFBundleDevelopmentRegion': 'en',
                  'NSMicrophoneUsageDescription': '音声をこのデバイスで文字起こししてタスクを入力するためにマイクを使用します。'}, stream)
PY
codesign --force --deep --sign - "$APP_PATH"
print "Built: $APP_PATH"
