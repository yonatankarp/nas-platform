#!/usr/bin/env ruby
# Emit one decimal port per roster service, in roster order, from a validated
# integration ports input.
#
# usage: read-integration-ports.rb PATH REPOSITORY SERVICE...
#
# The roster arrives as arguments rather than as a literal list so that the
# emission order and the order tests/mac/run.sh unpacks are the same list. Every
# refusal is the single word `unsafe`, deliberately: the caller turns any failure
# into one diagnostic, and nothing about the rejected file is echoed back.
#
# The checks are a TOCTOU-safe read, not a parse. The file is opened once and the
# stat held through the descriptor must agree with the lstat taken before it and
# with the stat taken after the read, so a file swapped underneath the path is
# refused rather than parsed. REPOSITORY is the tree the input must NOT live
# inside; it is a tree under inspection, never the checkout this program is part
# of, and the caller resolves this program from its own directory.
#
# It lived in a `<<'RUBY'` heredoc in tests/mac/run.sh until #315, opened as
# `ruby -rjson -`; the require below is that preload, which the body never had.
require "json"

path, repository, *services = ARGV
expected = services.map { |service| "#{service}_port" }
raise "unsafe" if expected.empty? || expected.uniq.length != expected.length
flags = File::RDONLY
flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
raise "unsafe" unless File.absolute_path(path) == path && !File.symlink?(path)
parent = File.realpath(File.dirname(path))
repository = File.realpath(repository)
raise "unsafe" if parent == repository || parent.start_with?(repository + File::SEPARATOR)
before = File.lstat(path)
raise "unsafe" unless before.file? && before.uid == Process.uid &&
  (before.mode & 0o777) == 0o600 && before.size <= 4096
bytes = File.open(path, flags) do |input|
  held = input.stat
  raise "unsafe" unless [held.dev, held.ino, held.size, held.mode, held.uid] ==
    [before.dev, before.ino, before.size, before.mode, before.uid]
  value = input.read(4097)
  raise "unsafe" if value.bytesize > 4096
  after = input.stat
  raise "unsafe" unless [after.dev, after.ino, after.size, after.mode, after.uid, after.mtime.to_r, after.ctime.to_r] ==
    [held.dev, held.ino, held.size, held.mode, held.uid, held.mtime.to_r, held.ctime.to_r]
  value
end
document = JSON.parse(bytes)
raise "unsafe" unless document.is_a?(Hash) && document.keys.sort == (["schema"] + expected).sort &&
  document["schema"] == 1
ports = expected.map { |name| document.fetch(name) }
raise "unsafe" unless ports.all? { |port| port.is_a?(Integer) && port.between?(1024, 65_535) } &&
  ports.uniq.length == ports.length
puts ports.join(" ")
