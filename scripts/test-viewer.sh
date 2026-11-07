#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/viewer-tests
zsh scripts/compile-test.sh .build/viewer-tests/geometry Sources/PhotoHarbor/ViewerGeometry.swift scripts/ViewportTests.swift
.build/viewer-tests/geometry
zsh scripts/compile-test.sh .build/viewer-tests/chrome Sources/PhotoHarbor/ViewerChrome.swift scripts/ChromeTests.swift
.build/viewer-tests/chrome
zsh scripts/compile-test.sh .build/viewer-tests/cache Sources/PhotoHarbor/ViewerImageCache.swift scripts/ViewerCacheTests.swift
.build/viewer-tests/cache
