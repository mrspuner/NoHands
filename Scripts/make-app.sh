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
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_PATH/NoHandsApp" "$APP/Contents/MacOS/NoHands"
cp App/Info.plist "$APP/Contents/Info.plist"

codesign --force --sign "$IDENTITY" --identifier com.nohands.app "$APP"
codesign --verify --verbose "$APP"

echo "готово: $APP"
