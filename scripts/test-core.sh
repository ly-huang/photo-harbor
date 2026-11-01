#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/core-tests
sed 's/^import XCTest$/import Foundation/; /@testable import PhotoHarbor/d' Tests/PhotoHarborTests/LibraryServiceTests.swift > .build/core-tests/Cases.swift
xcrun swiftc -parse-as-library -swift-version 5 -module-cache-path "$PWD/.build/clang-cache" Sources/PhotoHarbor/Models.swift Sources/PhotoHarbor/LibraryService.swift .build/core-tests/Cases.swift scripts/TestHarness.swift -o .build/core-tests/run
.build/core-tests/run
