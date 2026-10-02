#!/bin/zsh
# Compila Spectrum con SwiftPM y lo empaqueta como build/Spectrum.app.
# Uso: ./build.sh               → compila para la arquitectura de este Mac y firma ad-hoc
#      ./build.sh --universal   → binario universal (Apple Silicon + Intel), tarda el doble
#      ./build.sh --install     → además copia la app a /Applications
#      ./build.sh --zip         → además crea build/Spectrum.zip para distribuir
#      CODESIGN_IDENTITY="Apple Development: Tu Nombre (TEAMID)" ./build.sh  → firma con tu certificado
set -euo pipefail
cd "$(dirname "$0")"

UNIVERSAL=0; INSTALL=0; ZIP=0
for arg in "$@"; do
  case "$arg" in
    --universal) UNIVERSAL=1 ;;
    --install) INSTALL=1 ;;
    --zip) ZIP=1 ;;
    *) echo "Opción desconocida: $arg"; exit 1 ;;
  esac
done

if [[ $UNIVERSAL -eq 1 ]]; then
  echo "Compilando arm64…";  swift build -c release --triple arm64-apple-macosx14.2 2>&1 | grep -E "error|warning: unre|Build complete" || true
  echo "Compilando x86_64…"; swift build -c release --triple x86_64-apple-macosx14.2 2>&1 | grep -E "error|warning: unre|Build complete" || true
  mkdir -p .build/universal
  lipo -create .build/arm64-apple-macosx/release/Spectrum .build/x86_64-apple-macosx/release/Spectrum -output .build/universal/Spectrum
  BIN=".build/universal/Spectrum"
else
  swift build -c release 2>&1 | grep -E "error|warning: unre|Build complete" || true
  BIN=".build/release/Spectrum"
fi
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
echo "Listo: $(pwd)/$APP ($(lipo -archs "$APP/Contents/MacOS/Spectrum"))"

if [[ $ZIP -eq 1 ]]; then
  rm -f build/Spectrum.zip
  ditto -c -k --keepParent "$APP" build/Spectrum.zip
  echo "Zip: $(pwd)/build/Spectrum.zip"
fi

if [[ $INSTALL -eq 1 ]]; then
  pkill -x Spectrum 2>/dev/null || true
  rm -rf /Applications/Spectrum.app
  cp -R "$APP" /Applications/Spectrum.app
  echo "Instalado en /Applications/Spectrum.app"
else
  echo "Ábrelo con:  open \"$APP\""
fi
