#!/bin/bash
# Builds "build/Dedotated Wam.app". Works with the Command Line Tools alone; Xcode is not needed.
#   Scripts/build-app.sh             build only
#   Scripts/build-app.sh --run       build, then (re)start the app from the build folder
#   Scripts/build-app.sh --install   build, copy to /Applications, then (re)start it from there
set -euo pipefail
cd "$(dirname "$0")/.."

name="Dedotated Wam"
app="build/$name.app"

swift build -c release
binary="$(swift build -c release --show-bin-path)/DedotatedWam"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/DedotatedWam"
cp Resources/Info.plist "$app/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
# Ad-hoc signature: enough to run locally and to post notifications.
codesign --force --sign - "$app"
echo "Built $app"

stop_running() {
  pkill -x DedotatedWam 2>/dev/null || true
  sleep 0.5
}

case "${1:-}" in
  --run)
    stop_running
    open "$app"
    ;;
  --install)
    stop_running
    rm -rf "/Applications/$name.app"
    cp -R "$app" "/Applications/$name.app"
    open "/Applications/$name.app"
    echo "Installed to /Applications/$name.app"
    ;;
esac
