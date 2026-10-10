#!/bin/zsh
# Builds the release binary and wraps it in a proper macOS .app bundle.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "── Building release…"
swift build -c release

BIN=$(swift build -c release --show-bin-path)/TranscribeRebuilt
APP="build/Transcribe Rebuilt.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

echo "── Bundling $APP"
cp "$BIN" "$APP/Contents/MacOS/TranscribeRebuilt"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>Transcribe Rebuilt</string>
    <key>CFBundleDisplayName</key>      <string>Transcribe Rebuilt</string>
    <key>CFBundleExecutable</key>        <string>TranscribeRebuilt</string>
    <key>CFBundleIdentifier</key>        <string>com.rebuilt.transcribe.rebuilt</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundleVersion</key>           <string>1.0.0</string>
    <key>LSMinimumSystemVersion</key>    <string>26.0</string>
    <key>NSHighResolutionCapable</key>    <true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key><false/>
    <key>LSApplicationCategoryType</key> <string>public.app-category.music</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>       <string>Transcribe! transcription document</string>
            <key>CFBundleTypeRole</key>        <string>Editor</string>
            <key>LSHandlerRank</key>          <string>Alternate</string>
            <key>LSItemContentTypes</key>     <array><string>public.data</string></array>
            <key>CFBundleTypeExtensions</key> <array><string>xsc</string></array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>       <string>Sound file</string>
            <key>CFBundleTypeRole</key>        <string>Viewer</string>
            <key>LSHandlerRank</key>           <string>Alternate</string>
            <key>LSItemContentTypes</key>      <array><string>public.audio</string><string>public.audiovisual-content</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# Generate a simple programmatic app icon (amber waveform on rounded dark squircle)
mkdir -p "$APP/Contents/Resources/icon.iconset"
swift scripts/make-icon.swift "$APP/Contents/Resources/icon.iconset" 2>/dev/null || true
if [ -f "$APP/Contents/Resources/icon.iconset/icon_512x512@2x.png" ]; then
    iconutil -c icns "$APP/Contents/Resources/icon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
    plutil -insert CFBundleIconFile -string AppIcon "$APP/Contents/Info.plist"
    rm -rf "$APP/Contents/Resources/icon.iconset"
fi

echo "── Done: $APP"
echo "   Run with: open \"$APP\""
