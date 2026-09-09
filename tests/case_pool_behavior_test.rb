#!/usr/bin/env ruby
# frozen_string_literal: true

# A case that raises loses its own row and nothing else, at either width.
#
# `tests/case_pool_support.rb` is the pool eight policy checks drive their
# independent cases through. Until #514 a case that raised killed its worker,
# `Thread#join` re-raised in the caller, and the concatenation that assembles
# the report was never reached. Measured with eight cases where case 3 raises:
#
#   CASE_POOL_WORKERS=4  ->  RuntimeError: boom 3   failures collected = 0
#   POLICY_JOBS=1        ->  RuntimeError: boom 3   failures collected = 2
#
# THE LOSS. Seven cases ran and recorded real findings. None survived.
#
# THE DIVERGENCE, which is worse. The two widths reported *different* lists.
# CLAUDE.md prescribes POLICY_JOBS=1 for bisecting a failure that only appears
# under load; with a raising case in the set that flag changed the evidence
# instead of serialising it.
#
# WHY A CHILD PROCESS PER WIDTH. CASE_POOL_WORKERS is resolved from the
# environment once, at require time, so a single process reaches one width and
# one only. Rebinding the constant in-process would reach both, and would stop
# the test exercising the thing it exists to pin -- the width the real
# environment variables select. So each width is a child of this file, one
# started with CASE_POOL_WORKERS=4 and one with POLICY_JOBS=1, and the parent
# compares what they printed. Two children, not one per case: a subprocess per
# case is what makes a check the gate's floor, and this whole file runs in
# well under a second.
#
# WHY THE THREAD WITNESS. An equality between two lists is satisfied trivially
# if both were produced the same way, so each child reports the width it
# resolved and how many distinct threads its cases ran on. The wide child has
# to resolve 4 and observe more than one thread; the serial child has to
# resolve 1 and observe exactly one. Without that pair the central claim here
# is unfalsifiable -- two serial runs agree with each other perfectly.
#
# WHAT THE RAISING CASE OWES. Three entries, not one: the two findings it
# recorded before it raised, and then its exception. The four contract tests
# that pool by return value rescue by *rebuilding* the case's list, which they
# can because their block returns it; the shared helper's block appends to a
# list it was handed, so a rescue copied from them would silently drop whatever
# the case had already found. That count and that order are asserted below.
#
# WHAT IS DELIBERATELY NOT RESCUED. `abort` still ends the run. SystemExit is
# not a StandardError, and `abort_failures` pins that from the outside in both
# directions -- the child exits non-zero with the abort message on stderr, and
# prints no report at all -- so a later widening of the helper's rescue to
# `Exception` fails here rather than quietly swallowing a case's `abort`.

require "json"
require "open3"
require "rbconfig"
require_relative "policy_support"

include TestScaffold

# The issue's own shape: eight cases, the third of which raises.
CASE_COUNT = 8
RAISING_CASE = 3
PARALLEL_WORKERS = 4

# How long a case in the wide child waits for a second thread to show up before
# giving up and letting the witness fail. Only the wide child rendezvouses, so
# it is never spent by the serial one, and it is only ever spent in full by a
# run that is about to report the witness as broken.
RENDEZVOUS_SECONDS = 2.0

# The two widths, and the environment that selects each. The serial row goes
# through POLICY_JOBS rather than CASE_POOL_WORKERS on purpose: that is the flag
# CLAUDE.md prescribes, and it is the one whose reach into this helper is being
# claimed.
WIDTHS = {
  PARALLEL_WORKERS => { "CASE_POOL_WORKERS" => PARALLEL_WORKERS.to_s, "POLICY_JOBS" => nil },
  1 => { "CASE_POOL_WORKERS" => nil, "POLICY_JOBS" => "1" }
}.freeze

def scenario_items
  (1..CASE_COUNT).map { |number| { name: "case #{number}" } }
end

# What both widths have to report, entry for entry and in this order.
def expected_report
  (1..CASE_COUNT).flat_map do |number|
    findings = ["case #{number}: finding a", "case #{number}: finding b"]
    next findings unless number == RAISING_CASE

    findings + ["case #{number}: case raised RuntimeError: boom #{number}"]
  end
end

# --- the plant ---------------------------------------------------------------
#
# Derived from the helper as it stands rather than transcribed from history, so
# a rewrite that reintroduces #514 by another route is still reverted by these
# substitutions instead of compared against a frozen copy of code nobody runs.
# Each is required to match individually: an aggregate "something changed"
# passes when one of two applied, and only both together reproduce the measured
# divergence -- dropping the rescue alone loses both widths' reports equally,
# which is the loss without the disagreement.
PLANT_SUBSTITUTIONS = [
  # The rescue. Re-raising is the helper before it had one at all.
  ["rescue StandardError => error\n",
   "rescue StandardError => error\n  raise\n"],
  # The serial path, back to yielding the shared list directly and returning
  # early, which is where the two widths came apart: the entries a serial run
  # had already appended survived the raise, and the parallel run's did not.
  ["    items.each_with_index do |item, index|\n" \
   "      local = []\n" \
   "      run_pool_case(item, local, &case_body)\n" \
   "      collected[index] = local\n" \
   "    end\n",
   "    return items.each { |item| case_body.call(item, failures) }\n"]
].freeze

# The fragments the planted helper has to be reported with. Named separately,
# because a self-test that only required "something failed" would pass on a
# checker that had lost one of the two defects.
REQUIRED_DETECTIONS = [
  "escaped the pool",
  "entries the run must report",
  "the two widths disagree"
].freeze

# The pre-#514 helper under a name of its own, so it can be driven by exactly
# the code that drives the real one. Returns nil and its reasons when a
# substitution no longer matches.
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

# Drives the scenario through +variant+ at whatever width the environment
# selected and prints one JSON line the parent judges. Everything the parent
# asserts is in that line, so the two widths are compared against each other
# rather than each against its own idea of success.
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
      # Park the first arrival until a second thread joins it, so a pool of four
      # cannot be drained by whichever worker started first and the witness
      # reads the width rather than the scheduling.
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
    # Deterministic by construction: class and message only, no thread, no
    # timing, no backtrace -- the whole point is that both widths print the
    # same line.
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

# The properties, asked of whichever helper the children are told to drive, so
# the self-test asks exactly the same questions of a planted pre-#514 one.
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
    # Printed, so a self-test run reads differently from a plain one. A
    # --self-test whose output is identical to the run without it proves
    # nothing, which is the argument the rest of this suite makes too.
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

# The success line counts what was judged, so a run whose scenario emptied or
# whose self-test stopped planting reads differently from one that checked
# everything.
report(failures,
       "case pool behaviour: #{CASE_COUNT} cases, one of them raising after it recorded " \
       "findings, report the same #{expected_report.length} entries in the same order at " \
       "#{PARALLEL_WORKERS} workers and at 1, and a case that aborts still ends the run" +
         (planted_detections.zero? ? "" : ", and the pre-#514 helper is named by " \
                                          "#{planted_detections} of these properties"),
       "case pool behaviour violation(s)")
