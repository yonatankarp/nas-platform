#!/usr/bin/env ruby

require "fileutils"
require "open3"
require "rbconfig"
require "stringio"
require "tmpdir"
require "yaml"

require_relative "../policy_support"

include TestScaffold

SCRIPT = File.expand_path("classify_changes.rb", __dir__)
# Every fixture repository names its initial branch: `git init` takes the caller's
# init.defaultBranch, which is `main` locally and `master` on the runner.
FIXTURE_BRANCH = "main"
LANES = %w[
  static docs vault reconciliation foundation arr downloaders bindery kapowarr pinchflat trailarr seerr
  beszel dozzle audiobookshelf komga jellyfin immich paperless nextcloud
  vaultwarden karakeep upgrade idempotence_check
  idempotence_1 idempotence_2 idempotence_3 idempotence_4 idempotence_5 idempotence_6
].freeze
# A fall-open takes the shards, `--full` the single idempotence pass, never both. Lists here are
# restated rather than imported, so the test cannot agree with the classifier by construction.
IDEMPOTENCE_LANE = "idempotence_check"
IDEMPOTENCE_SHARD_LANES = %w[
  idempotence_1 idempotence_2 idempotence_3 idempotence_4 idempotence_5 idempotence_6
].freeze
# The upgrade lane is off in both forms: neither has a BASE revision to give it.
UPGRADE_LANE = "upgrade"
FULL_LANES = (LANES - IDEMPOTENCE_SHARD_LANES - [UPGRADE_LANE]).freeze
FALL_OPEN_LANES = (LANES - [IDEMPOTENCE_LANE] - [UPGRADE_LANE]).freeze
ACQUISITION_LANES = %w[arr downloaders bindery kapowarr pinchflat trailarr seerr].freeze
# Stated rather than imported, so widening the classifier's scope fails here.
RECONCILIATION_LANES = %w[arr downloaders].freeze
# Stated for the same reason; COMPANION_LANES in classify_changes.rb gives each row's why (#349).
COMPANION_LANES = {
  "beszel" => %w[dozzle],
  "downloaders" => %w[bindery],
  "audiobookshelf" => %w[bindery],
  "jellyfin" => %w[seerr]
}.freeze
# Shared-foundation tags every tagged lane carries; they already fall open to every lane, so the
# cross-lane derivation below skips them.
SHARED_TAGS = %w[host_prep deployment_bundle].freeze
# Cross-lane dependencies in suites.conf deliberately not routed (#349): arr's own lane and the
# reconciliation job assert its state, and its readers use a stable API. A row naming a pair the
# suite table no longer shows fails below.
DECLINED_COMPANIONS = [
  %w[arr downloaders],
  %w[arr bindery],
  %w[arr trailarr],
  %w[arr seerr]
].freeze
RECONCILIATION_OWNED_PATHS = %w[
  tests/media_acquisition_reconciliation_support.rb
  tests/media_acquisition_reconciliation_core_test.rb
  tests/media_acquisition_reconciliation_bazarr_test.rb
  tests/media_acquisition_reconciliation_configarr_test.rb
].freeze
failures = []

if File.file?(SCRIPT)
  require_relative "classify_changes"
else
  failures << "classifier script is missing"
end

def selected_lanes(paths, full: false)
  ClassifyChanges.classify(paths, full: full).select { |_lane, selected| selected }.keys
end

# Selections come back in LANES order (seerr precedes jellyfin), so assembled expectations are sorted.
def canonical(lanes)
  lanes.uniq.sort_by { |lane| LANES.index(lane) }
end

