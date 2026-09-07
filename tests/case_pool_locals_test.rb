#!/usr/bin/env ruby
# frozen_string_literal: true

# Every case the pool drives owns every name it assigns.
#
# `tests/case_pool_support.rb` and the fourteen contract tests' own copies run a
# check's independent cases in threads. A case appends its findings to a private
# list and the lists are concatenated in written order, so nothing is shared --
# unless a case assigns a local that lives in an enclosing scope, in which case
# every case writes and reads the one binding.
#
# THIS HAPPENED, and how it passed review is the reason this file exists. #488
# pooled `config_managed_users_test.rb`'s mutation cases; four of them wrote
# their subprocess result into `status`, which was a *script-level* local
# because the serial fixtures above them assigned it at top level and an `if`
# body opens no scope. Ruby resolves an already-declared name outward, so the
# four threads shared one binding. Nothing failed: every mutant those cases run
# is supposed to fail, so a sibling's failing status reads as this case's own
# detection. A mutation that stopped biting would still have been reported as
# detected, and the guard would have passed vacuously. Fixed in e012214 by
# declaring the result locals block-local -- the names after the `;` in the
# parameter list, which are fresh whatever the enclosing scope carries.
#
# WHY THIS IS NOT THE AST LOCAL-TABLE DIFF. Comparing the script's local table
# before and after a change catches a case that *adds* a script local. It cannot
# catch a case that assigns a name the table already carried, which is exactly
# what `status` did: the table was identical across that commit. That diff is
# the weaker of the two questions, and this file asks the other one -- for every
# block the pool drives, is every name it assigns local to that block?
#
# HOW THE QUESTION IS ANSWERED. A name first assigned inside a block is in that
# block's own local table; a name that resolves outward is not. So the names a
# case owns are its own table plus the tables of every block nested inside it,
# and any assigned name outside that set is an outward write.
#
# TWO AST DETAILS, both of which a first attempt at this got wrong together, and
# which made it report the known-buggy revision as clean. Inside a block Ruby
# emits `DASGN`, not `LASGN`. And a multiple assignment's targets hang off the
# MASGN's *second* child, not its first -- `children[0]` is the value list.
#
# `assigned_names` below answers both by walking the whole subtree for both
# assignment node types and special-casing neither, since a MASGN's targets are
# ordinary DASGN nodes the walk reaches on its own. Be precise about what
# `--self-test` therefore pins, because it is one of those and not both: a
# checker that looks only for `LASGN` fails all four planted rows, which is
# measured, not assumed. The MASGN detail is *unobservable* from the outside
# here -- reinstating the wrong-child special case changes no verdict, because
# the walk already found those targets -- so the row that reduces the shipped
# defect (a multiple assignment inside a nested block) proves the walk reaches
# it, and nothing in this file could fail if someone added a redundant MASGN
# branch back. Do not read the rows as covering more than that.
#
# WHAT IS IN SCOPE. Two kinds of block, and their union:
#
#   * any block or lambda whose parameter list contains `collected`, which is
#     this repository's name for a case's private failure list; and
#   * any block passed directly to `in_parallel_cases`, whatever it names its
#     parameters -- which is what covers
#     `media_acquisition_reconciliation_support.rb`, whose pool block calls its
#     private list `failures`, shadowing the outer name of the same thing.
#
# The second half also covers the five contract tests whose pool takes one
# argument and collects return values rather than appending
# (`in_parallel_cases(rows) do |row|` in jellyfin, dozzle, paperless, immich and
# audiobookshelf). An escaping write is a milder defect there, because a case
# returns its findings rather than recording them through a shared name, but the
# question is still worth asking and they are clean.
#
# Deliberately not asserted: that a case's *reads* are safe. A case reading a
# shared structure is correct and normal, and the ones that must not be written
# are frozen at their definition instead -- which is a runtime guard, and a
# better one, because it names the write site.

require_relative "policy_support"

include TestScaffold

# Sized well under the 21 files and 127 blocks found when this was written, so
# only a real collapse breaches it. A vacuous pass here is indistinguishable
# from compliance: if the glob stops matching or `in_parallel_cases` is renamed,
# every assertion below holds over nothing.
SUBJECT_FLOOR = 15
CASE_FLOOR = 80

def each_node(node, &block)
  return unless node.is_a?(RubyVM::AbstractSyntaxTree::Node)

  block.call(node)
  node.children.each { |child| each_node(child, &block) }
end

def block_scope(node)
  node.children.find do |child|
    child.is_a?(RubyVM::AbstractSyntaxTree::Node) && child.type == :SCOPE
  end
end

# Every local table at or below +node+: the case's own, plus each block nested
# inside it. A nested block's assignment to a name the case owns is the case's
# own business.
def owned_names(node)
  names = []
  each_node(node) { |inner| names.concat(inner.children[0]) if inner.type == :SCOPE }
  names.uniq
end

def assigned_names(node)
  names = []
  each_node(node) do |inner|
    next unless %i[DASGN LASGN].include?(inner.type)

    names << inner.children[0] if inner.children[0].is_a?(Symbol)
  end
  names.uniq
end

# The method a block is attached to, for the `in_parallel_cases` half of the
# scope. FCALL/CALL/VCALL all carry the name as their only Symbol child.
def attached_call_name(node)
  target = node.children[0]
  return nil unless target.is_a?(RubyVM::AbstractSyntaxTree::Node)

  target.children.find { |child| child.is_a?(Symbol) }
end

