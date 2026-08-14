#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require "tmpdir"
require "time"

ROOT = File.expand_path("..", __dir__)
CONTRACT = File.join(ROOT, "tests/contracts/beszel.sh")
NOW = Time.utc(2026, 8, 12, 12, 0, 0)

def fixture
  {
    "now" => NOW.iso8601(3),
    "system" => { "id" => "system-safe-id", "status" => "up" },
    "system_stats" => {
      "id" => "system-stats-safe-id",
      "system" => "system-safe-id",
      "type" => "1m",
      "created" => (NOW - 60).iso8601(3),
      "stats" => {
        "cpu" => 0.0, "m" => 8.0, "mu" => 2.0, "mp" => 25.0,
        "d" => 100.0, "du" => 40.0, "dp" => 40.0,
        "g" => { "0" => { "n" => "Intel", "u" => 0.0 } }
      }
    },
    "container_stats" => {
      "id" => "container-stats-safe-id",
      "system" => "system-safe-id",
      "type" => "1m",
      "created" => (NOW - 60).iso8601(3),
      "stats" => [{ "n" => "beszel", "c" => 0.0, "m" => 0.1 }]
    }
  }
end

def run_probe(platform, payload)
  Dir.mktmpdir("beszel-telemetry-probe") do |dir|
    path = File.join(dir, "fixture.json")
    File.write(path, JSON.generate(payload), mode: "w", perm: 0o600)
    Open3.capture3(CONTRACT, "telemetry-fixtures", platform, path)
  end
end

failures = []

%w[mac nas].each do |platform|
  _stdout, stderr, status = run_probe(platform, fixture)
  failures << "valid #{platform} persisted telemetry was rejected: #{stderr}" unless status.success?
end

live_pocketbase_timestamps = fixture
%w[system_stats container_stats].each do |record|
  live_pocketbase_timestamps.fetch(record)["created"] = "2026-08-12 11:59:00.000Z"
end
_stdout, stderr, status = run_probe("mac", live_pocketbase_timestamps)
failures << "valid PocketBase space-separated timestamps were rejected: #{stderr}" unless
  status.success?

record_mutations = {
  "missing system record ID" => ->(data) { data.fetch("system_stats").delete("id") },
  "invalid system record ID" => ->(data) { data.fetch("system_stats")["id"] = "bad id" },
  "whitespace system record ID" => ->(data) { data.fetch("system_stats")["id"] = "  " },
  "typed system record ID" => ->(data) { data.fetch("system_stats")["id"] = 123 },
  "missing container record ID" => ->(data) { data.fetch("container_stats").delete("id") },
  "invalid container record ID" => ->(data) { data.fetch("container_stats")["id"] = "bad id" },
  "whitespace container record ID" => ->(data) { data.fetch("container_stats")["id"] = "  " },
  "typed container record ID" => ->(data) { data.fetch("container_stats")["id"] = 123 },
  "wrong system" => ->(data) { data.fetch("system_stats")["system"] = "another-system" },
  "missing system" => ->(data) { data.fetch("system_stats").delete("system") },
  "wrong container system" => ->(data) { data.fetch("container_stats")["system"] = "another-system" },
  "missing container system" => ->(data) { data.fetch("container_stats").delete("system") },
  "wrong type" => ->(data) { data.fetch("system_stats")["type"] = "10m" },
  "missing type" => ->(data) { data.fetch("system_stats").delete("type") },
  "wrong container type" => ->(data) { data.fetch("container_stats")["type"] = "10m" },
  "missing container type" => ->(data) { data.fetch("container_stats").delete("type") },
  "boolean core" => ->(data) { data.fetch("system_stats").fetch("stats")["cpu"] = true },
  "boolean disk" => ->(data) { data.fetch("system_stats").fetch("stats")["d"] = true },
  "boolean GPU" => ->(data) { data.fetch("system_stats").fetch("stats").fetch("g").fetch("0")["u"] = true },
  "boolean container CPU" => ->(data) { data.fetch("container_stats").fetch("stats").fetch(0)["c"] = true },
  "boolean container memory" => ->(data) { data.fetch("container_stats").fetch("stats").fetch(0)["m"] = true },
  "malformed system record" => ->(data) { data["system_stats"] = [] },
  "malformed container record" => ->(data) { data["container_stats"] = [] },
  "malformed system stats" => ->(data) { data.fetch("system_stats")["stats"] = [] },
  "malformed container stats" => ->(data) { data.fetch("container_stats")["stats"] = {} },
  "malformed GPU entry" => ->(data) { data.fetch("system_stats").fetch("stats")["g"] = { "0" => [] } },
  "malformed container entry" => ->(data) { data.fetch("container_stats")["stats"] = ["bad"] },
  "invalid system timestamp" => ->(data) { data.fetch("system_stats")["created"] = "not-a-time" },
  "invalid container timestamp" => ->(data) { data.fetch("container_stats")["created"] = "not-a-time" },
  "naive system timestamp" => ->(data) { data.fetch("system_stats")["created"] = "2026-08-12T11:59:00" },
  "naive container timestamp" => ->(data) { data.fetch("container_stats")["created"] = "2026-08-12T11:59:00" },
  "typed system timestamp" => ->(data) { data.fetch("system_stats")["created"] = 123 },
  "typed container timestamp" => ->(data) { data.fetch("container_stats")["created"] = 123 },
  "future timestamp" => ->(data) { data.fetch("system_stats")["created"] = (NOW + 6).iso8601(3) },
  "whitespace GPU name" => ->(data) { data.fetch("system_stats").fetch("stats").fetch("g").fetch("0")["n"] = "  " },
  "whitespace container name" => ->(data) { data.fetch("container_stats").fetch("stats").fetch(0)["n"] = "  " }
}
record_mutations.each do |name, mutate|
  payload = fixture
  mutate.call(payload)
  _stdout, stderr, status = run_probe("nas", payload)
  failures << "#{name} telemetry was accepted" if status.success?
  failures << "#{name} failure omitted safe identifiers" unless stderr.include?("system-safe-id")
  failures << "#{name} failure emitted a Ruby exception" if stderr.include?("Error)") || stderr.include?("Traceback")
