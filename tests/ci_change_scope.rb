#!/usr/bin/env ruby
# frozen_string_literal: true

require "open3"
require "rbconfig"

def check(actual, expected, label)
  raise "#{label}: expected #{expected.inspect}, got #{actual.inspect}" unless actual == expected
end

def classify(paths)
  !paths.empty? && paths.all? do |path|
    path == "README.md" || path.start_with?("docs/")
  end
end

def parse_paths(input)
  return [] if input.empty?
  raise "changed paths must be NUL-delimited" unless input.end_with?("\0")

  paths = input.split("\0", -1)
  paths.pop
  raise "changed paths must be NUL-delimited" if paths.any?(&:empty?)
  raise "changed paths must be relative" if paths.any? { |path| path.start_with?("/") }
  raise "changed paths contain control bytes" if paths.any? { |path| path.match?(/[[:cntrl:]]/) }
  raise "changed paths contain an unsafe component" if paths.any? do |path|
    path.split("/", -1).any? { |component| [".", "..", ""].include?(component) }
  end
  paths
end

def run_cli(argv, input)
  raise "usage: ci_change_scope.rb [--self-test]" unless argv.empty?
  paths = parse_paths(input)
  "docs_only=#{classify(paths)}\nchanged_count=#{paths.length}\n"
end

def self_test_case(label, input, args, success, stdout, stderr)
  env = { "CI_CHANGE_SCOPE_CHILD" => "1" }
  actual_stdout, actual_stderr, status = Open3.capture3(env, RbConfig.ruby, __FILE__, *args, stdin_data: input)
  check([status.success?, actual_stdout, actual_stderr], [success, stdout, stderr], label)
end

if ARGV == ["--self-test"] && ENV["CI_CHANGE_SCOPE_CHILD"] != "1"
  self_test_case("valid docs", "docs/page.md\0README.md\0", [], true, "docs_only=true\nchanged_count=2\n", "")
  self_test_case("empty", "", [], true, "docs_only=false\nchanged_count=0\n", "")
  self_test_case("mixed", "docs/page.md\0roles/app.yml\0", [], true, "docs_only=false\nchanged_count=2\n", "")
  self_test_case("missing terminal NUL", "docs/page.md", [], false, "", "changed paths must be NUL-delimited\n")
  self_test_case("unterminated final record", "docs/page.md\0README.md", [], false, "", "changed paths must be NUL-delimited\n")
  self_test_case("embedded empty record", "docs/page.md\0\0", [], false, "", "changed paths must be NUL-delimited\n")
  self_test_case("absolute path", "/docs/page.md\0", [], false, "", "changed paths must be relative\n")
  self_test_case("control byte", "docs/page\x01.md\0", [], false, "", "changed paths contain control bytes\n")
  self_test_case("newline", "docs/page\n.md\0", [], false, "", "changed paths contain control bytes\n")
  self_test_case("dot", "docs/./page.md\0", [], false, "", "changed paths contain an unsafe component\n")
  self_test_case("dot-dot", "docs/../page.md\0", [], false, "", "changed paths contain an unsafe component\n")
  self_test_case("trailing empty component", "docs/\0", [], false, "", "changed paths contain an unsafe component\n")
  self_test_case("unexpected args", "", ["unexpected"], false, "", "usage: ci_change_scope.rb [--self-test]\n")
  puts "CI change scope: fail-closed classification holds"
  exit
end

begin
  puts run_cli(ARGV, STDIN.binmode.read)
rescue RuntimeError => e
  abort e.message
end
