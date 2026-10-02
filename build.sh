#!/bin/zsh
# Compila Spectrum con SwiftPM y lo empaqueta como build/Spectrum.app.
# Uso: ./build.sh            → compila en modo release y firma ad-hoc
#      ./build.sh --install  → además copia la app a /Applications
#      CODESIGN_IDENTITY="Apple Development: Tu Nombre (TEAMID)" ./build.sh  → firma con tu certificado
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release 2>&1 | grep -v "^\[" || true
BIN=".build/release/Spectrum"
[[ -x "$BIN" ]] || { echo "La compilación falló"; exit 1; }

APP="build/Spectrum.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Spectrum"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
echo -n "APPL????" > "$APP/Contents/PkgInfo"

IDENTITY="${CODESIGN_IDENTITY:--}"
codesign --force --sign "$IDENTITY" --identifier design.webake.spectrum "$APP"
echo "Listo: $(pwd)/$APP"
if [[ "${1:-}" == "--install" ]]; then
  pkill -x Spectrum 2>/dev/null || true
  rm -rf /Applications/Spectrum.app
  cp -R "$APP" /Applications/Spectrum.app
  echo "Instalado en /Applications/Spectrum.app"
else
  echo "Ábrelo con:  open \"$APP\""
fi