end

missing_gpu = fixture
missing_gpu.fetch("system_stats").fetch("stats").delete("g")
_stdout, stderr, status = run_probe("nas", missing_gpu)
failures << "NAS telemetry without GPU was accepted" if status.success?
failures << "missing GPU failure omitted safe category" unless stderr.include?("gpu")
failures << "missing GPU failure omitted safe IDs" unless stderr.include?("system-safe-id")

stale = fixture
stale.fetch("system_stats")["created"] = (NOW - 181).iso8601(3)
_stdout, stderr, status = run_probe("mac", stale)
failures << "stale core/disk telemetry was accepted" if status.success?
failures << "stale failure omitted affected categories" unless stderr.include?("core") && stderr.include?("disk")

missing_core = fixture
missing_core.fetch("system_stats").fetch("stats").delete("m")
_stdout, stderr, status = run_probe("mac", missing_core)
failures << "system telemetry without core fields was accepted" if status.success?
failures << "missing core failure omitted safe category" unless stderr.include?("core")

missing_disk = fixture
missing_disk.fetch("system_stats").fetch("stats").delete("d")
_stdout, stderr, status = run_probe("mac", missing_disk)
failures << "system telemetry without disk fields was accepted" if status.success?
failures << "missing disk failure omitted safe category" unless stderr.include?("disk")

empty_containers = fixture
empty_containers.fetch("container_stats")["stats"] = []
_stdout, stderr, status = run_probe("mac", empty_containers)
failures << "empty persisted container telemetry was accepted" if status.success?
failures << "empty container failure omitted safe category" unless stderr.include?("containers")

%w[first last].each do |position|
  mixed_gpu = fixture
  valid = { "n" => "Intel", "u" => 0.0 }
  malformed = { "n" => "Intel" }
  entries = position == "first" ? [malformed, valid] : [valid, malformed]
  mixed_gpu.fetch("system_stats").fetch("stats")["g"] =
    entries.each_with_index.to_h { |gpu, index| [index.to_s, gpu] }
  _stdout, stderr, status = run_probe("nas", mixed_gpu)
  failures << "mixed GPU telemetry with malformed #{position} entry was accepted" if status.success?
  failures << "mixed GPU #{position} failure omitted category" unless stderr.include?("gpu")

  mixed_containers = fixture
  valid = { "n" => "hub", "c" => 0.0, "m" => 0.1 }
  malformed = { "n" => "hub", "m" => 0.1 }
  mixed_containers.fetch("container_stats")["stats"] =
    position == "first" ? [malformed, valid] : [valid, malformed]
  _stdout, stderr, status = run_probe("mac", mixed_containers)
  failures << "mixed container telemetry with malformed #{position} entry was accepted" if status.success?
  failures << "mixed container #{position} failure omitted category" unless stderr.include?("containers")
end

health_only = fixture
health_only.delete("system_stats")
health_only.delete("container_stats")
health_only["token"] = "sensitive-token"
_stdout, stderr, status = run_probe("mac", health_only)
failures << "healthy system without persisted records was accepted" if status.success?
failures << "health-only failure leaked fixture contents" if stderr.include?("Intel") || stderr.include?("beszel\"")
failures << "health-only failure leaked a token" if stderr.include?("sensitive-token")

abort failures.join("\n") unless failures.empty?
puts "Beszel telemetry probe semantics passed"
