#!/usr/bin/env ruby
# frozen_string_literal: true

# A case that raises loses its own row and nothing else, at either pool width (#514).
# Each width runs in a child process because CASE_POOL_WORKERS resolves once at
# require time; each child also reports its thread count so two serial runs cannot
# pass as a comparison. `abort` (SystemExit) must still end the run.

require "json"
require "open3"
require "rbconfig"
require_relative "policy_support"

include TestScaffold

# The issue's own shape: eight cases, the third of which raises.
CASE_COUNT = 8
RAISING_CASE = 3
PARALLEL_WORKERS = 4

# How long a wide-child case waits for a second thread before the witness fails.
RENDEZVOUS_SECONDS = 2.0

# Serial goes through POLICY_JOBS, the flag CLAUDE.md prescribes for bisecting.
WIDTHS = {
  PARALLEL_WORKERS => { "CASE_POOL_WORKERS" => PARALLEL_WORKERS.to_s, "POLICY_JOBS" => nil },
  1 => { "CASE_POOL_WORKERS" => nil, "POLICY_JOBS" => "1" }
}.freeze

def scenario_items
  (1..CASE_COUNT).map { |number| { name: "case #{number}" } }
end

def expected_report
  (1..CASE_COUNT).flat_map do |number|
    findings = ["case #{number}: finding a", "case #{number}: finding b"]
    next findings unless number == RAISING_CASE

    findings + ["case #{number}: case raised RuntimeError: boom #{number}"]
  end
end

# --- the plant ---------------------------------------------------------------
# Derived from the current helper; each substitution must match individually, since
# only both together reproduce the divergence.
PLANT_SUBSTITUTIONS = [
  # The rescue. Re-raising is the helper before it had one at all.
  ["rescue StandardError => error\n",
   "rescue StandardError => error\n  raise\n"],
  # The serial path, back to yielding the shared list directly and returning early.
  ["    items.each_with_index do |item, index|\n" \
   "      local = []\n" \
   "      run_pool_case(item, local, &case_body)\n" \
   "      collected[index] = local\n" \
   "    end\n",
   "    return items.each { |item| case_body.call(item, failures) }\n"]
].freeze

# The loss and the divergence are two claims, so both are required in the report.
REQUIRED_DETECTIONS = [
  "escaped the pool",
  "entries the run must report",
  "the two widths disagree"
].freeze

# The pre-#514 helper under its own name; returns nil and reasons on a stale plant.
def planted_runner
  problems = []
  source = File.read(File.join(ROOT, "tests", "case_pool_support.rb"))
  bodies = source.scan(/^def (?:run_pool_case|in_parallel_cases)\b.*?^end$/m)
  check(problems, bodies.length == 2,
        "the plant reads run_pool_case and in_parallel_cases out of " \
        "tests/case_pool_support.rb and found #{bodies.length} definition(s)")
  return [nil, problems] unless bodies.length == 2

  mutant = bodies.join("\n\n")
  PLANT_SUBSTITUTIONS.each_with_index do |(target, replacement), position|
    reverted = mutant.sub(target, replacement)
    check(problems, reverted != mutant,
          "plant substitution #{position + 1} matched nothing in the helper as it stands, so " \
          "the pre-#514 behaviour it exists to reinstate is no longer being planted")
    mutant = reverted
  end
  return [nil, problems] unless problems.empty?

  eval(mutant.gsub("run_pool_case", "planted_run_pool_case")
             .gsub("in_parallel_cases", "planted_in_parallel_cases"),
       TOPLEVEL_BINDING, "#{__FILE__} (planted pre-#514 helper)")
  [method(:planted_in_parallel_cases), problems]
end

# --- the child ---------------------------------------------------------------

# Runs the scenario at the environment's width and prints one JSON line for the parent.
def emit_report(variant)
  require_relative "case_pool_support"
  runner, problems = variant == "planted" ? planted_runner : [method(:in_parallel_cases), []]
  abort "case_pool_behavior_test.rb child: #{problems.join('; ')}" if runner.nil?

  report = []
  threads = []
  lock = Mutex.new
  escaped = nil
  rendezvous = CASE_POOL_WORKERS > 1
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + RENDEZVOUS_SECONDS
  begin
    runner.call(report, scenario_items) do |item, collected; number|
      lock.synchronize { threads << Thread.current.object_id }
      # Park the first arrival until a second thread joins, so the witness reads width
      # rather than scheduling.
      while rendezvous && lock.synchronize { threads.uniq.length } < 2 &&
            Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        sleep 0.001
      end
      number = Integer(item.fetch(:name).split.last)
      collected << "#{item.fetch(:name)}: finding a"
      collected << "#{item.fetch(:name)}: finding b"
      raise "boom #{number}" if number == RAISING_CASE
    end
  rescue StandardError => error
    # Class and message only, so both widths print the same line.
    escaped = "#{error.class}: #{error.message}"
  end
  puts JSON.generate("workers" => CASE_POOL_WORKERS, "threads" => threads.uniq.length,
                     "escaped" => escaped, "report" => report)
end

# A case that aborts, so the parent can watch the run end from outside.
def emit_abort
  require_relative "case_pool_support"
  report = []
  in_parallel_cases(report, (1..CASE_COUNT).to_a) do |number, collected|
    abort "aborting on case #{number}" if number == RAISING_CASE

    collected << "case #{number}"
  end
  puts JSON.generate("report" => report)
