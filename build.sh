#!/bin/zsh
# Build WorkspaceBar.app, install it to ~/Applications, start it at login, and leave room for
# the bar at the bottom of the screen in Rectangle's layouts.
set -euo pipefail
cd "${0:A:h}"
APP=build/WorkspaceBar.app
rm -rf build && mkdir -p "$APP/Contents/MacOS"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.workspacebar</string>
  <key>CFBundleName</key><string>WorkspaceBar</string>
  <key>CFBundleExecutable</key><string>WorkspaceBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>WorkspaceBar hides and shows apps when you switch modes.</string>
</dict></plist>
PLIST
swiftc -O -swift-version 5 -parse-as-library main.swift switcher.swift hotkeys.swift modeserver.swift raycastcore.swift raycast.swift hooks.swift -o "$APP/Contents/MacOS/WorkspaceBar"
# The browser extension, a folder for Chromium browsers and one for Firefox, which the app copies
# to ~/.config/workspace-bar/extensions (ModeServer.extensionsFolder), and a zip of each.
EXT="$APP/Contents/Resources/extensions"
for b in chromium firefox; do
  mkdir -p "$EXT/$b"
  cp extension/background.js extension/blocked.html extension/blocked.js "$EXT/$b/"
done
cp extension/manifest.json "$EXT/chromium/manifest.json"
cp extension/manifest.firefox.json "$EXT/firefox/manifest.json"
for b in chromium firefox; do (cd "$EXT/$b" && zip -qrX "$PWD/../../../../../workspace-bar-$b.zip" .); done
# A designated requirement on the identifier alone keeps macOS permissions across rebuilds.
codesign --force -s - --requirements '=designated => identifier "local.workspacebar"' "$APP"

[[ "${1:-}" == "--no-install" ]] && exit 0

pkill -x WorkspaceBar 2>/dev/null || true
mkdir -p ~/Applications
rm -rf ~/Applications/WorkspaceBar.app
cp -R "$APP" ~/Applications/
# The app sets Rectangle's bottom gap to its own height (syncRectangleGap).
AGENT=~/Library/LaunchAgents/local.workspacebar.plist
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>local.workspacebar</string>
  <key>ProgramArguments</key><array><string>$HOME/Applications/WorkspaceBar.app/Contents/MacOS/WorkspaceBar</string></array>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/workspace-bar.log</string>
</dict></plist>
PLIST
launchctl bootout gui/$(id -u)/local.workspacebar 2>/dev/null || true
# bootout returns before the job is gone: retry for a few seconds.
for _ in 1 2 3 4 5; do launchctl bootstrap gui/$(id -u) "$AGENT" 2>/dev/null && break; sleep 1; done
echo "installed: ~/Applications/WorkspaceBar.app (log ~/Library/Logs/workspace-bar.log)"
