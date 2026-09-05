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
LANES = %w[
  static docs reconciliation foundation arr downloaders bindery kapowarr pinchflat trailarr seerr
  smoke beszel dozzle audiobookshelf komga jellyfin immich paperless idempotence_check
].freeze
ACQUISITION_LANES = %w[arr downloaders bindery kapowarr pinchflat trailarr seerr].freeze
# The lanes the media acquisition reconciliation contract reads, and the four
# files it owns. Both are stated here rather than imported so that widening the
# classifier's own list is a failure here rather than a silent change of scope.
RECONCILIATION_LANES = %w[arr downloaders].freeze
# The lane a selected lane cannot prove its subject without. Stated here for the
# same reason: the downloaders lane converges the Usenet provider undeclared and
# the bindery lane converges it declared, each asserting one branch of
# roles/downloaders/tasks/verify.yml, so anything selecting the first has to
# select the second or a branch is routed to no runtime lane at all. The seerr
# row is the other shape: the seerr lane is the only one converging arr and
# Jellyfin together, and it consumes Jellyfin's *converged* state -- its
# bootstrap POSTs the vault Jellyfin administrator to `/auth/jellyfin` inside
# the anonymous-takeover window, and its verify reads `/settings/jellyfin` and
# the managed-user roster -- so the jellyfin lane cannot see what a Jellyfin
# change broke (#349). Widening this in the classifier must fail here.
COMPANION_LANES = { "downloaders" => %w[bindery], "jellyfin" => %w[seerr] }.freeze
# The tags every tagged lane carries to converge the shared inert foundation and
# the alerting sink. They are not lane dependencies: host_prep and
# deployment_bundle already fall open to every lane, and ntfy is routed by
# NTFY_LANES, both pinned above. The cross-lane derivation below skips them for
# that reason rather than for convenience.
SHARED_TAGS = %w[host_prep deployment_bundle ntfy].freeze
# The cross-lane dependencies visible in tests/ci/suites.conf that are
# deliberately *not* routed, with the reason. #349 asked the question and this is
# the answer: the arr lane converges and asserts arr's own state and the
# reconciliation job re-asserts it against a fixture, and the four lanes that
# read arr do so over its stable HTTP API rather than through a one-shot
# handshake, so four more acquisition lanes on every arr change buys little. A
# row here is a decision someone has to re-take, not a gap that can be inherited
# silently; a row naming a pair the suite table no longer shows fails below.
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
# The alerting sink is deployed by every lane that carries the ntfy tag and by
# no other. Stated rather than imported for the same reason: widening the
# classifier's own list must fail here.
NTFY_LANES = %w[
  static reconciliation arr downloaders bindery kapowarr pinchflat trailarr seerr smoke
  beszel dozzle audiobookshelf komga jellyfin immich paperless idempotence_check
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

# A selection is returned in LANES order, and a companion lane need not sit
# beside the lane that pulled it in -- `seerr` precedes `smoke`, which every
# service lane also selects. Building an expectation by concatenation is how that
# produces a wrong list rather than a wrong-looking one, so expectations assembled
# from parts are ordered here instead.
def canonical(lanes)
  lanes.uniq.sort_by { |lane| LANES.index(lane) }
end

if defined?(ClassifyChanges)
  {
    ["docs/getting-started.md"] => %w[static docs],
    ["docs/bazarr-providers.md"] => %w[static docs],
    ["docs/media-acquisition-phase1.md"] => %w[static docs],
    # The regression #190 names: a document no registered check spells out is
    # still read by the link gate's glob, so it has to reach the job that runs it
    # instead of reaching no job at all.
    ["docs/superpowers/plans/2026-08-09-docs-only-ci-fast-path.md"] => %w[docs],
    ["docs/no-check-reads-this.md"] => %w[docs],
    ["docs/img/topology.png"] => %w[docs],
    # Not inert: tests/policy_beszel_test.rb and tests/policy_ci_test.rb both
    # read it, so it reaches the job that runs them rather than no job at all.
    [".gitignore"] => %w[static],
    ["LICENSE"] => [],
    ["README.md"] => %w[static docs],
    # The regression #346 names. tests/policy_test.rb reads CLAUDE.md in `static`
    # and tests/docs_links_test.rb reads it in both jobs, so it routes exactly as
    # README.md does; before the fix it matched no lane map and was classified
    # inert, and a change to the lane roster it documents selected nothing at all.
    ["CLAUDE.md"] => %w[static docs],
    ["docs/getting-started-nas.md"] => %w[static docs],
    # Only tests/secrets_docs_test.rb reads it, and the docs job runs that, so the
    # secrets guide no longer pays for the whole policy gate.
    ["docs/secrets.md"] => %w[docs],
    ["roles/paperless_ngx/tasks/main.yml"] => %w[static smoke paperless idempotence_check],
    ["services/dozzle/compose.yml"] => %w[static smoke dozzle idempotence_check],
    # Plus seerr: the seerr lane is the only one that converges Jellyfin
    # alongside arr and it signs in to Jellyfin as the vault administrator, so a
    # Jellyfin change has to reach it.
    ["tests/contracts/jellyfin.sh"] => %w[static seerr smoke jellyfin idempotence_check],
    ["roles/arr/tasks/main.yml"] => %w[static reconciliation arr idempotence_check],
    # Plus bindery: the downloaders lane converges the Usenet provider
    # undeclared now, so the lane that converges it declared has to come with it.
    ["services/downloaders/compose.yml"] =>
      %w[static reconciliation downloaders bindery idempotence_check],
    ["tests/expected/bindery.yml"] => %w[static bindery idempotence_check],
    ["tests/contracts/kapowarr-foundation.sh"] => %w[static kapowarr idempotence_check],
    ["tests/media_control_network_collision_test.sh"] => %w[static reconciliation arr idempotence_check],
    ["config/media-acquisition.yml"] => %w[static reconciliation arr downloaders bindery kapowarr pinchflat trailarr seerr idempotence_check],
    ["roles/host_prep/tasks/verify_media_acquisition.yml"] => %w[static reconciliation arr downloaders bindery kapowarr pinchflat trailarr seerr idempotence_check],
    ["roles/deployment_bundle/tasks/main.yml"] => LANES,
    ["tests/policy_test.rb"] => %w[static],
    ["tests/validate-policy.sh"] => %w[static],
    ["tests/ci/workflow_test.rb"] => %w[static],
    ["tests/expected/beszel.yml"] => %w[static],
    ["renovate.json"] => %w[static],
    ["generate-secrets.yml"] => %w[static],
    ["templates/vault-plain.yml.j2"] => %w[static],
    # tests/integration.sh installs the sandbox vault over this path, so no suite
    # reads the committed one; tests/policy_vault_test.rb is the only check that
    # opens it, and the policy gate is where that runs.
    ["inventory/group_vars/all/vault.yml"] => %w[static],
    ["install-production-auto-deploy.yml"] => %w[static],
    ["roles/production_auto_deploy/tasks/main.yml"] => %w[static],
    ["roles/image_prune/templates/config.json.j2"] => %w[static],
    ["scripts/production_auto_deploy.py"] => %w[static],
    ["tests/media_acquisition_foundation_test.rb"] =>
      ["static", "reconciliation", *ACQUISITION_LANES, "idempotence_check"],
    ["roles/ntfy/tasks/main.yml"] => NTFY_LANES,
    ["services/ntfy/compose.yml"] => NTFY_LANES,
    ["unexpected/new-runtime-file"] => LANES
  }.each do |paths, expected|
    check(failures, selected_lanes(paths) == expected,
          "#{paths.join(', ')} selected #{selected_lanes(paths).inspect}, expected #{expected.inspect}")
  end

  ACQUISITION_LANES.each do |project|
    [
      "roles/#{project}/tasks/main.yml",
      "services/#{project}/compose.yml",
      "tests/expected/#{project}.yml",
      "tests/contracts/#{project}-foundation.sh"
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

  # The contract's own files are read by no play and by no integration suite, so
  # they select the contract and the policy gate that carries them as fixtures --
  # not the whole repository, which is what they used to fall open to.
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
    "paperless-ngx" => %w[paperless]
  }.each do |service, expected_service_lanes|
    role = service == "paperless-ngx" ? "paperless_ngx" : service
    contract = service == "paperless-ngx" ? "paperless" : service
    [
      "roles/#{role}/tasks/main.yml",
      "services/#{service}/compose.yml",
      "tests/contracts/#{contract}.sh"
    ].each do |path|
      companions = expected_service_lanes.flat_map { |lane| COMPANION_LANES.fetch(lane, []) }
      expected = canonical(%w[static smoke] + expected_service_lanes + companions +
                           %w[idempotence_check])
      check(failures, selected_lanes([path]) == expected,
            "#{path} selected #{selected_lanes([path]).inspect}, expected #{expected.inspect}")
    end
  end

  check(failures, selected_lanes(["roles/beszel/tasks/main.yml", "services/dozzle/compose.yml"]) ==
                  %w[static smoke beszel dozzle idempotence_check],
        "multiple service changes must combine service lanes in canonical order")
  check(
    failures,
    selected_lanes([
      "roles/komga/tasks/main.yml",
      "services/jellyfin/compose.yml",
      "tests/contracts/immich.sh"
    ]) == %w[static seerr smoke komga jellyfin immich idempotence_check],
    "multiple media service changes must combine canonically, each carrying its own companion"
  )

  # The one #349 names, stated as a path rather than as a table row.
  check(failures, selected_lanes(["roles/jellyfin/tasks/main.yml"]).include?("seerr"),
        "a Jellyfin change must select the seerr lane, the only one that converges arr and " \
        "Jellyfin together and the only one that signs in to Jellyfin as the vault administrator")

  # The dependency COMPANION_LANES encodes is already written down in
  # tests/ci/suites.conf: a lane whose tags name another lane converges that
  # lane's role, so a change to that role can break this lane while the role's own
  # lane converges nothing that would notice. Deriving the pairs from the suite
  # table -- rather than pinning the single pair #349 named -- is what makes the
  # next cross-lane dependency have to be *declared*: routed in COMPANION_LANES,
  # or declined by name with a reason. A lane added to suites.conf whose tags name
  # a role fails here on the day it lands.
  cross_lane_pairs = ClassifyChanges::TAGGED_LANES.flat_map do |consumer|
    ClassifyChanges::SERVICE_TAGS.fetch(consumer)
                                 .reject { |tag| SHARED_TAGS.include?(tag) || tag == consumer }
                                 .select { |tag| LANES.include?(tag) }
                                 .map { |producer| [producer, consumer] }
  end
  routed_pairs, undeclared_pairs = cross_lane_pairs.partition do |producer, consumer|
    COMPANION_LANES.fetch(producer, []).include?(consumer)
  end
  # A floor rather than non-emptiness: a derivation that stops reading the tags
  # column examines nothing and reports every dependency routed. The floor is two
  # rather than today's six deliberately -- retiring a lane is allowed to lower
  # the count, and DECLINED_COMPANIONS below reports that case by name.
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
  check(failures, selected_lanes([], full: true) == LANES,
        "full events must select every lane")
  check(failures, selected_lanes(["AGENTS.md"]) == LANES,
        "AGENTS.md must not be treated as inert Markdown")
  # The rule that exemption used to be a single name for. A document at the
  # repository root is where a check-read claim lands -- CLAUDE.md was one, and
  # was called inert for it (#346) -- so root Markdown no lane map claims falls
  # open to every lane rather than to none.
  check(failures, selected_lanes(["NOTES.md"]) == LANES,
        "unrouted repository-root Markdown must not be treated as inert")
  check(failures, selected_lanes(["tests/fixtures/operator-guide.md"]) == LANES,
        "test fixture Markdown must not be treated as inert")

  # Routing a path under tests/ to the policy gate alone is only safe while no
  # integration suite reads it, and the harness reaches well past its own file:
  # tests/integration.sh runs the contracts, and those read document fixtures,
  # Mac drift hooks and shared Ruby support. Walking that reference closure --
  # rather than restating it -- is what makes a new harness file fail here on the
  # day it is added instead of silently skipping every suite it belongs to.
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
    "roles/beszel/tasks/main.yml" => "host_prep,deployment_bundle,ntfy,beszel",
    "roles/dozzle/tasks/main.yml" => "host_prep,deployment_bundle,ntfy,dozzle",
    "roles/audiobookshelf/tasks/main.yml" => "host_prep,deployment_bundle,ntfy,audiobookshelf",
    "roles/komga/tasks/main.yml" => "host_prep,deployment_bundle,ntfy,komga",
    # The seerr lane comes first in suites.conf row order and its tags are a
    # superset of Jellyfin's own, so the Jellyfin plan is Seerr's plan.
    "roles/jellyfin/tasks/main.yml" => "host_prep,deployment_bundle,ntfy,arr,jellyfin,seerr",
    "roles/immich/tasks/main.yml" => "host_prep,deployment_bundle,ntfy,immich",
    "roles/paperless_ngx/tasks/main.yml" => "host_prep,deployment_bundle,ntfy,paperless"
  }.each do |path, expected_tags|
    service_output = StringIO.new
    ClassifyChanges.write_github_outputs(ClassifyChanges.classify([path]), service_output)
    check(failures, service_output.string.end_with?("selected_tags=#{expected_tags}\n"),
          "#{path} emitted the wrong prerequisite tag plan: #{service_output.string.inspect}")
  end

  io = StringIO.new
  ClassifyChanges.write_github_outputs(
    ClassifyChanges.classify(%w[roles/beszel/tasks/main.yml services/dozzle/compose.yml]), io
  )
  expected_output = <<~OUTPUT
    static=true
    docs=false
    reconciliation=false
    foundation=false
    arr=false
    downloaders=false
    bindery=false
    kapowarr=false
    pinchflat=false
    trailarr=false
    seerr=false
    smoke=true
    beszel=true
    dozzle=true
    audiobookshelf=false
    komga=false
    jellyfin=false
    immich=false
    paperless=false
    idempotence_check=true
    suites=["smoke","beszel","dozzle","idempotence-check"]
    selected_tags=host_prep,deployment_bundle,ntfy,beszel,dozzle
  OUTPUT
  check(failures, io.string == expected_output,
        "GitHub output or prerequisite tag ordering was incorrect: #{io.string.inspect}")

  full_output = StringIO.new
  ClassifyChanges.write_github_outputs(ClassifyChanges.classify([], full: true), full_output)
  expected_full_output = <<~OUTPUT
    static=true
    docs=true
    reconciliation=true
    foundation=true
    arr=true
    downloaders=true
    bindery=true
    kapowarr=true
    pinchflat=true
    trailarr=true
    seerr=true
    smoke=true
    beszel=true
    dozzle=true
    audiobookshelf=true
    komga=true
    jellyfin=true
    immich=true
    paperless=true
    idempotence_check=true
    suites=["foundation","arr","downloaders","bindery","kapowarr","pinchflat","trailarr","seerr","smoke","beszel","dozzle","audiobookshelf","komga","jellyfin","immich","paperless","idempotence-check"]
    selected_tags=
  OUTPUT
  check(failures, full_output.string == expected_full_output,
        "--full output must leave selected_tags empty: #{full_output.string.inspect}")

  shared_output = StringIO.new
  ClassifyChanges.write_github_outputs(
    ClassifyChanges.classify(["roles/deployment_bundle/tasks/main.yml"]), shared_output
  )
  check(failures, shared_output.string == expected_full_output,
        "shared-scope output must select the full untagged site: #{shared_output.string.inspect}")

  unknown_output = StringIO.new
  ClassifyChanges.write_github_outputs(
    ClassifyChanges.classify(["unexpected/new-runtime-file"]), unknown_output
  )
  check(failures, unknown_output.string == expected_full_output,
        "unknown-path output must select the full untagged site: #{unknown_output.string.inspect}")

  paperless_output = StringIO.new
  ClassifyChanges.write_github_outputs(
    ClassifyChanges.classify(["roles/paperless_ngx/tasks/main.yml"]), paperless_output
  )
  check(failures, paperless_output.string == <<~OUTPUT,
    static=true
    docs=false
    reconciliation=false
    foundation=false
    arr=false
    downloaders=false
    bindery=false
    kapowarr=false
    pinchflat=false
    trailarr=false
    seerr=false
    smoke=true
    beszel=false
    dozzle=false
    audiobookshelf=false
    komga=false
    jellyfin=false
    immich=false
    paperless=true
    idempotence_check=true
    suites=["smoke","paperless","idempotence-check"]
    selected_tags=host_prep,deployment_bundle,ntfy,paperless
  OUTPUT
        "Paperless-only output must retain its exact tag plan: #{paperless_output.string.inspect}")

  # Bindery, Kapowarr and Pinchflat are the implemented acquisition projects
  # outside Phase 1. Each lane converges its own role rather than the shared
  # inert foundation, and Bindery is the only one of the three that also
  # converges Arr and the downloaders: it stores a Prowlarr instance and a
  # SABnzbd download client, and it resolves the host in both URLs at write
  # time, so neither row can be written unless both are running.
  bindery_output = StringIO.new
  ClassifyChanges.write_github_outputs(
    ClassifyChanges.classify(["roles/bindery/tasks/main.yml"]), bindery_output
  )
  check(failures, bindery_output.string == <<~OUTPUT,
    static=true
    docs=false
    reconciliation=false
    foundation=false
    arr=false
    downloaders=false
    bindery=true
    kapowarr=false
    pinchflat=false
    trailarr=false
    seerr=false
    smoke=false
    beszel=false
    dozzle=false
    audiobookshelf=false
    komga=false
    jellyfin=false
    immich=false
    paperless=false
    idempotence_check=true
    suites=["bindery","idempotence-check"]
    selected_tags=host_prep,deployment_bundle,ntfy,arr,downloaders,bindery
  OUTPUT
        "Bindery-only output must retain its exact tag plan: #{bindery_output.string.inspect}")

  kapowarr_output = StringIO.new
  ClassifyChanges.write_github_outputs(
    ClassifyChanges.classify(["roles/kapowarr/tasks/main.yml"]), kapowarr_output
  )
  check(failures, kapowarr_output.string == <<~OUTPUT,
    static=true
    docs=false
    reconciliation=false
    foundation=false
    arr=false
    downloaders=false
    bindery=false
    kapowarr=true
    pinchflat=false
    trailarr=false
    seerr=false
    smoke=false
    beszel=false
    dozzle=false
    audiobookshelf=false
    komga=false
    jellyfin=false
    immich=false
    paperless=false
    idempotence_check=true
    suites=["kapowarr","idempotence-check"]
    selected_tags=host_prep,deployment_bundle,ntfy,kapowarr
  OUTPUT
        "Kapowarr-only output must retain its exact tag plan: #{kapowarr_output.string.inspect}")

  pinchflat_output = StringIO.new
  ClassifyChanges.write_github_outputs(
    ClassifyChanges.classify(["roles/pinchflat/tasks/main.yml"]), pinchflat_output
  )
  check(failures, pinchflat_output.string == <<~OUTPUT,
    static=true
    docs=false
    reconciliation=false
    foundation=false
    arr=false
    downloaders=false
    bindery=false
    kapowarr=false
    pinchflat=true
    trailarr=false
    seerr=false
    smoke=false
    beszel=false
    dozzle=false
    audiobookshelf=false
    komga=false
    jellyfin=false
    immich=false
    paperless=false
    idempotence_check=true
    suites=["pinchflat","idempotence-check"]
    selected_tags=host_prep,deployment_bundle,ntfy,pinchflat
  OUTPUT
        "Pinchflat-only output must retain its exact tag plan: #{pinchflat_output.string.inspect}")

  # Trailarr is Phase 3 and is the only lane that converges Arr without also
  # converging the downloaders: it reads Radarr and Sonarr over their own APIs
  # and validates every connection it declares with a live call at write time,
  # but it acquires nothing itself and needs no download client.
  trailarr_output = StringIO.new
  ClassifyChanges.write_github_outputs(
    ClassifyChanges.classify(["roles/trailarr/tasks/main.yml"]), trailarr_output
  )
  check(failures, trailarr_output.string == <<~OUTPUT,
    static=true
    docs=false
    reconciliation=false
    foundation=false
    arr=false
    downloaders=false
    bindery=false
    kapowarr=false
    pinchflat=false
    trailarr=true
    seerr=false
    smoke=false
    beszel=false
    dozzle=false
    audiobookshelf=false
    komga=false
    jellyfin=false
    immich=false
    paperless=false
    idempotence_check=true
    suites=["trailarr","idempotence-check"]
    selected_tags=host_prep,deployment_bundle,ntfy,arr,trailarr
  OUTPUT
        "Trailarr-only output must retain its exact tag plan: #{trailarr_output.string.inspect}")

  # Seerr is Phase 4 and the only lane that converges Arr and Jellyfin
  # together: it declares Radarr's and Sonarr's connection rows and imports
  # Jellyfin's users, and its bootstrap signs in to Jellyfin as the vault
  # administrator.
  seerr_output = StringIO.new
  ClassifyChanges.write_github_outputs(
    ClassifyChanges.classify(["roles/seerr/tasks/main.yml"]), seerr_output
  )
  check(failures, seerr_output.string == <<~OUTPUT,
    static=true
    docs=false
    reconciliation=false
    foundation=false
    arr=false
    downloaders=false
    bindery=false
    kapowarr=false
    pinchflat=false
    trailarr=false
    seerr=true
    smoke=false
    beszel=false
    dozzle=false
    audiobookshelf=false
    komga=false
    jellyfin=false
    immich=false
    paperless=false
    idempotence_check=true
    suites=["seerr","idempotence-check"]
    selected_tags=host_prep,deployment_bundle,ntfy,arr,jellyfin,seerr
  OUTPUT
        "Seerr-only output must retain its exact tag plan: #{seerr_output.string.inspect}")

  io = StringIO.new
  ClassifyChanges.write_github_outputs(ClassifyChanges.classify(["README.md"]), io)
  check(failures, io.string.start_with?("static=true\ndocs=true\n"),
        "the README is read by the policy set and by the link gate, so it must select both")
  check(failures, io.string.end_with?("suites=[]\nselected_tags=\n"),
        "protected operator docs must select static CI and emit empty selected_tags")
  # The CI matrix job skips on exactly this literal, so it has to stay compact.
  check(failures, io.string.include?("suites=[]\n"),
        "protected operator docs must emit an empty suite array: #{io.string.inspect}")

  check(failures, ClassifyChanges::SUITES.keys == ClassifyChanges::LANES - ClassifyChanges::JOB_LANES,
        "every lane but the job lanes must map to exactly one integration suite")
  check(failures, ClassifyChanges::JOB_LANES == %w[static docs reconciliation],
        "static, docs and reconciliation are the only lanes that gate a job instead of a suite")
  check(failures,
        ClassifyChanges.suites(ClassifyChanges.classify(["roles/beszel/tasks/main.yml"])) ==
          %w[smoke beszel idempotence-check],
        "a Beszel-only change must dispatch smoke, beszel and idempotence-check")
  check(failures,
        ClassifyChanges.suites(ClassifyChanges.classify(["roles/arr/tasks/main.yml"])) ==
          %w[arr idempotence-check],
        "an Arr-only change must dispatch its foundation suite without smoke")

  # No lane emits the inert foundation tag plan any more: Phase 4 promoted the
  # last planned acquisition project. A foundation contract now routes to its
  # own project's lane, and Seerr's is the lane that carries the shared
  # foundation's runtime proof on top of its own service.
  acquisition_output = StringIO.new
  ClassifyChanges.write_github_outputs(
    ClassifyChanges.classify(["tests/contracts/seerr-foundation.sh"]), acquisition_output
  )
  check(failures,
        acquisition_output.string.end_with?(
          "selected_tags=host_prep,deployment_bundle,ntfy,arr,jellyfin,seerr\n"
        ),
        "an acquisition foundation contract must route to its own project's lane")
  check(failures, !acquisition_output.string.downcase.include?("tmm"),
        "classifier outputs must not resurrect the retired tMM project")

  Dir.mktmpdir("classify-changes-git-") do |root|
    system("git", "init", "-q", root, exception: true)
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
    system("git", "init", "-q", root, exception: true)
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

