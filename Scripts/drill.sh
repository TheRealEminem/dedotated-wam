#!/bin/bash
# Live check that auto-close really closes things. Run it before a release.
#
# Builds three throwaway apps, opens them in the background, then runs the app's own monitor and
# closing code with `--drill`, which acts as if memory were critical and may close only the
# targets it is given. Expected: one app quits when asked, a background process started by the
# second app is ended, that second app refuses to quit and is force quit, and the third app,
# which is in no rule, is left alone.
#
# Your real settings and activity log are not touched. Three icons appear in the Dock for a few
# seconds while it runs.
set -euo pipefail
cd "$(dirname "$0")/.."

Scripts/build-app.sh
binary="build/Dedotated Wam.app/Contents/MacOS/DedotatedWam"

work="build/drill"
rm -rf "$work"
mkdir -p "$work"
swiftc -O Scripts/drill/Target.swift -o "$work/target"

make_app() { # name, role, bundle id
  local bundle="$work/$1.app"
  mkdir -p "$bundle/Contents/MacOS"
  cp "$work/target" "$bundle/Contents/MacOS/$1"
  cp "$work/target" "$bundle/Contents/MacOS/wamdrillhog"
  cat > "$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>$1</string>
	<key>CFBundleIdentifier</key><string>$3</string>
	<key>CFBundleName</key><string>$1</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>WamDrillRole</key><string>$2</string>
</dict>
</plist>
PLIST
  codesign --force --sign - "$bundle" 2>/dev/null
}

make_app "Wam Drill Polite" polite test.wamdrill.polite
make_app "Wam Drill Stubborn" stubborn test.wamdrill.stubborn
make_app "Wam Drill Bystander" polite test.wamdrill.bystander

cleanup() { pkill -f "$PWD/$work/" 2>/dev/null || true; }
trap cleanup EXIT

for name in "Wam Drill Polite" "Wam Drill Stubborn" "Wam Drill Bystander"; do
  open -g -n "$work/$name.app"
done
sleep 4

status=0
"$binary" --drill test.wamdrill.polite process:wamdrillhog test.wamdrill.stubborn || status=$?

if pgrep -f "$PWD/$work/Wam Drill Bystander.app" >/dev/null; then
  echo "The app that is in no rule was left alone."
else
  echo "Drill FAILED: the app that is in no rule was closed."
  status=1
fi
exit $status