if defined?(ClassifyChanges)
  {
    ["docs/getting-started.md"] => %w[static docs],
    ["docs/bazarr-providers.md"] => %w[static docs],
    ["docs/media-acquisition-phase1.md"] => %w[static docs],
    # #190: a document no check names is still read by the link gate's glob.
    ["docs/superpowers/plans/2026-08-09-docs-only-ci-fast-path.md"] => %w[docs],
    ["docs/no-check-reads-this.md"] => %w[docs],
    ["docs/img/topology.png"] => %w[docs],
    # Not inert: tests/policy_beszel_test.rb and tests/policy_ci_test.rb both
    # read it, so it reaches the job that runs them rather than no job at all.
    [".gitignore"] => %w[static],
    ["LICENSE"] => [],
    ["README.md"] => %w[static docs],
    # #346: policy_test reads CLAUDE.md in static and docs_links_test in both, so it
    # routes like README.md.
    ["CLAUDE.md"] => %w[static docs],
    # The evidence #838 moved out of CLAUDE.md keeps the route that text had there.
    ["docs/incident-history.md"] => %w[static docs],
    ["docs/host-cleanup.md"] => %w[static docs],
    ["docs/getting-started-nas.md"] => %w[static docs],
    # Only tests/secrets_docs_test.rb reads it, and the docs job runs that, so the
    # secrets guide no longer pays for the whole policy gate.
    ["docs/secrets.md"] => %w[docs],
    ["roles/paperless_ngx/tasks/main.yml"] => %w[static paperless idempotence_check],
    ["roles/nextcloud/tasks/main.yml"] => %w[static nextcloud idempotence_check],
    ["roles/vaultwarden/tasks/main.yml"] => %w[static vaultwarden idempotence_check],
    ["roles/karakeep/tasks/main.yml"] => %w[static karakeep idempotence_check],
    ["services/dozzle/compose.yml"] => %w[static dozzle idempotence_check],
    # Plus seerr, which signs in to Jellyfin as the vault administrator.
    ["tests/contracts/jellyfin.sh"] => %w[static seerr jellyfin idempotence_check],
    ["roles/arr/tasks/main.yml"] => %w[static reconciliation arr idempotence_check],
    # Plus bindery: the downloaders lane converges the Usenet provider
    # undeclared now, so the lane that converges it declared has to come with it.
    ["services/downloaders/compose.yml"] =>
      %w[static reconciliation downloaders bindery idempotence_check],
    ["tests/expected/bindery.yml"] => %w[static bindery idempotence_check],
    ["tests/media_control_network_collision_test.sh"] => %w[static reconciliation arr idempotence_check],
    ["config/media-acquisition.yml"] => %w[static reconciliation arr downloaders bindery kapowarr pinchflat trailarr seerr idempotence_check],
    ["roles/host_prep/tasks/verify_media_acquisition.yml"] => %w[static reconciliation arr downloaders bindery kapowarr pinchflat trailarr seerr idempotence_check],
    ["roles/deployment_bundle/tasks/main.yml"] => FALL_OPEN_LANES,
    # A shared role no lane map claims, like roles/image_downgrade_guard: it runs
    # inside kapowarr and vaultwarden, so it falls open to every lane rather than
    # being routed to a hand-kept list of its callers (#836).
    ["roles/pre_upgrade_backup/tasks/main.yml"] => FALL_OPEN_LANES,
    ["tests/policy_test.rb"] => %w[static],
    ["tests/validate-policy.sh"] => %w[static],
    ["tests/ci/workflow_test.rb"] => %w[static],
    # The expectation file declares CPU ceilings the converge checks, so it selects the lane.
    # dozzle is beszel's companion: its beszel-notify mode sends through the hub.
    ["tests/expected/beszel.yml"] => %w[static beszel dozzle idempotence_check],
    ["renovate.json"] => %w[static],
    ["generate-secrets.yml"] => %w[static],
    ["templates/vault-plain.yml.j2"] => %w[static],
    # No suite reads the committed vault; static checks it is encrypted, the vault job decrypts it.
    # Both, not either: dropping `static` would take the encryption check off the file it is about.
    ["inventory/group_vars/all/vault.yml"] => %w[static vault],
    ["inventory/group_vars/all/vault_arr.yml"] => %w[static vault],
    ["install-production-auto-deploy.yml"] => %w[static],
    ["roles/production_auto_deploy/tasks/main.yml"] => %w[static],
    ["roles/image_prune/templates/config.json.j2"] => %w[static],
    ["scripts/production_auto_deploy.py"] => %w[static],
    ["tests/media_acquisition_foundation_test.rb"] =>
      ["static", "reconciliation", *ACQUISITION_LANES, "idempotence_check"],
    # One leg of every job, not of every suite (#395).
    [".github/workflows/ci.yml"] =>
      %w[static docs vault reconciliation komga idempotence_check],
    # Only that one file is mapped. A second workflow, or anything else under
    # .github/, is a path nobody has reasoned about and keeps falling open.
    [".github/workflows/release.yml"] => FALL_OPEN_LANES,
    [".github/dependabot.yml"] => FALL_OPEN_LANES,
    ["unexpected/new-runtime-file"] => FALL_OPEN_LANES
  }.each do |paths, expected|
    check(failures, selected_lanes(paths) == expected,
          "#{paths.join(', ')} selected #{selected_lanes(paths).inspect}, expected #{expected.inspect}")
  end

  ACQUISITION_LANES.each do |project|
    [
      "roles/#{project}/tasks/main.yml",
      "services/#{project}/compose.yml",
      "tests/expected/#{project}.yml",
      "inventory/group_vars/all/service_#{project}.yml"
    ].each do |path|
      expected = canonical(["static", *("reconciliation" if RECONCILIATION_LANES.include?(project)),
                            project, *COMPANION_LANES.fetch(project, []), "idempotence_check"])
      check(failures, selected_lanes([path]) == expected,
            "#{path} selected #{selected_lanes([path]).inspect}, expected #{expected.inspect}")
    end
  end

  %w[
    config/media-acquisition.yml
    roles/host_prep/tasks/verify_media_acquisition.yml
    tests/media_acquisition_foundation_verifier_test.rb
  ].each do |path|
    expected = ["static", "reconciliation", *ACQUISITION_LANES, "idempotence_check"]
    check(failures, selected_lanes([path]) == expected,
          "#{path} must select every acquisition foundation lane")
  end

  # The contract's own files select the contract and the policy gate that carries them as fixtures.
  RECONCILIATION_OWNED_PATHS.each do |path|
    expected = %w[static reconciliation]
    check(failures, selected_lanes([path]) == expected,
          "#{path} selected #{selected_lanes([path]).inspect}, expected #{expected.inspect}")
    check(failures, File.file?(File.expand_path("../../#{path}", __dir__)),
          "the classifier routes #{path}, which does not exist")
  end

  # Every lane the contract reads must select it, and no lane it does not read may.
  LANES.each do |lane|
    next if %w[static docs reconciliation].include?(lane)

    path = "roles/#{lane}/tasks/main.yml"
    next unless File.directory?(File.expand_path("../../roles/#{lane}", __dir__))

    check(failures, selected_lanes([path]).include?("reconciliation") ==
                    RECONCILIATION_LANES.include?(lane),
          "#{path} must #{RECONCILIATION_LANES.include?(lane) ? '' : 'not '}select reconciliation")
  end

  {
    "beszel" => %w[beszel],
    "dozzle" => %w[dozzle],
    "audiobookshelf" => %w[audiobookshelf],
    "komga" => %w[komga],
    "jellyfin" => %w[jellyfin],
    "immich" => %w[immich],
    "paperless-ngx" => %w[paperless],
    "nextcloud" => %w[nextcloud],
    "vaultwarden" => %w[vaultwarden],
    "karakeep" => %w[karakeep]
  }.each do |service, expected_service_lanes|
    role = service == "paperless-ngx" ? "paperless_ngx" : service
    contract = service == "paperless-ngx" ? "paperless" : service
    [
      "roles/#{role}/tasks/main.yml",
      "services/#{service}/compose.yml",
      "tests/expected/#{service}.yml",
      "inventory/group_vars/all/service_#{role}.yml",
      "tests/contracts/#{contract}.sh"
    ].each do |path|
      companions = expected_service_lanes.flat_map { |lane| COMPANION_LANES.fetch(lane, []) }
      expected = canonical(%w[static] + expected_service_lanes + companions +
                           %w[idempotence_check])
      check(failures, selected_lanes([path]) == expected,
            "#{path} selected #{selected_lanes([path]).inspect}, expected #{expected.inspect}")
    end
  end

  check(failures, selected_lanes(["roles/beszel/tasks/main.yml", "services/dozzle/compose.yml"]) ==
                  %w[static beszel dozzle idempotence_check],
        "multiple service changes must combine service lanes in canonical order")
  check(
    failures,
    selected_lanes([
      "roles/komga/tasks/main.yml",
      "services/jellyfin/compose.yml",
      "tests/contracts/immich.sh"
    ]) == %w[static seerr komga jellyfin immich idempotence_check],
    "multiple media service changes must combine canonically, each carrying its own companion"
  )

  # The one #349 names, stated as a path rather than as a table row.
  check(failures, selected_lanes(["roles/jellyfin/tasks/main.yml"]).include?("seerr"),
        "a Jellyfin change must select the seerr lane, the only one that converges arr and " \
        "Jellyfin together and the only one that signs in to Jellyfin as the vault administrator")

  # Derives cross-lane pairs from suites.conf: a lane whose tags name another lane's role must be
  # routed in COMPANION_LANES or declined by name, from the day it lands.
  cross_lane_pairs = ClassifyChanges::TAGGED_LANES.flat_map do |consumer|
    ClassifyChanges::SERVICE_TAGS.fetch(consumer)
                                 .reject { |tag| SHARED_TAGS.include?(tag) || tag == consumer }
                                 .select { |tag| LANES.include?(tag) }
                                 .map { |producer| [producer, consumer] }
  end
  routed_pairs, undeclared_pairs = cross_lane_pairs.partition do |producer, consumer|
    COMPANION_LANES.fetch(producer, []).include?(consumer)
  end
  # A floor, not non-emptiness: a derivation that stops reading tags reports everything routed.
  # Two rather than today's count, so retiring a lane may lower it.
  check(failures, cross_lane_pairs.length >= 2,
        "the suite table named #{cross_lane_pairs.length} cross-lane dependencies, expected at " \
        "least two: the derivation has stopped reading the tags column")
  check(failures, routed_pairs.length >= 2,
        "#{routed_pairs.length} cross-lane dependencies are routed, expected at least two: " \
        "#{routed_pairs.inspect}")
  undeclared_pairs.each do |pair|
    check(failures, DECLINED_COMPANIONS.include?(pair),
          "the #{pair.last} lane converges roles/#{pair.first}/ and no change there selects it: " \
          "route #{pair.first.inspect} in COMPANION_LANES or decline the pair with a reason")
  end
  DECLINED_COMPANIONS.each do |pair|
    check(failures, cross_lane_pairs.include?(pair),
          "#{pair.inspect} is declined but the suite table no longer names that dependency")
    check(failures, !routed_pairs.include?(pair),
          "#{pair.inspect} is both routed and declined")
  end
  check(failures, ClassifyChanges.classify([], full: false).keys == LANES,
        "classify must return every lane in canonical order")
  check(failures, selected_lanes([], full: true) == FULL_LANES,
        "full events must select every lane in the unsharded idempotence form")
  # smoke is a strict prefix of the idempotence lane, so dispatching it proves nothing (#832).
  # Read with fetch so the check survives smoke leaving the lane list.
  smoke_samples = [
    ["full", ClassifyChanges.classify([], full: true)],
    ["fall-open", ClassifyChanges.classify(["unexpected/new-runtime-file"])],
    [".github/workflows/ci.yml", ClassifyChanges.classify([".github/workflows/ci.yml"])]
  ] + LANES.map do |lane|
    path = "roles/#{lane}/tasks/main.yml"
    [path, ClassifyChanges.classify([path])]
  end
  smoke_samples.each do |label, selection|
    idempotence = ([IDEMPOTENCE_LANE] + IDEMPOTENCE_SHARD_LANES).any? { |lane| selection.fetch(lane, false) }
    check(failures, !(selection.fetch("smoke", false) && idempotence),
          "#{label} selected smoke beside an idempotence lane, which it is a strict prefix of")
  end
  check(failures, selected_lanes(["AGENTS.md"]) == FALL_OPEN_LANES,
        "AGENTS.md must not be treated as inert Markdown")
  # Root Markdown no lane map claims falls open to every lane (#346).
  check(failures, selected_lanes(["NOTES.md"]) == FALL_OPEN_LANES,
        "unrouted repository-root Markdown must not be treated as inert")
  check(failures, selected_lanes(["tests/fixtures/operator-guide.md"]) == FALL_OPEN_LANES,
        "test fixture Markdown must not be treated as inert")
  # The two idempotence forms are disjoint in exactly one lane each; never select both.
  check(failures, FULL_LANES.include?(IDEMPOTENCE_LANE) &&
                  (FULL_LANES & IDEMPOTENCE_SHARD_LANES).empty?,
        "a --full selection must carry the unsharded idempotence lane and no shard")
  check(failures, !FALL_OPEN_LANES.include?(IDEMPOTENCE_LANE) &&
                  (FALL_OPEN_LANES & IDEMPOTENCE_SHARD_LANES) == IDEMPOTENCE_SHARD_LANES,
        "a fall-open selection must carry every shard and not the unsharded lane")

  # Walks the harness's reference closure, so a new file an integration suite reads must be listed
  # in INTEGRATION_HARNESS_PATHS/PREFIXES or fail here.
  REPO_ROOT = File.expand_path("../..", __dir__)
  PATH_REFERENCE = %r{(?:/repo/)?(tests/[A-Za-z0-9_/.-]+)}
  REQUIRE_REFERENCE = /require_relative\s+"([^"]+)"/

  def harness_closure
    seen = {}
    queue = ["tests/integration.sh", *Dir.glob("tests/contracts/**/*", base: REPO_ROOT)]
    until queue.empty?
      path = queue.shift
      next if seen.key?(path)

      seen[path] = true
      absolute = File.join(REPO_ROOT, path)
      next unless File.file?(absolute)

      File.foreach(absolute) do |line|
        next if line.lstrip.start_with?("#")

        line.scan(PATH_REFERENCE) { |reference| queue << reference.first }
        line.scan(REQUIRE_REFERENCE) do |reference|
          queue << File.join(File.dirname(path), "#{reference.first}.rb")
        end
      end
    end
    seen.keys.select { |path| File.file?(File.join(REPO_ROOT, path)) }.sort
  end

  reached = harness_closure
  check(failures, reached.include?("tests/contracts/paperless.sh"),
        "the harness closure must reach the contracts tests/integration.sh runs")
  reached.each do |path|
    check(failures, !ClassifyChanges.suites(ClassifyChanges.classify([path])).empty?,
          "#{path} is executed by an integration suite but selects none")
  end

  {
    # beszel selects dozzle as its companion, whose tags are a superset.
    "roles/beszel/tasks/main.yml" => "host_prep,deployment_bundle,beszel,dozzle",
    # The dozzle lane converges Beszel too, for its beszel-notify mode.
    "roles/dozzle/tasks/main.yml" => "host_prep,deployment_bundle,beszel,dozzle",
    # The bindery row comes first and its tags are a superset, so this is Bindery's plan.
    "roles/audiobookshelf/tasks/main.yml" =>
      "host_prep,deployment_bundle,arr,downloaders,audiobookshelf,bindery",
    "roles/komga/tasks/main.yml" => "host_prep,deployment_bundle,komga",
    # Likewise the seerr lane for Jellyfin.
    "roles/jellyfin/tasks/main.yml" => "host_prep,deployment_bundle,arr,jellyfin,seerr",
    "roles/immich/tasks/main.yml" => "host_prep,deployment_bundle,immich",
    "roles/paperless_ngx/tasks/main.yml" => "host_prep,deployment_bundle,paperless",
    "roles/nextcloud/tasks/main.yml" => "host_prep,deployment_bundle,nextcloud",
    "roles/vaultwarden/tasks/main.yml" => "host_prep,deployment_bundle,vaultwarden",
    "roles/karakeep/tasks/main.yml" => "host_prep,deployment_bundle,karakeep"
  }.each do |path, expected_tags|
    service_output = StringIO.new
    ClassifyChanges.write_github_outputs(ClassifyChanges.classify([path]), service_output)
    check(failures,
          service_output.string.end_with?(
            "selected_tags=#{expected_tags}\nupgrade_service=\nupgrade_base_image=\n" \
            "upgrade_tags=\n"
          ),
          "#{path} emitted the wrong prerequisite tag plan: #{service_output.string.inspect}")
  end

  io = StringIO.new
  ClassifyChanges.write_github_outputs(
    ClassifyChanges.classify(%w[roles/beszel/tasks/main.yml services/dozzle/compose.yml]), io
  )
  expected_output = <<~OUTPUT
    static=true
    docs=false
    vault=false
    reconciliation=false
    foundation=false
    arr=false
    downloaders=false
    bindery=false
    kapowarr=false
    pinchflat=false
    trailarr=false
    seerr=false
    beszel=true
    dozzle=true
    audiobookshelf=false
    komga=false
    jellyfin=false
    immich=false
    paperless=false
    nextcloud=false
    vaultwarden=false
    karakeep=false
    upgrade=false
    idempotence_check=true
    idempotence_1=false
    idempotence_2=false
    idempotence_3=false
    idempotence_4=false
    idempotence_5=false
    idempotence_6=false
    suites=["beszel","dozzle","idempotence-check"]
    selected_tags=host_prep,deployment_bundle,beszel,dozzle
    upgrade_service=
    upgrade_base_image=
    upgrade_tags=
  OUTPUT
  check(failures, io.string == expected_output,
        "GitHub output or prerequisite tag ordering was incorrect: #{io.string.inspect}")

  full_output = StringIO.new
  ClassifyChanges.write_github_outputs(ClassifyChanges.classify([], full: true), full_output)
  expected_full_output = <<~OUTPUT
    static=true
    docs=true
    vault=true
    reconciliation=true
    foundation=true
    arr=true
    downloaders=true
    bindery=true
    kapowarr=true
    pinchflat=true
    trailarr=true
    seerr=true
    beszel=true
    dozzle=true
    audiobookshelf=true
    komga=true
    jellyfin=true
    immich=true
    paperless=true
    nextcloud=true
    vaultwarden=true
    karakeep=true
    upgrade=false
    idempotence_check=true
    idempotence_1=false
    idempotence_2=false
    idempotence_3=false
    idempotence_4=false
    idempotence_5=false
    idempotence_6=false
    suites=["foundation","arr","downloaders","bindery","kapowarr","pinchflat","trailarr","seerr","beszel","dozzle","audiobookshelf","komga","jellyfin","immich","paperless","nextcloud","vaultwarden","karakeep","idempotence-check"]
    selected_tags=
    upgrade_service=
    upgrade_base_image=
    upgrade_tags=
  OUTPUT
  check(failures, full_output.string == expected_full_output,
        "--full output must leave selected_tags empty: #{full_output.string.inspect}")

  # Written out rather than derived from the block above: a transformed pin agrees by construction.
  expected_fall_open_output = <<~OUTPUT
    static=true
    docs=true
    vault=true
    reconciliation=true
    foundation=true
    arr=true
    downloaders=true
    bindery=true
    kapowarr=true
    pinchflat=true
    trailarr=true
    seerr=true
    beszel=true
    dozzle=true
    audiobookshelf=true
    komga=true
    jellyfin=true
    immich=true
    paperless=true
    nextcloud=true
    vaultwarden=true
    karakeep=true
    upgrade=false
    idempotence_check=false
    idempotence_1=true
    idempotence_2=true
    idempotence_3=true
    idempotence_4=true
    idempotence_5=true
    idempotence_6=true
    suites=["foundation","arr","downloaders","bindery","kapowarr","pinchflat","trailarr","seerr","beszel","dozzle","audiobookshelf","komga","jellyfin","immich","paperless","nextcloud","vaultwarden","karakeep","idempotence-1","idempotence-2","idempotence-3","idempotence-4","idempotence-5","idempotence-6"]
    selected_tags=
    upgrade_service=
    upgrade_base_image=
    upgrade_tags=
  OUTPUT

  shared_output = StringIO.new
  ClassifyChanges.write_github_outputs(
    ClassifyChanges.classify(["roles/deployment_bundle/tasks/main.yml"]), shared_output
  )
  check(failures, shared_output.string == expected_fall_open_output,
        "shared-scope output must select the full untagged site: #{shared_output.string.inspect}")

  unknown_output = StringIO.new
  ClassifyChanges.write_github_outputs(
    ClassifyChanges.classify(["unexpected/new-runtime-file"]), unknown_output
  )
  check(failures, unknown_output.string == expected_fall_open_output,
        "unknown-path output must select the full untagged site: #{unknown_output.string.inspect}")

  paperless_output = StringIO.new
  ClassifyChanges.write_github_outputs(
    ClassifyChanges.classify(["roles/paperless_ngx/tasks/main.yml"]), paperless_output
  )
  check(failures, paperless_output.string == <<~OUTPUT,
    static=true
    docs=false
    vault=false
    reconciliation=false
    foundation=false
    arr=false
    downloaders=false
    bindery=false
    kapowarr=false
    pinchflat=false
    trailarr=false
    seerr=false
    beszel=false
    dozzle=false
    audiobookshelf=false
    komga=false
    jellyfin=false
    immich=false
    paperless=true
    nextcloud=false
    vaultwarden=false
    karakeep=false
    upgrade=false
    idempotence_check=true
    idempotence_1=false
    idempotence_2=false
    idempotence_3=false
    idempotence_4=false
    idempotence_5=false
    idempotence_6=false
    suites=["paperless","idempotence-check"]
    selected_tags=host_prep,deployment_bundle,paperless
    upgrade_service=
    upgrade_base_image=
    upgrade_tags=
  OUTPUT
        "Paperless-only output must retain its exact tag plan: #{paperless_output.string.inspect}")

  # Bindery also converges arr and downloaders: it stores a Prowlarr instance and a SABnzbd client
  # and resolves both hosts at write time.
  bindery_output = StringIO.new
  ClassifyChanges.write_github_outputs(
    ClassifyChanges.classify(["roles/bindery/tasks/main.yml"]), bindery_output
  )
  check(failures, bindery_output.string == <<~OUTPUT,
    static=true
    docs=false
    vault=false
    reconciliation=false
    foundation=false
    arr=false
    downloaders=false
    bindery=true
    kapowarr=false
    pinchflat=false
    trailarr=false
    seerr=false
    beszel=false
    dozzle=false
    audiobookshelf=false
    komga=false
    jellyfin=false
    immich=false
    paperless=false
    nextcloud=false
    vaultwarden=false
    karakeep=false
    upgrade=false
    idempotence_check=true
    idempotence_1=false
    idempotence_2=false
    idempotence_3=false
    idempotence_4=false
    idempotence_5=false
    idempotence_6=false
    suites=["bindery","idempotence-check"]
    selected_tags=host_prep,deployment_bundle,arr,downloaders,audiobookshelf,bindery
    upgrade_service=
    upgrade_base_image=
    upgrade_tags=
  OUTPUT
        "Bindery-only output must retain its exact tag plan: #{bindery_output.string.inspect}")

  kapowarr_output = StringIO.new
  ClassifyChanges.write_github_outputs(
    ClassifyChanges.classify(["roles/kapowarr/tasks/main.yml"]), kapowarr_output
  )
  check(failures, kapowarr_output.string == <<~OUTPUT,
    static=true
    docs=false
    vault=false
    reconciliation=false
    foundation=false
    arr=false
    downloaders=false
    bindery=false
    kapowarr=true
    pinchflat=false
    trailarr=false
    seerr=false
    beszel=false
    dozzle=false
    audiobookshelf=false
    komga=false
    jellyfin=false
    immich=false
    paperless=false
    nextcloud=false
    vaultwarden=false
    karakeep=false
    upgrade=false
    idempotence_check=true
    idempotence_1=false
    idempotence_2=false
    idempotence_3=false
    idempotence_4=false
    idempotence_5=false
    idempotence_6=false
    suites=["kapowarr","idempotence-check"]
    selected_tags=host_prep,deployment_bundle,kapowarr
    upgrade_service=
    upgrade_base_image=
    upgrade_tags=
  OUTPUT
        "Kapowarr-only output must retain its exact tag plan: #{kapowarr_output.string.inspect}")

  pinchflat_output = StringIO.new
  ClassifyChanges.write_github_outputs(
    ClassifyChanges.classify(["roles/pinchflat/tasks/main.yml"]), pinchflat_output
  )
  check(failures, pinchflat_output.string == <<~OUTPUT,
    static=true
    docs=false
    vault=false
    reconciliation=false
    foundation=false
    arr=false
    downloaders=false
    bindery=false
    kapowarr=false
    pinchflat=true
    trailarr=false
    seerr=false
    beszel=false
    dozzle=false
    audiobookshelf=false
    komga=false
    jellyfin=false
    immich=false
    paperless=false
    nextcloud=false
    vaultwarden=false
    karakeep=false
    upgrade=false
    idempotence_check=true
    idempotence_1=false
    idempotence_2=false
    idempotence_3=false
    idempotence_4=false
    idempotence_5=false
    idempotence_6=false
    suites=["pinchflat","idempotence-check"]
    selected_tags=host_prep,deployment_bundle,pinchflat
    upgrade_service=
    upgrade_base_image=
    upgrade_tags=
  OUTPUT
        "Pinchflat-only output must retain its exact tag plan: #{pinchflat_output.string.inspect}")

  # Trailarr converges arr but not downloaders: it validates connections live and acquires nothing.
  trailarr_output = StringIO.new
  ClassifyChanges.write_github_outputs(
    ClassifyChanges.classify(["roles/trailarr/tasks/main.yml"]), trailarr_output
  )
  check(failures, trailarr_output.string == <<~OUTPUT,
    static=true
    docs=false
    vault=false
    reconciliation=false
    foundation=false
    arr=false
    downloaders=false
    bindery=false
    kapowarr=false
    pinchflat=false
    trailarr=true
    seerr=false
    beszel=false
    dozzle=false
    audiobookshelf=false
    komga=false
    jellyfin=false
    immich=false
    paperless=false
    nextcloud=false
    vaultwarden=false
    karakeep=false
    upgrade=false
    idempotence_check=true
    idempotence_1=false
    idempotence_2=false
    idempotence_3=false
    idempotence_4=false
    idempotence_5=false
    idempotence_6=false
    suites=["trailarr","idempotence-check"]
    selected_tags=host_prep,deployment_bundle,arr,trailarr
    upgrade_service=
    upgrade_base_image=
    upgrade_tags=
  OUTPUT
        "Trailarr-only output must retain its exact tag plan: #{trailarr_output.string.inspect}")

  # Seerr converges arr and Jellyfin together: arr connection rows, Jellyfin users and admin sign-in.
  seerr_output = StringIO.new
  ClassifyChanges.write_github_outputs(
    ClassifyChanges.classify(["roles/seerr/tasks/main.yml"]), seerr_output
  )
  check(failures, seerr_output.string == <<~OUTPUT,
    static=true
    docs=false
    vault=false
    reconciliation=false
    foundation=false
    arr=false
    downloaders=false
    bindery=false
    kapowarr=false
    pinchflat=false
    trailarr=false
    seerr=true
    beszel=false
    dozzle=false
    audiobookshelf=false
    komga=false
    jellyfin=false
    immich=false
    paperless=false
    nextcloud=false
    vaultwarden=false
    karakeep=false
    upgrade=false
    idempotence_check=true
    idempotence_1=false
    idempotence_2=false
    idempotence_3=false
    idempotence_4=false
    idempotence_5=false
    idempotence_6=false
    suites=["seerr","idempotence-check"]
    selected_tags=host_prep,deployment_bundle,arr,jellyfin,seerr
    upgrade_service=
    upgrade_base_image=
    upgrade_tags=
  OUTPUT
        "Seerr-only output must retain its exact tag plan: #{seerr_output.string.inspect}")

  io = StringIO.new
  ClassifyChanges.write_github_outputs(ClassifyChanges.classify(["README.md"]), io)
  check(failures, io.string.start_with?("static=true\ndocs=true\n"),
        "the README is read by the policy set and by the link gate, so it must select both")
  check(failures,
        io.string.end_with?(
          "suites=[]\nselected_tags=\nupgrade_service=\nupgrade_base_image=\nupgrade_tags=\n"
        ),
        "protected operator docs must select static CI and emit empty selected_tags")
  # The CI matrix job skips on exactly this literal, so it has to stay compact.
  check(failures, io.string.include?("suites=[]\n"),
        "protected operator docs must emit an empty suite array: #{io.string.inspect}")

  check(failures, ClassifyChanges::SUITES.keys == ClassifyChanges::LANES - ClassifyChanges::JOB_LANES,
        "every lane but the job lanes must map to exactly one integration suite")
  check(failures, ClassifyChanges::JOB_LANES == %w[static docs vault reconciliation],
        "static, docs, vault and reconciliation are the only lanes that gate a job instead of a suite")
  check(failures,
        ClassifyChanges.suites(ClassifyChanges.classify(["roles/beszel/tasks/main.yml"])) ==
          %w[beszel dozzle idempotence-check],
        "a Beszel-only change must dispatch beszel, its dozzle companion and idempotence-check")
  check(failures,
        ClassifyChanges.suites(ClassifyChanges.classify(["roles/arr/tasks/main.yml"])) ==
          %w[arr idempotence-check],
        "an Arr-only change must dispatch its foundation suite and idempotence-check")

  # The shared foundation program is in ACQUISITION_SHARED_PATHS, so it selects every
  # acquisition lane (#639).
  acquisition_output = StringIO.new
  ClassifyChanges.write_github_outputs(
    ClassifyChanges.classify(["tests/media_acquisition_foundation_test.rb"]), acquisition_output
  )
  check(failures,
        acquisition_output.string.include?("seerr") &&
          acquisition_output.string.include?("kapowarr") &&
          acquisition_output.string.include?("pinchflat"),
        "the shared foundation program must route to every acquisition lane, not one")
  check(failures, !acquisition_output.string.downcase.include?("tmm"),
        "classifier outputs must not resurrect the retired tMM project")

  Dir.mktmpdir("classify-changes-git-") do |root|
    system("git", "init", "-q", "-b", FIXTURE_BRANCH, root, exception: true)
    system("git", "-C", root, "config", "user.email", "ci@example.invalid", exception: true)
    system("git", "-C", root, "config", "user.name", "CI Test", exception: true)
    source = File.join(root, "roles", "paperless_ngx", "tasks", "main.yml")
    FileUtils.mkdir_p(File.dirname(source))
    File.write(source, "paperless owned content\n" * 20)
    system("git", "-C", root, "add", ".", exception: true)
    system("git", "-C", root, "commit", "-qm", "base", exception: true)
    base, status = Open3.capture2("git", "-C", root, "rev-parse", "HEAD")
    check(failures, status.success?, "failed to resolve temporary base commit")
    base = base.strip
    destination = File.join(root, "docs", "paperless-role.md")
    FileUtils.mkdir_p(File.dirname(destination))
    system("git", "-C", root, "mv", source, destination, exception: true)
    system("git", "-C", root, "commit", "-qam", "rename", exception: true)
    head, status = Open3.capture2("git", "-C", root, "rev-parse", "HEAD")
    check(failures, status.success?, "failed to resolve temporary head commit")
    head = head.strip

    paths = Dir.chdir(root) { ClassifyChanges.changed_paths(base, head) }
    check(failures,
          paths == ["roles/paperless_ngx/tasks/main.yml", "docs/paperless-role.md"],
          "rename parsing must return old and new paths, got #{paths.inspect}")
    check(failures, selected_lanes(paths).include?("paperless"),
          "renaming a Paperless-owned path to docs must retain Paperless selection")
  end

  Dir.mktmpdir("classify-changes-copy-delete-") do |root|
    system("git", "init", "-q", "-b", FIXTURE_BRANCH, root, exception: true)
    system("git", "-C", root, "config", "user.email", "ci@example.invalid", exception: true)
    system("git", "-C", root, "config", "user.name", "CI Test", exception: true)
    beszel_source = File.join(root, "roles", "beszel", "tasks", "main.yml")
    dozzle_source = File.join(root, "roles", "dozzle", "tasks", "main.yml")
    FileUtils.mkdir_p(File.dirname(beszel_source))
    FileUtils.mkdir_p(File.dirname(dozzle_source))
    File.write(beszel_source, "beszel owned content\n" * 20)
    File.write(dozzle_source, "dozzle owned content\n" * 20)
    system("git", "-C", root, "add", ".", exception: true)
    system("git", "-C", root, "commit", "-qm", "base", exception: true)
    base, status = Open3.capture2("git", "-C", root, "rev-parse", "HEAD")
    check(failures, status.success?, "failed to resolve temporary copy base commit")
    base = base.strip

    copy = File.join(root, "docs", "copied.md")
    FileUtils.mkdir_p(File.dirname(copy))
    FileUtils.cp(beszel_source, copy)
    system("git", "-C", root, "add", ".", exception: true)
    system("git", "-C", root, "commit", "-qm", "copy", exception: true)
    copy_head, status = Open3.capture2("git", "-C", root, "rev-parse", "HEAD")
    check(failures, status.success?, "failed to resolve temporary copy commit")
    copy_head = copy_head.strip

    copied_paths = Dir.chdir(root) { ClassifyChanges.changed_paths(base, copy_head) }
    check(failures,
          copied_paths == ["roles/beszel/tasks/main.yml", "docs/copied.md"],
          "copy parsing must return source and destination paths, got #{copied_paths.inspect}")
    check(failures, selected_lanes(copied_paths).include?("beszel"),
          "copying a Beszel-owned path to docs must retain Beszel selection")

    FileUtils.rm(dozzle_source)
    system("git", "-C", root, "add", "-u", exception: true)
    system("git", "-C", root, "commit", "-qm", "delete", exception: true)
    delete_head, status = Open3.capture2("git", "-C", root, "rev-parse", "HEAD")
    check(failures, status.success?, "failed to resolve temporary deletion commit")
    delete_head = delete_head.strip

    deleted_paths = Dir.chdir(root) { ClassifyChanges.changed_paths(copy_head, delete_head) }
    check(failures, deleted_paths == ["roles/dozzle/tasks/main.yml"],
          "deletion parsing must retain the deleted path, got #{deleted_paths.inspect}")
    check(failures, selected_lanes(deleted_paths).include?("dozzle"),
          "deleting a Dozzle-owned path must retain Dozzle selection")
  end

  # The upgrade subject against a real two-revision history, since resolution uses `git show`. A
  # compose change that keeps its pin selects nothing; a service with no seed program is no subject.
  Dir.mktmpdir("classify-changes-upgrade-") do |root|
    system("git", "init", "-q", "-b", FIXTURE_BRANCH, root, exception: true)
    system("git", "-C", root, "config", "user.email", "ci@example.invalid", exception: true)
    system("git", "-C", root, "config", "user.name", "CI Test", exception: true)
    digest = ->(seed) { (seed.to_s * 64)[0, 64] }
    pin = ->(version, seed) { "docker.io/mrcas/kapowarr:#{version}@sha256:#{digest.call(seed)}" }
    compose = File.join(root, "services", "kapowarr", "compose.yml")
    komga = File.join(root, "services", "komga", "compose.yml")
    FileUtils.mkdir_p(File.dirname(compose))
    FileUtils.mkdir_p(File.dirname(komga))
    write_compose = lambda do |path, image, limit|
      File.write(path, "services:\n  app:\n    image: #{image}\n    mem_limit: #{limit}\n")
    end
    write_compose.call(compose, pin.call("v1.3.1", 1), "1g")
    write_compose.call(komga, pin.call("v1.0.0", 3), "1g")
    system("git", "-C", root, "add", ".", exception: true)
    system("git", "-C", root, "commit", "-qm", "base", exception: true)
    upgrade_base = Open3.capture2("git", "-C", root, "rev-parse", "HEAD").first.strip

    write_compose.call(compose, pin.call("v1.3.2", 2), "1g")
    system("git", "-C", root, "commit", "-qam", "bump", exception: true)
    upgrade_head = Open3.capture2("git", "-C", root, "rev-parse", "HEAD").first.strip

    subject = Dir.chdir(root) do
      ClassifyChanges.upgrade_subject(["services/kapowarr/compose.yml"], upgrade_base, upgrade_head)
    end
    check(failures, subject == ["kapowarr", pin.call("v1.3.1", 1)],
          "a moved Kapowarr pin must resolve as the upgrade subject, got #{subject.inspect}")

    write_compose.call(compose, pin.call("v1.3.2", 2), "2g")
    system("git", "-C", root, "commit", "-qam", "limit", exception: true)
    unmoved_head = Open3.capture2("git", "-C", root, "rev-parse", "HEAD").first.strip
    unmoved = Dir.chdir(root) do
      ClassifyChanges.upgrade_subject(["services/kapowarr/compose.yml"], upgrade_head, unmoved_head)
    end
    check(failures, unmoved.nil?,
          "a compose change that does not move the pin must select no upgrade subject, " \
          "got #{unmoved.inspect}")

    write_compose.call(komga, pin.call("v1.1.0", 4), "1g")
    system("git", "-C", root, "commit", "-qam", "komga", exception: true)
    komga_head = Open3.capture2("git", "-C", root, "rev-parse", "HEAD").first.strip
    unseeded = Dir.chdir(root) do
      ClassifyChanges.upgrade_subject(["services/komga/compose.yml"], unmoved_head, komga_head)
    end
    check(failures, unseeded.nil?,
          "a service with no seed-and-verify program must not be an upgrade subject, " \
          "got #{unseeded.inspect}")

    # A fall-open that moved a subject pin must still dispatch the lane: the unmapped-path return
    # once fired before the subject was resolved.
    write_compose.call(compose, pin.call("v1.3.3", 5), "2g")
    File.write(File.join(root, "unexpected-new-runtime-file"), "unmapped\n")
    system("git", "-C", root, "add", "-A", exception: true)
    system("git", "-C", root, "commit", "-qm", "bump beside an unmapped path", exception: true)
    fall_open_head = Open3.capture2("git", "-C", root, "rev-parse", "HEAD").first.strip
    fall_open = Dir.chdir(root) do
      ClassifyChanges.classify(
        ["services/kapowarr/compose.yml", "unexpected-new-runtime-file"],
        base: komga_head, head: fall_open_head
      )
    end
    check(failures, fall_open.fetch("upgrade"),
          "a fall-open whose diff moved a subject pin must still dispatch the upgrade lane")
    check(failures, ClassifyChanges.suites(fall_open).include?("upgrade"),
          "the fall-open selection must carry the upgrade suite, got " \
          "#{ClassifyChanges.suites(fall_open).inspect}")
    # ... and the shards rather than the single idempotence pass, because it is
    # still a fall-open. The upgrade lane is additive to that, not a form of it.
    check(failures, !fall_open.fetch(IDEMPOTENCE_LANE) &&
                    IDEMPOTENCE_SHARD_LANES.all? { |lane| fall_open.fetch(lane) },
          "a fall-open must keep taking the idempotence shards")

    # `--full` has no base revision, so there is no subject and the lane stays off.
    unmapped_only = Dir.chdir(root) do
      ClassifyChanges.classify(["unexpected-new-runtime-file"],
                               base: komga_head, head: fall_open_head)
    end
    check(failures, !unmapped_only.fetch("upgrade"),
          "a fall-open that moved no subject pin must not dispatch the upgrade lane")

    # The lane's tags are its subject's, since a fall-open empties selected_tags. Re-classified
    # because write_github_outputs reads the subject classify last resolved.
    fall_open_output = StringIO.new
    Dir.chdir(root) do
      ClassifyChanges.write_github_outputs(
        ClassifyChanges.classify(
          ["services/kapowarr/compose.yml", "unexpected-new-runtime-file"],
          base: komga_head, head: fall_open_head
        ),
        fall_open_output
      )
    end
    check(failures, fall_open_output.string.include?("selected_tags=\n"),
          "a fall-open must still empty selected_tags for the lanes that read it")
    check(failures,
          fall_open_output.string.include?(
            "upgrade_tags=host_prep,deployment_bundle,kapowarr\n"
          ),
          "the upgrade lane must carry its subject's own tags through a fall-open, got " \
          "#{fall_open_output.string[/^upgrade_tags=.*$/].inspect}")

    # The pairing guard: classifying twice then writing would pair the last subject with the first
    # selection's lanes. The case above re-classifies right before writing, so it cannot reach it.
    stale = Dir.chdir(root) do
      selection = ClassifyChanges.classify(
        ["services/kapowarr/compose.yml", "unexpected-new-runtime-file"],
        base: komga_head, head: fall_open_head
      )
      ClassifyChanges.classify(["README.md"])
      begin
        ClassifyChanges.write_github_outputs(selection, StringIO.new)
        nil
      rescue RuntimeError => e
        e.message
      end
    end
    check(failures, stale&.include?("does not match the resolved subject"),
          "writing a selection beside a later classification's subject must be refused, got " \
          "#{stale.inspect}")

    # The base is the merge base, not the tip: here the base ref moves its pin after the fork, and
    # the subject's base must still be what the branch forked from.
    system("git", "-C", root, "checkout", "-q", "-b", "fork", fall_open_head, exception: true)
    write_compose.call(compose, pin.call("v1.4.0", 7), "2g")
    system("git", "-C", root, "commit", "-qam", "branch bumps to v1.4.0", exception: true)
    branch_head = Open3.capture2("git", "-C", root, "rev-parse", "HEAD").first.strip
    system("git", "-C", root, "checkout", "-q", FIXTURE_BRANCH, exception: true)
    write_compose.call(compose, pin.call("v1.9.9", 9), "2g")
    system("git", "-C", root, "commit", "-qam", "base moves on without the branch", exception: true)
    moved_base = Open3.capture2("git", "-C", root, "rev-parse", "HEAD").first.strip

    forked = Dir.chdir(root) do
      ClassifyChanges.upgrade_subject(["services/kapowarr/compose.yml"], moved_base, branch_head)
    end
    check(failures, forked == ["kapowarr", pin.call("v1.3.3", 5)],
          "the upgrade base must be the pin at the merge base, not at the base tip " \
          "(#{pin.call('v1.9.9', 9)}), got #{forked.inspect}")
  end
