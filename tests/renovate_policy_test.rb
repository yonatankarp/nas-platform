#!/usr/bin/env ruby

require "json"
require "set"

require_relative "policy_support"

include TestScaffold

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

# #511: an application image whose container migrates its own store when it
# starts is not a freely reversible pin. Bindery v1.34.0 migrated its SQLite
# store to schema_migrations 81, the host went back to a release pinning
# v1.33.3, and v1.33.3 refused to open it -- correctly, and inside the
# container, where the only symptom was exit 1 every minute for three days.
# The bump that got there was an application MINOR, which the routine rule
# automerges; the existing manual set gated database MAJORS, which is a
# different hazard.
#
# Stated as a property over the services rather than rule by rule, and that is
# the point: Immich is withheld by `automerge: false` on its own coupling rule
# and the other three by `dependencyDashboardApproval`, so an assertion written
# against either mechanism would pass while the other silently reopened. What
# has to hold is that no automerging update type reaches any of them.
#
# The key is the image and the value is the services/ directory that pins it,
# because a list of package names is exactly the kind of subject that goes
# stale invisibly: #501 removed Seafile, which was in this set and had a
# Renovate carve-out of its own. A name that no longer appears as an `image:`
# in the tree is a rule guarding nothing.
SELF_MIGRATING_APPLICATION_IMAGES = {
  "ghcr.io/vavallee/bindery" => "bindery",
  "ghcr.io/immich-app/immich-server" => "immich",
  "ghcr.io/paperless-ngx/paperless-ngx" => "paperless-ngx",
  "docker.io/library/nextcloud" => "nextcloud"
}.freeze
# A stated count, not non-emptiness: a set that quietly became empty satisfies
# every loop below and reports a pass. Four is what the tree documents --
# roles/bindery/tasks/pre_upgrade_backup.yml, services/immich/compose.yml,
# services/paperless-ngx/compose.yml and services/nextcloud/compose.yml each
# say their application migrates its own store on start.
check(failures, SELF_MIGRATING_APPLICATION_IMAGES.length == 4,
      "the self-migrating application set must name four images, not " \
      "#{SELF_MIGRATING_APPLICATION_IMAGES.length}")

SELF_MIGRATING_APPLICATION_IMAGES.each do |package, directory|
  compose_path = File.join(ROOT, "services", directory, "compose.yml")
  pinned = File.file?(compose_path) ? File.read(compose_path) : ""
  check(failures, pinned.include?("image: #{package}:"),
        "#{package} is withheld from automerge but services/#{directory}/compose.yml " \
        "pins no such image; a rule naming an image the tree no longer has guards nothing")
end

# The resolver below reads matchPackageNames, matchUpdateTypes, matchDatasources
# and matchCategories and ignores matchFileNames, which is sound only while no
# rule narrows by file without also naming its packages. Asserted rather than
# assumed, because a rule that did would apply here when Renovate would not.
check(failures, rules.none? do |rule|
  rule.key?("matchFileNames") && Array(rule["matchPackageNames"]).empty?
end, "a Renovate rule narrows by file name without naming its packages; the " \
     "automerge resolver in this test would over-apply it")

def rule_reaches?(rule, package, update_type)
  names = Array(rule["matchPackageNames"])
  return false unless names.empty? || names.include?(package)

  types = Array(rule["matchUpdateTypes"])
  return false unless types.empty? || types.include?(update_type)

  datasources = Array(rule["matchDatasources"])
  return false unless datasources.empty? || datasources.include?("docker")

  categories = Array(rule["matchCategories"])
  categories.empty? || categories.include?("docker")
end

# Later rules win, which is Renovate's own resolution order.
#
# `key?` rather than a truthiness filter, and the difference is not pedantic:
# `filter_map { rule["automerge"] }` drops `false` along with `nil`, so the
# Immich rule -- which withholds every update type with `automerge: false` --
# resolved to the routine rule's `true` and this file reported that an Immich
# minor would automerge. Measured on the first run, not imagined.
def last_declared(rules, key)
  rules.select { |rule| rule.key?(key) }.map { |rule| rule[key] }.last
end

def automerge_verdict(config, rules, package, update_type)
  reaching = rules.select { |rule| rule_reaches?(rule, package, update_type) }
  automerge = last_declared(reaching, "automerge")
  automerge = config["automerge"] if automerge.nil?
  [automerge, last_declared(reaching, "dependencyDashboardApproval") == true]
end

# minor and patch only. pin, pinDigest and digest move no version, so they run
# no migration and are ordinary here -- which is the one automerged type this
# set deliberately keeps.
MIGRATING_UPDATE_TYPES = %w[major minor patch].freeze

MIGRATING_UPDATE_TYPES.each do |update_type|
  SELF_MIGRATING_APPLICATION_IMAGES.each_key do |package|
    automerge, approved = automerge_verdict(config, rules, package, update_type)
    check(failures, automerge == false || approved,
          "a #{update_type} bump of #{package} would automerge. That image migrates its own " \
          "store when it starts, so the bump is one-way: withhold it with " \
          "dependencyDashboardApproval, or with automerge false, or both")
  end
end

