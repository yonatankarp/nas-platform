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
# auto, not behind-base-branch (#831): Renovate resolves auto per branch from its own
# automerge verdict, so held branches rebase only on conflict. Asserted per package below.
check(failures, config["rebaseWhen"] == "auto",
      "Renovate's rebaseWhen must be auto, which rebases an automerged branch that falls " \
      "behind the base and a held one only when it conflicts (#831)")

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

# Images whose container migrates its own store on start: a one-way pin (#511). Stated
# as a property over every withholding mechanism, not one rule. Keyed image => services/
# directory so a name no longer pinned anywhere fails rather than guarding nothing.
SELF_MIGRATING_APPLICATION_IMAGES = {
  "ghcr.io/immich-app/immich-server" => "immich",
  "ghcr.io/paperless-ngx/paperless-ngx" => "paperless-ngx",
  "docker.io/library/nextcloud" => "nextcloud",
  # #551: Karakeep migrates db.db; Meilisearch upgrades an index (with MEILI_UPGRADE_DB).
  "ghcr.io/karakeep-app/karakeep" => "karakeep",
  "docker.io/getmeili/meilisearch" => "karakeep",
  # #671: Kapowarr v1.3.2 migrated database version 45 to 51 on start.
  "docker.io/mrcas/kapowarr" => "kapowarr",
  # Jellyfin 12.0 "includes database changes that prevent rolling back".
  "docker.io/jellyfin/jellyfin" => "jellyfin"
}.freeze
# A stated count, so a set that quietly emptied cannot pass. Vaultwarden left (#547,
# reversible pin); Bindery left (#781, one-way but covered by the upgrade lane). Jellyfin
# stays: the upgrade lane cannot take it. Both departures are pinned below.
check(failures, SELF_MIGRATING_APPLICATION_IMAGES.length == 7,
      "the self-migrating application set must name seven images, not " \
      "#{SELF_MIGRATING_APPLICATION_IMAGES.length}")

SELF_MIGRATING_APPLICATION_IMAGES.each do |package, directory|
  compose_path = File.join(ROOT, "services", directory, "compose.yml")
  pinned = File.file?(compose_path) ? File.read(compose_path) : ""
  check(failures, pinned.include?("image: #{package}:"),
        "#{package} is withheld from automerge but services/#{directory}/compose.yml " \
        "pins no such image; a rule naming an image the tree no longer has guards nothing")
end

# Without MEILI_UPGRADE_DB Meilisearch crash-loops on an older index (#511's mode).
karakeep_compose_path = File.join(ROOT, "services", "karakeep", "compose.yml")
karakeep_compose = File.file?(karakeep_compose_path) ? File.read(karakeep_compose_path) : ""
meilisearch_service = karakeep_compose[/^  meilisearch:\n(.*?)(?=^  \S|^\S)/m, 1].to_s
check(failures, meilisearch_service.match?(/^      MEILI_UPGRADE_DB: "true"$/),
      "services/karakeep/compose.yml must set MEILI_UPGRADE_DB: \"true\" on the meilisearch " \
      "service: without it a Meilisearch version bump crash-loops on the existing index")

# The resolver ignores matchFileNames, sound only while no rule narrows by file alone.
check(failures, rules.none? do |rule|
  rule.key?("matchFileNames") && Array(rule["matchPackageNames"]).empty?
end, "a Renovate rule narrows by file name without naming its packages; the " \
     "automerge resolver in this test would over-apply it")

def rule_reaches?(rule, package, update_type, datasource = "docker")
  names = Array(rule["matchPackageNames"])
  return false unless names.empty? || names.include?(package)

  types = Array(rule["matchUpdateTypes"])
  return false unless types.empty? || types.include?(update_type)

  datasources = Array(rule["matchDatasources"])
  return false unless datasources.empty? || datasources.include?(datasource)

  categories = Array(rule["matchCategories"])
  categories.empty? || (datasource == "docker" && categories.include?("docker"))
end

# Later rules win, as in Renovate. `key?`, not truthiness: filter_map drops `false`,
# which once made Immich's `automerge: false` read as true.
def last_declared(rules, key)
  rules.select { |rule| rule.key?(key) }.map { |rule| rule[key] }.last