end

# Invalid mode combinations must fail with usage status before touching output.
Dir.mktmpdir("classify-changes-cli-") do |root|
  output_path = File.join(root, "github-output")
  stdout, stderr, status = Open3.capture3(
    RbConfig.ruby, SCRIPT, "--full", "--files", "README.md", "--github-output", output_path
  )
  check(failures, status.exitstatus == 2, "invalid CLI modes must exit 2")
  check(failures, stdout.empty? && !File.exist?(output_path),
        "invalid CLI modes must fail before producing output")
  check(failures, stderr.include?("usage:"), "invalid CLI modes must print usage")

  stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCRIPT, "--files", "README.md")
  check(failures, status.success? && stderr.empty? &&
                  stdout.include?("static=true\n") && stdout.include?("docs=true\n") &&
                  stdout.include?("suites=[]\n"),
        "--files CLI mode did not select static CI for protected operator docs")

  stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCRIPT, "--full")
  check(failures, status.success? && stderr.empty? && stdout == expected_full_output,
        "--full CLI mode must emit an untagged full-site selection: #{stdout.inspect}")
end

# The push-to-main classify step's shell is lifted from the workflow and run against synthetic
# histories, so a rewrite that sweeps everything or classifies nothing fails here.
CI_WORKFLOW_PATH = File.expand_path("../../.github/workflows/ci.yml", __dir__)
CLASSIFY_STEP = begin
  steps = YAML.safe_load_file(CI_WORKFLOW_PATH).dig("jobs", "changes", "steps")
  step = Array(steps).find { |candidate| candidate.is_a?(Hash) && candidate["id"] == "classify" }
  step && step["run"].to_s
