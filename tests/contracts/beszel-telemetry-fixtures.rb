#!/usr/bin/env ruby
# Persisted-telemetry fixture half of the Beszel contract; needs nothing deployed.
# usage: beszel-telemetry-fixtures.rb mac|nas FIXTURE_JSON
# Run through tests/contracts/beszel.sh: BeszelTelemetry is -r preloaded from the INSPECTED tree.
platform, fixture_path = ARGV
abort "Beszel telemetry fixture failed: unknown platform" unless %w[mac nas].include?(platform)
fixture = JSON.parse(File.read(fixture_path))
evidence = BeszelTelemetry.evaluate(
  platform: platform,
  system: fixture["system"],
  system_stats: fixture["system_stats"],
  container_stats: fixture["container_stats"],
  now: Time.parse(fixture.fetch("now")).utc
)
abort "Beszel telemetry fixture failed: #{evidence.safe_failure}" unless evidence.ready?
puts "Beszel telemetry fixture passed (#{platform})"
