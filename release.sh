#!/bin/bash
# Build the free costdoctor command for both Apple silicon and Intel, sign it with the Developer ID certificate,
# have Apple notarize it, and zip it into dist/ for a GitHub release. Prints the SHA-256 for the Homebrew formula.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
VERSION="$(sed -n 's/^let version = "\(.*\)"/\1/p' Sources/costdoctor/main.swift)"
[[ -n "$VERSION" ]] || { echo "FAIL: could not read the version from main.swift"; exit 1; }
swift build -c release --arch arm64 --arch x86_64
BIN="$ROOT/.build/apple/Products/Release/costdoctor"
IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
[[ -n "$IDENTITY" ]] || { echo "FAIL: no Developer ID Application certificate on this Mac"; exit 1; }
rm -rf dist && mkdir -p dist/stage
cp "$BIN" dist/stage/costdoctor
codesign --force --options runtime --timestamp --sign "$IDENTITY" dist/stage/costdoctor
ZIP="dist/costdoctor-$VERSION-macos.zip"
(cd dist/stage && zip -q "../$(basename "$ZIP")" costdoctor)
xcrun notarytool submit "$ZIP" --keychain-profile costdoctor-notary --wait
lipo -archs dist/stage/costdoctor
echo "Built $ZIP"
shasum -a 256 "$ZIP"