def pool_cases(root)
  cases = []
  each_node(root) do |node|
    next unless %i[ITER LAMBDA].include?(node.type)

    scope = block_scope(node)
    next unless scope
    next unless scope.children[0].include?(:collected) ||
                attached_call_name(node) == :in_parallel_cases

    cases << node
  end
  cases
end

# Each offending case as [line, names], so the diagnostic can point at the
# parameter list that needs the declaration rather than at the file.
def escaping_writes(root)
  pool_cases(root).filter_map do |node|
    escaping = assigned_names(node) - owned_names(node)
    next if escaping.empty?

    [node.first_lineno, escaping]
  end
end

# Every check that drives a pool, found by the method's name rather than by a
# list, so a new one is covered the day it is written. This file is excluded
# because it names the method in prose and defines no case of its own; the
# support files that define `in_parallel_cases` stay in, and simply contribute
# no cases.
def subject_files
  Dir[File.join(ROOT, "tests", "**", "*.rb")].sort.select do |path|
    path != File.expand_path(__FILE__) && File.read(path).include?("in_parallel_cases")
  end
end

failures = []

subjects = subject_files
check_floor(failures, subjects.length, SUBJECT_FLOOR, "case pool subject files")

case_count = 0
subjects.each do |path|
  relative = path.delete_prefix("#{ROOT}/")
  root = begin
    RubyVM::AbstractSyntaxTree.parse_file(path)
  rescue SyntaxError => error
    failures << "#{relative} does not parse: #{error.message.lines.first&.strip}"
    next
  end
  case_count += pool_cases(root).length
  escaping_writes(root).each do |lineno, names|
    failures << "#{relative}:#{lineno} is a pooled case that assigns #{names.join(', ')} " \
                "from an enclosing scope, so every case sharing that binding reads and " \
                "writes one variable. Declare them block-local -- the names after the `;` " \
                "in the parameter list -- or give the case its own"
  end
end
check_floor(failures, case_count, CASE_FLOOR, "pooled cases")

if ARGV == ["--self-test"]
  # Each row is a source this checker has to judge, and the two that must be
  # reported are reductions of defects that really shipped. `expected` is the
  # names it must name, or nil for a row that must come back clean.
  rows = {
    "the 797f258 shape: a nested block assigning a script-level name" => [
      <<~RUBY, [:status]
        status = nil
        status = run_something
        cases = []
        cases << lambda do |collected|
          Dir.mktmpdir("x") do |directory|
            _stdout, _stderr, status = capture(directory)
            check(collected, !status.success?, "did not refuse")
          end
        end
      RUBY
    ],
    "the same case with the result declared block-local" => [
      <<~RUBY, nil
        status = nil
        status = run_something
        cases = []
        cases << lambda do |collected; _stdout, _stderr, status|
          Dir.mktmpdir("x") do |directory|
            _stdout, _stderr, status = capture(directory)
            check(collected, !status.success?, "did not refuse")
          end
        end
      RUBY
    ],
    "a single assignment rather than a multiple one" => [
      <<~RUBY, [:output]
        output = nil
        output = first_fixture
        cases = []
        cases << lambda do |collected|
          output = second_fixture
          check(collected, output.empty?, "not empty")
        end
      RUBY
    ],
    "a direct pool block that names its private list `failures`" => [
      <<~RUBY, [:rendered]
        failures = []
        rendered = nil
        in_parallel_cases(failures, rows) do |(field, mutate), failures|
          rendered = render(field, mutate)
          check(failures, rendered, "nothing rendered")
        end
      RUBY
    ],
    "a clean direct pool block" => [
      <<~RUBY, nil
        failures = []
        rendered = nil
        in_parallel_cases(failures, rows) do |(field, mutate), failures; rendered|
          rendered = render(field, mutate)
          check(failures, rendered, "nothing rendered")
        end
      RUBY
    ]
  }
  rows.each do |label, (source, expected)|
    found = escaping_writes(RubyVM::AbstractSyntaxTree.parse(source)).flat_map(&:last)
    if expected.nil?
      check(failures, found.empty?,
            "self-test: #{label} is clean but this checker named #{found.join(', ')}")
    else
      check(failures, found.sort == expected.sort,
            "self-test: #{label} must be reported as #{expected.join(', ')}, " \
            "and this checker named #{found.empty? ? 'nothing' : found.join(', ')}")
    end
  end

  # And once against a real subject, because a synthetic row shares none of the
  # size, nesting or idiom of the files this actually runs over. The plant is
  # the defect in its original form: reintroduce the enclosing binding, then
  # take one case's declaration of that name away.
  planted_subject = File.join(ROOT, "tests", "config_managed_users_test.rb")
  source = File.read(planted_subject)
  mutant = source.sub("failures = []\n", "failures = []\nstatus = nil\n")
                 .sub("|collected; _rendered, _output, status|", "|collected; _rendered, _output|")
  check(failures, mutant != source, "self-test: the real-subject plant changed nothing")
  planted = escaping_writes(RubyVM::AbstractSyntaxTree.parse(mutant)).flat_map(&:last)
  check(failures, planted == [:status],
        "self-test: a pooled case in config_managed_users_test.rb assigning a reintroduced " \
        "script-level `status` must be reported, and this checker named " \
        "#{planted.empty? ? 'nothing' : planted.join(', ')}")
elsif !ARGV.empty?
  failures << "usage: case_pool_locals_test.rb [--self-test]"
end

report(failures,
       "case pool locals: #{case_count} pooled cases across #{subjects.length} files own " \
       "every name they assign",
       "pooled case(s) assigning an enclosing local")