end

# --- the parent --------------------------------------------------------------

def run_child(mode, argument, environment)
  Open3.capture3(environment, RbConfig.ruby, __FILE__, mode, argument)
end

def read_child(variant, workers)
  stdout, stderr, status = run_child("--emit-report", variant, WIDTHS.fetch(workers))
  unless status.success?
    return [nil, "the #{workers}-worker child exited #{status.exitstatus}: " \
                 "#{failure_tail(stderr)}"]
  end

  [JSON.parse(stdout), nil]
rescue JSON::ParserError => error
  [nil, "the #{workers}-worker child printed no report the parent could read " \
        "(#{error.message}): #{failure_tail(stdout)}"]
end

# Asked identically of the real helper and the planted pre-#514 one.
def behavior_failures(variant)
  problems = []
  expected = expected_report
  results = {}
  WIDTHS.each_key do |workers|
    result, problem = read_child(variant, workers)
    problems << problem if problem
    results[workers] = result
  end
  return problems unless results.values.all?

  results.each do |workers, result|
    check(problems, result.fetch("escaped").nil?,
          "a case raising StandardError escaped the pool at #{workers} worker(s) as " \
          "#{result.fetch('escaped')}, so the run ends where it should have reported that " \
          "case and gone on")
    check(problems, result.fetch("workers") == workers,
          "the child started for #{workers} worker(s) resolved CASE_POOL_WORKERS to " \
          "#{result.fetch('workers')}, so #{WIDTHS.fetch(workers).compact.keys.join(' and ')} " \
          "does not select the width it is documented to select")
    check(problems, result.fetch("report") == expected,
          "the #{workers}-worker run reported #{result.fetch('report').length} of the " \
          "#{expected.length} entries the run must report: #{result.fetch('report').inspect}")
  end

  wide = results.fetch(PARALLEL_WORKERS)
  serial = results.fetch(1)
  check(problems, wide.fetch("threads") > 1,
        "the #{PARALLEL_WORKERS}-worker run ran its cases on #{wide.fetch('threads')} thread(s), " \
        "so nothing here distinguishes the parallel path from the serial one and the agreement " \
        "below is between the serial path and itself")
  check(problems, serial.fetch("threads") == 1,
        "the 1-worker run ran its cases on #{serial.fetch('threads')} thread(s), so " \
        "POLICY_JOBS=1 is not the serial path it is prescribed as")
  check(problems, wide.fetch("report") == serial.fetch("report"),
        "the two widths disagree, so POLICY_JOBS=1 changes the evidence rather than " \
        "serialising it: #{PARALLEL_WORKERS} workers reported " \
        "#{wide.fetch('report').inspect} and 1 worker reported #{serial.fetch('report').inspect}")
  problems
end

# `abort` in a case is still fatal, at both widths, and reports nothing.
def abort_failures
  problems = []
  WIDTHS.each do |workers, environment|
    stdout, stderr, status = run_child("--emit-abort", "real", environment)
    check(problems, !status.success?,
          "a case that aborts at #{workers} worker(s) must end the run, and the child exited 0 " \
          "-- `abort` is deliberately not rescued, because a case that cannot continue is the " \
          "check saying so")
    check(problems, stderr.include?("aborting on case #{RAISING_CASE}"),
          "a case that aborts at #{workers} worker(s) must leave its message on stderr, and " \
          "the child wrote #{failure_tail(stderr).inspect}")
    check(problems, stdout.strip.empty?,
          "a case that aborts at #{workers} worker(s) must report nothing, because the run ends " \
          "before anything is assembled, and the child printed #{failure_tail(stdout).inspect}")
  end
  problems
end

# --- entry point --------------------------------------------------------------

if ARGV.length == 2 && ARGV.first == "--emit-report"
  emit_report(ARGV.last)
  exit
elsif ARGV.length == 2 && ARGV.first == "--emit-abort"
  emit_abort
  exit
end

failures = []
failures.concat(behavior_failures("real"))
failures.concat(abort_failures)

planted_detections = 0

if ARGV == ["--self-test"]
  _runner, plant_problems = planted_runner
  failures.concat(plant_problems.map { |problem| "self-test: #{problem}" })
  if plant_problems.empty?
    detected = behavior_failures("planted")
    # Printed, so a self-test run reads differently from a plain one.
    detected.each { |line| puts "self-test detected: #{line}" }
    planted_detections = detected.length
    REQUIRED_DETECTIONS.each do |fragment|
      check(failures, detected.any? { |line| line.include?(fragment) },
            "self-test: the pre-#514 helper must be reported with #{fragment.inspect}, and " \
            "this test named #{detected.empty? ? 'nothing' : detected.join(' | ')}")
    end
  end
elsif !ARGV.empty?
  failures << "usage: case_pool_behavior_test.rb [--self-test]"
end

report(failures,
       "case pool behaviour: #{CASE_COUNT} cases, one of them raising after it recorded " \
       "findings, report the same #{expected_report.length} entries in the same order at " \
       "#{PARALLEL_WORKERS} workers and at 1, and a case that aborts still ends the run" +
         (planted_detections.zero? ? "" : ", and the pre-#514 helper is named by " \
                                          "#{planted_detections} of these properties"),
       "case pool behaviour violation(s)")
