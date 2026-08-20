#!/usr/bin/env ruby

require "open3"
require "rbconfig"

SCRIPT = File.expand_path("validate_results.rb", __dir__)
failures = []

def check(failures, condition, message)
  failures << message unless condition
end

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

unless failures.empty?
  failures.each { |failure| warn "FAIL #{failure}" }
  abort "#{failures.length} aggregate result-policy failure(s)"
end

puts "aggregate result policy: all checks passed"
