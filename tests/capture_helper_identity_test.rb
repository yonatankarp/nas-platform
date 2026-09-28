#!/usr/bin/env ruby
# frozen_string_literal: true
# Asserts the three per-file copies of capture3_with_timeout and its helpers stay
# byte-identical, region by region (#464, #470). Regions are declared, not inferred,
# because the files legitimately differ around them; a Ruby-parser cross-check catches
# an `end` scan that ran past the real end.

require "digest"

require_relative "policy_support"

include TestScaffold

FIXTURE_FILES = %w[
  tests/immich_configured_password_test.rb
  tests/beszel_password_preservation_test.rb
  tests/audiobookshelf_initial_scan_behavior_test.rb
].freeze

# `start`/`finish` match whole lines; `finish` is the first match after `start`.
# `definitions`..`locals` must each appear exactly once in the whole file.
REGIONS = [
  {
    "name" => "capture limit comment, constant and overflow error class",
    "start" => /\A# The most bytes one stream of one capture may accumulate before the capture is\z/,
    "finish" => /\Aclass FixtureCaptureOverflow < StandardError; end\z/,
    "minimum_lines" => 13,
    "definitions" => [],
    "constants" => %w[CAPTURE_LIMIT_BYTES],
    "classes" => %w[FixtureCaptureOverflow],
    "locals" => []
  },
  {
    "name" => "terminate_process_group",
    "start" => /\Adef terminate_process_group\(pid, signal\)\z/,
    "finish" => /\Aend\z/,
    "minimum_lines" => 5,
    "definitions" => %w[terminate_process_group],
    "constants" => [],
    "classes" => [],
    "locals" => []
  },
  {
    "name" => "bounded_capture, with the comment that says why it returns rather than raises",
    "start" => /\A# Closing the stream at the limit is the half that bounds memory in real time:\z/,
    "finish" => /\Aend\z/,
    "minimum_lines" => 11,
    "definitions" => %w[bounded_capture],
    "constants" => [],
    "classes" => [],
    "locals" => []
  },
  {
    "name" => "capture3_with_timeout",
    "start" => /\Adef capture3_with_timeout\(environment, \*command, chdir:, timeout_seconds:,\z/,
    "finish" => /\Aend\z/,
    "minimum_lines" => 36,
    "definitions" => %w[capture3_with_timeout],
    "constants" => [],
    "classes" => [],
    "locals" => []
  },
  {
    "name" => "the shared capture-overflow case",
    "start" => /\A# The capture limit is the only bound on how much of a runaway child this process\z/,
    "finish" => /\A      "a capture past its limit was not refused as an overflow: \#\{overflow\.inspect\}"\)\z/,
    "minimum_lines" => 18,
    "definitions" => [],
    "constants" => [],
    "classes" => [],
    "locals" => %w[overflow]
  }
].freeze

# Stated rather than derived, so a deleted file or region narrows the comparison
# loudly instead of leaving a smaller one green.
EXPECTED_FILES = 3
EXPECTED_REGIONS = 5
EXPECTED_EXTRACTIONS = 15

failures = []

check(failures, FIXTURE_FILES.length == EXPECTED_FILES,
      "the identity comparison must cover #{EXPECTED_FILES} files, not " \
      "#{FIXTURE_FILES.length}: a copy dropped from this list is a copy free to diverge")
check(failures, REGIONS.length == EXPECTED_REGIONS,
      "the shared surface must be #{EXPECTED_REGIONS} declared regions, not " \
      "#{REGIONS.length}: a region dropped from this list is compared by nothing")

def parsed_nodes(path)
  nodes = []
  walk = lambda do |node|
    return unless node.is_a?(RubyVM::AbstractSyntaxTree::Node)

    nodes << node
    node.children.each { |child| walk.call(child) }
  end
  walk.call(RubyVM::AbstractSyntaxTree.parse_file(path))
  nodes
end

def definition_spans(nodes, name)
  nodes.select { |node| node.type == :DEFN && node.children.first.to_s == name }
       .map { |node| [node.first_lineno, node.last_lineno] }
end

def constant_spans(nodes, name)
  nodes.select { |node| node.type == :CDECL && node.children.first.to_s == name }
       .map { |node| [node.first_lineno, node.last_lineno] }
end

def class_spans(nodes, name)
  nodes.select { |node| node.type == :CLASS && node.children.first.children.last.to_s == name }
       .map { |node| [node.first_lineno, node.last_lineno] }
end

def local_spans(nodes, name)
  nodes.select { |node| node.type == :LASGN && node.children.first.to_s == name }
       .map { |node| [node.first_lineno, node.last_lineno] }
end

# A missing parser must fail rather than silently reduce this to the textual scan.
PARSER_AVAILABLE = defined?(RubyVM::AbstractSyntaxTree) == "constant"
check(failures, PARSER_AVAILABLE,
      "RubyVM::AbstractSyntaxTree is unavailable, so the parser cross-check " \
      "cannot run and the textual extraction below would be unverified")

extractions = {}

