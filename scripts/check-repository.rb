#!/usr/bin/env ruby
# Audit the Git index, not just the working tree: unstaged edits must not hide a leak.
require 'open3'

paths, status = Open3.capture2('git', 'ls-files', '--cached', '-z')
abort 'Run inside a Git repository after staging intended files.' unless status.success?
files = paths.split("\0")
abort 'No tracked files to audit; stage the intended source files first.' if files.empty?
failures = []
secret_rules = {
  'private key' => /-----BEGIN (?:[A-Z0-9 ]+ )?PRIVATE KEY-----/,
  'GitHub credential' => /(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})/,
  'API credential' => /\bsk-(?:proj-)?[A-Za-z0-9_-]{30,}/,
  'cloud access key' => /\b(?:AKIA|ASIA)[A-Z0-9]{16}\b/,
  'credential assignment' => /(?:api[_-]?key|access[_-]?token|password|client[_-]?secret)\s*[:=]\s*["'][A-Za-z0-9_+\/-]{20,}["']/i,
  'credential in URL' => %r{https?://[^\s/:@]+:[^\s/@]+@},
  'personal absolute path' => %r{/(?:Users|Volumes|home)/[A-Za-z0-9_.-]+/}
}
forbidden_path = %r{(?:\A|/)(?:\.env(?:\..*)?|\.netrc|\.npmrc|\.aws|\.ssh|\.codex|\.agents|archive\.local|\.build|dist(?:\.noindex)?|state\.json)(?:/|\z)|\.(?:pem|key|p12|pfx|mobileprovision|provisionprofile|jpe?g|arw|dng|cr[23]|nef|heic|log)\z}i
files.each do |path|
  failures << [path, 'forbidden local/private file'] if path.match?(forbidden_path)
  data, ok = Open3.capture2('git', 'show', ":#{path}")
  unless ok.success?
    failures << [path, 'unable to inspect index entry']; next
  end
  data = data.b
  failures << [path, 'unexpected file larger than 2 MiB'] if data.bytesize > 2 * 1024 * 1024
  if path == 'assets/AppIcon/master.png'
    unless data.start_with?("\x89PNG\r\n\x1a\n".b)
      failures << [path, 'expected PNG icon source']; next
    end
    offset = 8
    while offset < data.bytesize
      length = data[offset, 4]&.unpack1('N')
      unless length && offset + length + 12 <= data.bytesize
        failures << [path, 'invalid PNG structure']; break
      end
      kind = data[offset + 4, 4]
      failures << [path, 'PNG contains textual/EXIF/time metadata'] if %w[tEXt iTXt zTXt eXIf tIME].include?(kind)
      offset += length + 12
    end
    next
  end
  if data.include?("\0")
    failures << [path, 'unexpected binary file']; next
  end
  text = data.force_encoding(Encoding::UTF_8)
  unless text.valid_encoding?
    failures << [path, 'not UTF-8 text']; next
  end
  secret_rules.each { |name, pattern| failures << [path, name] if text.match?(pattern) }
  emails = text.scan(/\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/i)
  failures << [path, 'non-noreply email address'] if emails.any? { |mail| !mail.end_with?('@users.noreply.github.com', '@example.com') && !mail.match?(/\Aicon_\d+x\d+@2x\.png\z/) }
end
unless failures.empty?
  failures.uniq.each { |path, rule| warn "BLOCKED #{path}: #{rule}" }
  abort 'Repository audit failed. No suspected secret values were printed.'
end
puts "Repository audit passed (#{files.length} indexed files; no disallowed metadata or detected credentials)."
