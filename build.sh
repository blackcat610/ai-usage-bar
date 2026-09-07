#!/bin/zsh
# Build AIUsageBar.app. Usage: ./build.sh [--install]
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release 2>&1 | grep -v -E "^\[|Compiling|Build complete" || true
APP=build/AIUsageBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/AIUsageBar "$APP/Contents/MacOS/AIUsageBar"
cp Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --deep --sign - "$APP" >/dev/null
echo "built $APP"
if [[ "${1:-}" == "--install" ]]; then
  pkill -x AIUsageBar 2>/dev/null || true
  sleep 0.3
  rm -rf /Applications/AIUsageBar.app
  cp -R "$APP" /Applications/AIUsageBar.app
  open /Applications/AIUsageBar.app
  echo "installed and launched /Applications/AIUsageBar.app"
fi
