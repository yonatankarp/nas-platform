#!/usr/bin/env ruby
# frozen_string_literal: true
# Four checks carry their own copy of capture3_with_timeout and its helpers:
# tests/immich_configured_password_test.rb, tests/ntfy_verify_execution_test.rb,
# tests/beszel_password_preservation_test.rb and
# tests/audiobookshelf_initial_scan_behavior_test.rb. Per-file copies are this
# repository's idiom and the reason is sound -- a shared helper would be another
# .rb to register in tests/validate-policy.sh, in one of its shard lists and in
# tests/policy_ci_test.rb -- but the whole value of that duplication is the
# copies agreeing, and until this file nothing checked that they did.
#
# They have not agreed. #464 found one copy missing
# `unit = timeout_seconds == 1 ? "second" : "seconds"`, rendering "after 1
# seconds", and it had been wrong since it was written because the line only
# renders at a one-second budget and nothing used one. #470 found three copies
# blocking indefinitely after KILL where the fourth bounded its joins at a
# second -- the correct copy was the minority, so the obvious reconciliation
# would have propagated the defect to all four. #474 and #475 each had to land a
# change in all four at once or reintroduce the divergence just removed. Five
# times the central property was "all four agree", five times it was established
# by an agent running an awk extract and a digest by hand and reporting it in a
# pull request body, and nothing carried it into the next change.
#
# This is that comparison, as a check. It extracts a declared list of regions
# from each of the four files and asserts exactly one distinct digest per region.
#
# WHY THE REGION LIST IS DECLARED rather than inferred. The four are not
# identical everywhere and must not be: immich_configured_password_test.rb
# carries the canonical-copy docstring above capture3_with_timeout, and
# audiobookshelf_initial_scan_behavior_test.rb carries a different explanatory
# block in the same place. A heuristic that guessed the shared surface would
# either demand sameness where the files legitimately differ or quietly stop
# covering a region somebody moved. The gate manifest is declared rather than
# inferred for the same reason (#476).
#
# DELIBERATELY OUT OF SCOPE: the "Every join on the timeout path is bounded"
# comment, which immich_configured_password_test.rb and
# audiobookshelf_initial_scan_behavior_test.rb both carry verbatim above
# capture3_with_timeout and the other two do not carry at all. That is a
# two-file property, not a four-way one, and folding it in here would mean
# either declaring a region that two of the four cannot satisfy or weakening the
# comparison from "all four" to "whoever has it". Adding a two-file region is a
# separate decision from this one.
#
# WHY A FLOOR AND AN EXACT COUNT, both. A digest comparison over an empty set
# finds one distinct value and passes, so an extractor that silently matched
# nothing would report the property it stopped checking as holding -- the
# failure this repository saw six times in one day. So every extraction is
# required to have matched its start anchor exactly once, in a named file, with a
# minimum line count; and the shapes of the declarations themselves are asserted
# as literals, because deleting a region declaration narrows the check one level
# up and every surviving assertion still passes.
#
# WHY A SECOND EXTRACTION METHOD. The line-anchored scan below is textual, and
# textual extraction has been wrong twice in this repository in a week: a
# `grep -c` of a name counted definitions alongside uses, and a regex for a
# construct matched a comment mentioning the construct. So every region is
# cross-checked against Ruby's own parser, which fails differently: each
# declared definition must be the file's only definition of that name and must
# end on the region's last line, so a scan that walked past the real `end` to a
# later column-0 one is caught even though its digests would agree.

require "digest"

require_relative "policy_support"

include TestScaffold

# The four copies, in the order they were reconciled.
FIXTURE_FILES = %w[
  tests/immich_configured_password_test.rb
  tests/ntfy_verify_execution_test.rb
  tests/beszel_password_preservation_test.rb
  tests/audiobookshelf_initial_scan_behavior_test.rb
].freeze

# The shared surface, one region per entry. `start` and `finish` are matched
# against whole lines, so a line mentioning `def capture3_with_timeout` inside a
# comment is not a definition. `finish` is searched forward from the line after
# the start match, so the first column-0 `end` closes the region.
#
# `definitions`, `constants`, `classes` and `locals` are the parser's half: what
# the region must contain, and each must appear exactly once in the whole file.
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
EXPECTED_FILES = 4
EXPECTED_REGIONS = 5
EXPECTED_EXTRACTIONS = 20

failures = []

check(failures, FIXTURE_FILES.length == EXPECTED_FILES,
      "the identity comparison must cover #{EXPECTED_FILES} files, not " \
      "#{FIXTURE_FILES.length}: a copy dropped from this list is a copy free to diverge")
check(failures, REGIONS.length == EXPECTED_REGIONS,
      "the shared surface must be #{EXPECTED_REGIONS} declared regions, not " \
      "#{REGIONS.length}: a region dropped from this list is compared by nothing")

# Every node the parser saw, flattened once per file, because each region asks
# about a different node type and re-walking per region would cost four walks.
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

# The parser is the half that fails differently, so its absence must fail rather
# than reduce this check to the textual scan alone with nothing said.
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

    # The parser's half. A definition must be the file's only one of that name
    # and must close on the region's own last line: an `end` scan that ran past
    # the real end to a later column-0 `end` would still digest consistently
    # across four files, and only this catches it. Lines between the region's
    # start and the definition are required to be comments, which is what makes
    # a comment-prefixed region a comment plus a definition rather than an
    # arbitrary span.
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

# The comparison itself. Four copies can split two against two, so there is no
# majority to name: print every file's digest and span for the region that
# differs, and the reader sees the partition without redoing the extraction.
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
    failures << "region #{name.inspect} has #{digests.length} distinct copies across the four " \
                "fixtures, expected one: #{detail.join('; ')}"
  else
    failures << "region #{name.inspect} was extracted from #{found.length} of " \
                "#{EXPECTED_FILES} fixtures, so its single digest proves nothing about the rest"
  end
end

report(failures, "capture helper identity: the shared surface is byte-identical across all four copies",
       "capture helper identity violation(s)")
