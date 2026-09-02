#!/bin/sh
set -eu
set +x

mode=${1:-run}
case $mode in
  static|run) ;;
  *)
    printf '%s\n' 'kapowarr contract accepts only static or run' >&2
    exit 2
    ;;
esac

repo_dir=${PLATFORM_CONTRACT_REPO_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)}
# The embedded Ruby below reads tests/policy_support.rb from here instead of
# carrying its own copy of flatten_tasks.
PLATFORM_CONTRACT_REPO_DIR=$repo_dir
export PLATFORM_CONTRACT_REPO_DIR
ruby - "$repo_dir" <<'RUBY'
require "yaml"

root = ARGV.fetch(0)
failures = []
required = %w[
  roles/kapowarr/defaults/main.yml
  roles/kapowarr/meta/argument_specs.yml
  roles/kapowarr/tasks/main.yml
  roles/kapowarr/templates/env.j2
  services/kapowarr/compose.yml
  services/kapowarr/compose.mac.yml
  services/kapowarr/compose.integration.yml
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
  compose = YAML.safe_load_file(File.join(root, "services/kapowarr/compose.yml"), aliases: true)
  service = compose.fetch("services").fetch("kapowarr")

  # Kapowarr is declared self-contained in this slice: no Prowlarr indexer and no
  # download client are configured for it, so it must not sit on the shared
  # control network, where it would be reachable by every acquisition project
  # for no purpose.
  failures << "Kapowarr must not join the shared media control network" if
    compose.key?("networks") || service.key?("networks")

  # The entrypoint has to start as root to remap its own account, so the
  # platform identity arrives under the linuxserver.io names instead of `user:`.
  failures << "Kapowarr must not override the container user" if service.key?("user")
  {
    "PUID" => "${NAS_UID:?}",
    "PGID" => "${NAS_GID:?}"
  }.each do |name, expected|
    failures << "Kapowarr must take the platform identity as #{name}" unless
      service.dig("environment", name) == expected
  end

  failures << "Kapowarr must mount exactly its database, staging and comics library" unless
    Array(service["volumes"]) == [
      "${KAPOWARR_CONFIG_PATH:?}:/app/db",
      "${KAPOWARR_DOWNLOADS_PATH:?}:/app/temp_downloads",
      "${KAPOWARR_COMICS_PATH:?}:/comics"
    ]

  # The published port and the container port are both pinned by
  # config/media-acquisition.yml, and the Mac override republishes only the host
  # half, so the container half is the one a drifting image tag would move.
  failures << "Kapowarr must publish the catalog web UI port" unless
    Array(service["ports"]) == ["5656:5656"]
  mac = YAML.safe_load_file(File.join(root, "services/kapowarr/compose.mac.yml"))
  failures << "the Mac override must republish the web UI on the harness port" unless
    mac.dig("services", "kapowarr", "ports") == ["${KAPOWARR_HOST_PORT:?}:5656"]

  # The runtime image ships neither curl nor wget, so a health probe written
  # against either would report unhealthy forever.
  health = Array(service.dig("healthcheck", "test")).join(" ")
  failures << "the Kapowarr health probe must use the interpreter the image ships" unless
    health.include?("python3") && health.include?("/api/public")

  defaults = YAML.safe_load_file(File.join(root, "roles/kapowarr/defaults/main.yml"))
  failures << "Kapowarr must write the declared comics library root" unless
    defaults["kapowarr_comics_host_path"] == "{{ nas_media_root }}/Books/Comics"
  failures << "Kapowarr must stage downloads beside the library it imports into" unless
    defaults["kapowarr_downloads_host_path"] ==
      "{{ nas_media_root }}/Books/.acquisition/usenet/comics"
  failures << "Kapowarr must keep its database in the declared config root" unless
    defaults["kapowarr_config_host_path"] == "{{ nas_docker_root }}/kapowarr/config"
  failures << "the declared library root must be the container path the library is mounted at" unless
    defaults["kapowarr_library_root"] == "/comics"

  env_assignments = environment_assignments(
    File.join(root, "roles/kapowarr/templates/env.j2")
  )
  failures << "Kapowarr env must render the CPU set exactly once" unless
    env_assignments.select { |name, _value| name == "PLATFORM_CONTAINER_CPUSET" } ==
      [["PLATFORM_CONTAINER_CPUSET", "{{ platform_effective_container_cpuset }}"]]
  # Kapowarr reads no credential from its environment: every one lives in its own
  # database. A credential appearing here would be a copy nothing consumes.
  failures << "the Kapowarr environment must carry no vault credential" if
    env_assignments.any? { |_name, value| value.include?("vault_") }

  tasks = flatten_tasks(
    YAML.safe_load_file(File.join(root, "roles/kapowarr/tasks/main.yml"), aliases: true)
  )
  failures << "Kapowarr must deploy through docker_compose_v2" unless
    tasks.count { |task| task.dig("community.docker.docker_compose_v2", "state") == "present" } == 1
  failures << "Kapowarr must verify its effective project CPU policy" unless
    tasks.count { |task| task.dig("vars", "container_cpu_service_name") == "kapowarr" } == 1

  # Every task naming either half of the administrator identity must stay
  # redacted: the pair is submitted as a request body, which a module result
  # renders in full.
  credential_tasks = tasks.select do |task|
    task.to_s.match?(/vault_kapowarr_admin_(?:username|password)/)
  end
  failures << "every Kapowarr task naming the administrator must use no_log" unless
    credential_tasks.length >= 4 && credential_tasks.all? { |task| task["no_log"] == true }

  # Kapowarr validates a ComicVine key against comicvine.gamespot.com before it
  # will store one, so no converge may submit it: doing so would make the run
  # depend on a third party. The vault authors it, and the role only guards its
  # shape.
  comicvine_requests = tasks.select do |task|
    task.key?("ansible.builtin.uri") &&
      task.to_s.include?("vault_kapowarr_comicvine_api_key")
  end
  failures << "no Kapowarr request may submit the ComicVine credential" unless
    comicvine_requests.empty?
  comicvine_guard = tasks.find do |task|
    task.key?("ansible.builtin.assert") &&
      task.to_s.include?("vault_kapowarr_comicvine_api_key")
  end
  failures << "Kapowarr must still guard the shape of the authored ComicVine credential" if
    comicvine_guard.nil?

  environment_render = tasks.find do |task|
    task.dig("ansible.builtin.template", "src") == "env.j2"
  end
  failures << "the Kapowarr environment render must be private" unless
    environment_render && environment_render.dig("ansible.builtin.template", "mode") == "0600"

  # The identity write is the one mutation the role performs against a service
  # whose settings interface accepts anything. It must be conditional on the
  # probes, or every converge would rewrite the login and never report a
  # converged state.
  identity_write = tasks.find do |task|
    task.dig("ansible.builtin.uri", "method") == "PUT" &&
      task.to_s.include?("auth_password")
  end
  identity_conditions = Array(identity_write&.fetch("when", nil)).join(" ")
  failures << "the Kapowarr identity write must be gated on the deployed identity" unless
    identity_write && identity_conditions.include?("kapowarr_identity_current") &&
    identity_conditions.include?("ansible_check_mode")

  # The settings declaration is this platform's ownership of Kapowarr's
  # configuration, and its shape is what keeps that ownership convergent.
  # Kapowarr masks every stored credential on read -- both halves of the
  # administrator identity answer as literal asterisks -- so a declaration
  # naming one could never match what comes back, and the write would run on
  # every converge. The service order is excluded for a different reason: the
  # application validates it as a permutation of its own service list, so it is
  # declared as a partial ordering and merged over the deployed order instead.
  declared_settings = defaults["kapowarr_settings"]
  credential_keys = Array(defaults["kapowarr_settings_credential_keys"])
  failures << "Kapowarr must declare the application settings it owns" unless
    declared_settings.is_a?(Hash) && !declared_settings.empty?
  failures << "the Kapowarr credential key list must name every masked credential" unless
    (%w[api_key auth_username auth_password comicvine_api_key] - credential_keys).empty?
  if declared_settings.is_a?(Hash)
    named_credentials = declared_settings.keys & credential_keys
    failures << "the declared Kapowarr settings must name no credential: " \
                "#{named_credentials.join(', ')}" unless named_credentials.empty?
    failures << "the declared Kapowarr settings must not carry the service order" if
      declared_settings.key?("service_preference")
    # Komga indexes the directory these name, so a change that drops them hands
    # a second service's view of the library back to the web interface.
    failures << "the declared Kapowarr settings must own the library naming templates" unless
      (%w[volume_folder_naming file_naming] - declared_settings.keys).empty?
  end
  failures << "Kapowarr must declare its download service order" if
    Array(defaults["kapowarr_service_preference"]).empty?

  settings_read = tasks.find do |task|
    task.dig("ansible.builtin.uri", "method") == "GET" &&
      task.dig("ansible.builtin.uri", "url").to_s.include?("/api/settings") &&
      !Array(task["tags"]).include?("platform_verify_kapowarr")
  end
  failures << "Kapowarr must read its deployed settings before declaring them" if settings_read.nil?
  # The read carries the API key in its query string and is a read: it must be
  # redacted, must not claim a change, and must really run under --check, or the
  # write decides from nothing.
  failures << "the Kapowarr settings read must be a redacted, real, changeless read" unless
    settings_read && settings_read["changed_when"] == false &&
    settings_read["check_mode"] == false && settings_read["no_log"] == true

  # The interface answers a no-op write and a real write identically, so the
  # write has to be gated on a difference computed before it, or the role
  # reports a change on every converge.
  settings_write = tasks.find do |task|
    task.dig("ansible.builtin.uri", "method") == "PUT" &&
      task.dig("ansible.builtin.uri", "url").to_s.include?("/api/settings") &&
      task.dig("ansible.builtin.uri", "body").to_s.include?("kapowarr_settings_declared")
  end
  settings_conditions = Array(settings_write&.fetch("when", nil)).join(" ")
  failures << "the Kapowarr settings write must be gated on the resolved drift" unless
    settings_write && settings_conditions.include?("kapowarr_settings_drift_keys") &&
    settings_conditions.include?("ansible_check_mode")
  failures << "the Kapowarr settings write must stay redacted" unless
    settings_write && settings_write["no_log"] == true

  # The volume folder migration is the only mutation in this repository that
  # moves a directory inside a media library, and the one the operator reviews
  # with --check --diff before it runs. Three properties keep that reviewable.
  failures << "the Kapowarr volume folder migration must be pinned closed" unless
    defaults.fetch("kapowarr_volume_folder_migration_allowed", nil) == false
  migration_option = YAML.safe_load_file(
    File.join(root, "roles/kapowarr/meta/argument_specs.yml")
  ).dig("argument_specs", "main", "options", "kapowarr_volume_folder_migration_allowed")
  failures << "the Kapowarr volume folder migration input must be a declared bool" unless
    migration_option.is_a?(Hash) && migration_option["type"] == "bool"

  # First: the move is gated on both the one-convergence input and check mode,
  # so neither an ordinary converge nor a review can move a directory.
  folder_migration = tasks.find do |task|
    body = task.dig("ansible.builtin.uri", "body")
    task.dig("ansible.builtin.uri", "method") == "PUT" &&
      body.is_a?(Hash) && body.key?("volume_folder")
  end
  migration_conditions = Array(folder_migration&.fetch("when", nil)).join(" ")
  failures << "Kapowarr must migrate volume folders through the application" if
    folder_migration.nil?
  failures << "the Kapowarr volume folder move must be gated on the one-convergence input" unless
    folder_migration &&
    migration_conditions.include?("kapowarr_volume_folder_migration_allowed") &&
    migration_conditions.include?("ansible_check_mode")
  # Second: it asks for the folder the application derives rather than naming
  # one, and repairs the custom-folder flag the same call would otherwise set --
  # a volume marked as carrying an operator-chosen folder is one Kapowarr stops
  # re-deriving, so the next template change would converge silently wrong.
  migration_body = folder_migration&.dig("ansible.builtin.uri", "body") || {}
  failures << "the Kapowarr volume folder move must take the derived folder" unless
    migration_body["volume_folder"].nil? && migration_body["custom_folder"] == false
  # Third: the plan is read from the application's own rename preview, and that
  # read must really run under --check, or the review reports nothing.
  rename_reads = tasks.select do |task|
    task.dig("ansible.builtin.uri", "url").to_s.include?("/rename?api_key=")
  end
  failures << "Kapowarr must read the application's own rename plan per volume" if
    rename_reads.length < 2
  rename_reads.each do |task|
    failures << "#{task.fetch('name')} must be a redacted, real, changeless read" unless
      task["changed_when"] == false && task["check_mode"] == false && task["no_log"] == true
  end
  # And the review itself: one report per volume, naming the folder it holds and
  # the folder the migration would move it to.
  migration_report = tasks.find do |task|
    task.key?("ansible.builtin.debug") &&
      task["loop"].to_s.include?("kapowarr_volume_folder_migrations")
  end
  failures << "Kapowarr must report each volume folder it would move" unless
    migration_report &&
    migration_report.dig("ansible.builtin.debug", "msg").to_s.include?("item.folder") &&
    migration_report.dig("ansible.builtin.debug", "msg").to_s.include?("item.target")

  # Kapowarr records a credential-free auth POST as a failed login, so every
  # anonymous probe is gated on the authentication mode the role has already
  # read. At mode 2 the authored pair is in force and an empty body can only be
  # refused, so an ungated probe writes a WARNING into the application's own
  # security log on every converge and buries a real attempt among its own. The
  # gate is asserted here because a comment cannot fail a run: the probe still
  # has to exist for the instance that is genuinely open.
  anonymous_probes = tasks.select do |task|
    task.dig("ansible.builtin.uri", "url") == "{{ kapowarr_api }}/api/auth" &&
      task.dig("ansible.builtin.uri", "body") == {}
  end
  failures << "Kapowarr must probe the login without a credential" if anonymous_probes.empty?
  anonymous_probes.each do |task|
    probe_conditions = Array(task["when"]).join(" ")
    failures << "#{task.fetch('name')} must be gated on the authentication mode already read" unless
      probe_conditions.include?("authentication_method") && probe_conditions.include?("2")
  end

  verification = tasks.select { |task| Array(task["tags"]).include?("platform_verify_kapowarr") }
  verification_urls = verification.filter_map { |task| task.dig("ansible.builtin.uri", "url") }
  failures << "Kapowarr verification must read its unauthenticated public endpoint" unless
    verification_urls.include?("{{ kapowarr_api }}/api/public")
  authenticated = verification.find do |task|
    task.dig("ansible.builtin.uri", "body", "password") == "{{ vault_kapowarr_admin_password }}"
  end
  failures << "Kapowarr verification must authenticate as the vault administrator" if
    authenticated.nil?
  anonymous = verification.find do |task|
    body = task.dig("ansible.builtin.uri", "body")
    task.dig("ansible.builtin.uri", "url") == "{{ kapowarr_api }}/api/auth" && body == {}
  end
  failures << "Kapowarr verification must probe the login without a credential" if anonymous.nil?
  roots = verification.find do |task|
    task.dig("ansible.builtin.uri", "url").to_s.include?("/api/rootfolder")
  end
  failures << "Kapowarr verification must read the library roots it owns" if roots.nil?
  settings_verification = verification.find do |task|
    task.dig("ansible.builtin.uri", "url").to_s.include?("/api/settings")
  end
  failures << "Kapowarr verification must read the settings it declares" if
    settings_verification.nil?

  # Every probe accepts any status and defers to the assertion, so a drifted
  # credential fails with a diagnosis rather than inside the redacted request.
  # The assertion is what pins the outcomes.
  [authenticated, anonymous, roots].compact.each do |task|
    label = task.fetch("name")
    failures << "#{label} must accept any status and defer to the assertion" unless
      task.dig("ansible.builtin.uri", "status_code") == "{{ range(100, 600) | list }}" &&
      task["failed_when"] == false
  end
  outcome_assertion = verification.find { |task| task.key?("ansible.builtin.assert") }
  conditions = Array(outcome_assertion&.dig("ansible.builtin.assert", "that"))
  failures << "Kapowarr verification must assert its exact access and ownership outcomes" unless
    conditions.any? do |value|
      value.include?("kapowarr_verify_public") && value.include?("authentication_method") &&
        value.include?("2")
    end &&
    conditions.any? do |value|
      value.include?("kapowarr_verify_identity.status") && value.include?("200")
    end &&
    conditions.any? do |value|
      value.include?("kapowarr_verify_anonymous.status") && value.include?("401")
    end &&
    conditions.any? do |value|
      value.include?("kapowarr_verify_roots") && value.include?("kapowarr_library_root")
    end &&
    conditions.any? do |value|
      value.include?("kapowarr_verify_settings") && value.include?("kapowarr_settings")
    end &&
    conditions.any? do |value|
      value.include?("kapowarr_verify_settings") &&
        value.include?("kapowarr_service_preference")
    end
  # The diagnosis is the point of deferring, so it must not be redacted away.
  failures << "the Kapowarr outcome assertion must stay readable" if
    outcome_assertion && outcome_assertion["no_log"]

  # The folder shape is verified, not merely migrated: a volume added while a
  # hand-edited template was in force, or a folder renamed in the web interface,
  # puts a series back under a name Komga titles wrongly, and nothing in
  # Kapowarr reports it. The migration alone would fix the library once and go
  # quiet.
  folder_assertion = verification.select { |task| task.key?("ansible.builtin.assert") }.find do |task|
    Array(task.dig("ansible.builtin.assert", "that")).any? do |value|
      value.to_s.include?("kapowarr_verify_volume_folder_drift")
    end
  end
  failures << "Kapowarr verification must assert every volume folder is the derived one" if
    folder_assertion.nil?
  # The drift list is resolved from a loop over what the application reported, so
  # an empty list is a real verdict only when both reads answered for every
  # volume. Without that floor a 401 verifies a library of nothing.
  folder_conditions = Array(folder_assertion&.dig("ansible.builtin.assert", "that")).join(" ")
  failures << "the Kapowarr volume folder assertion must require both reads to have answered" unless
    folder_assertion && folder_conditions.include?("kapowarr_verify_volumes.status") &&
    folder_conditions.include?("kapowarr_verify_rename_plans.results")
  # An unauthorized Kapowarr answers `result: {}` where the library was, and a
  # loop over that mapping dies with a type error instead of with the assertion's
  # diagnosis. The per-volume verification read loops the normalized list for
  # that reason, not for tidiness.
  failures << "the Kapowarr verification must loop a normalized volume list" unless
    rename_reads.any? do |task|
      Array(task["tags"]).include?("platform_verify_kapowarr") &&
        task["loop"].to_s.include?("kapowarr_verify_volume_list")
    end

  failures << "Kapowarr verification reads must not claim a change" unless
    verification.all? do |task|
      !task.key?("ansible.builtin.uri") ||
        (task["changed_when"] == false && task["check_mode"] == false)
    end
end

unless failures.empty?
  warn failures.join("\n")
  exit 1
end
RUBY

[ "$mode" = static ] && {
  printf '%s\n' 'kapowarr static contract: authenticated comics writer ownership holds'
  exit 0
}

# The runtime half. Both disposable lanes deploy Kapowarr under a project
# namespace and name the container after it; production leaves the namespace
# empty and keeps the canonical Compose name.
: "${PLATFORM_CONTRACT_VAULT_FILE:=${PLATFORM_MAC_VAULT_FILE:-}}"
: "${PLATFORM_CONTRACT_VAULT_PASSWORD_FILE:=${PLATFORM_MAC_VAULT_PASSWORD_FILE:-}}"
: "${PLATFORM_CONTRACT_VAULT_FILE:?PLATFORM_CONTRACT_VAULT_FILE is required}"
: "${PLATFORM_CONTRACT_VAULT_PASSWORD_FILE:?PLATFORM_CONTRACT_VAULT_PASSWORD_FILE is required}"
: "${PLATFORM_DOCKER_ROOT:?PLATFORM_DOCKER_ROOT is required}"
: "${PLATFORM_KAPOWARR_PORT:=5656}"
PLATFORM_KAPOWARR_CONTAINER=${PLATFORM_PROJECT_NAME:+$PLATFORM_PROJECT_NAME-}kapowarr
PLATFORM_CONTRACT_REPO_DIR=$repo_dir
export PLATFORM_CONTRACT_VAULT_FILE PLATFORM_CONTRACT_VAULT_PASSWORD_FILE
export PLATFORM_DOCKER_ROOT PLATFORM_KAPOWARR_PORT PLATFORM_KAPOWARR_CONTAINER
export PLATFORM_CONTRACT_REPO_DIR

exec ruby - <<'RUBY'
require "json"
require "net/http"
require "open3"
require "uri"
require "yaml"

READY_TIMEOUT_SECONDS = 120
BASE = URI("http://127.0.0.1:#{Integer(ENV.fetch('PLATFORM_KAPOWARR_PORT'), 10)}")
CONTAINER = ENV.fetch("PLATFORM_KAPOWARR_CONTAINER")
# Kapowarr's whole state is one SQLite database beneath the declared config
# root. It is what has to survive a container recreation, and its absence is
# what a wrongly owned or wrongly mounted config bind looks like.
DATABASE = File.join(ENV.fetch("PLATFORM_DOCKER_ROOT"), "kapowarr", "config", "Kapowarr.db")
LIBRARY_ROOT = "/comics"

def fail_contract(message)
  warn "Kapowarr contract failed: #{message}"
  exit 1
end

def get(path)
  request = Net::HTTP::Get.new(URI.join(BASE, path))
  Net::HTTP.start(BASE.host, BASE.port, read_timeout: 15) { |http| http.request(request) }
end

def post(path, payload)
  request = Net::HTTP::Post.new(URI.join(BASE, path), "Content-Type" => "application/json")
  request.body = JSON.generate(payload)
  Net::HTTP.start(BASE.host, BASE.port, read_timeout: 15) { |http| http.request(request) }
end

def wait_for_readiness
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + READY_TIMEOUT_SECONDS
  loop do
    begin
      response = get("/api/public")
      return response if response.code == "200"
    rescue StandardError
      nil
    end
    fail_contract("Kapowarr never answered its public endpoint") if
      Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

    sleep 2
  end
end

public_response = wait_for_readiness
begin
  document = JSON.parse(public_response.body)
rescue JSON::ParserError
  fail_contract("Kapowarr public endpoint did not answer JSON")
end
# 2 is the username-and-password mode. 1 accepts any username against the
# password, and 0 is no login at all, so anything below 2 is an open writer.
fail_contract("Kapowarr does not enforce the username and password pair") unless
  document.dig("result", "authentication_method") == 2

state, _error, status = Open3.capture3(
  "docker", "inspect", CONTAINER, "--format", "{{.State.Health.Status}}"
)
fail_contract("the Kapowarr container could not be inspected") unless status.success?
fail_contract("the Kapowarr container is not healthy") unless state.strip == "healthy"

vault_yaml, vault_error, vault_status = Open3.capture3(
  "ansible-vault", "view", "--vault-password-file",
  ENV.fetch("PLATFORM_CONTRACT_VAULT_PASSWORD_FILE"),
  ENV.fetch("PLATFORM_CONTRACT_VAULT_FILE")
)
fail_contract("encrypted vault could not be read") unless vault_status.success?
vault = YAML.safe_load(vault_yaml)
vault_yaml.replace("\0" * vault_yaml.bytesize)
vault_error.replace("\0" * vault_error.bytesize)
username = vault.fetch("vault_kapowarr_admin_username")
password = vault.fetch("vault_kapowarr_admin_password")

# A successful login is what hands out the API key that authorizes every route
# that renames or deletes comics, so all three outcomes are asserted: refused
# with no credential, refused with the wrong one, accepted with exactly the
# vault's.
fail_contract("Kapowarr logged in a caller with no credential") unless
  post("/api/auth", {}).code == "401"
fail_contract("Kapowarr logged in a caller with a wrong password") unless
  post("/api/auth", "username" => username, "password" => "contract-wrong-password").code == "401"
login = post("/api/auth", "username" => username, "password" => password)
fail_contract("Kapowarr refused the vault-authored administrator") unless login.code == "200"
api_key = JSON.parse(login.body).dig("result", "api_key")
fail_contract("Kapowarr returned no API key to the vault administrator") unless
  api_key.is_a?(String) && api_key.match?(/\A[0-9a-f]{32}\z/)

roots = get("/api/rootfolder?api_key=#{api_key}")
fail_contract("Kapowarr refused to list its library roots") unless roots.code == "200"
declared = JSON.parse(roots.body).fetch("result").map do |entry|
  entry.fetch("folder").sub(%r{/+\z}, "")
end
fail_contract("Kapowarr does not own exactly the declared comics library root") unless
  declared == [LIBRARY_ROOT]

fail_contract("Kapowarr did not persist its database in the declared config root") unless
  File.file?(DATABASE) && File.size?(DATABASE)

# The static half proves the role declares these settings and gates the write on
# a difference. This half proves the deployed application actually holds them,
# which is the only place the merge, the value types and the application's own
# validation are exercised against a real Kapowarr.
settings = get("/api/settings?api_key=#{api_key}")
fail_contract("Kapowarr refused to report its settings") unless settings.code == "200"
deployed_settings = JSON.parse(settings.body).fetch("result")
role_defaults = YAML.safe_load_file(
  File.join(ENV.fetch("PLATFORM_CONTRACT_REPO_DIR"), "roles/kapowarr/defaults/main.yml")
)
mismatched = role_defaults.fetch("kapowarr_settings").reject do |key, value|
  deployed_settings[key] == value
end
unless mismatched.empty?
  fail_contract(
    "Kapowarr does not hold the declared application settings: #{mismatched.keys.join(', ')}"
  )
end

# The declared order is a partial one: the services it names must appear in that
# relative order, and a service the deployed version knows and the declaration
# does not is free to sit anywhere. Filtering both lists by the other is what
# makes this a statement about order rather than about membership.
declared_order = Array(role_defaults.fetch("kapowarr_service_preference"))
deployed_order = Array(deployed_settings.fetch("service_preference"))
fail_contract("Kapowarr does not hold the declared download service order") unless
  deployed_order.select { |service| declared_order.include?(service) } ==
    declared_order.select { |service| deployed_order.include?(service) }

puts "kapowarr contract: health, exclusive administrator identity, comics root ownership, " \
     "declared application settings, and persisted state hold"
RUBY
