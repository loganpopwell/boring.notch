#!/bin/zsh
# Stress test for handing the fans back to macOS. Run as yourself:
#   scripts/fan-stress-test.sh
# It compiles Tests/FanStress, asks once for an administrator password, reinstalls the fan helper
# from /Applications/boringNotch.app, and runs the test as root (about 15 minutes, fans get loud).
# Progress and the report go to /tmp/boringnotch-fan-stress/report.txt.
#
# While it runs, a root-owned flag file lets the signed stress client connect to the daemon and
# enables fault injection. Both are removed on exit, whatever the result.
set -euo pipefail
label=theboringteam.boringnotch.FanHelper
out=/tmp/boringnotch-fan-stress

if [[ $EUID -ne 0 ]]; then
  root=${0:A:h:h}
  mkdir -p $out
  rm -f $out/report.txt
  xcrun swiftc -O -target arm64-apple-macos14 \
    $root/Shared/FanControlSnapshot.swift $root/BoringNotchXPCHelper/SMCFan.swift \
    $root/BoringNotchXPCHelper/FanHelperProtocol.swift $root/Tests/FanStress/main.swift \
    -o $out/FanStress 2>/dev/null
  codesign --force --sign - --identifier theboringteam.boringnotch.FanStressTest $out/FanStress
  echo "macOS will ask for an administrator password. Report: $out/report.txt"
  /usr/bin/osascript -e "do shell script \"'${0:A}' --as-root '$out/FanStress' > '$out/report.txt' 2>&1\" with prompt \"BoringNotch fan stress test needs to run as root.\" with administrator privileges"
  code=$?
  cat $out/report.txt
  exit $code
fi

[[ ${1:-} == --as-root && -n ${2:-} ]] || { echo "Run without arguments as your user."; exit 2 }
flag=/Library/PrivilegedHelperTools/$label.stress-test
fault=/Library/PrivilegedHelperTools/$label.fault
tmp=$(mktemp -d /tmp/fanstress-root.XXXXXX)
cleanup() { rm -f $flag $fault; rm -rf $tmp }
trap cleanup EXIT INT TERM
install -o root -g wheel -m 0755 $2 $tmp/FanStress

# Same steps as the panel's Install fan helper button.
helper=/Applications/boringNotch.app/Contents/Library/LaunchServices/$label
launchctl bootout system/$label 2>/dev/null || true
install -o root -g wheel -m 0755 $helper /Library/PrivilegedHelperTools/$label
/Library/PrivilegedHelperTools/$label --launchd-plist > /Library/LaunchDaemons/$label.plist
chown root:wheel /Library/LaunchDaemons/$label.plist
chmod 0644 /Library/LaunchDaemons/$label.plist
for i in {1..40}; do launchctl bootstrap system /Library/LaunchDaemons/$label.plist 2>/dev/null && break; sleep 0.25; done
launchctl print system/$label >/dev/null || { echo "Could not load the fan helper"; exit 1 }
echo "Installed fan helper $(shasum -a 256 /Library/PrivilegedHelperTools/$label | cut -c1-16)"

install -o root -g wheel -m 0644 /dev/null $flag
set +e
$tmp/FanStress
rc=$?
exit $rc
