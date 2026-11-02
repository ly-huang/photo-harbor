#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
output=$1
shift
mkdir -p "${output:h}" .build/test-cache
compiler_id=$(xcrun swiftc --version)
export PHOTOHARBOR_TEST_COMPILER="$compiler_id"
cache_key=$(ruby -rdigest -e 'd=Digest::SHA256.new;d<<ENV.fetch("PHOTOHARBOR_TEST_COMPILER");d<<File.binread("scripts/compile-test.sh");ARGV.each{|a|d<<a;d<<File.binread(a) if File.file?(a)};puts d.hexdigest' "$@")
stamp="$output.cache"
if [[ "${PHOTOHARBOR_CLEAN_BUILD:-0}" != 1 && -f "$output" && -f "$stamp" ]]; then
  binary_key=$(shasum -a 256 "$output" | cut -d' ' -f1)
  if [[ "$(cat "$stamp")" == "$cache_key $binary_key" ]]; then
    print "Using cached test build: ${output:t}"
    exit 0
  fi
fi
xcrun swiftc -parse-as-library -swift-version 5 -module-cache-path "$PWD/.build/clang-cache" "$@" -o "$output"
binary_key=$(shasum -a 256 "$output" | cut -d' ' -f1)
print -r -- "$cache_key $binary_key" > "$stamp"
