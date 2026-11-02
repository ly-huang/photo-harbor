#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/editor-tests
zsh scripts/compile-test.sh .build/editor-tests/run Sources/PhotoHarbor/ViewState.swift Sources/PhotoHarbor/Models.swift Sources/PhotoHarbor/LibraryService.swift Sources/PhotoHarbor/EditPersistence.swift Sources/PhotoHarbor/LUTLibrary.swift Sources/PhotoHarbor/RotationRuler.swift Sources/PhotoHarbor/ChannelCurves.swift Sources/PhotoHarbor/SystemAdjustments.swift Sources/PhotoHarbor/EditorGeometry.swift Sources/PhotoHarbor/PhotosAdjustmentTypes.swift Sources/PhotoHarbor/PhotoFilterLibrary.swift Sources/PhotoHarbor/ImageGeometryPlan.swift Sources/PhotoHarbor/PhotoEffects.swift Sources/PhotoHarbor/PhotoEditor.swift Sources/PhotoHarbor/GlassSlider.swift Sources/PhotoHarbor/AdvancedAdjustmentControls.swift scripts/EditorTests.swift
.build/editor-tests/run
