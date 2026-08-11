#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require_relative "legacy_secure_copy"

Dir.mktmpdir("nas-platform-secure-copy.") do |root|
  source = File.join(root, "source")
  target = File.join(root, "target")
  File.write(source, "expected\n", mode: "w", perm: 0o600)
  LegacySecureCopy.copy(source, target)
  raise "copy differs" unless File.read(target) == "expected\n"
  raise "mode differs" unless File.stat(target).mode & 0o777 == 0o600

  File.unlink(target)
  File.write(source, "initial\n", mode: "w", perm: 0o600)
  begin
    LegacySecureCopy.copy(source, target, before_open: lambda {
      File.rename(source, "#{source}.initial")
      File.write(source, "replacement\n", mode: "w", perm: 0o600)
    })
    raise "regular-file swap was accepted"
  rescue LegacySecureCopy::Unsafe
    raise "swap created destination" if File.exist?(target)
  end

  File.unlink(source)
  File.rename("#{source}.initial", source)
  begin
    LegacySecureCopy.copy(source, target, before_open: lambda {
      File.rename(source, "#{source}.initial")
      File.symlink("#{source}.initial", source)
    })
    raise "symlink swap was accepted"
  rescue LegacySecureCopy::Unsafe
    raise "symlink swap created destination" if File.exist?(target)
  end
end

puts "Legacy secure copy: descriptor identity and atomic publication hold"
