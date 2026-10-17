#!/bin/bash
# Builds InputLock, signs it, installs ~/Applications/InputLock.app and a login item.
#   bash build.sh            build + install + (re)start
#   bash build.sh uninstall  stop, remove login item and app
#   bash build.sh release    build a universal, ad-hoc signed dist/InputLock.zip (no install)
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/InputLock.app"
MACOS="$APP/Contents/MacOS"
BIN="$MACOS/InputLock"
LABEL="com.local.inputlock"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
# A stable signing identity keeps Accessibility / Input Monitoring grants across rebuilds.
# Uses SIGN_ID if set, otherwise the first "Apple Development" identity in your keychain.
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Apple Development/ {print $2; exit}')}"

stop() {
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    pkill -x InputLock 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x InputLock >/dev/null || break; sleep 0.2; done
}

if [[ "${1:-}" == "uninstall" ]]; then
    stop
    rm -f "$AGENT"
    rm -rf "$APP"
    echo "✅ InputLock uninstalled."
    exit 0
fi

MODE="${1:-install}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FRAMEWORKS=(-framework Cocoa -framework LocalAuthentication -framework IOKit -framework ApplicationServices)

echo "==> Compiling…"
if [[ "$MODE" == "release" ]]; then
    for arch in arm64 x86_64; do
        swiftc -O -swift-version 5 -target "$arch-apple-macos13.0" "$SRC_DIR/main.swift" \
            -o "$TMP/InputLock-$arch" "${FRAMEWORKS[@]}"
    done
    lipo -create "$TMP/InputLock-arm64" "$TMP/InputLock-x86_64" -output "$TMP/InputLock"
    APP="$TMP/InputLock.app"; MACOS="$APP/Contents/MacOS"; BIN="$MACOS/InputLock"
else
    swiftc -O -swift-version 5 "$SRC_DIR/main.swift" -o "$TMP/InputLock" "${FRAMEWORKS[@]}"
    stop
    rm -rf "$APP"
fi
mkdir -p "$MACOS" "$APP/Contents/Resources"
mv "$TMP/InputLock" "$BIN"
cp "$SRC_DIR/assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>InputLock</string>
    <key>CFBundleDisplayName</key>       <string>InputLock</string>
    <key>CFBundleIdentifier</key>        <string>com.local.inputlock</string>
    <key>CFBundleExecutable</key>        <string>InputLock</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>2.0</string>
    <key>CFBundleVersion</key>           <string>2</string>
    <key>LSMinimumSystemVersion</key>    <string>13.0</string>
    <key>LSUIElement</key>               <true/>
    <key>NSHighResolutionCapable</key>   <true/>
</dict>
</plist>
PLIST

echo "==> Signing…"
if [[ "$MODE" == "release" ]]; then
    codesign --force --sign - "$APP"          # ad-hoc: no personal certificate in the download
    codesign --verify --strict "$APP"
    mkdir -p "$SRC_DIR/dist"
    rm -f "$SRC_DIR/dist/InputLock.zip"
    ditto -c -k --norsrc --noextattr --keepParent "$APP" "$SRC_DIR/dist/InputLock.zip"
    echo "✅ Release: $SRC_DIR/dist/InputLock.zip"
    exit 0
elif [[ -n "$SIGN_ID" ]]; then
    codesign --force --options runtime --timestamp=none --sign "$SIGN_ID" "$APP"
else
    echo "   (no Apple Development identity — ad-hoc signing; permissions reset on each rebuild)"
    codesign --force --sign - "$APP"
fi
codesign --verify --strict "$APP"

echo "==> Installing login item…"
mkdir -p "$(dirname "$AGENT")"
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>             <string>$LABEL</string>
    <key>ProgramArguments</key>  <array><string>$BIN</string></array>
    <key>RunAtLoad</key>         <true/>
    <key>ProcessType</key>       <string>Interactive</string>
    <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict>
</plist>
PLIST
launchctl bootstrap "$DOMAIN" "$AGENT"

echo ""
echo "✅ Installed and running: $APP  (starts automatically at login)"
echo "   Lock / unlock:  Control + Option + Command + L"
echo "   First time only: enable InputLock in System Settings ▸ Privacy & Security ▸"
echo "   Accessibility AND Input Monitoring, then:  launchctl kickstart -k $DOMAIN/$LABEL"
echo "   Uninstall:  bash \"$SRC_DIR/build.sh\" uninstall"
