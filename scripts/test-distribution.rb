#!/usr/bin/env ruby
require 'open3'
require 'rbconfig'
root = File.expand_path('..', __dir__)
script = File.join(root, 'scripts/release-notes.rb')
version = File.read(File.join(root, 'scripts/build-app.sh'))[/CFBundleShortVersionString<\/key><string>([^<]+)/, 1]
raise 'Missing app version' unless version
notes, error, result = Open3.capture3(RbConfig.ruby, script, "v#{version}")
raise "Release notes failed: #{error}" unless result.success?
raise 'Missing distribution disclosures' unless notes.include?('未经 Developer ID') && notes.include?('SHA256SUMS.txt') && notes.include?('Apple Silicon')
raise 'Missing version changelog' unless notes.include?('## 版本变更') && notes.include?("PhotoHarbor-#{version}-macos-arm64.dmg")
['v999999.0.0', 'v1.2.3-rc1', '../1.2.3', 'v1.2.3;exit', ''].each do |tag|
  _, _, result = Open3.capture3(RbConfig.ruby, script, tag)
  raise "Unexpected acceptance of invalid or missing version: #{tag}" if result.success?
end
puts 'PASS release notes version matching, distribution disclosures and invalid/missing tag rejection'