end

def automerge_verdict(config, rules, package, update_type, datasource = "docker")
  reaching = rules.select { |rule| rule_reaches?(rule, package, update_type, datasource) }
  automerge = last_declared(reaching, "automerge")
  automerge = config["automerge"] if automerge.nil?
  [automerge, last_declared(reaching, "dependencyDashboardApproval") == true]
end

# pin, pinDigest and digest move no version, so they stay automerged.
MIGRATING_UPDATE_TYPES = %w[major minor patch].freeze

# Every dependency must reach a pull request: dependencyDashboardApproval and
# `enabled: false` are banned; withhold with `automerge: false` instead. The `approved`
# term below stays only to report which mechanism withheld a package.
rules.each_with_index do |rule, index|
  subject = Array(rule["matchPackageNames"]).join(", ")
  subject = "<every package>" if subject.empty?
  check(failures, !rule.key?("dependencyDashboardApproval"),
        "packageRules[#{index}] (#{subject}) carries dependencyDashboardApproval, which suppresses " \
        "the pull request rather than the merge. Withhold the merge with automerge false instead: " \
        "an update nobody is shown is not deferred, it stops existing")
  check(failures, rule["enabled"] != false,
        "packageRules[#{index}] (#{subject}) is disabled outright, so this dependency can never be " \
        "proposed at all. Every dependency must reach a pull request; withhold the merge with " \
        "automerge false and label it needs-manual-coupling if it must not move on its own")
end

MIGRATING_UPDATE_TYPES.each do |update_type|
  SELF_MIGRATING_APPLICATION_IMAGES.each_key do |package|
    automerge, approved = automerge_verdict(config, rules, package, update_type)
    check(failures, automerge == false || approved,
          "a #{update_type} bump of #{package} would automerge. That image migrates its own " \
          "store when it starts, so the bump is one-way: withhold it with " \
          "dependencyDashboardApproval, or with automerge false, or both")
  end
end

# Tripwire: a resolver reporting everything withheld would pass the loop above.
# Gotenberg holds no store, so its minors must automerge.
open_automerge, open_approval = automerge_verdict(config, rules,
                                                  "docker.io/gotenberg/gotenberg", "minor")
check(failures, open_automerge == true && !open_approval,
      "the automerge resolver reports that a minor bump of docker.io/gotenberg/gotenberg is " \
      "withheld. It holds no migrating store and the routine rule automerges it, so the " \
      "resolver is answering the same way for every package and the assertions above prove nothing")

# Vaultwarden: majors held, minors/patches automerge. Both halves, so neither drifts.
{ "major" => false, "minor" => true, "patch" => true }.each do |update_type, expected|
  automerge, approved = automerge_verdict(config, rules, "docker.io/vaultwarden/server", update_type)
  check(failures, (automerge == true && !approved) == expected,
        "a #{update_type} bump of docker.io/vaultwarden/server should " \
        "#{expected ? 'automerge' : 'wait for a human'}; see services/vaultwarden/compose.yml")
end

# Bindery (#781): the same shape, because the upgrade lane gates minors and patches.
{ "major" => false, "minor" => true, "patch" => true }.each do |update_type, expected|
  automerge, approved = automerge_verdict(config, rules, "ghcr.io/vavallee/bindery", update_type)
  check(failures, (automerge == true && !approved) == expected,
        "a #{update_type} bump of ghcr.io/vavallee/bindery should " \
        "#{expected ? 'automerge' : 'wait for a human'}; the upgrade lane covers #511's mode " \
        "on the pull request, and a major still waits for a human")
end

# #607: the Beszel agent is root-equivalent, and a re-pushed tag arrives as a digest, so
# no update type may automerge. Hub and portable agent share its branch and are held too.
HOST_ROOT_EQUIVALENT_IMAGE_GROUP = %w[
  ghcr.io/henrygd/beszel/beszel
  ghcr.io/henrygd/beszel/beszel-agent
  ghcr.io/henrygd/beszel/beszel-agent-intel
].freeze
EVERY_UPDATE_TYPE = %w[major minor patch pin pinDigest digest lockFileMaintenance].freeze
check(failures, HOST_ROOT_EQUIVALENT_IMAGE_GROUP.length == 3,
      "the host-root-equivalent Beszel image group must name three images, not " \
      "#{HOST_ROOT_EQUIVALENT_IMAGE_GROUP.length}")
