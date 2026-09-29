#!/bin/bash
# Builds NoHands.app and signs it.
#
# Signed with a self-signed certificate, not ad-hoc: ad-hoc signing bakes the binary's own
# hash into the code requirement, so every rebuild makes macOS see a different program and
# revokes the Accessibility permission the app needs. A named identity keeps the requirement
# at "this identifier, signed by this certificate" — no hash, so the permission survives
# rebuilds. See docs/DECISIONS.md, "Самоподписанный сертификат вместо ad-hoc подписи", for the
# one-time setup of the certificate in Keychain Access.
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${NOHANDS_SIGNING_IDENTITY:-NoHands Local}"
APP="build/NoHands.app"

swift build -c release --product NoHandsApp
BIN_PATH="$(swift build -c release --product NoHandsApp --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/NoHandsApp" "$APP/Contents/MacOS/NoHands"
cp App/Info.plist "$APP/Contents/Info.plist"
cp App/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign "$IDENTITY" --identifier com.nohands.app "$APP"
codesign --verify --verbose "$APP"

# Installed into /Applications so it shows up in Launchpad and so Login Items points at a path
# that does not move — the app registers itself there on launch, see App/LoginItem.swift.
# NOHANDS_NO_INSTALL=1 stops at the signed bundle in build/.
if [ "${NOHANDS_NO_INSTALL:-}" = "1" ]; then
    echo "готово: $APP"
    exit 0
fi

INSTALLED="/Applications/NoHands.app"
# SIGTERM rather than an Apple event "quit": the latter would ask for Automation permission for
# whatever terminal runs this. A meeting in flight survives as a draft, same as after a crash.
pkill -TERM -x NoHands || true
while pgrep -x NoHands >/dev/null; do sleep 0.2; done
rm -rf "$INSTALLED"
ditto "$APP" "$INSTALLED"
open "$INSTALLED"

echo "готово: $INSTALLED"
