#!/usr/bin/env ruby
# The static half of the Pinchflat service contract: every property it can
# decide from the repository alone, with nothing deployed.
#
# usage: pinchflat-static.rb REPOSITORY
#
# Silent and exit 0 when the repository holds; one line per violation on stderr
# and exit 1 when it does not. Callers grep those lines, so they are the
# interface -- tests/pinchflat_contract_test.rb asserts each one by its exact
# text.
#
# PLATFORM_CONTRACT_REPO_DIR names the checkout tests/policy_support.rb is read
# from, which is how this program shares flatten_tasks rather than carrying its
# own copy.
#
# Until #147 this was a `<<'RUBY'` heredoc inside tests/contracts/pinchflat.sh.
# `sh -n` reads a quoted heredoc as opaque text, so nothing but an integration
# run ever looked at it and no test could reach it. The body below is
# byte-identical to what that heredoc rendered; the heredoc carried no `-r`
# preloads and took exactly one argument, so neither does the invocation that
# replaced it.
require "yaml"

root = ARGV.fetch(0)
failures = []
required = %w[
  roles/pinchflat/defaults/main.yml
  roles/pinchflat/meta/argument_specs.yml
  roles/pinchflat/tasks/main.yml
  roles/pinchflat/templates/env.j2
  services/pinchflat/compose.yml
  services/pinchflat/compose.mac.yml
  services/pinchflat/compose.integration.yml
]
required.each do |relative|
  failures << "missing #{relative}" unless File.file?(File.join(root, relative))
end

# Task files are flattened so a task on a block's rescue or always path is still
# a task the role executes.
require File.join(ENV.fetch("PLATFORM_CONTRACT_REPO_DIR"), "tests", "policy_support")
include PolicySupport

# The environment file is a line-oriented grammar, so it is read as the
# assignments it declares: a commented-out sample of the right assignment
# satisfies a substring search while the live line exports something else.
def environment_assignments(path)
  File.readlines(path, chomp: true).filter_map do |line|
    stripped = line.strip
    next unless stripped.match?(/\A[A-Z][A-Z0-9_]*=/)

    name, _separator, value = stripped.partition("=")
    [name, value]
  end
end

