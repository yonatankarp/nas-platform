#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "contracts/support/beszel_telemetry"

now = Time.utc(2026, 8, 12, 12, 0, 0)
monotonic = 0.0
timeouts = []
collections = []
fetcher = lambda do |collection, timeout|
  collections << collection
  timeouts << timeout
  monotonic += timeout
  nil
end
clock = -> { monotonic }
sleeper = ->(seconds) { monotonic += seconds }

evidence = BeszelTelemetry.poll(
  platform: "mac", system: { "id" => "system-safe-id" }, timeout_seconds: 0.05,
  request_timeout_seconds: 0.02, delay_seconds: 0.01, now: now,
  fetcher: fetcher, clock: clock, sleeper: sleeper
)

abort "bounded poll unexpectedly succeeded" if evidence.ready?
abort "bounded poll exceeded its monotonic deadline" if monotonic > 0.05
abort "bounded poll did not cap request timeouts by remaining deadline" if
  timeouts.empty? || timeouts.any? { |timeout| timeout <= 0 || timeout > 0.02 }
abort "bounded poll requested a collection after its deadline" if collections.length > 3

monotonic = 0.0
created = now + 10
system_stats = {
  "id" => "system-stats-safe", "system" => "system-safe-id", "type" => "1m",
  "created" => created.iso8601,
  "stats" => { "cpu" => 0.0, "m" => 8.0, "mu" => 2.0, "mp" => 25.0,
               "d" => 100.0, "du" => 40.0, "dp" => 40.0 }
}
container_stats = {
  "id" => "container-stats-safe", "system" => "system-safe-id", "type" => "1m",
  "created" => created.iso8601,
  "stats" => [{ "n" => "hub", "c" => 0.0, "m" => 0.1 }]
}
evidence = BeszelTelemetry.poll(
  platform: "mac", system: { "id" => "system-safe-id" }, timeout_seconds: 20,
  request_timeout_seconds: 5, delay_seconds: 1,
  fetcher: lambda do |collection, _timeout|
    monotonic += 5
    collection == "system_stats" ? system_stats : container_stats
  end,
  clock: -> { monotonic }, wall_clock: -> { now + monotonic }, sleeper: ->(_seconds) {}
)
abort "poll evaluated a newly persisted sample against its start time" unless evidence.ready?

monotonic = 0.0
attempts = 0
transient_fetcher = lambda do |collection, _timeout|
  attempts += 1
  raise BeszelTelemetry::TransientFetchError, "temporary" if attempts == 1

  collection == "system_stats" ? system_stats : container_stats
end
evidence = BeszelTelemetry.poll(
  platform: "mac", system: { "id" => "system-safe-id" }, timeout_seconds: 20,
  request_timeout_seconds: 5, delay_seconds: 1, now: created,
  fetcher: transient_fetcher, clock: -> { monotonic }, sleeper: ->(seconds) { monotonic += seconds }
)
abort "transient telemetry failure was not retried to success" unless evidence.ready? && attempts >= 3

attempts = 0
begin
  BeszelTelemetry.poll(
    platform: "mac", system: { "id" => "system-safe-id" }, timeout_seconds: 20,
    request_timeout_seconds: 5, delay_seconds: 1, now: created,
    fetcher: lambda do |_collection, _timeout|
      attempts += 1
      raise BeszelTelemetry::NonRetryableFetchError, "telemetry request was not authorized"
    end,
    clock: -> { monotonic }, sleeper: ->(seconds) { monotonic += seconds }
  )
  abort "authorization failure was retried instead of failing immediately"
rescue BeszelTelemetry::NonRetryableFetchError
  abort "authorization failure made more than one request" unless attempts == 1
end

response = Struct.new(:code, :body)
responses = [
  response.new("503", ""),
  response.new("200", JSON.generate("items" => [system_stats]))
]
request_timeouts = []
requester = lambda do |_uri, _token, timeout|
  request_timeouts << timeout
  responses.shift
end
begin
  BeszelTelemetry.fetch_latest_record(
    base_uri: URI("http://127.0.0.1:8090"), collection: "system_stats",
    token: "safe-token", system_id: "system-safe-id", timeout_seconds: 0.02,
    requester: requester
  )
  abort "Ruby collection fetch accepted a retryable HTTP error"
rescue BeszelTelemetry::TransientFetchError
  record = BeszelTelemetry.fetch_latest_record(
    base_uri: URI("http://127.0.0.1:8090"), collection: "system_stats",
    token: "safe-token", system_id: "system-safe-id", timeout_seconds: 0.01,
    requester: requester
  )
  abort "Ruby collection fetch did not recover after a transient HTTP error" unless
    record == system_stats && request_timeouts == [0.02, 0.01]
end

auth_attempts = 0
begin
  BeszelTelemetry.fetch_latest_record(
    base_uri: URI("http://127.0.0.1:8090"), collection: "system_stats",
    token: "safe-token", system_id: "system-safe-id", timeout_seconds: 0.02,
    requester: lambda do |_uri, _token, _timeout|
      auth_attempts += 1
      response.new("401", "")
    end
  )
  abort "Ruby collection fetch accepted an authorization failure"
rescue BeszelTelemetry::NonRetryableFetchError
  abort "Ruby collection fetch retried authorization" unless auth_attempts == 1
end

puts "Beszel telemetry poll deadline passed"