FIXTURE_FILES.each do |relative|
  path = File.join(ROOT, relative)
  unless File.file?(path)
    failures << "#{relative} is absent, so the copy it carries is compared against nothing"
    next
  end

  lines = File.readlines(path, chomp: true)
  nodes = PARSER_AVAILABLE ? parsed_nodes(path) : []

  REGIONS.each do |region|
    name = region.fetch("name")
    starts = lines.each_index.select { |index| lines[index].match?(region.fetch("start")) }
    unless starts.length == 1
      failures << "#{relative} matches the start of region #{name.inspect} #{starts.length} " \
                  "times, expected exactly once; the extractor cannot say what it compared"
      next
    end

    first = starts.first
    last = ((first + 1)...lines.length).find { |index| lines[index].match?(region.fetch("finish")) }
    if last.nil?
      failures << "#{relative} region #{name.inspect} starts at line #{first + 1} and never " \
                  "reaches its closing line, so nothing was extracted"
      next
    end

    body = lines[first..last]
    check_floor(failures, body.length, region.fetch("minimum_lines"),
                "#{relative} region #{name.inspect} (lines #{first + 1}..#{last + 1})")

    # An `end` scan that overran to a later column-0 `end` would still digest
    # consistently across files; only the parser's end line catches it.
    region.fetch("definitions").each do |method_name|
      spans = definition_spans(nodes, method_name)
      unless spans.length == 1
        failures << "#{relative} defines #{method_name} #{spans.length} times, expected once; " \
                    "region #{name.inspect} cannot be identified by name"
        next
      end
      definition_first, definition_last = spans.first
      check(failures, definition_last == last + 1,
            "#{relative} region #{name.inspect} was extracted through line #{last + 1} but " \
            "#{method_name} ends on line #{definition_last}: the textual scan and the parser " \
            "disagree about where the region stops")
      check(failures, definition_first >= first + 1,
            "#{relative} region #{name.inspect} starts at line #{first + 1}, after " \
            "#{method_name} begins on line #{definition_first}")
      prefix = lines[first...(definition_first - 1)]
      check(failures, prefix.all? { |line| line.start_with?("#") },
            "#{relative} region #{name.inspect} covers #{prefix.length} line(s) before " \
            "#{method_name} and they are not all comments, so the region is a wider span " \
            "than it claims")
    end

    region.fetch("constants").each do |constant|
      spans = constant_spans(nodes, constant)
      check(failures, spans.length == 1 && spans.first.first.between?(first + 1, last + 1),
            "#{relative} must assign #{constant} exactly once, inside region #{name.inspect} " \
            "(lines #{first + 1}..#{last + 1}); the parser found #{spans.inspect}")
    end

    region.fetch("classes").each do |class_name|
      spans = class_spans(nodes, class_name)
      unless spans.length == 1
        failures << "#{relative} declares #{class_name} #{spans.length} times, expected once; " \
                    "region #{name.inspect} cannot be closed on it"
        next
      end
      check(failures, spans.first.last == last + 1,
            "#{relative} region #{name.inspect} was extracted through line #{last + 1} but " \
            "#{class_name} ends on line #{spans.first.last}")
    end

    region.fetch("locals").each do |local|
      spans = local_spans(nodes, local)
      check(failures, spans.length == 1 && spans.first.first.between?(first + 1, last + 1),
            "#{relative} must assign #{local} exactly once, inside region #{name.inspect} " \
            "(lines #{first + 1}..#{last + 1}); the parser found #{spans.inspect}")
    end

    text = "#{body.join("\n")}\n"
    extractions[[relative, name]] = {
      "digest" => Digest::SHA256.hexdigest(text),
      "span" => "#{first + 1}..#{last + 1}"
    }
  end
end

check(failures, extractions.length == EXPECTED_EXTRACTIONS,
      "#{EXPECTED_EXTRACTIONS} region extractions were expected (#{EXPECTED_FILES} files by " \
      "#{EXPECTED_REGIONS} regions), #{extractions.length} succeeded; the comparison below " \
      "covers less than it claims")

# No majority is trusted: print every copy's digest so the split is visible.
REGIONS.each do |region|
  name = region.fetch("name")
  found = FIXTURE_FILES.filter_map do |relative|
    extraction = extractions[[relative, name]]
    [relative, extraction] if extraction
  end
  next if found.empty?

  digests = found.map { |_relative, extraction| extraction.fetch("digest") }.uniq
  next if digests.length == 1 && found.length == EXPECTED_FILES

  if digests.length > 1
    detail = found.map do |relative, extraction|
      "#{relative} lines #{extraction.fetch('span')} #{extraction.fetch('digest')[0, 16]}"
    end
    failures << "region #{name.inspect} has #{digests.length} distinct copies across the " \
                "fixtures, expected one: #{detail.join('; ')}"
  else
    failures << "region #{name.inspect} was extracted from #{found.length} of " \
                "#{EXPECTED_FILES} fixtures, so its single digest proves nothing about the rest"
  end
end

report(failures, "capture helper identity: the shared surface is byte-identical across all three copies",
       "capture helper identity violation(s)")
