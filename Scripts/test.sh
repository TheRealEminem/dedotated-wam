#!/bin/bash
# Runs the tests. With only the Command Line Tools installed, a plain `swift test` intermittently
# fails to find the Swift Testing macro plugin, so its folder is passed explicitly when it exists.
set -euo pipefail
cd "$(dirname "$0")/.."

plugins="$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
if [ -d "$plugins" ]; then
  exec swift test -Xswiftc -plugin-path -Xswiftc "$plugins" "$@"
fi
exec swift test "$@"
