#!/bin/bash
# Builds "build/Dedotated Wam.app". Works with the Command Line Tools alone; Xcode is not needed.
#   Scripts/build-app.sh             build only
#   Scripts/build-app.sh --run       build, then (re)start the app from the build folder
#   Scripts/build-app.sh --install   build, copy to /Applications, then (re)start it from there
#   Scripts/build-app.sh --dmg       build for Apple silicon and Intel, and pack dist/DedotatedWam-<version>.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

name="Dedotated Wam"
app="build/$name.app"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

if [ "${1:-}" = "--dmg" ]; then
  # One binary for both kinds of Mac. Each build lands in the same folder, so copy it out in between.
  slices=()
  for arch in arm64 x86_64; do
    swift build -c release --triple "$arch-apple-macosx14.0"
    slice="build/DedotatedWam-$arch"
    cp "$(swift build -c release --triple "$arch-apple-macosx14.0" --show-bin-path)/DedotatedWam" "$slice"
    [ "$(lipo -archs "$slice")" = "$arch" ] || { echo "Expected an $arch build in $slice" >&2; exit 1; }
    slices+=("$slice")
  done
  lipo -create "${slices[@]}" -output "$app/Contents/MacOS/DedotatedWam"
  rm -f "${slices[@]}"
else
  swift build -c release
  cp "$(swift build -c release --show-bin-path)/DedotatedWam" "$app/Contents/MacOS/DedotatedWam"
fi
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
  --dmg)
    version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
    dmg="dist/DedotatedWam-$version.dmg"
    stage="$(mktemp -d)"
    cp -R "$app" "$stage/"
    ln -s /Applications "$stage/Applications"
    mkdir -p dist
    hdiutil create -volname "$name" -srcfolder "$stage" -ov -format UDZO "$dmg" >/dev/null
    rm -rf "$stage"
    (cd dist && shasum -a 256 "$(basename "$dmg")" > "$(basename "$dmg").sha256")
    echo "Packed $dmg ($(lipo -archs "$app/Contents/MacOS/DedotatedWam"))"
    ;;
esac
