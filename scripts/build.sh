#!/bin/bash
# Builds build/Hoole.app. Pass --dmg to also make build/Hoole.dmg for a GitHub release.
set -euo pipefail
cd "$(dirname "$0")/.."

[ "$(uname -m)" = arm64 ] || { echo "Hoole needs an Apple Silicon Mac (the speech engine ships for arm64)."; exit 1; }
command -v swift >/dev/null || { echo "Install the Xcode Command Line Tools first: xcode-select --install"; exit 1; }

# Pinned Hugging Face revisions of the speech engine and model (Apache-2.0, see THIRD_PARTY_LICENSES).
HF=https://huggingface.co/Cactus-Compute
ENGINE_REV=2ae11323dc000f5e70c49f7403efa6af12ba9e67
MODEL_REV=b358ddadd89b7a713b5aa131f23032d3cca1b251

fetch() { # url dest sha256
    if [ -f "$2" ] && echo "$3  $2" | shasum -a 256 -c - >/dev/null 2>&1; then return; fi
    echo "↓ $(basename "$2")"
    curl -fL --progress-bar -o "$2" "$1"
    echo "$3  $2" | shasum -a 256 -c - >/dev/null || { rm -f "$2"; echo "Checksum mismatch for $2"; exit 1; }
}

mkdir -p Vendor build
# The engine dylib from the Python wheel targets macOS 11; the platform folder's libneedle.a targets macOS 26.
fetch "$HF/needle3/resolve/$ENGINE_REV/python/cactus_needle-3.2.0-py3-none-macosx_11_0_arm64.whl" Vendor/engine.whl 3b0887a43cd6e9a99009fabf35b231c11bb3a978ab8af94b8119b2eb76e19832
[ -f Vendor/libneedle.dylib ] || unzip -p Vendor/engine.whl needle/libneedle3.dylib > Vendor/libneedle.dylib
fetch "$HF/needle3/resolve/$ENGINE_REV/macos-arm64/needle.h" Vendor/needle.h 914bbd00423939b02fc349f91cdb7c12531b3f5bb7105b743e0e93c7e409d7b1
# Whisper runtime (whisper.cpp, MIT) for the Best accuracy mode.
fetch "https://github.com/ggml-org/whisper.cpp/releases/download/b5454/whisper-b5454-xcframework.zip" Vendor/whisper-xcframework.zip e57f8c48933000acabc13bb913fbe82805d483a2deff692cc6738836bd92393b
[ -d Vendor/whisper.xcframework ] || { unzip -q -o Vendor/whisper-xcframework.zip -d Vendor/whisper-tmp && mv Vendor/whisper-tmp/build-apple/whisper.xcframework Vendor/ && rm -rf Vendor/whisper-tmp; }
fetch "$HF/whistle/resolve/$MODEL_REV/whistle.cact" Vendor/model.cact b6e02f048568ac5d01a2042556c658061e699acbc0aa2a1439f52f3d461dffeb
# Whisper large-v3-turbo (MIT), the Best accuracy model: ~870 MB, so the first build takes a while.
fetch "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo-q8_0.bin" Vendor/whisper-large-v3-turbo.bin 317eb69c11673c9de1e1f0d459b253999804ec71ac4c23c17ecf5fbe24e259a1

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Hoole"

if [ ! -f build/AppIcon.icns ]; then
    ICONSET=build/AppIcon.iconset
    mkdir -p "$ICONSET"
    swift scripts/icon.swift build/icon-1024.png
    for s in 16 32 128 256 512; do
        sips -z $s $s build/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
        sips -z $((s * 2)) $((s * 2)) build/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o build/AppIcon.icns
fi

# macOS ties Microphone/Accessibility grants to the app's signature. Ad-hoc signatures change on
# every build, so permissions would reset each time; a local self-signed certificate keeps them.
IDENTITY="Hoole Local Signing"
make_identity() {
    local tmp; tmp=$(mktemp -d)
    printf '[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=%s\n[ext]\nbasicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n' "$IDENTITY" > "$tmp/cfg"
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$tmp/key.pem" -out "$tmp/cert.pem" -config "$tmp/cfg" 2>/dev/null
    openssl pkcs12 -export -legacy -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -out "$tmp/id.p12" -passout pass:hoole 2>/dev/null \
        || openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -out "$tmp/id.p12" -passout pass:hoole
    security import "$tmp/id.p12" -k ~/Library/Keychains/login.keychain-db -P hoole -T /usr/bin/codesign >/dev/null
    echo "macOS will ask for your password to trust this certificate for code signing (one time only)."
    security add-trusted-cert -p codeSign -k ~/Library/Keychains/login.keychain-db "$tmp/cert.pem"
    rm -rf "$tmp"
}
if ! security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    echo "One-time setup: creating a local signing certificate so macOS remembers Hoole's permissions across rebuilds."
    make_identity || true
fi
if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    SIGN="$IDENTITY"
else
    SIGN=-
    echo "⚠ Signing ad-hoc: macOS will ask for Microphone/Accessibility again after every rebuild."
fi

APP=build/Hoole.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/Hoole"
cp Vendor/libneedle.dylib "$APP/Contents/Frameworks/"
codesign --force --sign "$SIGN" "$APP/Contents/Frameworks/libneedle.dylib"
cp -R Vendor/whisper.xcframework/macos-arm64_x86_64/whisper.framework "$APP/Contents/Frameworks/"
codesign --force --sign "$SIGN" "$APP/Contents/Frameworks/whisper.framework"
cp Vendor/model.cact Vendor/whisper-large-v3-turbo.bin "$APP/Contents/Resources/"
cp build/AppIcon.icns THIRD_PARTY_LICENSES "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Hoole</string>
    <key>CFBundleDisplayName</key><string>Hoole</string>
    <key>CFBundleIdentifier</key><string>io.github.hoole</string>
    <key>CFBundleExecutable</key><string>Hoole</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.2.0</string>
    <key>CFBundleVersion</key><string>3</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>Hoole listens while you dictate. Audio is transcribed on this Mac and never leaves it.</string>
</dict>
</plist>
EOF
codesign --force --sign "$SIGN" "$APP" # local identity; a Developer ID + notarization is the upgrade for wide distribution

if [ "${1:-}" = "--dmg" ]; then
    STAGE=build/dmg
    rm -rf "$STAGE" build/Hoole.dmg
    mkdir -p "$STAGE"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname Hoole -srcfolder "$STAGE" -ov -format UDZO build/Hoole.dmg >/dev/null
    rm -rf "$STAGE"
    echo "✓ build/Hoole.dmg"
fi

echo "✓ $APP  →  open it, or: cp -R $APP /Applications/"
