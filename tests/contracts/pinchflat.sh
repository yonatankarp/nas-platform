#!/bin/sh
set -eu
set +x

mode=${1:-run}
case $mode in
  static|run) ;;
  *)
    printf '%s\n' 'pinchflat contract accepts only static or run' >&2
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

  failures << "Pinchflat must mount exactly its config and YouTube library" unless
    Array(service["volumes"]) == [
      "${PINCHFLAT_CONFIG_PATH:?}:/config",
      "${PINCHFLAT_DOWNLOADS_PATH:?}:/downloads"
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
  warn failures.join("\n")
  exit 1
end
RUBY

[ "$mode" = static ] && {
  printf '%s\n' 'pinchflat static contract: authenticated YouTube writer ownership holds'
  exit 0
}

# The runtime half. Both disposable lanes deploy Pinchflat under a project
# namespace and name the container after it; production leaves the namespace
# empty and keeps the canonical Compose name.
: "${PLATFORM_CONTRACT_VAULT_FILE:=${PLATFORM_MAC_VAULT_FILE:-}}"
: "${PLATFORM_CONTRACT_VAULT_PASSWORD_FILE:=${PLATFORM_MAC_VAULT_PASSWORD_FILE:-}}"
: "${PLATFORM_CONTRACT_VAULT_FILE:?PLATFORM_CONTRACT_VAULT_FILE is required}"
: "${PLATFORM_CONTRACT_VAULT_PASSWORD_FILE:?PLATFORM_CONTRACT_VAULT_PASSWORD_FILE is required}"
: "${PLATFORM_DOCKER_ROOT:?PLATFORM_DOCKER_ROOT is required}"
: "${PLATFORM_PINCHFLAT_PORT:=8945}"
PLATFORM_PINCHFLAT_CONTAINER=${PLATFORM_PROJECT_NAME:+$PLATFORM_PROJECT_NAME-}pinchflat
export PLATFORM_CONTRACT_VAULT_FILE PLATFORM_CONTRACT_VAULT_PASSWORD_FILE
export PLATFORM_DOCKER_ROOT PLATFORM_PINCHFLAT_PORT PLATFORM_PINCHFLAT_CONTAINER

exec ruby - <<'RUBY'
require "json"
require "net/http"
require "open3"
require "timeout"
require "uri"
require "yaml"

READY_TIMEOUT_SECONDS = 120
BASE = URI("http://127.0.0.1:#{Integer(ENV.fetch('PLATFORM_PINCHFLAT_PORT'), 10)}")
CONTAINER = ENV.fetch("PLATFORM_PINCHFLAT_CONTAINER")
# Pinchflat's whole state is one SQLite database beneath the declared config
# root. It is what has to survive a container recreation, and its absence is
# what a wrongly owned or wrongly mounted config bind looks like.
DATABASE = File.join(ENV.fetch("PLATFORM_DOCKER_ROOT"), "pinchflat", "config", "db", "pinchflat.db")

def fail_contract(message)
  warn "Pinchflat contract failed: #{message}"
  exit 1
end

def request(path, credentials: nil)
  request = Net::HTTP::Get.new(URI.join(BASE, path))
  request.basic_auth(*credentials) if credentials
  Net::HTTP.start(BASE.host, BASE.port, read_timeout: 15) { |http| http.request(request) }
end

def wait_for_health
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + READY_TIMEOUT_SECONDS
  loop do
    begin
      response = request("/healthcheck")
      return response if response.code == "200"
    rescue StandardError
      nil
    end
    fail_contract("Pinchflat never answered its health endpoint") if
      Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

    sleep 2
  end
end

health = wait_for_health
begin
  document = JSON.parse(health.body)
rescue JSON::ParserError
  fail_contract("Pinchflat health endpoint did not answer JSON")
end
fail_contract("Pinchflat did not report a healthy status") unless document == { "status" => "ok" }

state, _error, status = Open3.capture3(
  "docker", "inspect", CONTAINER, "--format", "{{.State.Health.Status}}"
)
fail_contract("the Pinchflat container could not be inspected") unless status.success?
fail_contract("the Pinchflat container is not healthy") unless state.strip == "healthy"

vault_yaml, vault_error, vault_status = Open3.capture3(
  "ansible-vault", "view", "--vault-password-file",
  ENV.fetch("PLATFORM_CONTRACT_VAULT_PASSWORD_FILE"),
  ENV.fetch("PLATFORM_CONTRACT_VAULT_FILE")
)
fail_contract("encrypted vault could not be read") unless vault_status.success?
vault = YAML.safe_load(vault_yaml)
vault_yaml.replace("\0" * vault_yaml.bytesize)
vault_error.replace("\0" * vault_error.bytesize)
credentials = [
  vault.fetch("vault_pinchflat_admin_username"), vault.fetch("vault_pinchflat_admin_password")
]

# The interface is the writer, so all three outcomes are asserted: refused with
# no credential, refused with the wrong one, accepted with exactly the vault's.
fail_contract("Pinchflat served its interface to an anonymous request") unless
  request("/").code == "401"
fail_contract("Pinchflat served its interface to a wrong password") unless
  request("/", credentials: [credentials.first, "contract-wrong-password"]).code == "401"
fail_contract("Pinchflat refused the vault-authored administrator") unless
  request("/", credentials: credentials).code == "200"

fail_contract("Pinchflat did not persist its database in the declared config root") unless
  File.file?(DATABASE) && File.size?(DATABASE)

puts "pinchflat contract: health, exclusive basic-auth identity, and persisted state hold"
RUBY
