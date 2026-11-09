#!/bin/bash
# Gera UnificadorVR.app (Apple Silicon, sem App Sandbox) a partir do Swift Package.
# Uso: ./build_app.sh            → build/UnificadorVR.app
#      ./build_app.sh --install  → também copia para /Applications
set -euo pipefail

cd "$(dirname "$0")"
APP_NAME="UnificadorVR"
DISPLAY_NAME="Unificador VR"
BUNDLE_ID="com.cineoitoum.unificadorvr"
VERSION="1.0.0"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
OUT_DIR="build"
APP="$OUT_DIR/$APP_NAME.app"

if [[ "$(uname)" != "Darwin" ]]; then
  echo "Erro: este script precisa rodar no macOS." >&2
  exit 1
fi

echo "› Rodando testes…"
swift test

ARCH="$(uname -m)"   # arm64 no M1; x86_64 em Mac Intel
echo "› Compilando (release, $ARCH)…"
swift build -c release --arch "$ARCH" --product "$APP_NAME"
BIN_DIR="$(swift build -c release --arch "$ARCH" --show-bin-path)"

echo "› Montando $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>pt-BR</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$DISPLAY_NAME</string>
  <key>CFBundleDisplayName</key><string>$DISPLAY_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSRemovableVolumesUsageDescription</key>
  <string>O Unificador VR lê os cartões da câmera e grava a pasta unificada no disco escolhido.</string>
  <key>NSNetworkVolumesUsageDescription</key>
  <string>O Unificador VR pode ler e gravar material em volumes de rede.</string>
  <key>NSDesktopFolderUsageDescription</key>
  <string>O Unificador VR acessa as pastas que você escolher.</string>
  <key>NSDocumentsFolderUsageDescription</key>
  <string>O Unificador VR acessa as pastas que você escolher.</string>
  <key>NSDownloadsFolderUsageDescription</key>
  <string>O Unificador VR acessa as pastas que você escolher.</string>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Assinatura ad-hoc, SEM entitlements → App Sandbox desativado.
echo "› Assinando (ad-hoc, sem sandbox)…"
codesign --force --deep --sign - "$APP"
codesign --verify --verbose=1 "$APP"
if codesign -d --entitlements :- "$APP" 2>/dev/null | grep -q "com.apple.security.app-sandbox"; then
  echo "Erro: o app saiu com sandbox." >&2
  exit 1
fi

if [[ "${1:-}" == "--install" ]]; then
  # /Applications se der; senão ~/Applications (usuário sem permissão de administrador).
  TARGET="/Applications"
  if ! { [[ ! -e "$TARGET/$APP_NAME.app" ]] || rm -rf "$TARGET/$APP_NAME.app" 2>/dev/null; } \
     || ! cp -R "$APP" "$TARGET/" 2>/dev/null; then
    TARGET="$HOME/Applications"
    mkdir -p "$TARGET"
    rm -rf "$TARGET/$APP_NAME.app"
    cp -R "$APP" "$TARGET/"
  fi
  echo "✓ Instalado em $TARGET/$APP_NAME.app"
  echo "$TARGET/$APP_NAME.app" > "$OUT_DIR/.installed_path"
else
  echo "✓ $APP"
fi