end

# A repository the classifier can run inside: it needs its own script and the suite
# table beside it, committed first so they never appear in a diff under test.
def init_push_repository(root)
  system("git", "init", "-q", "-b", FIXTURE_BRANCH, root, exception: true)
  system("git", "-C", root, "config", "user.email", "ci@example.invalid", exception: true)
  system("git", "-C", root, "config", "user.name", "CI Test", exception: true)
  FileUtils.mkdir_p(File.join(root, "tests", "ci"))
  %w[classify_changes.rb suites.conf].each do |name|
    FileUtils.cp(File.expand_path(name, __dir__), File.join(root, "tests", "ci", name))
  end
end

def push_commit(root, *paths)
  paths.each do |path|
    absolute = File.join(root, path)
    FileUtils.mkdir_p(File.dirname(absolute))
    File.write(absolute, "owned content for #{path}\n#{Time.now.to_f}\n")
  end
  system("git", "-C", root, "add", "-A", exception: true)
  system("git", "-C", root, "commit", "-qm", "commit #{paths.join(' ')}", exception: true)
  git_revision(root, "HEAD")
end

def git_revision(root, revision)
  output, status = Open3.capture2("git", "-C", root, "rev-parse", revision)
  raise "failed to resolve #{revision}" unless status.success?

  output.strip