if failures.empty?
  compose = YAML.safe_load_file(File.join(root, "services/pinchflat/compose.yml"), aliases: true)
  service = compose.fetch("services").fetch("pinchflat")

  # Pinchflat is declared self-contained in the acquisition design: it calls no
  # other platform service, so it must not sit on the shared control network,
  # where it would be reachable by every acquisition project for no purpose.
  failures << "Pinchflat must not join the shared media control network" if
    compose.key?("networks") || service.key?("networks")

  # The image ships no PUID/PGID handling, so the bind mounts are only writable
  # if the container takes the platform identity directly.
  failures << "Pinchflat must run as the shared platform identity" unless
    service["user"] == "${NAS_UID:?}:${NAS_GID:?}"
  failures << "Pinchflat must declare the platform umask" unless
    service.dig("environment", "UMASK") == "022"

  # Basic auth is Pinchflat's only access control, and the `:?` suffix is what
  # turns an unset credential into a refused deployment rather than an
  # unauthenticated writer on the LAN.
  {
    "BASIC_AUTH_USERNAME" => "${PINCHFLAT_BASIC_AUTH_USERNAME:?}",
    "BASIC_AUTH_PASSWORD" => "${PINCHFLAT_BASIC_AUTH_PASSWORD:?}"
  }.each do |name, expected|
    failures << "Pinchflat must require #{name} from the rendered environment" unless
      service.dig("environment", name) == expected
  end

  # The third mount is the extractor, and it is read-only on purpose: nothing
  # inside the container may rewrite the thing that resolves every source.
  failures << "Pinchflat must mount exactly its config, library and extractor" unless
    Array(service["volumes"]) == [
      "${PINCHFLAT_CONFIG_PATH:?}:/config",
      "${PINCHFLAT_DOWNLOADS_PATH:?}:/downloads",
      "${PINCHFLAT_YTDLP_PATH:?}:/usr/local/bin/yt-dlp:ro"
    ]

  # The published port and the container port are both pinned by
  # config/media-acquisition.yml, and the Mac override republishes only the host
  # half, so the container half is the one a drifting image tag would move.
  failures << "Pinchflat must publish the catalog web UI port" unless
    Array(service["ports"]) == ["8945:8945"]
  mac = YAML.safe_load_file(File.join(root, "services/pinchflat/compose.mac.yml"))
  failures << "the Mac override must republish the web UI on the harness port" unless
    mac.dig("services", "pinchflat", "ports") == ["${PINCHFLAT_HOST_PORT:?}:8945"]

  defaults = YAML.safe_load_file(File.join(root, "roles/pinchflat/defaults/main.yml"))
  failures << "Pinchflat must write the declared YouTube library root" unless
    defaults["pinchflat_downloads_host_path"] == "{{ nas_media_root }}/Media/YouTube"
  failures << "Pinchflat must keep its state in the declared config root" unless
    defaults["pinchflat_config_host_path"] == "{{ nas_docker_root }}/pinchflat/config"

  # The image's own yt-dlp is frozen behind YouTube and upstream ships no newer
  # release image, so the extractor is a declared artifact rather than whatever
  # the image was built with. Pinned by shape, not by value, so a version bump
  # does not have to edit this contract -- but a bump that drops either half of
  # the pin fails here.
  failures << "Pinchflat must declare the yt-dlp build it deploys" unless
    defaults["pinchflat_ytdlp_version"].to_s.match?(/\A\d{4}\.\d{2}\.\d{2}\z/)
  failures << "Pinchflat must pin the yt-dlp artifact by sha256" unless
    defaults["pinchflat_ytdlp_sha256"].to_s.match?(/\A[0-9a-f]{64}\z/)
  failures << "Pinchflat must keep the extractor beside its own state" unless
    defaults["pinchflat_ytdlp_host_path"] == "{{ nas_docker_root }}/pinchflat/bin/yt-dlp"

  env_assignments = environment_assignments(
    File.join(root, "roles/pinchflat/templates/env.j2")
  )
  failures << "Pinchflat env must render the CPU set exactly once" unless
    env_assignments.select { |name, _value| name == "PLATFORM_CONTAINER_CPUSET" } ==
      [["PLATFORM_CONTAINER_CPUSET", "{{ platform_effective_container_cpuset }}"]]
  failures << "Pinchflat env must carry only the vault-authored identity" unless
    [
      ["PINCHFLAT_BASIC_AUTH_USERNAME", "{{ vault_pinchflat_admin_username }}"],
      ["PINCHFLAT_BASIC_AUTH_PASSWORD", "{{ vault_pinchflat_admin_password }}"]
    ].all? { |assignment| env_assignments.include?(assignment) }

  tasks = flatten_tasks(
    YAML.safe_load_file(File.join(root, "roles/pinchflat/tasks/main.yml"), aliases: true)
  )
  failures << "Pinchflat must deploy through docker_compose_v2" unless
    tasks.count { |task| task.dig("community.docker.docker_compose_v2", "state") == "present" } == 1
  failures << "Pinchflat must verify its effective project CPU policy" unless
    tasks.count { |task| task.dig("vars", "container_cpu_service_name") == "pinchflat" } == 1

  # Fetching the extractor unverified would turn a bad download into the code
  # that resolves every source, so the fetch must be checked against the pin.
  failures << "Pinchflat must fetch the extractor against the declared checksum" unless
    tasks.count { |task|
      task.dig("ansible.builtin.get_url", "checksum").to_s.include?("pinchflat_ytdlp_sha256")
    } == 1

  # The credential reaches the target through the rendered environment and the
  # authenticated probe. Both must stay redacted; the anonymous refusal probe
  # carries no credential and stays readable.
  credential_tasks = tasks.select do |task|
    task.to_s.match?(/vault_pinchflat_admin_(?:username|password)/)
  end
  failures << "every Pinchflat task naming the credential must use no_log" unless
    credential_tasks.length >= 2 && credential_tasks.all? { |task| task["no_log"] == true }
  environment_render = tasks.find do |task|
    task.dig("ansible.builtin.template", "src") == "env.j2"
  end
  failures << "the Pinchflat environment render must be redacted and private" unless
    environment_render && environment_render["no_log"] == true &&
      environment_render.dig("ansible.builtin.template", "mode") == "0600"

  verification = tasks.select { |task| Array(task["tags"]).include?("platform_verify_pinchflat") }
  verification_urls = verification.filter_map { |task| task.dig("ansible.builtin.uri", "url") }
  failures << "Pinchflat verification must read its unauthenticated health endpoint" unless
    verification_urls.include?("{{ pinchflat_api }}/healthcheck")
  authenticated = verification.find do |task|
    task.dig("ansible.builtin.uri", "url_password") == "{{ vault_pinchflat_admin_password }}"
  end
  failures << "Pinchflat verification must authenticate as the vault administrator" unless
    authenticated && authenticated.dig("ansible.builtin.uri", "force_basic_auth") == true
  anonymous = verification.find do |task|
    uri = task["ansible.builtin.uri"]
    uri.is_a?(Hash) && uri["url"] == "{{ pinchflat_api }}/" && !uri.key?("url_password")
  end
  failures << "Pinchflat verification must probe the interface anonymously" if anonymous.nil?

  # Both interface probes accept any status and defer to the assertion, so a
  # drifted credential fails with a diagnosis rather than inside the redacted
  # request. The assertion is what pins the two outcomes.
  [authenticated, anonymous].compact.each do |task|
    label = task.fetch("name")
    failures << "#{label} must accept any status and defer to the assertion" unless
      task.dig("ansible.builtin.uri", "status_code") == "{{ range(100, 600) | list }}" &&
      task["failed_when"] == false
  end
  outcome_assertion = verification.find { |task| task.key?("ansible.builtin.assert") }
  conditions = Array(outcome_assertion&.dig("ansible.builtin.assert", "that"))
  failures << "Pinchflat verification must assert its exact health and access outcomes" unless
    conditions.any? { |value| value.include?("pinchflat_verify_health.json.status == 'ok'") } &&
    conditions.any? do |value|
      value.include?("pinchflat_verify_authenticated.status") && value.include?("200")
    end &&
    conditions.any? do |value|
      value.include?("pinchflat_verify_anonymous.status") && value.include?("401")
    end
  # The diagnosis is the point of deferring, so it must not be redacted away.
  failures << "the Pinchflat outcome assertion must stay readable" if
    outcome_assertion && outcome_assertion["no_log"]

  failures << "Pinchflat verification reads must not claim a change" unless
    verification.all? do |task|
      !task.key?("ansible.builtin.uri") ||
        (task["changed_when"] == false && task["check_mode"] == false)
    end
end

unless failures.empty?
  # Every violation, one per line, each line naming the contract that authored it.
  # The prefix is not decoration: tests/<service>_contract_test.rb requires a row
  # that says "this must be refused" to see it, so a Ruby backtrace or a shell
  # diagnostic can no longer stand in for a refusal (#352).
  warn failures.map { |failure| "Pinchflat contract failed: #{failure}" }.join("\n")
  exit 1
end
