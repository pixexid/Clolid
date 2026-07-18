#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Clolid"
BUNDLE_ID="com.pixexid.Clolid"
APP_VERSION="0.1.4"
APP_BUILD="5"
MIN_SYSTEM_VERSION="13.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"

cd "$ROOT_DIR"

PID_FILE="$HOME/Library/Caches/Clolid/caffeinate.pid"
if [ -f "$PID_FILE" ]; then
  read -r OLD_CAFFEINATE_PID OLD_CAFFEINATE_START_SECONDS _ <"$PID_FILE" || true
  OLD_CAFFEINATE_COMMAND="$(ps -ww -p "$OLD_CAFFEINATE_PID" -o args= 2>/dev/null | xargs || true)"
  OLD_CAFFEINATE_PARENT="$(ps -p "$OLD_CAFFEINATE_PID" -o ppid= 2>/dev/null | xargs || true)"
  CURRENT_CLOLID_PID="$(pgrep -x "$APP_NAME" | head -n 1 || true)"
  OLD_CAFFEINATE_START="$(ps -ww -p "$OLD_CAFFEINATE_PID" -o lstart= 2>/dev/null | xargs || true)"
  CURRENT_CAFFEINATE_START_SECONDS="$(
    LC_ALL=C date -j -f "%a %b %e %T %Y" "$OLD_CAFFEINATE_START" "+%s" 2>/dev/null || true
  )"
  case "$OLD_CAFFEINATE_COMMAND" in
    /usr/bin/caffeinate|/usr/bin/caffeinate\ *)
      if [ -n "$OLD_CAFFEINATE_START_SECONDS" ] &&
         [ "$CURRENT_CAFFEINATE_START_SECONDS" = "$OLD_CAFFEINATE_START_SECONDS" ]; then
        kill "$OLD_CAFFEINATE_PID" >/dev/null 2>&1 || true
      elif [ -z "$OLD_CAFFEINATE_START_SECONDS" ] &&
           [ -n "$CURRENT_CLOLID_PID" ] &&
           [ "$OLD_CAFFEINATE_PARENT" = "$CURRENT_CLOLID_PID" ]; then
        kill "$OLD_CAFFEINATE_PID" >/dev/null 2>&1 || true
      fi
      ;;
  esac
  rm -f "$PID_FILE"
fi

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

find "$ROOT_DIR/.build" -type d -name "Clolid_Clolid.bundle" -prune -exec rm -rf {} + 2>/dev/null || true
swift build
BUILD_BIN_PATH="$(swift build --show-bin-path)"
BUILD_BINARY="$BUILD_BIN_PATH/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

if [ -d "$BUILD_BIN_PATH/Clolid_Clolid.bundle" ]; then
  cp -R "$BUILD_BIN_PATH/Clolid_Clolid.bundle" "$APP_RESOURCES/"
  cp -R "$BUILD_BIN_PATH/Clolid_Clolid.bundle" "$APP_BUNDLE/"
fi

cp "$ROOT_DIR/Sources/Clolid/Resources/AppIcon.icns" "$APP_RESOURCES/AppIcon.icns"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>Clolid</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_BUILD</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LSUIElement</key>
  <true/>
  <key>LSMultipleInstancesProhibited</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

open_app() {
  /usr/bin/open "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --bundle|bundle)
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 2
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--bundle|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
