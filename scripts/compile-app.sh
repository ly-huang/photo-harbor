#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
configuration=${1:-debug}
mkdir -p ".build/incremental/$configuration"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
mapfile="$PWD/.build/incremental/$configuration/outputs.json"
ruby -rjson -e 'root=ARGV[0];map={""=>{"swift-dependencies"=>root+"/master.swiftdeps"}};Dir["Sources/PhotoHarbor/*.swift"].sort.each{|f|base=root+"/"+File.basename(f,".swift");map[f]={"object"=>base+".o","swift-dependencies"=>base+".swiftdeps","dependencies"=>base+".d"}};File.write(root+"/outputs.json",JSON.pretty_generate(map))' "$PWD/.build/incremental/$configuration"
flags=(-Onone -g)
if [[ "$configuration" == release ]]; then flags=(-O); fi
xcrun swiftc -incremental -emit-dependencies -emit-module -emit-module-path "$PWD/.build/incremental/$configuration/PhotoHarbor.swiftmodule" -target "$(uname -m)-apple-macosx14.0" -emit-executable -swift-version 5 -module-name PhotoHarbor -module-cache-path "$CLANG_MODULE_CACHE_PATH" -output-file-map "$mapfile" -j 4 "${flags[@]}" Sources/PhotoHarbor/*.swift -o ".build/incremental/$configuration/PhotoHarbor"
