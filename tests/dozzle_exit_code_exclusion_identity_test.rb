#!/usr/bin/env ruby
# frozen_string_literal: true
# The "Unexpected exit" rule's exit-code exclusion list must be identical in all
# six owners: a code Dozzle forwards but the relay refuses is dropped silently (#516).
# Owners are declared, not grepped (#476); 137 stays out so host OOM kills page (#493).

require "fileutils"
require "tmpdir"
require "yaml"

require_relative "policy_support"

include TestScaffold

RULE_NAME = "Unexpected exit"

EXPRESSION_PATTERN = /attributes\["exitCode"\]\s+in\s+\[([^\]]*)\]/
RELAY_SET_PATTERN = /numeric_exit\s+in\s+\{([^}]*)\}/
# The relay test has a second `for exit_code in (...)` loop; the region anchor disambiguates.
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

# Stated, so a dropped owner fails loudly.
EXPECTED_OWNERS = 6
# The floor stops six empty lists from agreeing.
MINIMUM_EXCLUDED_CODES = 3
REFUSED_CODE = 137

class ExtractionError < StandardError; end

# Canonical decimal only: the relay refuses non-canonical spellings like "0130".
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

# Takes a root so --self-test can plant divergences in a copy.
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

  # #516's exact shape: the group of four moved, the relay left behind.
  expect_self_test_failure(failures, "143 dropped from the rule and all three Ruby literals at once",
                           SELF_TEST_MESSAGE) do |root|
    plant(root, "roles/dozzle/defaults/main.yml", '["0", "130", "143"]', '["0", "130"]')
    plant(root, "tests/dozzle_contract_test.rb", '["0", "130", "143"]', '["0", "130"]')
    plant(root, "tests/contracts/dozzle-runtime.rb", '["0", "130", "143"]', '["0", "130"]')
    plant(root, "tests/contracts/dozzle-alerts.rb", '["0", "130", "143"]', '["0", "130"]')
  end

  expect_self_test_failure(failures, "the list emptied in every owner", "found, expected at least") do |root|
    plant(root, "roles/dozzle/defaults/main.yml", '["0", "130", "143"]', '["0"]')
    plant(root, "services/dozzle/alert_relay.py", "{0, 130, 143}", "{0}")
    plant(root, "tests/dozzle_contract_test.rb", '["0", "130", "143"]', '["0"]')
    plant(root, "tests/contracts/dozzle-runtime.rb", '["0", "130", "143"]', '["0"]')
    plant(root, "tests/contracts/dozzle-alerts.rb", '["0", "130", "143"]', '["0"]')
    plant(root, "tests/dozzle_alert_relay_test.py", '("0", "130", "143")', '("0",)')
  end

  expect_self_test_failure(failures, "137 restored in every owner", "which #493 removed on purpose") do |root|
    plant(root, "roles/dozzle/defaults/main.yml", '["0", "130", "143"]', '["0", "130", "143", "137"]')
    plant(root, "services/dozzle/alert_relay.py", "{0, 130, 143}", "{0, 130, 143, 137}")
    plant(root, "tests/dozzle_contract_test.rb", '["0", "130", "143"]', '["0", "130", "143", "137"]')
    plant(root, "tests/contracts/dozzle-runtime.rb", '["0", "130", "143"]', '["0", "130", "143", "137"]')
    plant(root, "tests/contracts/dozzle-alerts.rb", '["0", "130", "143"]', '["0", "130", "143", "137"]')
    plant(root, "tests/dozzle_alert_relay_test.py", '("0", "130", "143")', '("0", "130", "143", "137")')
  end

  # An extractor that stops matching must fail, not drop its owner.
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
