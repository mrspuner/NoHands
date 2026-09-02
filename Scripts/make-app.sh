#!/bin/bash
# Собирает NoHands.app и подписывает его.
#
# Подпись — самоподписанным сертификатом, а не ad-hoc: ad-hoc пишет в требование к коду хеш
# самого бинарника, и после каждой пересборки macOS считает приложение другой программой,
# отзывая разрешение на управление компьютером. Сертификат создаётся один раз вручную в
# Связке ключей: Ассистент сертификатов → Создать сертификат → тип «Подпись кода».
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