end

# Exactly what the runner does: the step's shell, the push event, and nothing in
# the environment but the values the workflow passes through `env:`.
def classify_push(root, before)
  script = File.join(root, ".classify-step.sh")
  File.write(script, CLASSIFY_STEP.to_s)
  output_path = File.join(root, ".github-output")
  FileUtils.rm_f(output_path)
  environment = {
    "EVENT_NAME" => "push", "PR_BASE" => "", "PR_HEAD" => "",
    "PUSH_BEFORE" => before, "GITHUB_OUTPUT" => output_path
  }
  _stdout, stderr, status = Open3.capture3(environment, "bash", "-e", script, chdir: root)
  [status, File.exist?(output_path) ? File.read(output_path) : "", stderr]
end

def push_lanes(output)
  output.lines.filter_map { |line| line.split("=", 2).first if line.strip.end_with?("=true") }
end

check(failures, !CLASSIFY_STEP.to_s.empty?,
      "the changes job must still carry a step with id `classify`")

unless CLASSIFY_STEP.to_s.empty?
  # A squash merge: main gains one commit, and `before` is the tip it replaced.
  Dir.mktmpdir("classify-push-squash-") do |root|
    init_push_repository(root)
    # The landed commit is dozzle's, because beszel's would select dozzle too as
    # its companion and the tip it replaced could no longer be told apart.
    before = push_commit(root, "roles/beszel/tasks/main.yml")
    push_commit(root, "roles/dozzle/tasks/main.yml")
    status, output, stderr = classify_push(root, before)
    lanes = push_lanes(output)
    check(failures, status.success?, "a squash merge must classify cleanly: #{stderr.inspect}")
    check(failures, lanes.include?("dozzle") && !lanes.include?("beszel"),
          "a squash merge must select only the lanes it touched, got #{lanes.inspect}")
    check(failures, !lanes.include?("immich"),
          "a squash merge must not fall back to a full sweep, got #{lanes.inspect}")
  end

  # A merge commit: HEAD has two parents, and the diff has to be the whole branch
  # that was merged rather than one parent's side of it.
  Dir.mktmpdir("classify-push-merge-") do |root|
    init_push_repository(root)
    before = push_commit(root, "roles/dozzle/tasks/main.yml")
    system("git", "-C", root, "checkout", "-q", "-b", "feature", exception: true)
    push_commit(root, "roles/immich/tasks/main.yml")
    push_commit(root, "roles/komga/tasks/main.yml")
    system("git", "-C", root, "checkout", "-q", "-", exception: true)
    system("git", "-C", root, "merge", "-q", "--no-ff", "-m", "merge", "feature", exception: true)
    status, output, stderr = classify_push(root, before)
    lanes = push_lanes(output)
    check(failures, status.success?, "a merge commit must classify cleanly: #{stderr.inspect}")
    check(failures, lanes.include?("immich") && lanes.include?("komga"),
          "a merge commit must classify the whole branch it merged, got #{lanes.inspect}")
    check(failures, !lanes.include?("dozzle"),
          "a merge commit must not select lanes it did not touch, got #{lanes.inspect}")
  end

  # A direct push of several commits. This is the case `HEAD^` alone gets wrong:
  # it would see only the last commit and drop every lane the earlier ones touched.
  Dir.mktmpdir("classify-push-multi-") do |root|
    init_push_repository(root)
    before = push_commit(root, "roles/dozzle/tasks/main.yml")
    push_commit(root, "roles/jellyfin/tasks/main.yml")
    push_commit(root, "roles/paperless-ngx/tasks/main.yml")
    status, output, stderr = classify_push(root, before)
    lanes = push_lanes(output)
    check(failures, status.success?, "a multi-commit push must classify cleanly: #{stderr.inspect}")
    check(failures, lanes.include?("paperless"),
          "a multi-commit push must select the last commit's lane, got #{lanes.inspect}")
    check(failures, lanes.include?("jellyfin"),
          "a multi-commit push must classify every commit it carried, not just HEAD^: " \
          "#{lanes.inspect}")
  end

  # No usable `before` (all zeros, or unfetched after a force push): both fall back to HEAD^.
  ["0" * 40, "1" * 40, ""].each do |unusable|
    Dir.mktmpdir("classify-push-fallback-") do |root|
      init_push_repository(root)
      push_commit(root, "roles/dozzle/tasks/main.yml")
      push_commit(root, "roles/audiobookshelf/tasks/main.yml")
      status, output, stderr = classify_push(root, unusable)
      lanes = push_lanes(output)
      check(failures, status.success?,
            "an unusable before=#{unusable.inspect} must still classify: #{stderr.inspect}")
      check(failures, lanes.include?("audiobookshelf") && !lanes.include?("dozzle"),
            "before=#{unusable.inspect} must fall back to the first parent, got #{lanes.inspect}")
    end
  end

  # Nothing to diff against: must reach `--full`, never an empty selection that skips every job.
  Dir.mktmpdir("classify-push-rootless-") do |root|
    init_push_repository(root)
    push_commit(root, "roles/dozzle/tasks/main.yml")
    status, output, stderr = classify_push(root, "0" * 40)
    check(failures, status.success?,
          "a push with no parent must still classify: #{stderr.inspect}")
    check(failures, output == expected_full_output,
          "a push with no parent must fail open to a full run, got #{output.inspect}")
  end
