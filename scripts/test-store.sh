#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/store-tests
sources=(Sources/PhotoHarbor/*.swift)
sources=(${sources:#Sources/PhotoHarbor/PhotoHarborApp.swift})
xcrun swiftc -parse-as-library -swift-version 5 -module-cache-path "$PWD/.build/clang-cache" $sources scripts/StoreTests.swift -o .build/store-tests/run
.build/store-tests/run
