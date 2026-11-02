#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
zsh scripts/compile-test.sh .build/marker-tests/run Sources/PhotoHarbor/Models.swift Sources/PhotoHarbor/LibraryService.swift Sources/PhotoHarbor/EditPersistence.swift Sources/PhotoHarbor/PhotoMarks.swift scripts/MarkerTests.swift
.build/marker-tests/run