end

# Every document a registered check reads must select at least one job that runs that check.
# Both halves are derived: the literals a check names, and whether it globs docs/.
POLICY_DOC_ROOT = File.expand_path("../..", __dir__)
POLICY_MANIFEST = File.join(POLICY_DOC_ROOT, "tests", "validate-policy.sh")
POLICY_WORKFLOW = File.join(POLICY_DOC_ROOT, ".github", "workflows", "ci.yml")
# The routing and its fixtures name documents to route them, not read them; counting them would
# make this guard assert whatever the routing already says.
ROUTING_SOURCES = %w[
  tests/ci/classify_changes.rb
  tests/ci/classify_changes_test.rb
  tests/ci/workflow_test.rb
].freeze
# How tests/docs_links_test.rb spells "all of docs/".
DOCS_GLOB_PATTERN = %r{docs/\*\*|"docs"\)\s*\.glob\(}
# Every document a check names by path, root Markdown included (#346). The lookbehind keeps
# `docs/plans/notes.md` from also counting as a root `notes.md`.
DOCUMENT_REFERENCE_PATTERN = %r{(?<![\w./-])(?:docs/[A-Za-z0-9_./-]+|[A-Za-z0-9_-]+)\.md}

# The checks each classifier lane runs; mutation and lint are gated on `static`. A job left out
# silently shrinks this derivation rather than failing, so add every job that runs a check.
def lane_check_text(workflow_path, manifest_path)
  workflow = File.file?(workflow_path) ? YAML.safe_load_file(workflow_path, aliases: false) : {}
  jobs = workflow.fetch("jobs", {})
  runs = lambda do |job|
    Array(jobs.dig(job, "steps")).filter_map { |step| step["run"] if step.is_a?(Hash) }.join("\n")
  end
  manifest = File.file?(manifest_path) ? File.read(manifest_path) : ""
  {
    "static" => [manifest, runs.call("static"), runs.call("lint"), runs.call("mutation")].join("\n"),
    "docs" => runs.call("docs")
  }
