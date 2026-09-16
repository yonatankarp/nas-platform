#!/usr/bin/env ruby
# The mutation audit's coverage report, checked without running the audit.
#
# `ruby tests/policy_manifest_test.rb --audit` is deliberately out of CI: it
# re-runs all eight policy scripts per row and costs twenty-five minutes. The
# report it prints -- how many mutations it re-derived, and how many it could not
# see -- carries two guards, and both of them exist because #439 found the audit
# claiming a wider verdict than it had. A guard reachable only by a human
# spending twenty-five minutes is the same defect one level down, so this checks
# the reporting directly: the counters are driven with synthetic rows and the
# report is read back, which takes a second because no policy script runs.
#
# What this cannot check is the figures a real tree produces. Those come from the
# run itself, and there is no correct value to pin, only a current one. Since
# #725 there is a lower bound on two of them -- POLICY_MUTATION_CENSUS_BASELINE,
# which a shrinking census fails against and a growing one does not -- and the
# same division applies to it: the arithmetic of the floor is driven here with
# synthetic figures and synthetic baselines, and whether a real tree clears the
# real baseline is something only the real run says.

require "stringio"

# POLICY_AUDIT is read from ARGV when the support file loads, and every figure
# here exists only under `--audit`. Set before the require, not after.
ARGV.replace(["--audit"])
require_relative "policy_mutation_support"

include TestScaffold

failures = []

# `record_audit_detection` wants whatever `caller_locations` gave the row; only
# its line number is read, and a stated one keeps a case's identity in the case
# rather than in this file's own layout.
Site = Struct.new(:lineno)

# One result set per script, where exactly the named scripts reject the mutation.
def results_detected_by(names)
  detecting = names.map { |name| POLICY_SCRIPTS_BY_NAME.fetch(name) }
  POLICY_SCRIPTS.map { |script| [script, "", !detecting.include?(script)] }
end

def reset_coverage
  POLICY_AUDIT_SITES.clear
  POLICY_AUDIT_COVERAGE[:policy_runs] = 0
  POLICY_AUDIT_COVERAGE[:bypass_shapes].clear
  POLICY_AUDIT_COVERAGE[:bypass_sites].clear
end

# The report goes to stdout, and a check that only read the returned failures
# would pass while the printed half said nothing.
def capture_audit(failures)
  captured = StringIO.new
  previous_stdout = $stdout
  begin
    $stdout = captured
    audit_policy_detection(failures)
  ensure
    $stdout = previous_stdout
  end
  captured.string
end

# The census half, captured the same way and for the same reason: the floor
# reports through `failures` and the headroom only through stdout, so a check
# reading one of them would pass while the other said nothing.
#
# The baseline is splatted rather than defaulted here. A default of its own would
# have been the committed constant again, so the case below that means to reach
# report_mutation_census's *own* default would have been reaching this one
# instead -- which is what it did until a planted vacuous default passed it.
def capture_census(failures, **baseline_argument)
  captured = StringIO.new
  previous_stdout = $stdout
  begin
    $stdout = captured
    report_mutation_census(failures, **baseline_argument)
  ensure
    $stdout = previous_stdout
  end
  captured.string
end

# A census of a given size. The call sites are keyed by line number in the real
# harness, so the keys here are arbitrary and only their count is read.
def set_census(mutations:, call_sites:)
  POLICY_MUTATION_CENSUS[:mutations] = mutations
  POLICY_MUTATION_CENSUS[:single_script] = mutations
  POLICY_MUTATION_CENSUS[:integration] = 0
  POLICY_MUTATION_CENSUS[:sites] = (1..call_sites).to_h { |lineno| [lineno, true] }
end

# Where the tripwire's arithmetic comes from. The subtraction that catches an
# unlabelled bypass is `policy_runs` minus what the audit recorded, so it is only
# sound while the real run_policy_scripts is what increments `policy_runs` --
# every case below stubs that method, and stubbing it would prove the stub.
#
# An empty script list runs no subprocess, so this costs one fixture copy.
reset_coverage
run_policy_scripts([]) { |_root| nil }
check(failures, POLICY_AUDIT_COVERAGE[:policy_runs] == 1,
      "run_policy_scripts must count the sandbox it runs: the bypass total is derived from that " \
      "count and reads short without it")

