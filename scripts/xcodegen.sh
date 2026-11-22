#!/bin/bash
# XcodeGen for CI without Homebrew (2026-11-22: `brew install xcodegen` took about three minutes
# in every job, and failed once on "Homebrew's files could not be checked"). A pinned release,
# checked against its SHA-256; Homebrew only when the download fails.
set -euo pipefail
VERSION=2.48.0
SHA=620c9f0dc10849f94728ab5df52d225ebab8187439dd6fee1925e59e80dff892
DIR="${RUNNER_TEMP:-/tmp}/xcodegen-$VERSION"
BIN="$DIR/xcodegen/bin/xcodegen"
if [ ! -x "$BIN" ]; then
  mkdir -p "$DIR"
  if curl -fsSL --retry 3 -o "$DIR/xcodegen.zip" "https://github.com/yonaskolb/XcodeGen/releases/download/$VERSION/xcodegen.zip" \
     && [ "$(shasum -a 256 "$DIR/xcodegen.zip" | cut -d' ' -f1)" = "$SHA" ]; then
    unzip -q -o "$DIR/xcodegen.zip" -d "$DIR"
  else
    echo "XcodeGen $VERSION could not be downloaded or did not match its checksum: Homebrew instead"
    HOMEBREW_NO_AUTO_UPDATE=1 brew install xcodegen
    BIN=xcodegen
  fi
fi
"$BIN" --version
"$BIN" generate "$@"
