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
def flatten_tasks(tasks)
  Array(tasks).flat_map do |task|
    next [] unless task.is_a?(Hash)

    [task] + flatten_tasks(task["block"]) + flatten_tasks(task["rescue"]) +
      flatten_tasks(task["always"])
  end
end

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
    end
  # The diagnosis is the point of deferring, so it must not be redacted away.
  failures << "the Kapowarr outcome assertion must stay readable" if
    outcome_assertion && outcome_assertion["no_log"]

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
export PLATFORM_CONTRACT_VAULT_FILE PLATFORM_CONTRACT_VAULT_PASSWORD_FILE
export PLATFORM_DOCKER_ROOT PLATFORM_KAPOWARR_PORT PLATFORM_KAPOWARR_CONTAINER

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

puts "kapowarr contract: health, exclusive administrator identity, comics root ownership, " \
     "and persisted state hold"
RUBY
