#!/bin/bash
# Builds build/spaceflick (CLI) and build/SpaceFlick.app (menu-bar-less agent).
#   ./build.sh            build only
#   ./build.sh install    put it in /Applications and start it at login
#   ./build.sh uninstall  stop it and remove it
set -euo pipefail
cd "$(dirname "$0")"

PLIST="$HOME/Library/LaunchAgents/com.julien.spaceflick.plist"
APP=build/SpaceFlick.app

if [[ "${1:-}" == "uninstall" ]]; then
  launchctl bootout "gui/$(id -u)/com.julien.spaceflick" 2>/dev/null || true
  rm -f "$PLIST"
  rm -rf /Applications/SpaceFlick.app
  echo "done → uninstalled"
  exit 0
fi

mkdir -p build
echo "• compiling"
swiftc -O -o build/spaceflick mac/main.swift

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/spaceflick "$APP/Contents/MacOS/spaceflick"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key><string>com.julien.spaceflick</string>
	<key>CFBundleName</key><string>SpaceFlick</string>
	<key>CFBundleExecutable</key><string>spaceflick</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>LSUIElement</key><true/>
</dict>
</plist>
EOF
codesign --force --sign - "$APP" 2>/dev/null

if [[ "${1:-}" == "install" ]]; then
  launchctl bootout "gui/$(id -u)/com.julien.spaceflick" 2>/dev/null || true
  rm -rf /Applications/SpaceFlick.app
  ditto "$APP" /Applications/SpaceFlick.app
  # The ad-hoc signature changes on every build, which strands the old
  # Accessibility grant (it still shows ON but no longer matches).
  tccutil reset Accessibility com.julien.spaceflick >/dev/null 2>&1 || true
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>com.julien.spaceflick</string>
	<key>ProgramArguments</key>
	<array>
		<string>/Applications/SpaceFlick.app/Contents/MacOS/spaceflick</string>
		<string>run</string>
	</array>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key><true/>
	<key>StandardErrorPath</key><string>/tmp/spaceflick.log</string>
</dict>
</plist>
EOF
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  echo "done → installed and running. Grant Accessibility to SpaceFlick when macOS asks"
  echo "       (System Settings → Privacy & Security → Accessibility), then:"
  echo "       launchctl kickstart -k gui/$(id -u)/com.julien.spaceflick"
else
  echo "done → ./build/spaceflick   (./build.sh install to run it at login)"
fi
