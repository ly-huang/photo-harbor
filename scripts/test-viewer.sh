#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/viewer-tests
xcrun swiftc -parse-as-library -swift-version 5 -module-cache-path "$PWD/.build/clang-cache" Sources/PhotoHarbor/ViewerGeometry.swift scripts/ViewportTests.swift -o .build/viewer-tests/geometry
.build/viewer-tests/geometry
xcrun swiftc -parse-as-library -swift-version 5 -module-cache-path "$PWD/.build/clang-cache" Sources/PhotoHarbor/ViewerChrome.swift scripts/ChromeTests.swift -o .build/viewer-tests/chrome
.build/viewer-tests/chrome