# The tripwire the loop above needs, and it is not decoration. Every assertion
# there is satisfied by a resolver that reports every package as withheld --
# a mistyped key, an inverted return, a rules list read as empty -- and such a
# resolver would report a pass on a configuration that automerges everything.
# Gotenberg converts documents and holds no store; its minor bumps do automerge,
# and this row fails if the resolver has stopped being able to say so.
open_automerge, open_approval = automerge_verdict(config, rules,
                                                  "docker.io/gotenberg/gotenberg", "minor")
check(failures, open_automerge == true && !open_approval,
      "the automerge resolver reports that a minor bump of docker.io/gotenberg/gotenberg is " \
      "withheld. It holds no migrating store and the routine rule automerges it, so the " \
      "resolver is answering the same way for every package and the assertions above prove nothing")

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

controller_requirements_path = File.join(ROOT, "controller-requirements.txt")
controller_lines = File.readlines(controller_requirements_path, chomp: true)
controller_requests_pins = controller_lines.filter_map do |line|
  line.match(/\Arequests==(?<version>\d+\.\d+\.\d+)\z/)&.[](:version)
end
integration_requests_pins = File.read(HARNESS_PATH)
                              .scan(/^requests_version=(\d+\.\d+\.\d+)$/)
                              .flatten

check(failures, controller_requests_pins.length == 1,
      "controller-requirements.txt must contain exactly one requests pin")
check(failures, integration_requests_pins.length == 1,
      "tests/integration.sh must contain exactly one requests_version pin")
check(failures,
      controller_requests_pins.first == integration_requests_pins.first,
      "controller and integration requests pins must match")

controller_managers = Array(config["customManagers"]).select do |manager|
  Array(manager["managerFilePatterns"]).any? do |pattern|
    body = pattern.sub(%r{\A/}, "").sub(%r{/\z}, "")
    Regexp.new(body).match?("controller-requirements.txt")
  end
end
controller_match_strings = controller_managers
                           .flat_map { |manager| Array(manager["matchStrings"]) }
                           .map { |source| Regexp.new(source) }
controller_lines.grep(/\A[A-Za-z0-9][A-Za-z0-9._-]*==\d+\.\d+\.\d+\z/).each do |line|
  check(failures, controller_match_strings.any? { |pattern| pattern.match?(line) },
        "no Renovate custom manager tracks the controller pin #{line.inspect}")
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

# A container image pinned outside a Compose file is a second copy of a pin
# Renovate cannot see: enabledManagers covers docker-compose plus the custom
# managers above, and none of them look at roles/**, inventory/**, config/** or
# tests/contracts/**. The Configarr digest hashed into the Arr reconciliation
# fingerprint drifted two releases behind the deployed image exactly that way,
# which silently disabled the reconcile a version bump exists to force. The
# Dozzle contract's disposable ntfy fixture drifted a release behind the same
# way, so CI pulled a second ntfy image on every dozzle leg for the sake of an
# image it picked because the platform had already pulled it. The Compose
# definition is the one pin; everything else reads the image out of it.
RESTATED_PIN_TREES = ["roles", "inventory", "config", "tests/contracts"].freeze
RESTATED_PIN_TEXT = /\.(ya?ml|j2|json|py|rb|sh|cfg|txt|md)\z/.freeze
IMAGE_PIN = %r{[a-z0-9][a-z0-9._/-]*:[\w][\w.-]*@sha256:[0-9a-f]{64}}.freeze

restated_pin_files = RESTATED_PIN_TREES.to_h do |tree|
  [tree, Dir[File.join(ROOT, tree, "**", "*")].sort.select do |path|
    File.file?(path) && path.match?(RESTATED_PIN_TEXT)
  end]
end

# The sweep below is a per-line negative assertion, so it is the shape that
# reports success loudest when it reads nothing at all -- and it is the only
# guard against a pin restated outside services/. Two floors, because the two
# ways it can go quiet fail differently. A tree that is renamed or emptied takes
# its whole contribution with it, which the presence check names by tree; the
# extension filter losing a common suffix thins every tree at once, which only a
# count over the total can see. Neither catches RESTATED_PIN_TEXT dropping just
# `.cfg` or `.txt`, and nothing cheap would: those extensions are a handful of
# files and a floor sized to notice them would fail on ordinary churn.
RESTATED_PIN_TREES.each do |tree|
  check_floor(failures, restated_pin_files.fetch(tree).length, 1,
              "the restated-pin sweep of #{tree}/ matched no file")
end
# 150 against today's 257 (roles 192, tests/contracts 56, inventory 7, config 2).
# Sized so that losing any tree but roles/ still clears it -- those are removals
# a reviewer would see -- while roles/ collapsing, or the filter no longer
# recognising .yml or .j2, does not.
check_floor(failures, restated_pin_files.values.sum(&:length), 150,
            "the restated-pin sweep read too few files across #{RESTATED_PIN_TREES.join(', ')}")

restated_pin_files.each_value do |paths|
  paths.each do |path|
    relative = path.delete_prefix("#{ROOT}/")
    File.readlines(path, chomp: true).each_with_index do |line, index|
      pin = line[IMAGE_PIN]
      check(failures, pin.nil?,
            "#{relative}:#{index + 1} restates the pinned image #{pin.inspect}; " \
            "read it from the service's compose.yml, which Renovate does bump")
    end
  end
end

report(failures, "renovate policy: all checks passed", "Renovate policy regression(s)")
