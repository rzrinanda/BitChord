#!/usr/bin/env bash
# Build an unsigned Release iOS IPA locally on macOS (Apple Silicon).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-1.0.4}"

echo "==> [1/4] Building Shared KMP Framework (Release)..."
CONFIG=release ./scripts/build-shared-framework.sh

echo "==> [2/4] Building Native Core Framework (Rust)..."
./scripts/build-native-core.sh

echo "==> [3/4] Generating Xcode Project with XcodeGen..."
xcodegen generate --spec AppleApp/project.yml

echo "==> [4/4] Packaging Unsigned iOS IPA (v$VERSION)..."
./scripts/package-ios-ipa.sh "$VERSION" --output-dir "$ROOT/build/release" --overwrite

echo "Done! Your unsigned IPA is located in: $ROOT/build/release/"
