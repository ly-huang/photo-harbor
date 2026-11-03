#!/usr/bin/env ruby
# Generate release notes from the matching changelog section, without local paths.
version = ARGV.fetch(0, '').delete_prefix('v')
abort 'Expected a stable semantic version' unless version.match?(/\A\d+\.\d+\.\d+\z/)
root = File.expand_path('..', __dir__)
changelog = File.read(File.join(root, 'CHANGELOG.md'))
section = changelog[/^## #{Regexp.escape(version)}(?:[^\n]*)\n(.*?)(?=^## |\z)/m, 1]
abort 'No changelog section found for release version' unless section
puts "## 安装与兼容性\n\n"
puts "下载 `PhotoHarbor-#{version}-macos-arm64.dmg`，打开后将「拾影.app」拖入「Applications」。"
puts "\n- 仅支持 Apple Silicon（M 系列）Mac，最低 macOS 14；审美评分需 macOS 15+，系统玻璃效果需 macOS 26+。"
puts "- 本包使用临时签名，**未经 Developer ID 签名和 Apple 公证**，系统可能阻止首次打开。请核对来源与校验文件，并参考 [Apple 官方说明](https://support.apple.com/102445)。"
puts "- 同目录下载 DMG 与 `SHA256SUMS.txt` 后，可运行 `shasum -a 256 -c SHA256SUMS.txt` 校验下载完整性。"
puts "- 此校验不替代 Apple 公证，也不证明软件不存在安全问题。"
puts "\n## 版本变更\n\n#{section.strip}\n"
