#!/usr/bin/env ruby
# frozen_string_literal: true

# Every owned Configarr field must be visible in the owned projection.
#
# Drift is detected by comparing projections, so a field the projection drops is
# a field whose drift is silently accepted. The reconciliation fixture proved
# this per field with a full Ansible round trip, which costs about twenty-two
# seconds each and proves the same pure property every time: break one owned
# field and the projection must change. That property is checked here directly
# against the real filter, for every field at once, in about a second. The
# fixture keeps one round trip per behavioural class, which is the part only a
# real play can show — that a difference reaches Configarr as exactly one write
# and is recorded.
#
# The mutation table is the one the fixture uses. Two tables would let this file
# report coverage of fields the contract does not actually own.
#
# Run with --self-test to prove the check detects its own regression.

require "digest/sha2"
require "json"
require "open3"
require_relative "media_acquisition_reconciliation_support"

CONFIGARR_ENDPOINTS = %w[qualityprofile qualitydefinition customformat config/naming].freeze

def configarr_api_results(state)
  %w[radarr sonarr].flat_map do |service|
    CONFIGARR_ENDPOINTS.map do |endpoint|
      {
        "item" => [{ "name" => service }, endpoint],
        "json" => state.fetch("configarr").fetch(service).fetch(endpoint)
      }
    end
  end
end

def ansible_python
  version, status = Open3.capture2(ANSIBLE_PLAYBOOK, "--version")
  abort "could not resolve the Ansible interpreter" unless status.success?
  path = version[/^\s*python version = .*\((\/[^()]*)\)$/, 1]
  abort "could not read the Ansible interpreter path" unless path && File.executable?(path)
  path
end

# Projects every payload in one interpreter: starting Python once per field
# would cost more than the round trips this file replaces.
PROJECTION_PROGRAM = <<~PYTHON
  import hashlib, importlib.util, json, pathlib, sys

  root = pathlib.Path(sys.argv[1])
  spec = importlib.util.spec_from_file_location(
      "acquisition_configarr", root / "filter_plugins" / "acquisition_configarr.py"
  )
  module = importlib.util.module_from_spec(spec)
  spec.loader.exec_module(module)

  payloads = json.load(sys.stdin)
  digests = {}
  for label, results in payloads.items():
      try:
          projection = module.acquisition_configarr_owned_projection(results)
      except Exception as caught:
          # A refusal is detection too: an absent owned resource must not project
          # as though nothing had changed.
          digests[label] = "refused:" + type(caught).__name__
          continue
      digests[label] = hashlib.sha256(
          json.dumps(projection, sort_keys=True).encode("utf-8")
      ).hexdigest()
  json.dump(digests, sys.stdout)
PYTHON

def project(payloads)
  output, errors, status = Open3.capture3(
    ansible_python, "-c", PROJECTION_PROGRAM, ROOT, stdin_data: JSON.generate(payloads)
  )
  abort "projection probe failed: #{errors}" unless status.success?
  JSON.parse(output)
end

def collect_failures(mutations)
  failures = []
  baseline = { "configarr" => deep_copy(CONFIGARR) }
  payloads = { "__baseline__" => configarr_api_results(baseline) }
  mutations.each do |label, mutate|
    state = deep_copy(baseline)
    mutate.call(state)
    payloads[label] = configarr_api_results(state)
  end

  digests = project(payloads)
  reference = digests.fetch("__baseline__")
  failures << "the baseline projection refused its own fixture: #{reference}" if
    reference.start_with?("refused:")

  mutations.each_key do |label|
    failures << "owned field #{label} is invisible to the projection" if
      digests.fetch(label) == reference
  end
  failures
end

mutations = configarr_owned_field_mutations
abort "the Configarr mutation table is empty" if mutations.empty?

if ARGV.include?("--self-test")
  # Plant the regression this check exists to catch: a field that the projection
  # drops, so breaking it looks identical to leaving it alone.
  planted = mutations.merge(
    "planted.invisible field" => lambda do |state|
      state.dig("configarr", "radarr", "qualityprofile").first["unprojectedField"] = "drifted"
    end
  )
  planted_failures = collect_failures(planted)
  unless planted_failures.any? { |failure| failure.include?("planted.invisible field") }
    abort "self-test failed: an invisible owned field was accepted"
  end
  puts "acquisition Configarr field coverage: self-test detects an invisible field"
  exit
end

failures = collect_failures(mutations)
abort failures.join("\n") unless failures.empty?
puts "acquisition Configarr field coverage: all #{mutations.length} owned fields reach their projection"
