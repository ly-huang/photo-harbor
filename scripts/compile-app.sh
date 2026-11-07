#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
configuration=${1:-debug}
build_dir="$PWD/.build/app-binary/$configuration"
mkdir -p "$build_dir"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
sdk=$(xcrun --sdk macosx --show-sdk-path)
target="$(uname -m)-apple-macosx14.0"
flags=(-Onone -g)
if [[ "$configuration" == release ]]; then flags=(-O); fi
sources=(Sources/PhotoHarbor/*.swift)

# Reuse a complete binary only. Mixing incremental objects after a type layout
# change can produce an executable that links successfully but crashes at launch.
cache_key=$(
  {
    xcrun swiftc --version
    xcrun --sdk macosx --show-sdk-build-version
    printf '%s\n' "$sdk" "$target" "${flags[@]}"
    shasum -a 256 scripts/compile-app.sh "${sources[@]}"
  } | shasum -a 256 | cut -d' ' -f1
)
output="$build_dir/PhotoHarbor"
stamp="$build_dir/build.cache"
if [[ "${PHOTOHARBOR_CLEAN_BUILD:-0}" != 1 && -f "$output" && -f "$stamp" ]]; then
  binary_key=$(shasum -a 256 "$output" | cut -d' ' -f1)
  if [[ "$(cat "$stamp")" == "$cache_key $binary_key" ]]; then
    print "Using verified app build: $configuration"
    exit 0
  fi
fi

staging=$(mktemp -d "$build_dir/build.XXXXXX")
trap 'rm -rf "$staging"' EXIT
xcrun swiftc -sdk "$sdk" -target "$target" -emit-executable -swift-version 5 \
  -module-name PhotoHarbor -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
  -j 4 "${flags[@]}" "${sources[@]}" -o "$staging/PhotoHarbor"
binary_key=$(shasum -a 256 "$staging/PhotoHarbor" | cut -d' ' -f1)
print -r -- "$cache_key $binary_key" > "$staging/build.cache"
mv -f "$staging/PhotoHarbor" "$output"
mv -f "$staging/build.cache" "$stamp"
