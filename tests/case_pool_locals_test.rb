#!/usr/bin/env ruby
# frozen_string_literal: true

# Every case the pool drives owns every name it assigns: a case assigning a name that
# lives in an enclosing scope shares one binding across threads (#488's `status`, where a
# sibling's failure read as this case's detection). Scope: blocks taking `collected`, and
# blocks passed to `in_parallel_cases`. Reads are not checked. Inside a block Ruby emits
# DASGN, not LASGN; `--self-test` pins that.

require_relative "policy_support"

include TestScaffold

# Well under today's counts, so only a collapse (glob or rename) breaches it.
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

# Owned names are those on the path from the case down to the assignment, not every
# nested table: a nested block's parameters shadow only inside it (#489).
def escaping_in(node, tables, found)
  return unless node.is_a?(RubyVM::AbstractSyntaxTree::Node)

  if %i[DASGN LASGN].include?(node.type) && node.children[0].is_a?(Symbol)
    name = node.children[0]
    found << name unless tables.any? { |table| table.include?(name) }
  end
  inner = node.type == :SCOPE ? tables + [node.children[0]] : tables
  node.children.each { |child| escaping_in(child, inner, found) }
end

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

def escaping_writes(root)
  pool_cases(root).filter_map do |node|
    scope = block_scope(node)
    next if scope.nil?

    escaping = []
    escaping_in(scope, [], escaping)
    escaping = escaping.uniq
    next if escaping.empty?

    [node.first_lineno, escaping]
  end
end

# Found by method name so new checks are covered. This file names the method in prose,
# so it is excluded.
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

judged_rows = 0

if ARGV == ["--self-test"]
  # `expected` is the names to report, or nil for a clean row.
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
    # #489: a nested block parameter sharing the name must not mask the outward write.
    "a nested block parameter that shares the written name" => [
      <<~RUBY, [:status]
        status = nil
        status = run_something
        cases = []
        cases << lambda do |collected|
          helper do |_tmp, output, status|
            check(collected, status, "inner")
          end
          status = second_fixture
          check(collected, status, "outer")
        end
      RUBY
    ],
    # And a name first assigned inside a nested block IS case-local.
    "a name first assigned inside a nested block" => [
      <<~RUBY, nil
        cases = []
        cases << lambda do |collected|
          Dir.mktmpdir("x") do |directory|
            mutated_source = mutate(directory)
            _stdout, _stderr, mutant_status = run_fixture(mutated_source)
            check(collected, !mutant_status.success?, "did not reject")
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
  judged_rows = rows.length + 1 # the synthetic rows, plus the real-subject plant
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

  # Once against a real subject: reintroduce the enclosing binding, remove one declaration.
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

# The row count is in the success line so a self-test that judged nothing reads differently.
report(failures,
       "case pool locals: #{case_count} pooled cases across #{subjects.length} files own " \
       "every name they assign#{judged_rows.zero? ? '' : ", and #{judged_rows} planted " \
       "regressions are each named by this checker"}",
       "pooled case(s) assigning an enclosing local")
