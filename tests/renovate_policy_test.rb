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
ALPINE_PACKAGE_DATASOURCE = "custom.alpine-3.24-main"
ALPINE_PACKAGE_NAMES = Set.new(%w[ruby curl]).freeze

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

# Every pinned version in the integration harness must be tracked by a custom
# manager. Without this, a pin silently stops being bumped: nothing fails until
# the pinned value leaves its upstream index, and then every suite fails at
# sandbox setup on a change that has nothing to do with it. The pins are found
# by shape rather than by name so a newly added one is covered too, and the
# managers' own matchStrings are the oracle for whether it is tracked.
HARNESS_PATH = File.join(ROOT, "tests", "integration.sh")
PIN_ASSIGNMENT = /^[a-z_]+='?[^']*\d+\.\d+/.freeze

harness_lines = File.readlines(HARNESS_PATH).map(&:chomp).grep(PIN_ASSIGNMENT)
check(failures, !harness_lines.empty?,
      "the pinned-assignment detector matched nothing in tests/integration.sh")

harness_managers = Array(config["customManagers"]).select do |manager|
  Array(manager["managerFilePatterns"]).any? do |pattern|
    body = pattern.sub(%r{\A/}, "").sub(%r{/\z}, "")
    Regexp.new(body).match?("tests/integration.sh")
  end
end
harness_match_strings = harness_managers.flat_map { |manager| Array(manager["matchStrings"]) }
                                        .map { |source| Regexp.new(source) }

harness_lines.each do |line|
  check(failures, harness_match_strings.any? { |pattern| pattern.match?(line) },
        "no Renovate custom manager tracks the pin #{line.inspect}")
end

# Alpine package pins must be resolved from the release branch that supplies
# the runner image. Repology can lag a new Alpine release and report no-result
# even while the packages are present in Alpine's own repositories.
alpine_datasource = config.dig("customDatasources", "alpine-3.24-main")
check(failures,
      alpine_datasource == {
        "defaultRegistryUrlTemplate" =>
          "https://raw.githubusercontent.com/alpinelinux/aports/3.24-stable/main/{{packageName}}/APKBUILD",
        "format" => "plain"
      },
      "Alpine pins must use the official 3.24-stable APKBUILD datasource")

alpine_managers = Array(config["customManagers"]).select do |manager|
  manager["datasourceTemplate"] == ALPINE_PACKAGE_DATASOURCE
end
check(failures, Set.new(alpine_managers.map { |manager| manager["depNameTemplate"] }) ==
                ALPINE_PACKAGE_NAMES,
      "Renovate must track ruby and curl through the Alpine 3.24 datasource")
check(failures, alpine_managers.all? { |manager| manager["extractVersionTemplate"] ==
                                               "^pkgver=(?<version>.+)$" },
      "Alpine managers must extract pkgver from APKBUILD")
check(failures, Array(config["customManagers"]).none? do |manager|
  manager["datasourceTemplate"] == "repology" &&
    manager["depNameTemplate"].to_s.start_with?("alpine_3_24/")
end, "Alpine 3.24 pins must not depend on Repology coverage")

if failures.empty?
  puts "renovate policy: all checks passed"
else
  failures.each { |failure| warn "FAIL #{failure}" }
  abort "#{failures.length} Renovate policy regression(s)"
end
