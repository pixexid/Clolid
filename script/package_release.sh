#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")"
APP_NAME="Clolid"
RELEASE_DIR="$ROOT_DIR/releases"
ARCHIVE_PATH="$RELEASE_DIR/$APP_NAME-$VERSION-macOS.zip"

cd "$ROOT_DIR"

./script/build_and_run.sh --bundle

mkdir -p "$RELEASE_DIR"
rm -f "$ARCHIVE_PATH"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$ROOT_DIR/dist/$APP_NAME.app" "$ARCHIVE_PATH"

echo "$ARCHIVE_PATH"
