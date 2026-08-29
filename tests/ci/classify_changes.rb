#!/usr/bin/env ruby

require "json"
require "open3"

module ClassifyChanges
  LANES = %w[
    static reconciliation foundation arr downloaders bindery kapowarr pinchflat trailarr seerr
    smoke beszel dozzle audiobookshelf komga jellyfin immich paperless idempotence_check
  ].freeze
  # Lanes that gate a workflow job of their own rather than dispatching an
  # integration suite. Everything else in LANES is one suite.
  JOB_LANES = %w[static reconciliation].freeze
  # The integration suite each lane dispatches, in the order the CI matrix runs
  # them. The job lanes above are not suites.
  SUITES = {
    "foundation" => "foundation",
    "arr" => "arr",
    "downloaders" => "downloaders",
    "bindery" => "bindery",
    "kapowarr" => "kapowarr",
    "pinchflat" => "pinchflat",
    "trailarr" => "trailarr",
    "seerr" => "seerr",
    "smoke" => "smoke",
    "beszel" => "beszel",
    "dozzle" => "dozzle",
    "audiobookshelf" => "audiobookshelf",
    "komga" => "komga",
    "jellyfin" => "jellyfin",
    "immich" => "immich",
    "paperless" => "paperless",
    "idempotence_check" => "idempotence-check"
  }.freeze
  SERVICE_LANES = %w[
    beszel dozzle audiobookshelf komga jellyfin immich paperless
  ].freeze
  ACQUISITION_LANES = %w[
    arr downloaders bindery kapowarr pinchflat trailarr seerr
  ].freeze
  TAGGED_LANES = (ACQUISITION_LANES + SERVICE_LANES).freeze
  # Active services include ntfy because each role publishes its deployment
  # report there. Planned acquisition suites instead converge only the shared
  # inert foundation and validate it with their static contract.
  SERVICE_TAGS = {
    "arr" => %w[host_prep deployment_bundle ntfy arr],
    "downloaders" => %w[host_prep deployment_bundle ntfy arr downloaders],
    "bindery" => %w[host_prep deployment_bundle media_acquisition_foundation],
    "kapowarr" => %w[host_prep deployment_bundle media_acquisition_foundation],
    "pinchflat" => %w[host_prep deployment_bundle media_acquisition_foundation],
    "trailarr" => %w[host_prep deployment_bundle media_acquisition_foundation],
    "seerr" => %w[host_prep deployment_bundle media_acquisition_foundation],
    "beszel" => %w[host_prep deployment_bundle ntfy beszel],
    "dozzle" => %w[host_prep deployment_bundle ntfy dozzle],
    "audiobookshelf" => %w[host_prep deployment_bundle ntfy audiobookshelf],
    "komga" => %w[host_prep deployment_bundle ntfy komga],
    "jellyfin" => %w[host_prep deployment_bundle ntfy jellyfin],
    "immich" => %w[host_prep deployment_bundle ntfy immich],
    "paperless" => %w[host_prep deployment_bundle ntfy paperless]
  }.freeze
  SERVICE_NAMES = {
    "arr" => %w[arr],
    "downloaders" => %w[downloaders],
    "beszel" => %w[beszel],
    "dozzle" => %w[dozzle],
    "audiobookshelf" => %w[audiobookshelf],
    "komga" => %w[komga],
    "jellyfin" => %w[jellyfin],
    "immich" => %w[immich],
    "paperless" => %w[paperless paperless-ngx paperless_ngx]
  }.freeze
  # Paths the policy gate checks and nothing else in CI reads. The auto-deploy
  # playbook and its two roles are reachable only from
  # install-production-auto-deploy.yml -- site.yml never includes them and
  # tests/integration.sh never names them -- so no suite can observe a change to
  # one. The vault generator is the same shape: the suites build their sandbox
  # vault with tests/generate-ephemeral-vault.sh, which writes its own plaintext
  # rather than running this playbook. renovate.json is read by
  # tests/renovate_policy_test.rb and by no play at all.
  STATIC_ONLY_PATHS = %w[
    README.md
    docs/getting-started-nas.md
    docs/secrets.md
    generate-secrets.yml
    install-production-auto-deploy.yml
    renovate.json
    templates/vault-plain.yml.j2
  ].freeze
  STATIC_ONLY_PREFIXES = %w[
    roles/image_prune/
    roles/production_auto_deploy/
    scripts/
  ].freeze
  # The files under tests/ that tests/integration.sh executes on the target. A
  # change to one of them changes what every suite does, so they keep falling
  # open; everything else under tests/ is a check the policy gate runs and
  # selects the gate alone. tests/ci/classify_changes_test.rb asserts this list
  # against what the harness actually invokes, so a new harness file that is
  # missing here fails there rather than silently skipping every suite.
  INTEGRATION_HARNESS_PATHS = %w[
    tests/assert-no-vault-secrets.rb
    tests/generate-ephemeral-vault.sh
    tests/integration.sh
    tests/integration_lock.sh
    tests/mac/generate-immich-fixture-vars.rb
    tests/mac/snapshot-paperless.sh
    tests/mac_inventory_path_test.yml
    tests/policy_support.rb
    tests/run_contracts.rb
    tests/sandbox_cleanup.sh
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
  # The media acquisition reconciliation contract lifts task files out of these
  # two roles and runs them against a fixture, and reads their defaults for its
  # timings, so any change inside either role changes what it asserts. Selecting
  # the lane rather than the individual files is deliberate: the contract reads
  # roles/arr/tasks/, roles/arr/files/configarr/ and roles/downloaders/tasks/,
  # and a file added to any of them must select the contract without an edit
  # here.
  RECONCILIATION_LANES = %w[arr downloaders].freeze
  # The contract's own files. They are read by no play and by no integration
  # suite, so they select the contract alone rather than falling open to every
  # lane in the repository. The support file is listed because all three legs
  # require it -- routing one leg on its own is not safe while they share it.
  RECONCILIATION_OWNED_PATHS = %w[
    tests/media_acquisition_reconciliation_support.rb
    tests/media_acquisition_reconciliation_core_test.rb
    tests/media_acquisition_reconciliation_bazarr_test.rb
    tests/media_acquisition_reconciliation_configarr_test.rb
  ].freeze
  # Every lane whose tags start the alerting sink, which is where each role
  # publishes its deployment report. The five acquisition foundation suites
  # converge only the shared inert foundation and never start ntfy, so a change
  # to it cannot reach them.
  NTFY_LANES = TAGGED_LANES.select { |lane| SERVICE_TAGS.fetch(lane).include?("ntfy") }.freeze

  module_function

  def classify(paths, full: false)
    selection = LANES.to_h { |lane| [lane, false] }
    return selection.transform_values { true } if full

    tagged_lanes = []
    reconciliation_owned = false
    paths.each do |raw_path|
      path = raw_path.to_s.sub(%r{\A\./}, "")
      if static_only_path?(path)
        selection["static"] = true
        next
      end
      next if inert_path?(path)

      if RECONCILIATION_OWNED_PATHS.include?(path)
        reconciliation_owned = true
        next
      end

      if path.start_with?("roles/ntfy/", "services/ntfy/")
        tagged_lanes.concat(NTFY_LANES)
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
        return selection.transform_values { true } unless static_only_test?(path)

        selection["static"] = true
        next
      end

      tagged_lanes << lane
    end

    unless tagged_lanes.empty?
      %w[static idempotence_check].each { |lane| selection[lane] = true }
      selection["smoke"] = true if (tagged_lanes & SERVICE_LANES).any?
      tagged_lanes.each { |lane| selection[lane] = true }
    end
    # The contract's own files are fixtures of the policy gate as well -- they are
    # named in tests/policy_mutation_support.rb and tests/policy_vault_test.rb --
    # so they select static too.
    selection["static"] = true if reconciliation_owned
    selection["reconciliation"] = true if reconciliation_owned ||
                                          RECONCILIATION_LANES.any? { |lane| selection.fetch(lane) }
    selection
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

  def write_github_outputs(selection, io)
    LANES.each { |lane| io.puts "#{lane}=#{selection.fetch(lane)}" }
    io.puts "suites=#{suites(selection).to_json}"
    io.puts "run_ci=#{selection.values.any?}"
    tags = if selection.fetch("foundation")
             []
           else
             TAGGED_LANES.filter { |lane| selection.fetch(lane) }
                          .flat_map { |lane| SERVICE_TAGS.fetch(lane) }
                          .uniq
           end
    io.puts "selected_tags=#{tags.join(',')}"
  end

  def suites(selection)
    SUITES.filter_map { |lane, suite| suite if selection.fetch(lane) }
  end

  def inert_path?(path)
    return true if path == "README.md" || path == ".gitignore" || path.match?(%r{\ALICENSE(?:\.[^/]+)?\z})
    return true if path.match?(%r{\A(?:\.idea|\.vscode)/}) || path == ".editorconfig"
    return true if path.start_with?("docs/")
    return false if path == "AGENTS.md" || path.match?(%r{\A(?:tests|fixtures|scripts)/})

    path.end_with?(".md")
  end

  def static_only_path?(path)
    STATIC_ONLY_PATHS.include?(path) ||
      STATIC_ONLY_PREFIXES.any? { |prefix| path.start_with?(prefix) }
  end

  # Reached only once no lane has claimed the path, so the contract fixtures and
  # the per-service contracts routed above keep the lanes they already had.
  def static_only_test?(path)
    path.start_with?("tests/") &&
      INTEGRATION_HARNESS_PREFIXES.none? { |prefix| path.start_with?(prefix) } &&
      !INTEGRATION_HARNESS_PATHS.include?(path)
  end

  def service_lane(path)
    SERVICE_NAMES.each do |lane, names|
      names.each do |name|
        return lane if path.start_with?("roles/#{name}/", "services/#{name}/")
        return lane if path.match?(%r{\Atests/contracts/#{Regexp.escape(name)}(?:[-.]|\z)})
      end
    end
    nil
  end

  def acquisition_lane(path)
    ACQUISITION_LANES.find do |lane|
      path.start_with?("roles/#{lane}/", "services/#{lane}/") ||
        path == "tests/expected/#{lane}.yml" ||
        path == "tests/contracts/#{lane}-foundation.sh" ||
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
                  classify(changed_paths(mode[1], mode[2]))
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
