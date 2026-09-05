#!/usr/bin/env ruby

require "open3"
require "rbconfig"

require_relative "../policy_support"
require_relative "validate_results"

include TestScaffold

SCRIPT = File.expand_path("validate_results.rb", __dir__)
failures = []

def validate(*arguments)
  Open3.capture3(RbConfig.ruby, SCRIPT, *arguments)
end

stdout, stderr, status = validate("changes=success", "static=skipped", "paperless=success")
check(failures, status.success?, "success and skipped results must be accepted: #{stderr.inspect}")
check(failures, stderr.empty?, "accepted results must not write to stderr: #{stderr.inspect}")
check(failures,
      stdout == "accepted: changes=success static=skipped paperless=success\n",
      "accepted summary was not compact and deterministic: #{stdout.inspect}")

{
  "paperless=failure" => %w[paperless failure],
  "immich=cancelled" => %w[immich cancelled],
  "smoke=pending" => %w[smoke pending],
  "foundation=unknown" => %w[foundation unknown],
  "static=" => ["static", ""],
}.each do |argument, (job, result)|
  stdout, stderr, status = validate(argument)
  check(failures, !status.success?, "#{argument.inspect} must be rejected")
  check(failures, stdout.empty?, "#{argument.inspect} must not print an accepted summary")
  check(failures,
        stderr.include?(job) && stderr.include?(result.inspect),
        "#{argument.inspect} error must name job and unexpected result: #{stderr.inspect}")
end

# The non-blocking jobs are the ones the workflow declares it cannot be blocked
# by, and the gate used to abort on them anyway. Read the list out of the script
# rather than restating it: a job added there without a row here would otherwise
# gain its tolerance untested.
check(failures, !ValidateResults::NON_BLOCKING_JOBS.empty?,
      "the non-blocking rows below prove nothing if no job is declared non-blocking")
ValidateResults::NON_BLOCKING_JOBS.each do |job|
  (ValidateResults::KNOWN_RESULTS - ValidateResults::ALLOWED_RESULTS).each do |result|
    stdout, stderr, status = validate("changes=success", "#{job}=#{result}")
    check(failures, status.success?,
          "#{job}=#{result} must not fail the gate: #{stderr.inspect}")
    check(failures, stdout == "accepted: changes=success #{job}=#{result}\n",
          "#{job}=#{result} must still print the accepted summary: #{stdout.inspect}")
    check(failures, stderr.include?(job) && stderr.include?(result.inspect),
          "#{job}=#{result} must be reported on stderr rather than swallowed: #{stderr.inspect}")
  end

  stdout, stderr, status = validate("#{job}=success")
  check(failures, status.success? && stderr.empty?,
        "a non-blocking job that succeeded must say nothing: #{stderr.inspect}")
  check(failures, stdout == "accepted: #{job}=success\n",
        "a non-blocking job that succeeded must print the accepted summary: #{stdout.inspect}")

  # Tolerating the results GitHub reports is not tolerating any string at all.
  # A value outside KNOWN_RESULTS is a typo or a schema change, and a
  # non-blocking job is exactly where one would go unnoticed.
  %w[pending unknown].each do |result|
    stdout, stderr, status = validate("#{job}=#{result}")
    check(failures, !status.success?,
          "#{job}=#{result} must be rejected: a non-blocking job still reports a known result")
    check(failures, stdout.empty?, "#{job}=#{result} must not print an accepted summary")
    check(failures, stderr.include?(job) && stderr.include?(result.inspect),
          "#{job}=#{result} error must name job and unexpected result: #{stderr.inspect}")
  end
end

# The tolerance is keyed by job name and must not leak to the jobs that carry the
# coverage.
(ValidateResults::KNOWN_RESULTS - ValidateResults::ALLOWED_RESULTS).each do |result|
  _stdout, _stderr, status = validate("static=#{result}")
  check(failures, !status.success?, "static=#{result} must still fail the gate")
end

{
  "no arguments" => [],
  "missing separator" => ["paperless"],
  "empty job" => ["=success"],
  "extra separator" => ["paperless=success=ignored"],
  "duplicate job" => ["paperless=success", "paperless=skipped"]
}.each do |description, arguments|
  stdout, stderr, status = validate(*arguments)
  check(failures, !status.success?, "#{description} must be rejected")
  check(failures, stdout.empty?, "#{description} must not print an accepted summary")
  check(failures, !stderr.empty?, "#{description} must explain why validation failed")
end

report(failures, "aggregate result policy: all checks passed",
       "aggregate result-policy failure(s)")
