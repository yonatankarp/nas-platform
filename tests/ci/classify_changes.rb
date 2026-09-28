#!/usr/bin/env ruby

require "json"
require "open3"

module ClassifyChanges
  # tests/ci/suites.conf is the one suite table; tests/integration.sh reads the same rows.
  SUITE_TABLE_PATH = File.expand_path("suites.conf", __dir__)
  SUITE_TABLE = File.readlines(SUITE_TABLE_PATH, chomp: true).filter_map do |line|
    fields = line.sub(/#.*/, "").split
    next if fields.empty?
    raise "malformed row in #{SUITE_TABLE_PATH}: #{line.inspect}" unless fields.length == 3

    suite, kind, tags = fields
    [suite, kind, tags == "-" ? [] : tags.split(",")]
  end.freeze
  # Lanes that gate a workflow job of their own rather than dispatch a suite.
  JOB_LANES = %w[static docs vault reconciliation].freeze
  # `harness` rows (full, smoke) are suites no CI lane dispatches (#832). A lane is its suite
  # with hyphens as underscores, because a lane is also a GitHub Actions output key.
  CI_SUITE_ROWS = SUITE_TABLE.reject { |_suite, kind, _tags| kind == "harness" }.freeze
  # The suite each lane dispatches, in CI matrix order.
  SUITES = CI_SUITE_ROWS.to_h { |suite, _kind, _tags| [suite.tr("-", "_"), suite] }.freeze
  LANES = (JOB_LANES + SUITES.keys).freeze
  SERVICE_LANES = CI_SUITE_ROWS.filter_map do |suite, kind, _tags|
    suite.tr("-", "_") if kind == "service"
  end.freeze
  ACQUISITION_LANES = CI_SUITE_ROWS.filter_map do |suite, kind, _tags|
    suite.tr("-", "_") if kind == "acquisition"
  end.freeze
  TAGGED_LANES = (ACQUISITION_LANES + SERVICE_LANES).freeze
  # The unsharded idempotence lane and its shards: a selection takes one form, never both.
  # `--full` keeps the single pass, the only whole-site idempotence proof; a fall-open takes the shards.
  IDEMPOTENCE_LANE = "idempotence_check"
  IDEMPOTENCE_SHARD_LANES = SUITES.keys.filter do |lane|
    lane.start_with?("idempotence_") && lane != IDEMPOTENCE_LANE
  end.freeze
  # Needs a BASE revision, so only --diff can select it.
  UPGRADE_LANE = "upgrade"
  # Derived from which services carry tests/contracts/<svc>-upgrade.rb, the rule
  # tests/integration.sh applies too.
  UPGRADE_SUBJECTS = Dir.glob(File.expand_path("../contracts/*-upgrade.rb", __dir__))
                        .map { |path| File.basename(path, ".rb").delete_suffix("-upgrade") }
                        .sort.freeze
  # The tags CI narrows the site to for each tagged lane.
  SERVICE_TAGS = CI_SUITE_ROWS.filter_map do |suite, kind, tags|
    [suite.tr("-", "_"), tags] if %w[acquisition service].include?(kind)
  end.to_h.freeze
  SERVICE_NAMES = {
    "arr" => %w[arr],
    "downloaders" => %w[downloaders],
    "bindery" => %w[bindery],
    "kapowarr" => %w[kapowarr],
    "pinchflat" => %w[pinchflat],
    "trailarr" => %w[trailarr],
    "seerr" => %w[seerr],
    "beszel" => %w[beszel],
    "dozzle" => %w[dozzle],
    "audiobookshelf" => %w[audiobookshelf],
    "komga" => %w[komga],
    "jellyfin" => %w[jellyfin],
    "immich" => %w[immich],
    "paperless" => %w[paperless paperless-ngx paperless_ngx],
    "nextcloud" => %w[nextcloud],
    "vaultwarden" => %w[vaultwarden],
    "karakeep" => %w[karakeep]
  }.freeze
  # Paths only the policy gate reads. The auto-deploy play and roles and the vault generator are
  # unreachable from site.yml and the suites (which install their own sandbox vault). vault.yml stays
  # listed so re-adding it reaches the check that refuses it (#612). Each document is read by name by a
  # static-only check, which classify_changes_test derives; the 2026-08-05 plan is here because
  # tests/dozzle_exit_code_exclusion_identity_test.rb's owner count depends on it staying historical.
  STATIC_ONLY_PATHS = %w[
    .gitignore
    CLAUDE.md
    README.md
    docs/adding-a-service.md
    docs/ansible-basics.md
    docs/asustor-adm-rollout.md
    docs/bazarr-providers.md
    docs/ci-performance-history.md
    docs/getting-started-mac.md
    docs/getting-started-nas.md
    docs/getting-started.md
    docs/host-cleanup.md
    docs/incident-history.md
    docs/media-acquisition-phase1.md
    docs/superpowers/plans/2026-08-05-mac-platform-proof.md
    generate-secrets.yml
    install-production-auto-deploy.yml
    inventory/group_vars/all/vault.yml
    renovate.json
    templates/vault-plain.yml.j2
  ].freeze
  # tests/docs_links_test.rb reads CLAUDE.md, README.md and every docs/ Markdown (and their link
  # targets), so the whole directory selects the cheap docs job.
  DOCUMENTATION_PATHS = %w[CLAUDE.md README.md].freeze
  DOCUMENTATION_PREFIXES = %w[docs/].freeze
  STATIC_ONLY_PREFIXES = %w[
    roles/image_prune/
    roles/production_auto_deploy/
    scripts/
  ].freeze
  # Files tests/integration.sh executes; they fall open. Everything else under tests/ selects the
  # gate alone. classify_changes_test asserts this list against what the harness invokes.
  INTEGRATION_HARNESS_PATHS = %w[
    tests/assert-no-vault-secrets.rb
    tests/ci/suites.conf
    tests/generate-ephemeral-vault.sh
    tests/integration.Dockerfile
    tests/integration.sh
    tests/integration_controller.sh
    tests/integration_controller_lib.sh
    tests/integration_lock.sh
    tests/mac/generate-immich-fixture-vars.rb
    tests/mac/snapshot-paperless-test.rb
    tests/mac/snapshot-paperless.rb
    tests/mac/snapshot-paperless.sh
    tests/mac_inventory_path_test.yml
    tests/nas_storage_support.rb
    tests/policy_support.rb
    tests/run_contracts.rb
    tests/sandbox_cleanup.sh
    tests/sandbox_cleanup_contents.py
    tests/verify_deployment_manifest.rb
  ].freeze
  # The contracts a suite runs, the document fixtures they upload and the Mac
  # hooks they read as the definition of a drifted service.
  INTEGRATION_HARNESS_PREFIXES = %w[
    tests/contracts/
    tests/fixtures/
    tests/mac/hooks/
  ].freeze
  ACQUISITION_SHARED_PATHS = %w[
    config/media-acquisition.yml
    roles/host_prep/tasks/verify_media_acquisition.yml
    tests/media_acquisition_foundation_test.rb
    tests/media_acquisition_foundation_verifier_test.rb
  ].freeze
  ACQUISITION_OWNED_PATHS = {
    "tests/media_control_network_collision_test.sh" => "arr"
  }.freeze
  # The reconciliation contract lifts task files and defaults out of these roles, so any change
  # inside either selects it without a per-file edit.
  RECONCILIATION_LANES = %w[arr downloaders].freeze
  # A lane, and the lane its subject is not fully proved without. Two shapes:
  # - one role, two states no single sandbox reaches: downloaders converges an undeclared Usenet
  #   provider (#274), bindery a declared one; only dozzle exercises beszel's stored webhook.
  # - a lane consuming another role's converged state: seerr claims its admin through Jellyfin (#349),
  #   bindery mints an Audiobookshelf API key. Arr rows are declined; classify_changes_test says why.
  COMPANION_LANES = {
    "beszel" => %w[dozzle],
    "downloaders" => %w[bindery],
    "audiobookshelf" => %w[bindery],
    "jellyfin" => %w[seerr]
  }.freeze
  # Read by no play or suite, so they select the contract alone; all three legs share the support file.
  RECONCILIATION_OWNED_PATHS = %w[
    tests/media_acquisition_reconciliation_support.rb
    tests/media_acquisition_reconciliation_core_test.rb
    tests/media_acquisition_reconciliation_bazarr_test.rb
    tests/media_acquisition_reconciliation_configarr_test.rb
  ].freeze
  # ci.yml is routed for job coverage, not readers: it defines the jobs, so it selects one leg of
  # every job (#395). One suite leg suffices because workflow_test executes the suites job's
  # `case "$SUITE"` for every suite. Any other .github/ path still falls open.
  CI_WORKFLOW_ROUTED_PATH = ".github/workflows/ci.yml"
  # vault.yml and vault_<role>.yml also select the vault job (additive to static). roles/vault_contract/
  # and validate-vault.yml are deliberately unmatched: they already fall open to every job.
  VAULT_ROUTED_PATTERN = %r{\Ainventory/group_vars/all/vault(?:_[a-z0-9_]+)?\.yml\z}
  CI_WORKFLOW_JOB_LANES = %w[docs vault reconciliation].freeze
  # A tagged lane (foundation would empty selected_tags) with no companion, so one leg costs one leg.
  CI_WORKFLOW_SUITE_LANE = "komga"

  module_function

  def classify(paths, full: false, base: nil, head: nil)
    @upgrade_subject = nil
    selection = LANES.to_h { |lane| [lane, false] }
    return everything(selection, sharded: false) if full

    # Resolved before the loop, which returns on a fall-open: a fall-open must still dispatch the
    # upgrade lane when a pin moved.
    @upgrade_subject = upgrade_subject(paths, base, head)

    tagged_lanes = []
    reconciliation_owned = false
    paths.each do |raw_path|
      path = raw_path.to_s.sub(%r{\A\./}, "")
      documentation = docs_input?(path)
      selection["docs"] = true if documentation
      if static_only_path?(path)
        selection["static"] = true
        selection["vault"] = true if vault_path?(path)
        next
      end
      next if documentation || inert_path?(path)

      if RECONCILIATION_OWNED_PATHS.include?(path)
        reconciliation_owned = true
        next
      end

      if path == CI_WORKFLOW_ROUTED_PATH
        CI_WORKFLOW_JOB_LANES.each { |lane| selection[lane] = true }
        tagged_lanes << CI_WORKFLOW_SUITE_LANE
        next
      end

      if ACQUISITION_SHARED_PATHS.include?(path)
        tagged_lanes.concat(ACQUISITION_LANES)
        next
      end

      if (owner = ACQUISITION_OWNED_PATHS[path])
        tagged_lanes << owner
        next
      end

      lane = acquisition_lane(path) || service_lane(path)
      unless lane
        return everything(selection, sharded: true) unless static_only_test?(path)

        selection["static"] = true
        next
      end

      tagged_lanes << lane
      tagged_lanes.concat(COMPANION_LANES.fetch(lane, []))
    end

    unless tagged_lanes.empty?
      %w[static idempotence_check].each { |lane| selection[lane] = true }
      tagged_lanes.each { |lane| selection[lane] = true }
    end
    # The contract's files are policy-gate fixtures too.
    selection["static"] = true if reconciliation_owned
    selection["reconciliation"] = true if reconciliation_owned ||
                                          RECONCILIATION_LANES.any? { |lane| selection.fetch(lane) }
    selection[UPGRADE_LANE] = !@upgrade_subject.nil?
    selection
  end

  # [service, base image] for the upgrade lane, or nil. Compares pins, not files: a compose change
  # that leaves `image:` alone proves nothing. ONE subject: two moved pins prove the first.
  def upgrade_subject(paths, base, head)
    return nil unless base && head

    # The merge base, matching changed_paths' `base...head`: main's tip may have moved the pin
    # since the fork, which would red the downgrade guard on a PR performing no downgrade.
    merge_base, _error, status = Open3.capture3("git", "merge-base", base, head)
    comparison = status.success? && !merge_base.strip.empty? ? merge_base.strip : base

    UPGRADE_SUBJECTS.each do |service|
      compose = "services/#{service}/compose.yml"
      next unless paths.include?(compose)

      base_image = pinned_image(comparison, compose)
      head_image = pinned_image(head, compose)
      next if base_image.nil? || head_image.nil? || base_image == head_image
      # An untagged subject would converge the whole site; tests/contract_upgrade_seed_test.rb
      # requires every subject to be a tagged row.
      next unless SERVICE_TAGS.key?(service.tr("-", "_"))

      return [service, base_image]
    end
    nil
  end

  # The single `image:` a compose.yml pins at a revision; nil for none or several, because a
  # guess converges the wrong version and reports success.
  def pinned_image(revision, path)
    content, _error, status = Open3.capture3("git", "show", "#{revision}:#{path}")
    return nil unless status.success?

    images = content.lines.filter_map do |line|
      line[/\A\s*image:\s*(\S+)\s*\z/, 1]
    end
    images.length == 1 ? images.first : nil
  end

  def changed_paths(base, head)
    output, error, status = Open3.capture3(
      "git", "diff", "--name-status", "-z", "--find-renames", "--find-copies-harder",
      "#{base}...#{head}"
    )
    raise "git diff failed: #{error.strip}" unless status.success?

    fields = output.split("\0", -1)
    fields.pop if fields.last == ""
    paths = []
    until fields.empty?
      status_field = fields.shift
      if status_field.start_with?("R", "C")
        raise "malformed git diff output" if fields.length < 2

        paths << fields.shift << fields.shift
      else
        raise "malformed git diff output" if fields.empty?

        paths << fields.shift
      end
    end
    paths
  end

  # Every lane on, in one of the two idempotence forms.
  def everything(selection, sharded:)
    # Upgrade stays off only without a subject: --full and --files have no base, but a fall-open
    # whose diff moved a pin still dispatches it.
    off = sharded ? [IDEMPOTENCE_LANE] : IDEMPOTENCE_SHARD_LANES
    off += [UPGRADE_LANE] if @upgrade_subject.nil?
    selection.to_h { |lane, _| [lane, !off.include?(lane)] }
  end

  def write_github_outputs(selection, io)
    LANES.each { |lane| io.puts "#{lane}=#{selection.fetch(lane)}" }
    io.puts "suites=#{suites(selection).to_json}"
    tags = if selection.fetch("foundation")
             []
           else
             TAGGED_LANES.filter { |lane| selection.fetch(lane) }
                          .flat_map { |lane| SERVICE_TAGS.fetch(lane) }
                          .uniq
           end
    io.puts "selected_tags=#{tags.join(',')}"
    # The subject lives in @upgrade_subject, so classifying twice before writing would pair one
    # run's subject with another's lanes.
    unless selection.fetch(UPGRADE_LANE) == !@upgrade_subject.nil?
      raise "upgrade selection #{selection.fetch(UPGRADE_LANE)} does not match the resolved " \
            "subject #{@upgrade_subject.inspect}: write_github_outputs must be given the " \
            "selection classify resolved that subject for"
    end
    service, base_image = @upgrade_subject
    io.puts "upgrade_service=#{service}"
    io.puts "upgrade_base_image=#{base_image}"
    # The subject's tags, never selected_tags: a fall-open empties that and would send this lane
    # down the untagged branch, converging the whole site twice.
    io.puts "upgrade_tags=#{service ? SERVICE_TAGS.fetch(service.tr('-', '_')).join(',') : ''}"
  end

  def suites(selection)
    SUITES.filter_map { |lane, suite| suite if selection.fetch(lane) }
  end

  # Reached after docs_input?. Root Markdown is never inert: it falls open (#346). Nor is
  # .gitignore: policy scripts read it, so it is in STATIC_ONLY_PATHS.
  def inert_path?(path)
    return true if path.match?(%r{\ALICENSE(?:\.[^/]+)?\z})
    return true if path.match?(%r{\A(?:\.idea|\.vscode)/}) || path == ".editorconfig"
    return false unless path.include?("/")
    return false if path.match?(%r{\A(?:tests|fixtures|scripts)/})

    path.end_with?(".md")
  end

  def docs_input?(path)
    DOCUMENTATION_PATHS.include?(path) ||
      DOCUMENTATION_PREFIXES.any? { |prefix| path.start_with?(prefix) }
  end

  def vault_path?(path)
    path.match?(VAULT_ROUTED_PATTERN)
  end

  def static_only_path?(path)
    STATIC_ONLY_PATHS.include?(path) || vault_path?(path) ||
      STATIC_ONLY_PREFIXES.any? { |prefix| path.start_with?(prefix) }
  end

  # Reached only once no lane has claimed the path, so the contract fixtures and
  # the per-service contracts routed above keep the lanes they already had.
  def static_only_test?(path)
    path.start_with?("tests/") &&
      INTEGRATION_HARNESS_PREFIXES.none? { |prefix| path.start_with?(prefix) } &&
      !INTEGRATION_HARNESS_PATHS.include?(path)
  end

  # tests/expected/<svc>.yml and service_<role>.yml change what the lane asserts, so they route
  # to it (#650). Keyed by role name, hence paperless_ngx in SERVICE_NAMES. acquisition_lane
  # repeats both routes; either copy alone is redundant, deleting the pair is not.
  def service_lane(path)
    SERVICE_NAMES.each do |lane, names|
      names.each do |name|
        return lane if path.start_with?("roles/#{name}/", "services/#{name}/")
        return lane if path == "tests/expected/#{name}.yml"
        return lane if path == "inventory/group_vars/all/service_#{name}.yml"
        return lane if path.match?(%r{\Atests/contracts/#{Regexp.escape(name)}(?:[-.]|\z)})
      end
    end
    nil
  end

  def acquisition_lane(path)
    ACQUISITION_LANES.find do |lane|
      path.start_with?("roles/#{lane}/", "services/#{lane}/") ||
        path == "tests/expected/#{lane}.yml" ||
        path == "inventory/group_vars/all/service_#{lane}.yml" ||
        path == "tests/contracts/#{lane}.sh"
    end
  end

  def parse_cli(arguments)
    modes = []
    output_path = nil
    index = 0
    while index < arguments.length
      case arguments[index]
      when "--github-output"
        return nil if output_path || index + 1 >= arguments.length

        output_path = arguments[index + 1]
        index += 2
      when "--full"
        modes << [:full]
        index += 1
      when "--diff"
        return nil if index + 2 >= arguments.length || arguments[index + 1].start_with?("--") ||
                      arguments[index + 2].start_with?("--")

        modes << [:diff, arguments[index + 1], arguments[index + 2]]
        index += 3
      when "--files"
        index += 1
        files = []
        while index < arguments.length && !arguments[index].start_with?("--")
          files << arguments[index]
          index += 1
        end
        return nil if files.empty?

        modes << [:files, files]
      else
        return nil
      end
    end
    return nil unless modes.length == 1

    [modes.first, output_path]
  end

  def run_cli(arguments)
    parsed = parse_cli(arguments)
    unless parsed
      warn "usage: classify_changes.rb (--files PATH... | --diff BASE HEAD | --full) " \
           "[--github-output PATH]"
      return 2
    end

    mode, output_path = parsed
    selection = case mode.first
                when :full
                  classify([], full: true)
                when :diff
                  classify(changed_paths(mode[1], mode[2]), base: mode[1], head: mode[2])
                when :files
                  classify(mode[1])
                end
    if output_path
      File.open(output_path, "w") { |io| write_github_outputs(selection, io) }
    else
      write_github_outputs(selection, $stdout)
    end
    0
  rescue StandardError => e
    warn e.message
    1
  end
end

exit ClassifyChanges.run_cli(ARGV) if $PROGRAM_NAME == __FILE__
