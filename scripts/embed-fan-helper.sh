#!/bin/zsh
# Compiles the root fan helper daemon and places it in an unsigned app bundle at
# Contents/Library/LaunchServices, where the XPC helper installs it from.
# Run after xcodebuild and before signing. Usage: scripts/embed-fan-helper.sh path/to/boringNotch.app
set -euo pipefail
app=${1:?usage: embed-fan-helper.sh path/to/boringNotch.app}
root=${0:A:h:h}
label=theboringteam.boringnotch.FanHelper
out="$app/Contents/Library/LaunchServices"
mkdir -p "$out"
xcrun swiftc -O -target arm64-apple-macos14 \
  "$root/Shared/FanControlSnapshot.swift" \
  "$root/BoringNotchXPCHelper/SMCFan.swift" \
  "$root/BoringNotchXPCHelper/FanHelperProtocol.swift" \
  "$root/BoringNotchFanHelper/main.swift" \
  -o "$out/$label"
codesign --force --sign - --identifier "$label" --options runtime "$out/$label"
echo "Embedded $out/$label"
