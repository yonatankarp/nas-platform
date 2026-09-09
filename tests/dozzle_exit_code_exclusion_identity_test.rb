#!/usr/bin/env ruby
# frozen_string_literal: true
# The "Unexpected exit" rule's exit-code exclusion list is written in six places
# and, until this file, no check read two of them together.
#
# The list is a contract between two programs. Dozzle evaluates the rule
# expression in roles/dozzle/defaults/main.yml and forwards every `die` event
# whose exit code is not excluded; services/dozzle/alert_relay.py re-validates
# the same exclusion and answers 400 to anything it thinks Dozzle should have
# filtered. The two halves must name the same codes or the platform loses
# alerts: a code the rule forwards and the relay rejects is dropped at
# `alert_relay.py:799` as a bare HTTP 400, and `log_message` is a no-op, so the
# alert leaves no notification and no log line. The relay is the delivery path
# every alert on this platform takes, so it cannot report its own drop either.
#
# The other four copies are the tests, which pin the rule's whole expression
# string: tests/dozzle_contract_test.rb, tests/contracts/dozzle-runtime.rb and
# tests/contracts/dozzle-alerts.rb each restate it, and
# tests/dozzle_alert_relay_test.py restates the relay's set. Each copy is pinned
# only to the half it belongs to, which is what let #516's probe pass every
# existing check: dropping 143 from the role default and the three Ruby literals
# together, leaving the relay and its unit test at {0, 130, 143}, kept
# policy_test.rb, dozzle_contract_test.rb, dozzle_quality_test.rb and
# dozzle_alert_relay_test.py all green while Dozzle forwarded exit-143 die
# events into a relay that refused them.
#
# So this is the comparison, as a check, over all six owners rather than the two
# the divergence needs: four of them are copies that move as a group, and a
# comparison that covered only the group and the relay would still pass a
# divergence introduced in one member of the group alone.
#
# WHY THE OWNER LIST IS DECLARED rather than discovered by grepping for the
# expression. A grep finds the copies that still look like copies; a copy
# reworded past the pattern would silently leave the comparison, which is the
# failure this check exists to prevent. The gate manifest and
# tests/capture_helper_identity_test.rb are declared for the same reason (#476).
#
# WHY A FLOOR AND AN EXACT COUNT, both. An identity comparison over zero
# extractions finds one distinct value and passes, and an identity comparison
# over six empty lists passes just as happily while the rule excludes nothing
# and the relay refuses every code Dozzle sends. So every owner must yield
# exactly one list, the owner count is asserted as a literal, and each list is
# floored at MINIMUM_EXCLUDED_CODES entries.
#
# WHY 137 IS NAMED HERE and nothing else is. #493 removed "137" from the
# exclusion list precisely so that a host-level OOM kill pages: Docker's own
# `oom` event is cgroup-scoped and cannot report one, which leaves the `die`
# rule as the only path. That is a decision about one value, and restoring the
# value to any owner would silence it again, so the value is refused by name.
# The rest of the list is compared and never restated, because a restatement
# here would be a seventh copy for the next divergence to hide in.

require "fileutils"
require "tmpdir"
require "yaml"

require_relative "policy_support"

include TestScaffold

# The alert whose expression carries the list. Named once; every owner below
# that reads YAML or a whole expression string is anchored on it.
RULE_NAME = "Unexpected exit"

# `["0", "130", "143"]` out of the rule expression, in any of the four files
# that restate the expression.
EXPRESSION_PATTERN = /attributes\["exitCode"\]\s+in\s+\[([^\]]*)\]/
# `{0, 130, 143}` out of the relay's own re-validation.
RELAY_SET_PATTERN = /numeric_exit\s+in\s+\{([^}]*)\}/
# `("0", "130", "143")` out of the relay unit test, inside the one test method
# that asserts the graceful codes stay quiet. The file has a second
# `for exit_code in (...)` loop over non-canonical spellings, so the region
# anchor is what makes this extraction unambiguous rather than the pattern.
RELAY_TEST_TUPLE_PATTERN = /for exit_code in \(([^)]*)\):/
RELAY_TEST_REGION_START = "    def test_sigkill_exit_pages_while_the_graceful_codes_stay_quiet(self):"
RELAY_TEST_REGION_END = /\A    def /

