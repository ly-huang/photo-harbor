#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
app=${1:-"$PWD/dist.noindex/拾影.app"}
output_directory=${2:-"$PWD/dist.noindex/release"}
plist="$app/Contents/Info.plist"
[[ -f "$plist" ]] || { print -u2 'App bundle not found. Run scripts/build-app.sh --release first.'; exit 1; }
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")
identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")
[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { print -u2 'Invalid bundle version'; exit 1; }
[[ "$identifier" == 'com.tron.photoharbor' ]] || { print -u2 'Unexpected bundle identifier'; exit 1; }
if [[ -n "${RELEASE_TAG:-}" && "$RELEASE_TAG" != "v$version" ]]; then
  print -u2 'Release tag must match CFBundleShortVersionString'; exit 1
fi
[[ "$(lipo -archs "$app/Contents/MacOS/PhotoHarbor")" == arm64 ]] || { print -u2 'This distribution target requires an arm64-only binary'; exit 1; }
codesign --verify --deep --strict "$app"
mkdir -p "$output_directory"
output_directory=${output_directory:A}
filename="PhotoHarbor-$version-macos-arm64.dmg"
[[ ! -e "$output_directory/$filename" && ! -e "$output_directory/SHA256SUMS.txt" ]] || { print -u2 'Release output already exists; use a new output directory.'; exit 1; }
staging=$(mktemp -d "$PWD/.build/dmg-stage.XXXXXX")
cleanup_package() { rm -rf "$staging"; }
trap cleanup_package EXIT
mkdir "$staging/contents"
ditto "$app" "$staging/contents/拾影.app"
ln -s /Applications "$staging/contents/Applications"
cp LICENSE "$staging/contents/LICENSE.txt"
cat > "$staging/contents/安装说明.txt" <<'INSTALL'
拾影 · Photo Harbor

适用：Apple Silicon（M 系列）Mac，macOS 14 或更高版本。
安装：退出已运行的拾影，将「拾影.app」拖入「Applications」文件夹。

此构建采用本地临时签名，未经 Developer ID 签名和 Apple 公证。
macOS 可能阻止首次打开；请核对来源与校验文件，再参考 Apple 官方说明自行判断：
https://support.apple.com/102445
本安装包不会关闭系统安全保护，也不会修改现有照片或应用配置。

项目与版本：
https://github.com/ly-huang/photo-harbor
https://github.com/ly-huang/photo-harbor/releases

照片备份、编辑行为与已知限制详见仓库 README 和 docs。
INSTALL
codesign --verify --deep --strict "$staging/contents/拾影.app"
hdiutil create -quiet -format UDZO -fs HFS+ -volname "Photo Harbor $version" -srcfolder "$staging/contents" "$staging/package.dmg"
hdiutil verify -quiet "$staging/package.dmg"
mv "$staging/package.dmg" "$output_directory/$filename"
(cd "$output_directory" && shasum -a 256 "$filename" > SHA256SUMS.txt)
print "Packaged: $output_directory/$filename"
