#!/usr/bin/env ruby
# frozen_string_literal: true

require "pathname"
require "tmpdir"
require "uri"

ROOT = Pathname.new(File.expand_path("..", __dir__))
SOURCES = [ROOT.join("README.md"), *ROOT.join("docs").glob("**/*.md")].freeze

def markdown_target(body)
  value = body.strip
  return if value.empty?

  if value.start_with?("<")
    closing = value.index(">")
    return unless closing

    value[1...closing]
  else
    value.split(/\s+/, 2).first
  end
end

def check_sources(root, sources)
  root = root.realpath
  failures = []
  sources.each do |source|
    source = source.realpath
    source.read.scan(/\[[^\]]*\]\(([^)]*)\)/).flatten.each do |body|
      raw_target = body.strip
      target = markdown_target(body)
      next if target.nil? || target.empty? || target.start_with?("#")
      next if target.match?(/\A(?:https?|mailto):/i)

      path_text = URI.decode_www_form_component(target.split("#", 2).first)
      resolved = source.dirname.join(path_text).cleanpath
      lexical_inside = resolved.to_s.start_with?("#{root}/")
      valid = lexical_inside && resolved != root && (resolved.file? || resolved.directory?)
      if valid
        begin
          valid = resolved.realpath.to_s.start_with?("#{root}/")
        rescue Errno::ENOENT, Errno::ELOOP
          valid = false
        end
      end
      unless valid
        shown = raw_target.gsub(/[\r\n\t]/, " ")
        failures << "#{source.relative_path_from(root)}: broken local link #{shown}"
      end
    rescue ArgumentError
      shown = raw_target.gsub(/[\r\n\t]/, " ")
      failures << "#{source.relative_path_from(root)}: malformed local link #{shown}"
    end
  end
  failures
end

def self_test
  Dir.mktmpdir("docs-links-test") do |directory|
    root = Pathname.new(directory)
    docs = root.join("docs")
    docs.mkpath
    docs.join("valid file.md").write("ok\n")
    docs.join("subdir").mkpath
    outside = root.parent.join("docs-links-outside-#{Process.pid}")
    outside.write("outside\n")
    docs.join("escape.md").make_symlink(outside)
    source = docs.join("sample.md")
    source.write(<<~MARKDOWN)
      [file](valid%20file.md)
      [titled](<valid%20file.md> "title")
      [directory](subdir/)
      [fragment](valid%20file.md#section)
      [external](https://example.test/missing)
      [missing](missing.md)
      [traversal](../../etc/passwd)
      [malformed](bad%ZZ.md)
      [symlink](escape.md)
    MARKDOWN
    failures = check_sources(root, [source])
    expected = %w[missing.md ../../etc/passwd bad%ZZ.md escape.md]
    unless expected.all? { |target| failures.any? { |failure| failure.end_with?(target) } } && failures.length == expected.length
      warn "docs links self-test failed: #{failures.inspect}"
      exit 1
    end
  ensure
    outside&.delete if outside&.exist?
  end
  puts "docs links: self-test passed"
end

if ARGV == ["--self-test"]
  self_test
else
  failures = check_sources(ROOT, SOURCES)
  if failures.empty?
    puts "docs links: all local targets exist"
  else
    warn failures.join("\n")
    exit 1
  end
end