# From here the policy set is never really run: every case is about the
# bookkeeping, and a sandbox per case would put this check in the gate's floor,
# which is what took the mutation harness out of the gate in the first place.
def run_policy_scripts(scripts)
  POLICY_AUDIT_COVERAGE[:policy_runs] += 1
  scripts.map { |script| [script, "", true] }
end

# The two shapes that reach a sandbox through run_policy_scripts must label
# themselves there. Asserted through the public helpers rather than by calling
# the recorder, because what silently stops working is the wiring, not the
# recorder.
reset_coverage
run_policy(["tests/policy_test.rb"]) { |_root| nil }
expect_success([], "synthetic success row") { |_root| nil }
record_direct_audit_bypass(:synthetic_direct_shape)
shapes = POLICY_AUDIT_COVERAGE[:bypass_shapes]
check(failures, shapes[:run_policy] == 1,
      "run_policy must register the assertion it runs as one the audit did not re-derive")
check(failures, shapes[:expect_success] == 1,
      "expect_success must register the assertion it runs as one the audit did not re-derive")
check(failures, shapes[:synthetic_direct_shape] == 1,
      "record_direct_audit_bypass must register the shape it is given")
check(failures, POLICY_AUDIT_COVERAGE[:policy_runs] == 3,
      "a shape that runs its own checker must count its own run: run_policy and expect_success " \
      "are counted in run_policy_scripts, and record_direct_audit_bypass has to count itself")

# A loop is one row covering several mutations, which is how the audited half
# keys its call sites; the bypass half has to read the same way, or the two
# figures in one sentence are not comparable.
reset_coverage
2.times { record_audit_bypass(:looped_shape) }
record_audit_bypass(:looped_shape)
check(failures, POLICY_AUDIT_COVERAGE[:bypass_shapes][:looped_shape] == 3,
      "every bypassing mutation must be counted, including a loop's repeats")
check(failures, POLICY_AUDIT_COVERAGE[:bypass_sites].length == 2,
      "bypass call sites must be keyed on the chain of lines inside the program under test: a " \
      "loop is one site, and two rows are two")

# The healthy case: what the audit re-derived plus what it could not see is every
# run there was, so there is nothing to report but the figures.
reset_coverage
POLICY_AUDIT_COVERAGE[:policy_runs] = 3
[[Site.new(11), 2], [Site.new(22), 1]].each do |site, mutations|
  mutations.times do
    record_audit_detection("row at #{site.lineno}", "planted", %i[policy], results_detected_by(%i[policy]), site)
  end
end
record_audit_bypass(:run_policy)
record_audit_bypass(:run_policy)
POLICY_AUDIT_COVERAGE[:policy_runs] += 2
healthy = []
report = capture_audit(healthy)
check(failures, healthy.empty?,
      "an audit whose halves account for every run must report no failure, got #{healthy.inspect}")

# The printed line, by substring: the halves must be in one unit, and the
# per-shape breakdown is the part that says which rows are outside the verdict.
check(failures, report.scan(/mutations at \d+ call sites/).length == 2,
      "both halves of the audit line must carry mutations and call sites, in that unit, so no " \
      "ratio between them can be misread: #{report.strip.inspect}")
["3 mutations at 2 call sites", "re-derived against all eight scripts",
 "2 mutations at 2 call sites", "never reach expect_failure", "2 run_policy"].each do |fragment|
  check(failures, report.include?(fragment),
        "the audit line must state #{fragment.inspect}: #{report.strip.inspect}")
end

# The tripwire. A run counted with no shape to label it is a bypass nobody is
# reporting, which is this issue's own defect reappearing in the fix for it.
reset_coverage
POLICY_AUDIT_COVERAGE[:policy_runs] = 4
[Site.new(31), Site.new(32)].each do |site|
  record_audit_detection("row at #{site.lineno}", "planted", %i[policy], results_detected_by(%i[policy]), site)
