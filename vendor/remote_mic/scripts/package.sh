#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
identity="${CODE_SIGN_IDENTITY:-}"
if [[ -z "$identity" && -f .codesign-identity ]]; then
  identity="$(< .codesign-identity)"
fi
if [[ -z "$identity" || "$identity" == "-" ]]; then
  print -u2 -- "请将固定签名证书的 SHA-1 写入 .codesign-identity，或设置 CODE_SIGN_IDENTITY；使用 security find-identity -v -p codesigning 查看证书。"
  exit 1
fi
swift build -c release
app="$PWD/.build/RemoteVibe.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
iconset="$PWD/.build/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" Resources/icon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
  sips -z "$((size * 2))" "$((size * 2))" Resources/icon.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
cp .build/release/RemoteVibe "$app/Contents/MacOS/RemoteVibe"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/RC003-remote-photo.png "$app/Contents/Resources/"
cp LICENSE LICENSE-MIT THIRD_PARTY_NOTICES.md "$app/Contents/Resources/"
codesign --force --sign "$identity" --identifier dev.remotevibe.controller "$app"
codesign --verify --strict "$app"
print -r -- "应用已生成：$app"
