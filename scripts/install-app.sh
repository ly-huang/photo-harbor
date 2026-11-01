#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
source_app="$PWD/dist.noindex/拾影.app"
installed_app="/Applications/拾影.app"
legacy_app="$HOME/Applications/拾影.app"
if [[ ! -f "$source_app/Contents/Info.plist" ]]; then
  print -u2 '请先运行 scripts/build-app.sh'
  exit 1
fi
if [[ -e "$installed_app" ]]; then
  existing_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$installed_app/Contents/Info.plist")
  if [[ "$existing_id" != 'com.tron.photoharbor' && "$existing_id" != 'local.photoharbor.app' ]]; then
    print -u2 '目标位置已有其他应用，停止安装。'
    exit 1
  fi
  if /usr/bin/pgrep -f "$installed_app/Contents/MacOS/PhotoHarbor" >/dev/null; then
    print -u2 '请先退出已安装的拾影，再更新。'
    exit 1
  fi
fi
# The user chose the system Applications directory for all future installs.
if [[ -e "$legacy_app" ]]; then
  legacy_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$legacy_app/Contents/Info.plist")
  if [[ "$legacy_id" != 'com.tron.photoharbor' && "$legacy_id" != 'local.photoharbor.app' ]]; then
    print -u2 '用户目录中同名应用标识不同，停止迁移。'
    exit 1
  fi
  if /usr/bin/pgrep -f "$legacy_app/Contents/MacOS/PhotoHarbor" >/dev/null; then
    print -u2 '请先退出用户目录中的拾影，再迁移。'
    exit 1
  fi
fi
# Stage and verify a clean bundle. Merging with ditto leaves obsolete icon
# resources behind, invalidating the resource seal after an icon filename change.
staging_dir=$(/usr/bin/mktemp -d "/Applications/.photoharbor-install.XXXXXX")
cleanup_install() {
  result=$?
  if [[ "$result" != 0 && ! -e "$installed_app" && -d "$staging_dir/previous.app" ]]; then
    /bin/mv "$staging_dir/previous.app" "$installed_app"
  fi
  /bin/rm -rf "$staging_dir"
}
trap cleanup_install EXIT
/usr/bin/ditto "$source_app" "$staging_dir/next.app"
codesign --verify --deep --strict "$staging_dir/next.app"
if [[ -e "$installed_app" ]]; then
  /bin/mv "$installed_app" "$staging_dir/previous.app"
fi
/bin/mv "$staging_dir/next.app" "$installed_app"
codesign --verify --deep --strict "$installed_app"
touch "$installed_app"
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
# Remove only the obsolete development location so launches resolve to the install.
"$lsregister" -u "$source_app" || true
# Retire the verified old bundle only after the system copy has passed validation.
# Application data remains in ~/Library/Application Support/PhotoHarbor.
if [[ -e "$legacy_app" ]]; then
  "$lsregister" -u "$legacy_app" || true
  /bin/mv "$legacy_app" "$staging_dir/previous-user.app"
fi
"$lsregister" -f "$installed_app"
/usr/bin/mdimport -i "$installed_app" || print -u2 '应用已安装；Spotlight 将在后台更新索引。'
print "已安装：$installed_app"
