#!/bin/bash
set -euo pipefail
PROJECT_ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_DIR=$(mktemp -d /tmp/mac-voice-mix-tests.XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT
cd "$PROJECT_ROOT"
xcrun clang++ -std=c++17 -fobjc-arc -mmacosx-version-min=14.4 -Wno-deprecated-declarations tests/native-render.mm -framework CoreAudio -framework Foundation -framework AppKit -framework AudioToolbox -o "$TEST_DIR/render"
"$TEST_DIR/render"
xcrun clang++ -std=c++17 -fobjc-arc -mmacosx-version-min=14.4 -Wno-deprecated-declarations -dynamiclib native/macos/audio.mm -framework CoreAudio -framework Foundation -framework AppKit -framework AudioToolbox -o "$TEST_DIR/native.dylib"
python3 scripts/native-smoke.py "$TEST_DIR/native.dylib" "$@"
