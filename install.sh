#!/bin/bash
# InputLock installer
#   Install:    curl -fsSL https://raw.githubusercontent.com/devrashed01/InputLock/main/install.sh | bash
#   Uninstall:  curl -fsSL https://raw.githubusercontent.com/devrashed01/InputLock/main/install.sh | bash -s uninstall
set -euo pipefail

REPO="devrashed01/InputLock"
DEST="${INPUTLOCK_DIR:-$HOME/Applications}"
APP="$DEST/InputLock.app"
LABEL="com.local.inputlock"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

[[ "$(uname)" == "Darwin" ]] || { echo "InputLock only runs on macOS." >&2; exit 1; }

stop() {
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    pkill -x InputLock 2>/dev/null || true
    for _ in $(seq 10); do pgrep -x InputLock >/dev/null || break; sleep 0.2; done
}

if [[ "${1:-}" == "uninstall" ]]; then
    stop
    rm -f "$AGENT"
    rm -rf "$APP"
    echo "✅ InputLock uninstalled."
    exit 0
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
echo "==> Downloading InputLock…"
curl -fsSL "https://github.com/$REPO/releases/latest/download/InputLock.zip" -o "$TMP/InputLock.zip"
ditto -x -k "$TMP/InputLock.zip" "$TMP"
codesign --verify --strict "$TMP/InputLock.app"

echo "==> Installing to $APP…"
stop
mkdir -p "$DEST"
rm -rf "$APP"
mv "$TMP/InputLock.app" "$APP"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

if [[ -n "${INPUTLOCK_NO_START:-}" ]]; then echo "✅ Installed (not started)."; exit 0; fi

echo "==> Adding login item…"
mkdir -p "$(dirname "$AGENT")"
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>             <string>$LABEL</string>
    <key>ProgramArguments</key>  <array><string>$APP/Contents/MacOS/InputLock</string></array>
    <key>RunAtLoad</key>         <true/>
    <key>ProcessType</key>       <string>Interactive</string>
    <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict>
</plist>
PLIST
launchctl bootstrap "$DOMAIN" "$AGENT"

cat <<MSG

✅ InputLock installed and starts automatically at login.

One-time setup: allow InputLock in
  System Settings ▸ Privacy & Security ▸ Accessibility      (opening now)
  System Settings ▸ Privacy & Security ▸ Input Monitoring
Then start it:  launchctl kickstart -k $DOMAIN/$LABEL

Lock / unlock:  Control + Option + Command + L
MSG
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" 2>/dev/null || true
