#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
ruby scripts/check-repository.rb
ruby scripts/test-repository.rb
ruby scripts/test-distribution.rb
zsh scripts/test-core.sh
zsh scripts/test-store.sh
zsh scripts/test-viewer.sh
zsh scripts/test-editor.sh
zsh scripts/test-marks.sh