beszel_compose_path = File.join(ROOT, "services", "beszel", "compose.yml")
beszel_compose = File.file?(beszel_compose_path) ? File.read(beszel_compose_path) : ""
HOST_ROOT_EQUIVALENT_IMAGE_GROUP.each do |package|
  check(failures, beszel_compose.include?("image: #{package}:"),
        "#{package} is withheld from automerge but services/beszel/compose.yml pins no such " \
        "image; a rule naming an image the tree no longer has guards nothing")
end
check(failures, rules.any? do |rule|
  rule["groupName"] == "beszel" &&
    Set.new(Array(rule["matchPackageNames"])) == Set.new(HOST_ROOT_EQUIVALENT_IMAGE_GROUP)
end, "the Beszel hub and both agents must stay one Renovate group, so a withheld agent " \
     "cannot be left behind a hub that moved on its own")
EVERY_UPDATE_TYPE.each do |update_type|
  HOST_ROOT_EQUIVALENT_IMAGE_GROUP.each do |package|
    automerge, approved = automerge_verdict(config, rules, package, update_type)
    check(failures, automerge == false || approved,
          "a #{update_type} update of #{package} would automerge. The Beszel Intel agent runs " \
          "with CAP_SYS_RAWIO and CAP_SYS_ADMIN, and a re-pushed tag arrives as a digest, so no " \
          "update to its release group may merge without a human")
  end
end
digest_automerge, digest_approval = automerge_verdict(config, rules,
                                                      "docker.io/gotenberg/gotenberg", "digest")
check(failures, digest_automerge == true && !digest_approval,
      "the automerge resolver reports that a digest refresh of docker.io/gotenberg/gotenberg is " \
      "withheld. The routine rule automerges it, so the Beszel digest assertions above prove nothing")

# #828: a Docker-socket mount is root on the host (`:ro` restricts nothing at the API).
# Derived from services/*/compose*.yml, with a stated set closed both ways as the floor.
DOCKER_SOCKET_IMAGES = %w[lscr.io/linuxserver/socket-proxy].to_set.freeze

def compose_image_repository(image)
  image.to_s.sub(/@.*\z/, "").sub(%r{:[^/:]*\z}, "")
end

# ponytail: literal paths only. A ${VAR} source or a parent-directory mount
# (/var/run, /run) also exposes the socket and is not seen; none exists today.
def docker_socket_source?(volume)
  source = volume.is_a?(Hash) ? volume["source"] : volume.to_s.split(":").first
  source.to_s.match?(%r{\A(/var)?/run/docker\.sock\z})
end

