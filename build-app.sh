#!/bin/sh
set -eu
cache="${TMPDIR:-/tmp}/aula-swiftpm-cache"
CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/aula-clang-cache" \
  SWIFTPM_CUSTOM_CACHE_PATH="$cache" \
  swift build -c release --disable-sandbox --cache-path "$cache"
app="dist/AULA F75.app"
mkdir -p "$app/Contents/MacOS"
cp .build/release/AulaF75Mac "$app/Contents/MacOS/AulaF75Mac"
cp Resources/Info.plist "$app/Contents/Info.plist"
codesign --force --deep --sign - "$app"
echo "$app"
