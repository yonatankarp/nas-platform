#!/usr/bin/env ruby
# frozen_string_literal: true

# The untagged idempotence-check lane is decomposed into shards, and this is what
# holds the decomposition together.
#
# CLAUDE.md records why a guard has to exist before the partition does: sharding
# is an unusually efficient way to manufacture the defect this repository keeps
# closing. Drop a tag from the split and nothing converges it, every shard passes,
# and the gate goes green *faster* than it did before. The static gate answered
# that with tests/gate_manifest_coverage_test.rb, which declares the manifest as
# literal lists and refuses any drift in either direction. This is the same shape
# for a different partition, with one difference that matters: the universe here
# is *derived* from site.yml rather than restated. A restated list would have to
# be edited when a service is added, and adding a service already touches 59
# files -- the sixtieth would be the one nobody edits, and its symptom would be
# silence.
#
# What is deliberately *not* asserted is exclusivity. The static shards refuse a
# check claimed twice because running it twice is waste; here a prerequisite has
# to repeat -- bindery reads the arr APIs, seerr reads arr and jellyfin -- so the
# same tag legitimately converges in several shards. Duplication costs time,
# omission costs coverage, and only one of those is silent.
#
# Run alone:  ruby tests/idempotence_shard_partition_test.rb
# Self-test:  ruby tests/idempotence_shard_partition_test.rb --self-test

require "yaml"

REPO_ROOT = File.expand_path("..", __dir__)
SITE_PATH = File.join(REPO_ROOT, "site.yml")
SUITES_PATH = File.join(REPO_ROOT, "tests/ci/suites.conf")

# Tags every shard converges because every service role needs them, plus the ones
# a shard never has to name. `preflight` carries `always`, so it runs under any
# --tags whatsoever and belongs to no shard; the shared prerequisites are named
# because they are the shards' floor rather than their content.
ALWAYS_TAGS = %w[always preflight].freeze
SHARED_PREREQUISITE_TAGS = %w[host_prep deployment_bundle ntfy].freeze
# A stated number, for the reason tests/gate_manifest_coverage_test.rb states one:
# a partition that should hold five shards and holds one satisfies every
# non-emptiness test there is.
EXPECTED_SHARD_COUNT = 6

def site_tag_universe(site_source)
  play = YAML.safe_load(site_source, aliases: true).first
  tags = []
  # A role's own tag is the first one it declares; the rest are aliases naming a
  # group (media, monitoring, documents, media_acquisition_phase2) that a shard
  # has no reason to converge by name.
  play.fetch("roles").each do |entry|
    declared = Array(entry["tags"])
    next if (declared & ALWAYS_TAGS).any?

    tags << declared.first
  end
  # post_tasks are the half a roles-only sweep misses, and deployment_summary is
  # the only one: it is tagged rather than `always`, so an untagged run reaches it
  # and a sharded run reaches it only if some shard names it.
  Array(play["post_tasks"]).each do |task|
    declared = Array(task["tags"])
    next if (declared & ALWAYS_TAGS).any?

    tags.concat(declared)
  end
  tags.compact.uniq
end

def shard_rows(suites_source)
  suites_source.lines.filter_map do |line|
    fields = line.sub(/#.*/, "").split
    next if fields.length != 3

    suite, _kind, tags = fields
    next unless suite.start_with?("idempotence-") && suite != "idempotence-check"

    [suite, tags == "-" ? [] : tags.split(",")]
  end
end

def failures(site_source, suites_source)
  found = []
  universe = site_tag_universe(site_source)
  shards = shard_rows(suites_source)

  if shards.length != EXPECTED_SHARD_COUNT
    found << "expected #{EXPECTED_SHARD_COUNT} idempotence shards in " \
             "tests/ci/suites.conf, found #{shards.length}"
  end

  covered = shards.flat_map(&:last).uniq
  (universe - covered).sort.each do |tag|
    found << "site.yml converges #{tag} and no idempotence shard does: a sharded " \
             "run would skip it silently and finish sooner for it"
  end
  (covered - universe).sort.each do |tag|
    found << "idempotence shards converge #{tag}, which names no role or " \
             "post_task in site.yml"
  end

  shards.each do |suite, tags|
    missing = SHARED_PREREQUISITE_TAGS - tags
    next if missing.empty?

    found << "shard #{suite} omits #{missing.join(', ')}: every service role " \
             "needs them, so the shard would fail rather than run"
  end
  found
end

def report(found)
  if found.empty?
    puts "idempotence shard partition: every site.yml tag is converged by a shard"
    return 0
  end
  found.each { |failure| warn "idempotence shard partition: #{failure}" }
  1
end

site_source = File.read(SITE_PATH)
suites_source = File.read(SUITES_PATH)

if ARGV.include?("--self-test")
  # Each row plants a defect the checker must catch. The first is the one the
  # whole file exists for -- a shard silently losing a tag -- and it is planted by
  # deleting a tag from a shard rather than by editing the universe, because that
  # is the direction a rebalance actually goes wrong in.
  # Anchored to the shard rows by name. The first three plants were written as
  # bare substring edits -- ",immich\n", ",komga\n", "ntfy,beszel" -- and every
  # one of them landed on the *service* row of the same name, which appears
  # earlier in the file, so `sub` mangled a row this checker does not read and the
  # self-test reported three defects undetected. That is the failure this
  # repository calls a vacuous pass, caught here only because the self-test ran
  # before the checker was trusted.
  edit_shard = lambda do |source, suite, &change|
    source.sub(/^(#{Regexp.escape(suite)}\s+untagged\s+)(\S+)$/) do
      "#{Regexp.last_match(1)}#{change.call(Regexp.last_match(2))}"
    end
  end
  plants = [
    ["a shard drops a tag", lambda {
      [site_source,
       edit_shard.call(suites_source, "idempotence-3") { |t| t.sub(",nextcloud", "") }]
    }],
    ["a shard names a tag site.yml does not", lambda {
      [site_source,
       edit_shard.call(suites_source, "idempotence-2") { |t| "#{t},nosuchrole" }]
    }],
    ["a shard omits a shared prerequisite", lambda {
      [site_source,
       edit_shard.call(suites_source, "idempotence-5") { |t| t.sub("ntfy,", "") }]
    }],
    ["a shard is deleted outright", lambda {
      [site_source,
       suites_source.sub(/^idempotence-5 .*\n/, "")]
    }],
    ["a new role reaches no shard", lambda {
      [site_source.sub("  post_tasks:",
                       "    - role: newservice\n      tags: [newservice, media]\n\n  post_tasks:"),
       suites_source]
    }]
  ]
  undetected = plants.reject do |_name, plant|
    planted_site, planted_suites = plant.call
    !failures(planted_site, planted_suites).empty?
  end
  if undetected.empty?
    puts "idempotence shard partition self-test: #{plants.length} planted defects, all detected"
    exit 0
  end
  undetected.each { |name, _| warn "idempotence shard partition self-test: UNDETECTED: #{name}" }
  exit 1
end

exit report(failures(site_source, suites_source))
