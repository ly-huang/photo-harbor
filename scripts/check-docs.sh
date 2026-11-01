#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
base="${1:?Provide the base commit}"
git diff --name-only "$base" HEAD | ruby -e '
  changed = STDIN.read.lines.map(&:strip)
  code = changed.any? { |path| path.match?(%r{\A(?:Sources/|scripts/|assets/|Package\.swift\z)}) }
  abort "代码或构建行为变化必须同步 CHANGELOG.md，并更新对应文档。" if code && !changed.include?("CHANGELOG.md")
  puts "Documentation change policy passed."
'