end
record_audit_bypass(:run_policy)
unlabelled = []
capture_audit(unlabelled)
check(failures, unlabelled.any? { |failure| failure.include?("2 runs bypass the re-derivation but 1 are labelled") },
      "an unlabelled bypass must be reported by name and by count, got #{unlabelled.inspect}")

# The floor. Every property the audit asserts is asserted over the sites it
# collected, so a collection that goes quiet passes vacuously -- and prints a
# clean verdict while doing it.
reset_coverage
POLICY_AUDIT_COVERAGE[:policy_runs] = 1
record_audit_detection("only row", "planted", %i[policy], results_detected_by(%i[policy]), Site.new(41))
collapsed = []
capture_audit(collapsed)
check(failures, collapsed.any? { |failure| failure.include?("re-derived only 1 call sites") },
      "an audit that re-derived one call site must say so rather than print a clean verdict, " \
      "got #{collapsed.inspect}")

# The drift the audit exists for, both directions, since the coverage report is
# printed from the same method and a change there could silence them.
reset_coverage
POLICY_AUDIT_COVERAGE[:policy_runs] = 2
record_audit_detection("wider than declared", "planted", %i[policy],
                       results_detected_by(%i[policy vault]), Site.new(51))
record_audit_detection("narrower than declared", "planted", %i[policy vault],
                       results_detected_by(%i[policy]), Site.new(52))
drift = []
capture_audit(drift)
check(failures, drift.any? { |failure| failure.include?("line 51") && failure.include?("detected_by omits vault") },
      "a script that has started detecting a row must be reported, got #{drift.inspect}")
check(failures,
      drift.any? { |failure| failure.include?("line 52") && failure.include?("no longer detect it") },
      "a script that has stopped detecting a row must be reported, got #{drift.inspect}")

# The census floor (#725). Everything above is about the audit's own report,
# which a human reaches by spending twenty-five minutes; the census is printed by
# every run of the harness, including the one CI runs, so the floor that catches
# a collapsing subject list lives there.
#
# Asserted through expect_failure rather than by calling the recorder, because
# what silently stops working is the wiring: a row that no longer registers is
# the whole defect, and a recorder called directly would count a row nothing
# registered. run_policy_scripts is stubbed above, so this runs no policy script.
reset_coverage
set_census(mutations: 0, call_sites: 0)
expect_failure([], "synthetic census row", "planted", detected_by: %i[policy]) { |_root| nil }
check(failures, POLICY_MUTATION_CENSUS[:mutations] == 1 && POLICY_MUTATION_CENSUS[:sites].length == 1,
      "expect_failure must count every mutation and its call site into the census: the floor is " \
      "read off those counters and reads short without them, got " \
      "#{POLICY_MUTATION_CENSUS[:mutations]} mutations at #{POLICY_MUTATION_CENSUS[:sites].length} sites")

# A synthetic baseline, so these cases do not rot the next time the real one is
# refreshed -- and so the real constant is exercised separately, below, where
# nothing but its own arithmetic can be what passes.
synthetic_baseline = { mutations: 10, call_sites: 4 }

# The rise, which is the direction this file moves in: a census above the floor
# reports no failure and prints the gap the floor cannot see.
set_census(mutations: 12, call_sites: 5)
grown = []
report = capture_census(grown, baseline: synthetic_baseline)
check(failures, grown.empty?,
      "a census above its floor must report no failure, got #{grown.inspect}")
check(failures, report.include?("headroom +2 mutations +1 call sites"),
      "the census must print how far it stands above the floor, since a ratchet cannot see that " \
      "span: #{report.strip.inspect}")

# The boundary. A floor is cleared by standing on it, or a legitimate refresh
# reds the run that wrote it.
set_census(mutations: 10, call_sites: 4)
exact = []
capture_census(exact, baseline: synthetic_baseline)
check(failures, exact.empty?,
      "a census exactly at its floor must report no failure, got #{exact.inspect}")

