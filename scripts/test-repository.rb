#!/usr/bin/env ruby
require 'tmpdir'
require 'open3'
require 'fileutils'

scanner = File.expand_path('check-repository.rb', __dir__)
Dir.mktmpdir('photo-harbor-audit-') do |dir|
  git = ->(*args) do
    output, status = Open3.capture2e('git', '-C', dir, *args)
    raise "fixture git command failed" unless status.success?
    output
  end
  git.call('init', '--quiet')
  File.write(File.join(dir, 'README.md'), "Synthetic public fixture\n")
  git.call('add', 'README.md')
  audit = -> { Open3.capture2e('ruby', scanner, chdir: dir).last.success? }
  raise 'clean index rejected' unless audit.call
  cases = {
    'API credential' => ['fixture.txt', 'gh' + 'p_' + ('A' * 40)],
    'private path' => ['fixture.txt', '/' + 'Users/' + 'sample/' + 'Pictures/example'],
    'private filename' => ['.env', 'SYNTHETIC=example'],
    'binary file' => ['fixture.bin', "\0synthetic"]
  }
  cases.each do |name, (path, content)|
    File.binwrite(File.join(dir, path), content)
    git.call('add', '-f', path)
    raise "#{name} accepted" if audit.call
    # A benign working tree must not hide a secret still in the Git index.
    File.write(File.join(dir, path), 'benign unstaged replacement')
    raise 'index/working-tree mismatch bypassed audit' if audit.call
    git.call('rm', '--cached', '--force', '--quiet', path)
    FileUtils.rm_f(File.join(dir, path))
    raise 'audit failed after fixture removal' unless audit.call
    puts "PASS repository audit blocks #{name} and checks staged content"
  end
end
