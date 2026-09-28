#!/usr/bin/env ruby
# frozen_string_literal: true

# Every site.yml tag must be converged by some idempotence shard: a dropped tag makes
# the gate greener and faster. The universe is derived from site.yml, because a restated
# list is the one nobody edits. A tag in several shards is fine; omission is not.
#
# Run alone:  ruby tests/idempotence_shard_partition_test.rb
# Self-test:  ruby tests/idempotence_shard_partition_test.rb --self-test

require "yaml"

REPO_ROOT = File.expand_path("..", __dir__)
SITE_PATH = File.join(REPO_ROOT, "site.yml")
SUITES_PATH = File.join(REPO_ROOT, "tests/ci/suites.conf")

# `preflight` carries `always`, so it runs under any --tags and belongs to no shard.
ALWAYS_TAGS = %w[always preflight].freeze
SHARED_PREREQUISITE_TAGS = %w[host_prep deployment_bundle].freeze
# Stated, not derived: a partition collapsed into one shard passes every other test.
EXPECTED_SHARD_COUNT = 6

def site_tag_universe(site_source)
  play = YAML.safe_load(site_source, aliases: true).first
  tags = []
  # A role's own tag is its first; the rest are group aliases.
  play.fetch("roles").each do |entry|
    declared = Array(entry["tags"])
    next if (declared & ALWAYS_TAGS).any?

    tags << declared.first
  end
  # deployment_summary is a tagged post_task, reached by a sharded run only if named.
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
  # Plants are anchored to shard rows by name: bare substring edits landed on the
  # earlier service row of the same name and were silently undetected.
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
       edit_shard.call(suites_source, "idempotence-5") { |t| t.sub("deployment_bundle,", "") }]
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
