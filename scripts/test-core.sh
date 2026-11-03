#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/core-tests
sed 's/^import XCTest$/import Foundation/; /@testable import PhotoHarbor/d' Tests/PhotoHarborTests/LibraryServiceTests.swift > .build/core-tests/Cases.swift
zsh scripts/compile-test.sh .build/core-tests/run Sources/PhotoHarbor/Models.swift Sources/PhotoHarbor/LibraryService.swift Sources/PhotoHarbor/PhotoExport.swift .build/core-tests/Cases.swift scripts/TestHarness.swift
.build/core-tests/run
