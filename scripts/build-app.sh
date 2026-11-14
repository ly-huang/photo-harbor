#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
configuration=${PHOTOHARBOR_BUILD_CONFIGURATION:-debug}
if [[ "${1:-}" == '--release' ]]; then configuration=release; fi
if [[ "$configuration" != debug && "$configuration" != release ]]; then print -u2 'Build configuration must be debug or release'; exit 1; fi
mkdir -p .build dist.noindex
zsh scripts/compile-app.sh "$configuration"
binary_dir="$PWD/.build/app-binary/$configuration"
staging_root=$(mktemp -d "$PWD/.build/app-stage.XXXXXX")
cleanup_build() { rm -rf "$staging_root"; }
trap cleanup_build EXIT
app="$staging_root/拾影.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_dir/PhotoHarbor" "$app/Contents/MacOS/PhotoHarbor"
# Only the approved source artwork is versioned; all generated icon files stay local.
icon_build="$PWD/.build/app-icon"
mkdir -p "$icon_build"
icon_input=$(ruby -rdigest -e 'd=Digest::SHA256.new;ARGV.each{|f|d<<File.binread(f)};puts d.hexdigest' assets/AppIcon/master.png scripts/prepare-system-icon.swift scripts/package-icon.swift scripts/verify-icon.swift)
icon_output=missing
if [[ -f "$icon_build/AppIcon.icns" ]]; then icon_output=$(shasum -a 256 "$icon_build/AppIcon.icns" | cut -d' ' -f1); fi
if [[ ! -f "$icon_build/verified.cache" || "$(cat "$icon_build/verified.cache")" != "$icon_input $icon_output" ]]; then
  rm -f "$icon_build/verified.cache"
  xcrun swift -module-cache-path "$CLANG_MODULE_CACHE_PATH" scripts/prepare-system-icon.swift "$PWD/assets/AppIcon/master.png" "$icon_build/master.png" 0 0 1024 1024
  xcrun swift -module-cache-path "$CLANG_MODULE_CACHE_PATH" scripts/package-icon.swift "$icon_build/master.png" "$icon_build/AppIcon.iconset" "$icon_build/AppIcon.icns"
  xcrun swift -module-cache-path "$CLANG_MODULE_CACHE_PATH" scripts/verify-icon.swift "$PWD/assets/AppIcon/master.png" "$icon_build/master.png" "$icon_build/AppIcon.icns"
  icon_output=$(shasum -a 256 "$icon_build/AppIcon.icns" | cut -d' ' -f1)
  print -r -- "$icon_input $icon_output" > "$icon_build/verified.cache"
else
  print 'Using verified icon cache'
fi
cp "$icon_build/AppIcon.icns" "$app/Contents/Resources/AppIconPearlWhiteSized.icns"
rm -f "$app/Contents/Resources/AppIconPearlWhiteAlpha.icns" "$app/Contents/Resources/AppIconPearlWhite.icns" "$app/Contents/Resources/AppIconGlass.icns"
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
<key>CFBundleIconFile</key><string>AppIconPearlWhiteSized</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleShortVersionString</key><string>1.1.8</string>
<key>CFBundleVersion</key><string>36</string>
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
output="$PWD/dist.noindex/拾影.app"
if [[ -e "$output" ]]; then mv "$output" "$staging_root/previous.app"; fi
mv "$app" "$output"
print "已生成：$output ($configuration)"
