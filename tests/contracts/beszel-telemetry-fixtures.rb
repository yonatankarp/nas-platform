#!/usr/bin/env ruby
# The persisted-telemetry fixture half of the Beszel service contract: one
# recorded system/system_stats/container_stats triple, judged by the same
# category evaluator the role's probe uses. Needs nothing deployed and no
# vault, because tests/contracts/beszel.sh reaches it before its three
# ${VAR:?} requirements -- which is what lets
# tests/beszel_telemetry_probe_test.rb drive sixty-odd cases through it.
#
# usage: beszel-telemetry-fixtures.rb mac|nas FIXTURE_JSON
#
# BeszelTelemetry arrives as a -r preload from the INSPECTED tree, not from
# this checkout, so this file must not require it itself. Run it through
# tests/contracts/beszel.sh rather than directly.
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
