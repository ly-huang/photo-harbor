#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/store-tests
sources=(Sources/PhotoHarbor/*.swift)
sources=(${sources:#Sources/PhotoHarbor/PhotoHarborApp.swift})
zsh scripts/compile-test.sh .build/store-tests/run $sources scripts/StoreTests.swift
.build/store-tests/run
