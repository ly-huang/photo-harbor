#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
mkdir -p .build/release
xcrun swiftc -O -parse-as-library -swift-version 5 -module-name PhotoHarbor \
  -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
  -target "$(uname -m)-apple-macosx14.0" Sources/PhotoHarbor/*.swift -o .build/release/PhotoHarbor
app="${PWD}/dist.noindex/拾影.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/PhotoHarbor "$app/Contents/MacOS/PhotoHarbor"
# Only the approved source artwork is versioned; all generated icon files stay local.
icon_build="$PWD/.build/app-icon"
mkdir -p "$icon_build"
xcrun swift -module-cache-path "$CLANG_MODULE_CACHE_PATH" scripts/prepare-system-icon.swift "$PWD/assets/AppIcon/master.png" "$icon_build/master.png" 0 0 1024 1024
if [[ ! -f "$icon_build/AppIcon.icns" ]] || ! cmp -s "$icon_build/master.png" "$icon_build/AppIcon.iconset/icon_512x512@2x.png"; then
  xcrun swift -module-cache-path "$CLANG_MODULE_CACHE_PATH" scripts/package-icon.swift "$icon_build/master.png" "$icon_build/AppIcon.iconset" "$icon_build/AppIcon.icns"
fi
cp "$icon_build/AppIcon.icns" "$app/Contents/Resources/AppIconPearlWhite.icns"
rm -f "$app/Contents/Resources/AppIconGlass.icns"
rm -f "$app/Contents/Resources/AppIcon.icns" "$app/Contents/Resources/AppIconDock.png" "$app/Contents/Resources/AppIcon-v2.icns" "$app/Contents/Resources/AppIcon-v3.icns" "$app/Contents/Resources/AppIcon-v4.icns" "$app/Contents/Resources/AppIcon-v5.icns"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>PhotoHarbor</string>
<key>CFBundleIdentifier</key><string>com.tron.photoharbor</string>
<key>CFBundleName</key><string>拾影</string>
<key>CFBundleDisplayName</key><string>拾影 Photo Harbor</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIconPearlWhite</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleShortVersionString</key><string>0.7.4</string>
<key>CFBundleVersion</key><string>22</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSRemovableVolumesUsageDescription</key><string>读取存储卡和外置硬盘中的照片，按你的选择整理和移入废纸篓。</string>
</dict></plist>
PLIST
codesign --force --sign - "$app"
# IconServices keys some cached artwork by the bundle directory timestamp.
touch "$app"
# Development output stays in dist.noindex; register only the installed bundle.
print "已生成：$app"
