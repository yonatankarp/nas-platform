#!/usr/bin/env ruby

require "json"
require "open3"

module ClassifyChanges
  # The suite table is data, not code: tests/ci/suites.conf lists every suite
  # once, with the tags it converges, and tests/integration.sh reads the same
  # rows for its own --list-suites, its unknown-suite refusal and its fixed tags.
  # Everything below is derived from it, so a new suite is one row rather than
  # one table here and another one there kept equal by a policy check.
  SUITE_TABLE_PATH = File.expand_path("suites.conf", __dir__)
  SUITE_TABLE = File.readlines(SUITE_TABLE_PATH, chomp: true).filter_map do |line|
    fields = line.sub(/#.*/, "").split
    next if fields.empty?
    raise "malformed row in #{SUITE_TABLE_PATH}: #{line.inspect}" unless fields.length == 3

    suite, kind, tags = fields
    [suite, kind, tags == "-" ? [] : tags.split(",")]
  end.freeze
  # Lanes that gate a workflow job of their own rather than dispatching an
  # integration suite. Every other lane is one suite.
  JOB_LANES = %w[static docs reconciliation].freeze
  # `full` is the runner's own default and no CI lane dispatches it, so it is the
  # one row the classifier drops. A lane is its suite with hyphens written as
  # underscores, because a lane is also a GitHub Actions output key.
  CI_SUITE_ROWS = SUITE_TABLE.reject { |_suite, kind, _tags| kind == "harness" }.freeze
  # The integration suite each lane dispatches, in the order the CI matrix runs
  # them. The job lanes above are not suites.
  SUITES = CI_SUITE_ROWS.to_h { |suite, _kind, _tags| [suite.tr("-", "_"), suite] }.freeze
  LANES = (JOB_LANES + SUITES.keys).freeze
  SERVICE_LANES = CI_SUITE_ROWS.filter_map do |suite, kind, _tags|
    suite.tr("-", "_") if kind == "service"
  end.freeze
  ACQUISITION_LANES = CI_SUITE_ROWS.filter_map do |suite, kind, _tags|
    suite.tr("-", "_") if kind == "acquisition"
  end.freeze
  TAGGED_LANES = (ACQUISITION_LANES + SERVICE_LANES).freeze
  # The tags CI narrows the site to for each lane it selects by tag. Active
  # services include ntfy because each role publishes its deployment report
  # there. Planned acquisition suites instead converge only the shared inert
  # foundation and validate it with their static contract.
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
    "paperless" => %w[paperless paperless-ngx paperless_ngx]
  }.freeze
  # Paths the policy gate checks and nothing else in CI reads. The auto-deploy
  # playbook and its two roles are reachable only from
  # install-production-auto-deploy.yml -- site.yml never includes them and
  # tests/integration.sh never names them -- so no suite can observe a change to
  # one. The vault generator is the same shape: the suites build their sandbox
  # vault with tests/generate-ephemeral-vault.sh, which writes its own plaintext
  # rather than running this playbook. The encrypted vault is the other half of
  # that: tests/integration.sh installs the sandbox vault *over*
  # inventory/group_vars/all/vault.yml before any play runs, so no suite ever
  # reads the committed one, and the only check that opens it is
  # tests/policy_vault_test.rb, which asserts it is still encrypted. Falling open
  # to every lane was costing a full seventeen-suite matrix to re-prove that one
  # line. renovate.json is read by tests/renovate_policy_test.rb and by no play
  # at all.
  #
  # The documents are here for the same reason and not because they are
  # documentation: each one is read *by name* by a check that only the static job
  # runs -- tests/policy_test.rb, the mutation harness's retired-declaration
  # sweep, tests/policy_mac_test.rb, tests/policy_vault_test.rb,
  # tests/bazarr_provider_schema_test.rb, tests/production_auto_deploy_role_test.rb
  # -- and those checks are the policy gate itself, so they cannot move to a
  # cheaper job. Everything else under docs/ is routed by docs_input? below to the
  # docs job instead, which is why docs/secrets.md is no longer here: the only
  # check that reads it, tests/secrets_docs_test.rb, runs there.
  # tests/ci/classify_changes_test.rb derives the coupling from the registered
  # checks themselves and fails when a document reaches no job that runs a check
  # reading it, so the next doc-reading check cannot reopen the hole by being
  # written.
  #
  # CLAUDE.md is the one that got in anyway (issue #346), because the derivation
  # only ever looked for `docs/...` and README: tests/policy_test.rb sweeps it for
  # retired declarations and tests/docs_links_test.rb compares its lane roster and
  # its service-stack count against the tree, both added by #276, while it matched
  # no lane map at all and fell through to inert_path? as ordinary Markdown.
  # Editing either of those two claims merged green and turned main red on the
  # next unrelated change.
  STATIC_ONLY_PATHS = %w[
    CLAUDE.md
    README.md
    docs/adding-a-service.md
    docs/ansible-basics.md
    docs/asustor-adm-rollout.md
    docs/bazarr-providers.md
    docs/getting-started-mac.md
    docs/getting-started-nas.md
    docs/getting-started.md
    docs/media-acquisition-phase1.md
    generate-secrets.yml
    install-production-auto-deploy.yml
    inventory/group_vars/all/vault.yml
    renovate.json
    templates/vault-plain.yml.j2
  ].freeze
  # Documentation is a gate input rather than inert text, and the coupling is a
  # glob, not a list: tests/docs_links_test.rb reads README.md and every *.md
  # under docs/, and it resolves each link against the working tree, so deleting
  # an image a document points at breaks it too. Routing the whole directory here
  # is what closes the half that rescuing documents by name never could -- a
  # broken link under docs/superpowers/plans/ used to merge green and turn main
  # red. It selects the docs job, which needs Ruby and the checkout and nothing
  # else, rather than the fifteen-minute static job a typo fix has no business
  # paying for. The documents STATIC_ONLY_PATHS still names select both, CLAUDE.md
  # among them: the link gate reads it here, the policy gate reads it there.
  DOCUMENTATION_PATHS = %w[CLAUDE.md README.md].freeze
  DOCUMENTATION_PREFIXES = %w[docs/].freeze
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
  # The media acquisition reconciliation contract lifts task files out of these
  # two roles and runs them against a fixture, and reads their defaults for its
  # timings, so any change inside either role changes what it asserts. Selecting
  # the lane rather than the individual files is deliberate: the contract reads
  # roles/arr/tasks/, roles/arr/files/configarr/ and roles/downloaders/tasks/,
  # and a file added to any of them must select the contract without an edit
  # here.
  RECONCILIATION_LANES = %w[arr downloaders].freeze
  # A selected lane, and the lane its subject is not fully proved without. Two
  # different shapes share the table, and both are dependencies between lanes
  # rather than between files, which is why the table is keyed by lane: whatever
  # selects the first lane needs the second, and a file added to the role must
  # not need an edit here to get it.
  #
  # The first shape is one role with two states no single sandbox reaches. The
  # Usenet provider is declared in the vault or it is not, and SABnzbd's
  # `section=servers` reconciliation
  # only ever upserts, so a server declared once stands after the declaration is
  # emptied. The `downloaders` lane therefore converges the undeclared state from
  # the start -- tests/integration_controller.sh builds its vault with
  # `--undeclared usenet`, which is the state every real target starts in and the
  # one #274 broke -- and the `bindery` lane converges the same arr and
  # downloaders stacks from a fully declared vault. Each lane asserts one branch
  # of roles/downloaders/tasks/verify.yml, so a change inside that role has to
  # select both or one branch is routed to no runtime lane at all.
  #
  # The second shape is a lane that consumes another role's *converged* state, so
  # the producing role's own lane cannot see what it broke. The `seerr` lane is
  # the only one that converges arr and Jellyfin together, and Seerr does not
  # merely need Jellyfin running: roles/seerr/tasks/bootstrap.yml POSTs the vault
  # Jellyfin administrator credentials to `/auth/jellyfin` to claim the Seerr
  # admin account inside the anonymous-takeover window, and
  # roles/seerr/tasks/main.yml verifies `/settings/jellyfin` against
  # `seerr_jellyfin_hostname`/`_port` and reconciles `jellyfinUsername` against
  # the managed-user roster. A Jellyfin change to its address, its administrator
  # identity or its user list therefore breaks the seerr lane, and the `jellyfin`
  # lane converges no Seerr and reports nothing (#349). This is not the fail-open
  # property CLAUDE.md relies on: roles/jellyfin/ *is* mapped, so the unmapped
  # fallback never fires -- fail-open covers paths nobody thought about, not
  # paths mapped too tightly.
  #
  # The arr rows of the same shape are declined rather than missing, and
  # tests/ci/classify_changes_test.rb states them so: the `arr` lane and the
  # `reconciliation` job already converge and assert arr's own state, and the
  # downloaders, bindery, trailarr and seerr lanes read it over stable APIs
  # rather than through a one-shot credential handshake. Four more lanes on every
  # arr change is not what that buys.
  COMPANION_LANES = { "downloaders" => %w[bindery], "jellyfin" => %w[seerr] }.freeze
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
  # publishes its deployment report. The one remaining acquisition foundation
  # suite converges only the shared inert foundation and never starts ntfy, so a
  # change to it cannot reach it.
  NTFY_LANES = TAGGED_LANES.select { |lane| SERVICE_TAGS.fetch(lane).include?("ntfy") }.freeze

  module_function

  def classify(paths, full: false)
    selection = LANES.to_h { |lane| [lane, false] }
    return selection.transform_values { true } if full

    tagged_lanes = []
    reconciliation_owned = false
    paths.each do |raw_path|
      path = raw_path.to_s.sub(%r{\A\./}, "")
      documentation = docs_input?(path)
      selection["docs"] = true if documentation
      if static_only_path?(path)
        selection["static"] = true
        next
      end
      next if documentation || inert_path?(path)

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
      tagged_lanes.concat(COMPANION_LANES.fetch(lane, []))
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

  # Reached only after docs_input? has claimed CLAUDE.md, README.md and everything
  # under docs/, so no documentation the link gate reads can be called inert here.
  # What is left is Markdown the gate does not read at all -- a stray note beside
  # a role -- and editor droppings.
  #
  # Repository-root Markdown is the exception, and it is a rule rather than a
  # list. This line used to exempt AGENTS.md by name, a file that has never
  # existed in any ref, while the agent-instructions file that does exist fell
  # through it into `.md` and reached no job (issue #346). Root Markdown is where
  # a check-read document lands, so it falls open to every lane instead of being
  # guessed at by name; naming it above is what buys it a cheaper answer.
  def inert_path?(path)
    return true if path == ".gitignore" || path.match?(%r{\ALICENSE(?:\.[^/]+)?\z})
    return true if path.match?(%r{\A(?:\.idea|\.vscode)/}) || path == ".editorconfig"
    return false unless path.include?("/")
    return false if path.match?(%r{\A(?:tests|fixtures|scripts)/})

    path.end_with?(".md")
  end

  def docs_input?(path)
    DOCUMENTATION_PATHS.include?(path) ||
      DOCUMENTATION_PREFIXES.any? { |prefix| path.start_with?(prefix) }
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
