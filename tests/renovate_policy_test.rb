#!/usr/bin/env ruby

require "json"
require "set"

ROOT = File.expand_path("..", __dir__)
ELIGIBLE_UPDATE_TYPES = Set.new(%w[
  minor
  patch
  pin
  pinDigest
  digest
  lockFileMaintenance
]).freeze
IMMICH_PACKAGES = Set.new(%w[
  ghcr.io/immich-app/immich-server
  ghcr.io/immich-app/immich-machine-learning
]).freeze

failures = []

def check(failures, condition, message)
  failures << message unless condition
end

config = JSON.parse(File.read(File.join(ROOT, "renovate.json")))
rules = config.fetch("packageRules")

check(failures, config["automerge"] == false,
      "Renovate automerge must remain disabled by default")
check(failures, config["automergeType"] == "pr",
      "Renovate automerge must create pull requests")
check(failures, config["platformAutomerge"] == true,
      "Renovate must use GitHub-native automerge")
check(failures, config["automergeStrategy"] == "rebase",
      "Renovate automerge must use the rebase strategy")
check(failures, config["rebaseWhen"] == "behind-base-branch",
      "Renovate must rebase branches that fall behind the protected base")

eligible_rules = rules.select do |rule|
  rule["description"] == "Automerge routine non-major updates after required checks pass."
end
check(failures, eligible_rules.length == 1,
      "Renovate must define exactly one routine automerge rule")

eligible_rule = eligible_rules.first
if eligible_rule
  check(failures, eligible_rule["automerge"] == true,
        "The routine update rule must enable automerge")
  check(failures, Set.new(Array(eligible_rule["matchUpdateTypes"])) == ELIGIBLE_UPDATE_TYPES,
        "The routine automerge rule must match only the approved update types")
end

immich_rule = rules.find do |rule|
  Set.new(Array(rule["matchPackageNames"])) == IMMICH_PACKAGES &&
    Array(rule["addLabels"]).include?("needs-manual-coupling")
end
check(failures, !immich_rule.nil?,
      "The Immich manual-coupling rule must remain present")
check(failures, immich_rule && immich_rule["automerge"] == false,
      "The Immich manual-coupling rule must disable automerge")
check(failures, immich_rule && rules.index(immich_rule) > rules.index(eligible_rule),
      "The Immich override must follow the general automerge rule") if eligible_rule

if failures.empty?
  puts "renovate policy: all checks passed"
else
  failures.each { |failure| warn "FAIL #{failure}" }
  abort "#{failures.length} Renovate policy regression(s)"
end
