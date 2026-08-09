#!/usr/bin/env ruby
# frozen_string_literal: true

def check(actual, expected, label)
  raise "#{label}: expected #{expected.inspect}, got #{actual.inspect}" unless actual == expected
end

def classify(paths)
  !paths.empty? && paths.all? do |path|
    path == "README.md" || path.start_with?("docs/")
  end
end

if ARGV == ["--self-test"]
  check(classify(["README.md"]), true, "README")
  check(classify(["docs/guide.md", "docs/nested/page.md"]), true, "docs")
  check(classify(["docs/guide.md", "roles/ntfy/tasks/main.yml"]), false, "mixed")
  check(classify([".github/workflows/ci.yml"]), false, "workflow")
  check(classify([]), false, "empty")
  check(classify(["docs"]), false, "docs directory literal")
  puts "CI change scope: fail-closed classification holds"
  exit
end

abort "usage: ci_change_scope.rb [--self-test]" unless ARGV.empty?
input = STDIN.binmode.read
paths = input.split("\0", -1)
paths.pop if paths.last == ""
abort "changed paths must be NUL-delimited" if paths.any?(&:empty?)
abort "changed paths must be relative" if paths.any? { |path| path.start_with?("/") }
abort "changed paths contain control bytes" if paths.any? { |path| path.match?(/[[:cntrl:]]/) }
abort "changed paths contain an unsafe component" if paths.any? do |path|
  path.split("/").any? { |component| [".", "..", ""].include?(component) }
end
puts "docs_only=#{classify(paths)}"
puts "changed_count=#{paths.length}"