derived_docker_socket_images = Set.new
Dir.glob(File.join(ROOT, "services", "*", "compose.yml")).sort.each do |canonical_path|
  canonical = YAML.safe_load_file(canonical_path, aliases: true) || {}
  canonical_services = canonical.fetch("services", nil) || {}
  Dir.glob(File.join(File.dirname(canonical_path), "compose*.yml")).sort.each do |path|
    document = YAML.safe_load_file(path, aliases: true) || {}
    (document.fetch("services", nil) || {}).each do |name, service|
      next unless Array(service && service["volumes"]).any? { |volume| docker_socket_source?(volume) }

      image = (service["image"] || canonical_services.dig(name, "image")).to_s
      check(failures, !image.empty?,
            "#{path.delete_prefix("#{ROOT}/")} mounts the Docker socket on #{name}, which has no image")
      derived_docker_socket_images << compose_image_repository(image) unless image.empty?
    end
  end
end
check(failures, derived_docker_socket_images == DOCKER_SOCKET_IMAGES,
      "the images mounting the Docker socket must be exactly the stated set. Missing: " \
      "#{(DOCKER_SOCKET_IMAGES - derived_docker_socket_images).to_a.sort.inspect}; unexpected: " \
      "#{(derived_docker_socket_images - DOCKER_SOCKET_IMAGES).to_a.sort.inspect}. A new " \
      "socket-holding image must be withheld from automerge and stated here")
EVERY_UPDATE_TYPE.each do |update_type|
  (DOCKER_SOCKET_IMAGES | derived_docker_socket_images).each do |package|
    automerge, approved = automerge_verdict(config, rules, package, update_type)
    check(failures, automerge == false || approved,
          "a #{update_type} update of #{package} would automerge. It mounts the Docker socket, " \
          "which is root on the host, and a re-pushed tag arrives as a digest, so no update to " \
          "it may merge without a human")
  end
end

# #831: automerged branches must stay behind-base-branch, held ones conflicted, per the
# automerge verdict. auto is resolved as Renovate 44's determineRebaseWhenValue, less
# keep-updated labels (refused below) and repository settings this file cannot see.
check(failures, !config.key?("keepUpdatedLabel") && rules.none? { |rule| rule.key?("keepUpdatedLabel") },
      "keepUpdatedLabel makes Renovate rebase a labelled held branch behind the base, which " \
      "undoes #831's rebaseWhen split for it")

def rebase_verdict(config, rules, package, update_type, datasource)
  reaching = rules.select { |rule| rule_reaches?(rule, package, update_type, datasource) }
  rebase = last_declared(reaching, "rebaseWhen") || config["rebaseWhen"] || "auto"
  return rebase unless rebase == "auto"

  automerge, = automerge_verdict(config, rules, package, update_type, datasource)
  automerge == true ? "behind-base-branch" : "conflicted"
end

rebase_subjects = Set.new
rules.each do |rule|
  datasource = Array(rule["matchDatasources"]).first || "docker"
  Array(rule["matchPackageNames"]).each do |name|
    rebase_subjects << [name.delete_prefix("!"), datasource]
  end
end
Dir.glob(File.join(ROOT, "services", "*", "compose*.yml")).sort.each do |path|
  document = YAML.safe_load_file(path, aliases: true) || {}
  (document.fetch("services", nil) || {}).each_value do |service|
    image = service && service["image"]
    rebase_subjects << [compose_image_repository(image), "docker"] if image
  end
end

rebase_verdicts = Hash.new(0)
rebase_subjects.each do |package, datasource|
  (ELIGIBLE_UPDATE_TYPES.to_a + ["major"]).each do |update_type|
    automerge, approved = automerge_verdict(config, rules, package, update_type, datasource)
    automerged = automerge == true && !approved
    expected = automerged ? "behind-base-branch" : "conflicted"
    actual = rebase_verdict(config, rules, package, update_type, datasource)
    rebase_verdicts[expected] += 1
    check(failures, actual == expected,
          "a #{update_type} update of #{package} (#{datasource}) is " \
          "#{automerged ? 'automerged' : 'held for a human'} but rebases #{actual}; " \
          "#{automerged ? 'an automerged branch must stay behind-base-branch so it never merges ' \
                          'untested against the current main' \
                        : 'a held branch must be conflicted so it stops re-running CI after ' \
                          'every merge (#831)'}")
  end
end
check_floor(failures, rebase_verdicts["conflicted"], 1, "the rebase check found no held update")
check_floor(failures, rebase_verdicts["behind-base-branch"], 1,
            "the rebase check found no automerged update")
[["ghcr.io/paperless-ngx/paperless-ngx", "docker", "minor", "conflicted"],
 ["yt-dlp/yt-dlp", "github-releases", "patch", "conflicted"],
 ["docker.io/gotenberg/gotenberg", "docker", "minor", "behind-base-branch"]].each do |package, datasource, type, want|
  check(failures, rebase_subjects.include?([package, datasource]) &&
                  rebase_verdict(config, rules, package, type, datasource) == want,
        "a #{type} update of #{package} must rebase #{want}; the rebase check's subjects or " \
        "resolver have stopped meaning what its assertions read them as")
end

# The batching group's safety lives in its exclusions, which must equal the union of the
# withheld sets (derived, not restated) with a floor on its reach. COUPLED_DATABASE_IMAGES
# is separate from IMMICH_PACKAGES, which is compared exactly against the coupling rule.
COUPLED_DATABASE_IMAGES = %w[ghcr.io/immich-app/postgres].freeze

GROUP_EXCLUDED_IMAGES = (SELF_MIGRATING_APPLICATION_IMAGES.keys +
                         IMMICH_PACKAGES.to_a +
                         COUPLED_DATABASE_IMAGES +
                         HOST_ROOT_EQUIVALENT_IMAGE_GROUP +
                         DOCKER_SOCKET_IMAGES.to_a).to_set.freeze
BATCHED_UPDATE_TYPES = Set.new(%w[minor patch digest pinDigest]).freeze

batching_rules = rules.select { |rule| rule["groupName"] == "container images" }
check(failures, batching_rules.length == 1,
      "Renovate must define exactly one batching group for routine container image updates")

batching_rule = batching_rules.first
if batching_rule
  # Last, so a held package can never join a shared branch with automerged ones.
  check(failures, rules.index(batching_rule) == rules.length - 1,
        "the batching group must be the last package rule, so no withholding rule can " \
        "follow it and leave a held image carrying its groupName")
  check(failures, Array(batching_rule["schedule"]).any?,
        "the batching group must carry a schedule; without one the branch automerges as soon " \
        "as it is green and the next arrival opens a fresh one, so no batch ever forms")
  check(failures, Set.new(Array(batching_rule["matchUpdateTypes"])) == BATCHED_UPDATE_TYPES,
        "the batching group must match minor, patch, digest and pinDigest: patch alone leaves " \
        "most of the traffic ungrouped, and major is withheld by the routine rule not matching it")
  check(failures, Array(batching_rule["matchDatasources"]) == ["docker"],
        "the batching group must be bound to the docker datasource: controller-requirements.txt, " \
        "requirements.yml and tests/integration.sh are unmapped paths that fall open to every " \
        "lane and all six idempotence shards, so batching one in costs more than the group saves")

  # All negations: renovate-config-validator refuses "*" beside other patterns (#775), but
  # accepts a single positive pattern, which would silently shrink the group to one image.
  names = Array(batching_rule["matchPackageNames"])
  check(failures, names.any? && names.all? { |name| name.start_with?("!") },
        "the batching group must be a list of negations and nothing else. It must narrow by " \
        "negation rather than name an allowlist, which would silently omit every service " \
        "added after it was written. A positive pattern that is not \"*\" passes " \
        "renovate-config-validator and narrows this group to that one image; a bare \"*\" is " \
        "the spelling the validator refuses outright, which stopped pull requests " \
        "repository-wide (#775)")
  excluded = names.filter_map { |name| name.delete_prefix("!") if name.start_with?("!") }
  check(failures, excluded.to_set == GROUP_EXCLUDED_IMAGES,
        "the batching group's exclusions must equal the withheld set exactly. Missing: " \
        "#{(GROUP_EXCLUDED_IMAGES - excluded.to_set).to_a.sort.inspect}; unexpected: " \
        "#{(excluded.to_set - GROUP_EXCLUDED_IMAGES).to_a.sort.inspect}. A withheld image that " \
        "is not excluded joins an automerged batch, which is #511 arriving faster than before")

  # Tripwire: a group reaching nothing would pass the checks above.
  check(failures, !excluded.include?("docker.io/gotenberg/gotenberg"),
        "docker.io/gotenberg/gotenberg is excluded from the batching group. It holds no " \
        "migrating store and is in no withheld set, so the exclusions have stopped meaning " \
        "what the assertions above read them as")
end

# Every harness pin must be tracked by a custom manager, found by shape; the managers'
# matchStrings are the oracle.
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

# The lock is owned by Renovate's pip-compile manager (#827). A regex manager over it
# must not return: it would bump a version without regenerating its hash.
controller_source_path = File.join(ROOT, "controller-requirements.in")
controller_lines = File.file?(controller_source_path) ? File.readlines(controller_source_path, chomp: true) : []
controller_requests_pins = controller_lines.filter_map do |line|
  line.match(/\Arequests==(?<version>\d+\.\d+\.\d+)\z/)&.[](:version)
end
integration_requests_pins = File.read(HARNESS_PATH)
                              .scan(/^requests_version=(\d+\.\d+\.\d+)$/)
                              .flatten

check(failures, controller_requests_pins.length == 1,
      "controller-requirements.in must contain exactly one requests pin")
check(failures, integration_requests_pins.length == 1,
      "tests/integration.sh must contain exactly one requests_version pin")
check(failures,
      controller_requests_pins.first == integration_requests_pins.first,
      "controller and integration requests pins must match")

def renovate_pattern_matches?(pattern, path)
  Regexp.new(pattern.sub(%r{\A/}, "").sub(%r{/\z}, "")).match?(path)
end

check(failures, Array(config["enabledManagers"]).include?("pip-compile"),
      "enabledManagers must include pip-compile, the manager that regenerates the controller lock")
check(failures,
      Array(config.dig("pip-compile", "managerFilePatterns")).any? do |pattern|
        renovate_pattern_matches?(pattern, "controller-requirements.txt")
      end,
      "the pip-compile manager must target the lock, controller-requirements.txt, whose header " \
      "names the source it is compiled from")
%w[controller-requirements.txt controller-requirements.in].each do |path|
  check(failures,
        Array(config["customManagers"]).none? do |manager|
          Array(manager["managerFilePatterns"]).any? { |pattern| renovate_pattern_matches?(pattern, path) }
        end,
        "no custom manager may track #{path}: a regex bump there rewrites a version without " \
        "regenerating the lock's hashes")
end
check(failures, config.dig("lockFileMaintenance", "enabled") == true,
      "lockFileMaintenance must be enabled, or the controller lock's transitive pins never move")

# The lint job's validator pin must be tracked, both directions.
WORKFLOW_PATH = File.join(ROOT, ".github", "workflows", "ci.yml")
workflow_source = File.read(WORKFLOW_PATH)
validator_pins = workflow_source.scan(/^\s*renovate_pin=renovate@\d+\.\d+\.\d+$/).map(&:strip)
check(failures, validator_pins.length == 1,
      "the lint job must carry exactly one renovate-config-validator pin, found " \
      "#{validator_pins.inspect}")

workflow_managers = Array(config["customManagers"]).select do |manager|
  Array(manager["managerFilePatterns"]).any? do |pattern|
    body = pattern.sub(%r{\A/}, "").sub(%r{/\z}, "")
    Regexp.new(body).match?(".github/workflows/ci.yml")
  end
end
workflow_match_strings = workflow_managers
                         .flat_map { |manager| Array(manager["matchStrings"]) }
                         .map { |source| Regexp.new(source) }
check(failures, workflow_match_strings.any?,
      "no Renovate custom manager reads .github/workflows/ci.yml, so the " \
      "renovate-config-validator pin the lint job runs is tracked by nothing")
validator_pins.each do |line|
  check(failures, workflow_match_strings.any? { |pattern| pattern.match?(line) },
        "no Renovate custom manager tracks the workflow pin #{line.inspect}")
end
check(failures, workflow_managers.all? { |manager| manager["datasourceTemplate"] == "npm" },
      "the workflow pin must resolve against npm, which is where renovate ships")

# Alpine pins resolve from the runner's release branch; Repology can lag.
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

# An image pinned outside Compose is invisible to Renovate and drifts (the Configarr
# fingerprint did). The Compose definition is the one pin.
RESTATED_PIN_TREES = ["roles", "inventory", "config", "tests/contracts"].freeze
RESTATED_PIN_TEXT = /\.(ya?ml|j2|json|py|rb|sh|cfg|txt|md)\z/.freeze
IMAGE_PIN = %r{[a-z0-9][a-z0-9._/-]*:[\w][\w.-]*@sha256:[0-9a-f]{64}}.freeze

restated_pin_files = RESTATED_PIN_TREES.to_h do |tree|
  [tree, Dir[File.join(ROOT, tree, "**", "*")].sort.select do |path|
    File.file?(path) && path.match?(RESTATED_PIN_TEXT)
  end]
end

# Two floors for this negative sweep: per tree (rename/empty) and total (lost suffix).
RESTATED_PIN_TREES.each do |tree|
  check_floor(failures, restated_pin_files.fetch(tree).length, 1,
              "the restated-pin sweep of #{tree}/ matched no file")
end
# Sized so losing roles/ or .yml/.j2 recognition fails, smaller trees do not.
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

# #826: every self-migrating image needs an image_downgrade_guard call on its Compose
# service, derived from the call sites and closed both ways. Exceptions:
DOWNGRADE_GUARD_EXCEPTIONS = {
  # One-way pin; the upgrade lane proves its bumps (#781).
  "ghcr.io/vavallee/bindery" => "bindery",
  # Reversible (#547), but its call site also carries a CVE floor.
  "docker.io/vaultwarden/server" => "vaultwarden"
}.freeze
# Stated floor, so a walk that matched nothing fails.
EXPECTED_DOWNGRADE_GUARD_CALLS = [
  %w[bindery bindery], %w[immich immich-server], %w[jellyfin jellyfin],
  %w[kapowarr kapowarr], %w[karakeep karakeep], %w[karakeep meilisearch],
  %w[nextcloud nextcloud], %w[paperless-ngx webserver], %w[vaultwarden vaultwarden]
].freeze

def downgrade_guard_calls(node, found = [])
  case node
  when Array then node.each { |child| downgrade_guard_calls(child, found) }
  when Hash
    include_role = node.find do |key, _|
      %w[include_role import_role ansible.builtin.include_role
         ansible.builtin.import_role].include?(key)
    end&.last
    if include_role.is_a?(Hash) && include_role["name"] == "image_downgrade_guard"
      found << node.fetch("vars", {})
    end
    %w[block rescue always].each { |key| downgrade_guard_calls(node[key], found) }
  end
  found
end

guard_calls = Dir.glob(File.join(ROOT, "roles", "*", "tasks", "*.yml")).sort.flat_map do |path|
  next [] if path.include?("/roles/image_downgrade_guard/")

  downgrade_guard_calls(YAML.safe_load_file(path, aliases: true)).map do |vars|
    [vars["image_downgrade_guard_service_name"].to_s,
     vars["image_downgrade_guard_compose_service"].to_s,
     path.delete_prefix("#{ROOT}/")]
  end
end
check(failures, guard_calls.map { |call| call.first(2) }.sort == EXPECTED_DOWNGRADE_GUARD_CALLS.sort,
      "the image_downgrade_guard call sites must be #{EXPECTED_DOWNGRADE_GUARD_CALLS.inspect}, " \
      "found #{guard_calls.map { |call| call.first(2) }.sort.inspect}")

guarded_images = guard_calls.to_h do |directory, service, relative|
  compose_path = File.join(ROOT, "services", directory, "compose.yml")
  compose = File.file?(compose_path) ? YAML.safe_load_file(compose_path, aliases: true) : {}
  image = compose.dig("services", service, "image")
  check(failures, !image.nil? && !directory.include?("{{") && !service.include?("{{"),
        "#{relative} guards #{directory}/#{service}, which names no image in " \
        "services/#{directory}/compose.yml; a guard on a service with no pin guards nothing")
  [compose_image_repository(image), directory]
end

SELF_MIGRATING_APPLICATION_IMAGES.each do |package, directory|
  check(failures, guarded_images[package] == directory,
        "#{package} migrates its own store on start but no role calls " \
        "roles/image_downgrade_guard on the Compose service in services/#{directory} " \
        "that runs it, so a reverted pin reaches the host unrefused (#511, #826)")
end
guarded_images.each do |package, directory|
  expected = SELF_MIGRATING_APPLICATION_IMAGES.merge(DOWNGRADE_GUARD_EXCEPTIONS)[package]
  check(failures, expected == directory,
        "roles/image_downgrade_guard guards #{package} in services/#{directory}, which is " \
        "neither in SELF_MIGRATING_APPLICATION_IMAGES nor a stated DOWNGRADE_GUARD_EXCEPTIONS entry")
end
DOWNGRADE_GUARD_EXCEPTIONS.each_key do |package|
  check(failures, !SELF_MIGRATING_APPLICATION_IMAGES.key?(package),
        "#{package} is both self-migrating and a downgrade guard exception; drop the exception")
end

report(failures, "renovate policy: all checks passed", "Renovate policy regression(s)")