OWNERS = [
  {
    "path" => "roles/dozzle/defaults/main.yml",
    "role" => "the rule Dozzle evaluates",
    "kind" => :rule_yaml
  },
  {
    "path" => "services/dozzle/alert_relay.py",
    "role" => "the relay's re-validation of the same exclusion",
    "kind" => :relay_set
  },
  {
    "path" => "tests/dozzle_contract_test.rb",
    "role" => "the contract test's expected alert definitions",
    "kind" => :expression_text
  },
  {
    "path" => "tests/contracts/dozzle-runtime.rb",
    "role" => "the live contract's expected alert definitions",
    "kind" => :expression_text
  },
  {
    "path" => "tests/contracts/dozzle-alerts.rb",
    "role" => "the static contract's expected alert definitions",
    "kind" => :expression_text
  },
  {
    "path" => "tests/dozzle_alert_relay_test.py",
    "role" => "the relay unit test's quiet-code cases",
    "kind" => :relay_test_tuple
  }
].freeze

# Stated rather than derived, so an owner dropped from the list narrows the
# comparison loudly instead of leaving a smaller one green.
EXPECTED_OWNERS = 6
# The list has held three codes since it was written and #493 only removed one.
# The floor is not the content -- it is what stops six empty lists from agreeing.
MINIMUM_EXCLUDED_CODES = 3
# The one value the list must not regain. See the header.
REFUSED_CODE = 137

class ExtractionError < StandardError; end

