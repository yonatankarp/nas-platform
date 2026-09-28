#!/usr/bin/env ruby
# Emit one decimal port per roster service, in roster order, from a validated input.
# usage: read-integration-ports.rb PATH REPOSITORY SERVICE...
# TOCTOU-safe read (lstat/fstat/stat must agree); every refusal is just `unsafe`.
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