end

# Both spellings a job uses to name a check: a path, and the dotted module name
# that `python3 -m unittest` takes.
def registered_checks(text)
  checks = text.scan(%r{tests/[A-Za-z0-9_./-]+\.(?:rb|sh|py)})
  checks.concat(text.scan(/\btests\.([A-Za-z0-9_]+)\b/).flatten.map { |name| "tests/#{name}.py" })
  checks.uniq
end

# One check and everything it requires, so a document read by a shared support
# file is attributed to the check that loads it.
def check_closure(root, entry)
  pending = [entry]
  sources = []
  until pending.empty?
    relative = pending.shift
    next if sources.include?(relative)

    path = File.join(root, relative)
    next unless File.file?(path)

    sources << relative
    next unless relative.end_with?(".rb")

    File.read(path).scan(/require_relative\s+["']([^"']+)["']/).flatten.each do |target|
      resolved = File.expand_path(target, File.dirname(path))
      resolved += ".rb" unless resolved.end_with?(".rb")
      prefix = "#{root}/"
      pending << resolved.delete_prefix(prefix) if resolved.start_with?(prefix)
    end
  end
  sources
end

check_lanes = Hash.new { |lanes, check| lanes[check] = [] }
lane_check_text(POLICY_WORKFLOW, POLICY_MANIFEST).each do |lane, text|
  registered_checks(text).each { |check_path| check_lanes[check_path] << lane }