# `"0", "130", "143"` / `0, 130, 143` -> [0, 130, 143]. Canonical decimal only:
# the relay refuses "0130" as a non-canonical spelling, so a copy that wrote one
# would be comparing something the relay can never receive.
def parse_code_list(raw, owner_path)
  elements = raw.split(",").map(&:strip).reject(&:empty?)
  raise ExtractionError, "#{owner_path} lists no exit codes at all" if elements.empty?

  elements.map do |element|
    text = element.gsub(/\A["']|["']\z/, "")
    unless /\A(?:0|[1-9][0-9]*)\z/.match?(text)
      raise ExtractionError,
            "#{owner_path} lists #{element.inspect}, which is not a canonical decimal exit code"
    end

    Integer(text, 10)
  end
end

def single_capture(text, pattern, owner_path, subject)
  matches = text.scan(pattern)
  unless matches.length == 1
    raise ExtractionError,
          "#{owner_path} matches #{subject} #{matches.length} times, expected exactly once; " \
          "the extraction cannot say which list it compared"
  end

  matches.first.first
end

def rule_expression_from_yaml(path, owner_path)
  document = YAML.safe_load_file(path)
  alerts = document["dozzle_alerts"]
  unless alerts.is_a?(Array)
    raise ExtractionError, "#{owner_path} declares no dozzle_alerts list"
  end

  named = alerts.select { |alert| alert.is_a?(Hash) && alert["name"] == RULE_NAME }
  unless named.length == 1
    raise ExtractionError,
          "#{owner_path} declares #{named.length} alerts named #{RULE_NAME.inspect}, expected one"
  end

  expression = named.first["eventExpression"]
  unless expression.is_a?(String)
    raise ExtractionError, "#{owner_path} alert #{RULE_NAME.inspect} has no eventExpression string"
  end

  expression
end

def relay_test_region(text, owner_path)
  lines = text.lines.map(&:chomp)
  starts = lines.each_index.select { |index| lines[index] == RELAY_TEST_REGION_START }
  unless starts.length == 1
    raise ExtractionError,
          "#{owner_path} declares the graceful-codes test #{starts.length} times, expected once; " \
          "the region anchor no longer identifies one method"
  end

  first = starts.first
  last = ((first + 1)...lines.length).find { |index| lines[index].match?(RELAY_TEST_REGION_END) }
  last = lines.length if last.nil?
  lines[first...last].join("\n")
end

def excluded_codes(root, owner)
  owner_path = owner.fetch("path")
  path = File.join(root, owner_path)
  raise ExtractionError, "#{owner_path} is absent, so the copy it carries is compared against nothing" unless
    File.file?(path)

  case owner.fetch("kind")
  when :rule_yaml
    expression = rule_expression_from_yaml(path, owner_path)
    parse_code_list(single_capture(expression, EXPRESSION_PATTERN, owner_path,
                                   "the exitCode exclusion list"), owner_path)
  when :expression_text
    parse_code_list(single_capture(File.read(path), EXPRESSION_PATTERN, owner_path,
                                   "the exitCode exclusion list"), owner_path)
  when :relay_set
    parse_code_list(single_capture(File.read(path), RELAY_SET_PATTERN, owner_path,
                                   "the relay's numeric_exit exclusion set"), owner_path)
  when :relay_test_tuple
    region = relay_test_region(File.read(path), owner_path)
    parse_code_list(single_capture(region, RELAY_TEST_TUPLE_PATTERN, owner_path,
                                   "the quiet-code loop inside the graceful-codes test"), owner_path)
  else
    raise ExtractionError, "#{owner_path} declares an unknown extraction kind"
  end
end

# The whole comparison, against an arbitrary root, so --self-test can plant a
# divergence in a copy of the six files and re-run it in process. Returns the
# accumulated failures rather than reporting them.
def exclusion_failures(root)
  failures = []

  check(failures, OWNERS.length == EXPECTED_OWNERS,
        "the exclusion list has #{EXPECTED_OWNERS} declared owners, not #{OWNERS.length}: an " \
        "owner dropped from this list is a copy free to diverge")

  extracted = {}
  OWNERS.each do |owner|
    begin
      codes = excluded_codes(root, owner)
    rescue ExtractionError => error
      failures << error.message
      next
    end

    owner_path = owner.fetch("path")
    check_floor(failures, codes.length, MINIMUM_EXCLUDED_CODES,
                "#{owner_path} (#{owner.fetch('role')}) exit-code exclusion list")
    check(failures, codes.uniq.length == codes.length,
          "#{owner_path} repeats an exit code in #{codes.inspect}; a duplicate hides a value " \
          "that was meant to be replaced")
    check(failures, !codes.include?(REFUSED_CODE),
          "#{owner_path} excludes #{REFUSED_CODE}, which #493 removed on purpose: Docker's own " \
          "`oom` event is cgroup-scoped, so the `die` rule is the only path a host-level " \
          "out-of-memory kill can page on")
    extracted[owner_path] = codes.sort
  end

  check(failures, extracted.length == EXPECTED_OWNERS,
        "#{EXPECTED_OWNERS} owners were expected to yield a list, #{extracted.length} did; the " \
        "comparison below covers less than it claims")

  distinct = extracted.values.uniq
  if distinct.length > 1
    detail = extracted.map { |owner_path, codes| "#{owner_path} #{codes.inspect}" }
    failures << "the exit-code exclusion list has #{distinct.length} distinct forms across its " \
                "owners, expected one: #{detail.join('; ')}. Dozzle forwards what the rule does " \
                "not exclude and the relay refuses what its own set does not, so any disagreement " \
                "drops alerts on the path that cannot report its own drop"
  end

  failures
end

SELF_TEST_MESSAGE = "distinct forms across its owners"

# Copy just the six owners, so a planted divergence costs a few kilobytes rather
# than a copy of the repository.
def with_planted_root
  Dir.mktmpdir("dozzle-exclusion-identity") do |root|
    OWNERS.each do |owner|
      destination = File.join(root, owner.fetch("path"))
      FileUtils.mkdir_p(File.dirname(destination))
      FileUtils.cp(File.join(ROOT, owner.fetch("path")), destination)
    end
    yield root
  end
end

def plant(root, relative, original, replacement)
  path = File.join(root, relative)
  text = File.read(path)
  occurrences = text.scan(Regexp.new(Regexp.escape(original))).length
  raise "planting #{original.inspect} in #{relative} matched #{occurrences} times" unless
    occurrences == 1

  File.write(path, text.sub(original, replacement))
end

def expect_self_test_failure(failures, label, expected_fragment)
  with_planted_root do |root|
    yield root
    detected = exclusion_failures(root)
    matched = detected.select { |failure| failure.include?(expected_fragment) }
    if matched.empty?
      failures << "self-test: #{label} was not detected; expected a failure containing " \
                  "#{expected_fragment.inspect}, got #{detected.inspect}"
    else
      puts "self-test detected #{label}: #{matched.first}"
    end
  end
end

def run_self_test
  failures = []

  with_planted_root do |root|
    clean = exclusion_failures(root)
    unless clean.empty?
      failures << "self-test: the unplanted copy of the six owners already fails, so every " \
                  "detection below would prove nothing: #{clean.inspect}"
    end
  end

  # #516's own probe, one owner at a time. Each of the four expression copies and
  # the two Python copies must be enough on its own.
  expect_self_test_failure(failures, "143 dropped from the rule Dozzle evaluates",
                           SELF_TEST_MESSAGE) do |root|
    plant(root, "roles/dozzle/defaults/main.yml", '["0", "130", "143"]', '["0", "130"]')
  end
  expect_self_test_failure(failures, "143 dropped from the relay's own set",
                           SELF_TEST_MESSAGE) do |root|
    plant(root, "services/dozzle/alert_relay.py", "{0, 130, 143}", "{0, 130}")
  end
  expect_self_test_failure(failures, "143 dropped from the contract test's literal",
                           SELF_TEST_MESSAGE) do |root|
    plant(root, "tests/dozzle_contract_test.rb", '["0", "130", "143"]', '["0", "130"]')
  end
  expect_self_test_failure(failures, "143 dropped from the live contract's literal",
                           SELF_TEST_MESSAGE) do |root|
    plant(root, "tests/contracts/dozzle-runtime.rb", '["0", "130", "143"]', '["0", "130"]')
  end
  expect_self_test_failure(failures, "143 dropped from the static contract's literal",
                           SELF_TEST_MESSAGE) do |root|
    plant(root, "tests/contracts/dozzle-alerts.rb", '["0", "130", "143"]', '["0", "130"]')
  end
  expect_self_test_failure(failures, "143 dropped from the relay unit test's quiet codes",
                           SELF_TEST_MESSAGE) do |root|
    plant(root, "tests/dozzle_alert_relay_test.py", '("0", "130", "143")', '("0", "130")')
  end

  # The exact shape #516 probed: the group of four moved together, the relay half
  # left behind. Every existing check passed this; this one must not.
  expect_self_test_failure(failures, "143 dropped from the rule and all three Ruby literals at once",
                           SELF_TEST_MESSAGE) do |root|
    plant(root, "roles/dozzle/defaults/main.yml", '["0", "130", "143"]', '["0", "130"]')
    plant(root, "tests/dozzle_contract_test.rb", '["0", "130", "143"]', '["0", "130"]')
    plant(root, "tests/contracts/dozzle-runtime.rb", '["0", "130", "143"]', '["0", "130"]')
    plant(root, "tests/contracts/dozzle-alerts.rb", '["0", "130", "143"]', '["0", "130"]')
  end

  # An identity comparison passes over six empty lists, so the floor is what has
  # to catch a list emptied everywhere at once.
  expect_self_test_failure(failures, "the list emptied in every owner", "found, expected at least") do |root|
    plant(root, "roles/dozzle/defaults/main.yml", '["0", "130", "143"]', '["0"]')
    plant(root, "services/dozzle/alert_relay.py", "{0, 130, 143}", "{0}")
    plant(root, "tests/dozzle_contract_test.rb", '["0", "130", "143"]', '["0"]')
    plant(root, "tests/contracts/dozzle-runtime.rb", '["0", "130", "143"]', '["0"]')
    plant(root, "tests/contracts/dozzle-alerts.rb", '["0", "130", "143"]', '["0"]')
    plant(root, "tests/dozzle_alert_relay_test.py", '("0", "130", "143")', '("0",)')
  end

  # #493 restored in every owner at once: six agreeing copies, all of them wrong.
  expect_self_test_failure(failures, "137 restored in every owner", "which #493 removed on purpose") do |root|
    plant(root, "roles/dozzle/defaults/main.yml", '["0", "130", "143"]', '["0", "130", "143", "137"]')
    plant(root, "services/dozzle/alert_relay.py", "{0, 130, 143}", "{0, 130, 143, 137}")
    plant(root, "tests/dozzle_contract_test.rb", '["0", "130", "143"]', '["0", "130", "143", "137"]')
    plant(root, "tests/contracts/dozzle-runtime.rb", '["0", "130", "143"]', '["0", "130", "143", "137"]')
    plant(root, "tests/contracts/dozzle-alerts.rb", '["0", "130", "143"]', '["0", "130", "143", "137"]')
    plant(root, "tests/dozzle_alert_relay_test.py", '("0", "130", "143")', '("0", "130", "143", "137")')
  end

  # An extractor that stops matching must fail rather than drop its owner from a
  # comparison that then reports one distinct form.
  expect_self_test_failure(failures, "the relay's exclusion set renamed past its pattern",
                           "expected exactly once") do |root|
    plant(root, "services/dozzle/alert_relay.py", "numeric_exit in {0, 130, 143}",
          "int(exit_code) in {0, 130, 143}")
  end
  expect_self_test_failure(failures, "the relay unit test's region anchor renamed",
                           "expected once") do |root|
    plant(root, "tests/dozzle_alert_relay_test.py",
          "def test_sigkill_exit_pages_while_the_graceful_codes_stay_quiet(self):",
          "def test_sigkill_exit_pages_and_graceful_codes_stay_quiet(self):")
  end
  expect_self_test_failure(failures, "the rule renamed out of the role default",
                           "expected one") do |root|
    plant(root, "roles/dozzle/defaults/main.yml", "  - name: Unexpected exit",
          "  - name: Unexpected stop")
  end

  report(failures, "dozzle exit-code exclusion identity self-test: every planted divergence was detected",
         "self-test failure(s)")
end

if ARGV.include?("--self-test")
  run_self_test
else
  report(exclusion_failures(ROOT),
         "dozzle exit-code exclusion identity: all #{EXPECTED_OWNERS} owners name the same exit codes",
         "dozzle exit-code exclusion violation(s)")
end