# The collapse, in each figure on its own. Separately, because they move
# separately -- a loop is one call site covering several mutations -- and a check
# reading only the mutation count would pass a file whose call sites had gone.
set_census(mutations: 3, call_sites: 4)
shrunk = []
capture_census(shrunk, baseline: synthetic_baseline)
check(failures, shrunk.any? do |failure|
        failure.include?("3 expect_failure mutations, below the floor of 10") &&
          failure.include?("POLICY_MUTATION_CENSUS_BASELINE")
      end,
      "a census below its floor must name the figure, the floor and the constant that declares " \
      "it, got #{shrunk.inspect}")

set_census(mutations: 12, call_sites: 2)
pruned_sites = []
capture_census(pruned_sites, baseline: synthetic_baseline)
check(failures, pruned_sites.any? { |failure| failure.include?("2 call sites, below the floor of 4") },
      "call sites must be floored on their own, not only through the mutation count, got " \
      "#{pruned_sites.inspect}")

# The real constant, reached through the default argument. Every case above
# passes a baseline of its own, so all of them would still pass if the default
# were an empty hash or a zero -- which is the floor not being there at all.
collapsed_census = []
set_census(mutations: 0, call_sites: 0)
capture_census(collapsed_census)
check(failures, collapsed_census.length == 2 &&
        collapsed_census.all? { |failure| failure.include?("POLICY_MUTATION_CENSUS_BASELINE") },
      "a census of nothing must fail against the committed baseline by default, in both figures, " \
      "got #{collapsed_census.inspect}")
check(failures,
      collapsed_census.any? do |failure|
        failure.include?("below the floor of #{POLICY_MUTATION_CENSUS_BASELINE.fetch(:mutations)}")
      end,
      "the default floor must be the committed baseline itself, got #{collapsed_census.inspect}")

# The baseline's own shape, derived rather than stated: a floor that had been
# zeroed, or whose two figures had been swapped, would be cleared by a census
# that had collapsed. Every call site carries at least one mutation, so the
# mutation figure can never legitimately be the smaller of the two.
check(failures,
      POLICY_MUTATION_CENSUS_BASELINE.fetch(:call_sites).is_a?(Integer) &&
        POLICY_MUTATION_CENSUS_BASELINE.fetch(:call_sites).positive? &&
        POLICY_MUTATION_CENSUS_BASELINE.fetch(:mutations) >= POLICY_MUTATION_CENSUS_BASELINE.fetch(:call_sites),
      "POLICY_MUTATION_CENSUS_BASELINE must floor both figures with positive counts and at least " \
      "as many mutations as call sites, got #{POLICY_MUTATION_CENSUS_BASELINE.inspect}")

# The two shapes that execute a checker themselves are invisible to the
# subtraction above -- nothing counts a run this file never sees -- so their
# registration is asserted where it lives. Stated by name rather than derived:
# the point is that these two are known to be outside the audit, and a third
# arriving is what the tripwire is for.
#
# There were three until #639. `run_foundation_wrapper` in
# tests/policy_manifest_test.rb was the other, and it went with the seven
# tests/contracts/*-foundation.sh wrappers it planted defects into. This list
# being stated is what turned that deletion into a failing check rather than a
# silently shorter census -- which is the whole argument for stating it, made
# once in practice.
{
  "tests/policy_mutation_support.rb" => ["def check_direct_policy_hostile_environment",
                                         "def run_compose_metadata_behavior"]
}.each do |relative_path, definitions|
  source = File.read(File.join(ROOT, relative_path))
  definitions.each do |definition|
    index = source.index(definition)
    raise "#{relative_path}: #{definition.inspect} is absent" unless index

    body = source[index, 1200]
    check(failures, body.include?("record_direct_audit_bypass("),
          "#{relative_path}: #{definition} runs a checker of its own, so it must register itself " \
          "as an assertion the audit did not re-derive")
  end
end

report(failures, "policy audit coverage: the audit reports its own scope",
       "policy audit coverage regression(s)")