end

coupled_documents = Hash.new { |documents, name| documents[name] = [] }
globbing_checks = []
check_lanes.each do |check_path, lanes|
  next if ROUTING_SOURCES.include?(check_path)

  sources = check_closure(POLICY_DOC_ROOT, check_path).reject { |s| ROUTING_SOURCES.include?(s) }
  next if sources.empty?

  body = sources.map { |relative| File.read(File.join(POLICY_DOC_ROOT, relative)) }.join("\n")
  body.scan(DOCUMENT_REFERENCE_PATTERN).uniq.each do |document|
    next unless File.file?(File.join(POLICY_DOC_ROOT, document))

    coupled_documents[document] << [check_path, lanes]
  end
  globbing_checks << [check_path, lanes] if body.match?(DOCS_GLOB_PATTERN)
end

# A derivation that finds nothing would pass silently, which is the failure mode
# this whole check exists to end.
check(failures, coupled_documents.length >= 6,
      "the registered checks name only #{coupled_documents.length} existing documents; " \
      "the derivation is broken rather than the routing")
check(failures, !globbing_checks.empty?,
      "no registered check was seen to glob docs/, but tests/docs_links_test.rb does; " \
      "the derivation is blind to the half of the coupling that is not a literal")
# A derivation seeing only docs/ and README still clears the count floor, so require a
# root document (#346).
root_documents = coupled_documents.keys.grep_v(%r{/})
check(failures, root_documents.include?("CLAUDE.md"),
      "the registered checks name CLAUDE.md, but the derivation found the " \
      "repository-root documents #{root_documents.inspect}; it is blind to root " \
      "Markdown rather than the routing being complete")
if defined?(ClassifyChanges)
  coupled_documents.sort.each do |document, readers|
    selection = ClassifyChanges.classify([document])
    readers.each do |check_path, lanes|
      check(failures, lanes.any? { |lane| selection.fetch(lane) },
            "#{document} is read by #{check_path}, which runs in #{lanes.join(' and ')}, but " \
            "selects neither; route it in tests/ci/classify_changes.rb")
    end
  end

  # Unnamed documents, one nonexistent: the link gate globs docs/, so these must still reach it.
  %w[
    docs/superpowers/plans/2026-08-09-docs-only-ci-fast-path.md
    docs/superpowers/specs/2026-08-14-production-auto-deployment-design.md
    docs/no-check-will-ever-name-this.md
  ].each do |document|
    selection = ClassifyChanges.classify([document])
    globbing_checks.each do |check_path, lanes|
      check(failures, lanes.any? { |lane| selection.fetch(lane) },
            "#{document} is read by #{check_path}, which globs docs/, but selects none of " \
            "#{lanes.join(', ')}")
    end
  end
end

# ci.yml buys job coverage, not reader coverage (#395), derived from the workflow. Only each job's
# `needs.changes.outputs.*` terms are read: nothing else in an `if` is something a selection turns on.
GATING_OUTPUT_PATTERN = /needs\.changes\.outputs\.([A-Za-z0-9_]+)/
if defined?(ClassifyChanges)
  workflow_document = File.file?(POLICY_WORKFLOW) ? YAML.safe_load_file(POLICY_WORKFLOW, aliases: false) : {}
  workflow_jobs = workflow_document.fetch("jobs", {})
  routed_workflow_path = ClassifyChanges::CI_WORKFLOW_ROUTED_PATH
  workflow_selection = ClassifyChanges.classify([routed_workflow_path])
  gating_outputs = workflow_jobs.to_h do |job_name, job|
    [job_name, job.fetch("if", "").to_s.scan(GATING_OUTPUT_PATTERN).flatten.uniq]
  end
  # Floors rather than emptiness, as for the cross-lane derivation above.
  check(failures, workflow_jobs.length >= 6,
        "the workflow declares #{workflow_jobs.length} jobs, expected at least six: " \
        "the derivation has stopped reading it")
  distinct_gates = gating_outputs.values.flatten.uniq
  # Two rather than today's four, so retiring a job may lower it.
  check(failures, distinct_gates.length >= 2,
        "the workflow jobs are gated on #{distinct_gates.inspect}, expected at least two " \
        "distinct classifier outputs: the derivation has stopped reading the job gates")

  gating_outputs.each do |job_name, outputs|
    outputs.each do |output|
      enabled = if output == "suites"
                  !ClassifyChanges.suites(workflow_selection).empty?
                else
                  workflow_selection.key?(output) && workflow_selection.fetch(output)
                end
      check(failures, enabled,
            "the #{job_name} job is gated on needs.changes.outputs.#{output}, which a change to " \
            "#{routed_workflow_path} does not turn on: that job would never run against the " \
            "change that defines it. Route the lane in CI_WORKFLOW_JOB_LANES")
    end
  end

  routed_workflow_suites = ClassifyChanges.suites(workflow_selection)
  check(failures, !routed_workflow_suites.empty?,
        "#{routed_workflow_path} must dispatch at least one suite: no static check can prove " \
        "the suites job's steps still run on a runner")
  check(failures, routed_workflow_suites.length < ClassifyChanges::SUITES.length,
        "#{routed_workflow_path} still dispatches every suite, which is what #395 removed")
  # A service lane with no companion; workflow_test proves the matrix uniform, so one leg suffices.
  check(failures, ClassifyChanges::SERVICE_LANES.include?(ClassifyChanges::CI_WORKFLOW_SUITE_LANE),
        "#{ClassifyChanges::CI_WORKFLOW_SUITE_LANE.inspect} is no longer a service lane")
  check(failures, ClassifyChanges::COMPANION_LANES.fetch(ClassifyChanges::CI_WORKFLOW_SUITE_LANE, []).empty?,
        "#{ClassifyChanges::CI_WORKFLOW_SUITE_LANE.inspect} now carries a companion lane; pick a " \
        "cheaper representative or accept the extra leg deliberately")
  # `foundation` would empty selected_tags and converge the whole site on the idempotence leg.
  check(failures, !workflow_selection.fetch("foundation"),
        "#{routed_workflow_path} must not select the foundation lane: it empties selected_tags")
  workflow_outputs = StringIO.new
  ClassifyChanges.write_github_outputs(workflow_selection, workflow_outputs)
  workflow_tags = workflow_outputs.string[/^selected_tags=(.*)$/, 1].to_s
  check(failures, !workflow_tags.empty?,
        "#{routed_workflow_path} must select tags for its suite legs, or the idempotence_check leg converges " \
        "the whole site rather than the representative stack")
end

report(failures, "changed-path classifier: all checks passed",
       "changed-path classifier failure(s)")