# How a push to main is classified is decided in shell, in the workflow's own
# classify step, and it is the half of the routing that says whether a merge costs
# the 202 runner-minutes a full sweep took or the handful its own diff is worth.
# The step's `run:` block is lifted out of the workflow and executed against
# synthetic histories rather than reimplemented here, so a rewrite that quietly
# returns to sweeping -- or, worse, one that classifies nothing and lets every job
# skip into a green run that tested nothing -- fails here rather than on main.
CI_WORKFLOW_PATH = File.expand_path("../../.github/workflows/ci.yml", __dir__)
CLASSIFY_STEP = begin
  steps = YAML.safe_load_file(CI_WORKFLOW_PATH).dig("jobs", "changes", "steps")
  step = Array(steps).find { |candidate| candidate.is_a?(Hash) && candidate["id"] == "classify" }
  step && step["run"].to_s
end

# A repository the classifier can run inside: it needs its own script and the suite
# table beside it, committed first so they never appear in a diff under test.
def init_push_repository(root)
  system("git", "init", "-q", root, exception: true)
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
    before = push_commit(root, "roles/dozzle/tasks/main.yml")
    push_commit(root, "roles/beszel/tasks/main.yml")
    status, output, stderr = classify_push(root, before)
    lanes = push_lanes(output)
    check(failures, status.success?, "a squash merge must classify cleanly: #{stderr.inspect}")
    check(failures, lanes.include?("beszel") && !lanes.include?("dozzle"),
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

  # The two pushes with no usable `before`: a ref reported as all zeros, and a
  # force push naming a commit this clone never fetched. Both fall back to HEAD^,
  # which still classifies rather than sweeping.
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

  # Nothing to diff against at all. Routing fails open, so this must reach `--full`
  # and select every lane -- never an empty selection, which would skip every job
  # and conclude the run green having tested nothing.
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

# Every document a registered check reads is a CI input, and until the docs job
# existed inert_path? dropped all of docs/, so such a document reached no job at
# all unless STATIC_ONLY_PATHS rescued it by name. That is how a documentation
# commit broke the policy gate on main and still merged green: the gate was never
# run against it.
#
# Rescuing by name only ever covered the documents a check spells out.
# tests/docs_links_test.rb reads README.md and every *.md under docs/ through a
# glob, so the earlier form of this guard -- collect the literals, require each to
# select `static` -- reported the hole as closed while a broken link under
# docs/superpowers/plans/ still merged green. Both halves are derived below: the
# literals a check names, and whether it globs the directory.
#
# What is asserted is coverage, not a fixed job. A document must select at least
# one job that runs each check reading it, which is what lets a plan document
# select the cheap docs job while docs/getting-started.md still selects `static`,
# because tests/policy_test.rb reads it and tests/policy_test.rb is the gate.
POLICY_DOC_ROOT = File.expand_path("../..", __dir__)
POLICY_MANIFEST = File.join(POLICY_DOC_ROOT, "tests", "validate-policy.sh")
POLICY_WORKFLOW = File.join(POLICY_DOC_ROOT, ".github", "workflows", "ci.yml")
# The routing and its own fixtures name documents in order to route them, not
# because they read them. Counting them as readers would make this guard assert
# whatever the routing already says -- and would make the regression fixture
# above demand the very job it proves is no longer needed.
ROUTING_SOURCES = %w[
  tests/ci/classify_changes.rb
  tests/ci/classify_changes_test.rb
  tests/ci/workflow_test.rb
].freeze
# How tests/docs_links_test.rb spells "all of docs/". A check that stops globbing
# is not a failure; a derivation that stops seeing the glob is, which is what the
# emptiness check below says.
DOCS_GLOB_PATTERN = %r{docs/\*\*|"docs"\)\s*\.glob\(}
# Every document a registered check names by path. The root alternative is the
# half #346 cost: the pattern knew `docs/...` and README, so CLAUDE.md could
# never enter coupled_documents however many checks read it by name, and the
# guard reported the routing whole while that document reached no job. The
# lookbehind is what keeps `docs/plans/notes.md` from also being counted as a
# root `notes.md`; a name that matches but does not exist is dropped below.
DOCUMENT_REFERENCE_PATTERN = %r{(?<![\w./-])(?:docs/[A-Za-z0-9_./-]+|[A-Za-z0-9_-]+)\.md}

# The checks each classifier lane runs. The mutation harness is gated on the same
# `static` output as the gate, so a check it carries is a `static` input like any
# other; the docs job is gated on `docs`.
def lane_check_text(workflow_path, manifest_path)
  workflow = File.file?(workflow_path) ? YAML.safe_load_file(workflow_path, aliases: false) : {}
  jobs = workflow.fetch("jobs", {})
  runs = lambda do |job|
    Array(jobs.dig(job, "steps")).filter_map { |step| step["run"] if step.is_a?(Hash) }.join("\n")
  end
  manifest = File.file?(manifest_path) ? File.read(manifest_path) : ""
  {
    "static" => [manifest, runs.call("static"), runs.call("mutation")].join("\n"),
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
# The third health assertion, and the one #346 was closed by. Counting documents
# cannot say which kind was found: a derivation that has gone back to seeing only
# docs/ and README still counts well past its floor while every repository-root
# document is invisible again, which is the state that let CLAUDE.md route
# nowhere for as long as it did.
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

  # The half a list of literals cannot see. These documents exist in no check's
  # source, and one of them does not exist at all -- which is the point: the link
  # gate reads whatever is under docs/ on the day it runs, so an unnamed document
  # still has to reach the job that runs it.
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

report(failures, "changed-path classifier: all checks passed",
       "changed-path classifier failure(s)")
