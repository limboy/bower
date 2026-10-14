#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bower-youtube-url.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

xcrun swiftc -swift-version 6 -parse-as-library \
  "$ROOT_DIR/Bower/YouTube/YouTubeURL.swift" \
  "$ROOT_DIR/tests/YouTubeURLTests.swift" \
  -module-cache-path "$TEST_DIR/module-cache" \
  -o "$TEST_DIR/youtube-url-tests"
"$TEST_DIR/youtube-url-tests"

# Preserve the original 52-case regression suite as a compatibility baseline.
cp "$ROOT_DIR/tests/LegacyYouTubeURLTests.swift" "$TEST_DIR/main.swift"
xcrun swiftc -swift-version 6 \
  "$ROOT_DIR/Bower/YouTube/YouTubeURL.swift" \
  "$TEST_DIR/main.swift" \
  -module-cache-path "$TEST_DIR/module-cache" \
  -o "$TEST_DIR/legacy-youtube-url-tests"
"$TEST_DIR/legacy-youtube-url-tests"
