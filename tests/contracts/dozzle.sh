#!/bin/sh
set -eu
set +x
umask 077

mode=${1:-verify}
case $mode in
  static|verify|drift|drift-verify|notify|\
  duplicate-dispatcher-create|duplicate-dispatcher-verify|\
  duplicate-dispatcher-assert-output|duplicate-dispatcher-cleanup|\
  duplicate-rule-create|duplicate-rule-verify|duplicate-rule-assert-output|\
  duplicate-rule-cleanup|surplus-create|surplus-verify|surplus-removed|\
  surplus-cleanup|check-mixed-create|check-mixed-unchanged|\
  check-mixed-cleanup|check-mixed-recover|check-missing-create|\
  check-missing-unchanged|check-missing-cleanup|assert-check-mixed-output|\
  assert-check-missing-output) ;;
  *) exit 2 ;;
esac
[ "$#" -eq 0 ] || shift

repo_dir=${PLATFORM_CONTRACT_REPO_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)}
compose=$repo_dir/services/dozzle/compose.yml
relay_script=$repo_dir/services/dozzle/alert_relay.py
role=$repo_dir/roles/dozzle/tasks/main.yml
defaults=$repo_dir/roles/dozzle/defaults/main.yml
env_template=$repo_dir/roles/dozzle/templates/env.j2
deployment_inputs=$repo_dir/roles/deployment_bundle/tasks/inputs.yml
deployment_bundle=$repo_dir/roles/deployment_bundle/tasks/main.yml
integration=$repo_dir/tests/integration.sh
mac_drift=$repo_dir/tests/mac/hooks/drift/20-dozzle.sh
mac_verify=$repo_dir/tests/mac/hooks/verify/20-dozzle.sh

fail_contract() {
  printf 'Dozzle contract failed: %s\n' "$1" >&2
  exit 1
}

[ -f "$compose" ] || fail_contract 'services/dozzle/compose.yml is absent'
[ -f "$relay_script" ] || fail_contract 'services/dozzle/alert_relay.py is absent'
[ -f "$role" ] || fail_contract 'roles/dozzle/tasks/main.yml is absent'

render_group_contract() {
  stack=$1
  expected_group=$2
  variant=$3
  shift 3
  rendered=$(env \
    PLATFORM_PROJECT_NAME=dozzle-contract PLATFORM_CONTAINER_CPUSET=0-2 \
    PLATFORM_DOCKER_ROOT=/tmp/dozzle-contract/docker \
    PLATFORM_CURRENT_DIR="$repo_dir" DOZZLE_STATE_ROOT=/tmp/dozzle-contract/docker/dozzle/data \
    NAS_DOCKER_ROOT=/tmp/dozzle-contract/docker \
    NAS_MEDIA_ROOT=/tmp/dozzle-contract/media NAS_RENDER_DEVICE=/dev/null \
    NAS_UID=1000 NAS_GID=100 \
    BESZEL_APP_URL=http://127.0.0.1:8090 BESZEL_SYSTEM_NAME=contract \
    BESZEL_AGENT_KEY=contract BESZEL_AGENT_TOKEN=contract BESZEL_HOST_PORT=38090 \
    DOZZLE_HOST_PORT=38080 NTFY_HOST_PORT=32586 NTFY_BASE_URL=http://127.0.0.1:32586 \
    ALERT_RELAY_SCRIPT_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    ALERT_RELAY_TOKEN=contract-relay-token NTFY_PUBLISH_URL=http://host.docker.internal:32586/ \
    NTFY_TOPIC=nas-critical NTFY_CONTAINERS_TOPIC=nas-containers NTFY_TOKEN=contract-ntfy-token \
    NTFY_AUTH_USERS= NTFY_AUTH_ACCESS= NTFY_AUTH_TOKENS= \
    AUDIOBOOKSHELF_HOST_PORT=33378 \
    AUDIOBOOKSHELF_CONFIG_PATH=/tmp/dozzle-contract/audiobookshelf-config \
    AUDIOBOOKSHELF_METADATA_PATH=/tmp/dozzle-contract/audiobookshelf-metadata \
    AUDIOBOOKSHELF_BACKUP_PATH=/tmp/dozzle-contract/audiobookshelf-backups \
    AUDIOBOOKSHELF_MEDIA_PATH=/tmp/dozzle-contract/audiobooks \
    KOMGA_HOST_PORT=35600 KOMGA_CONFIG_PATH=/tmp/dozzle-contract/komga-config \
    KOMGA_LIBRARY_PATH=/tmp/dozzle-contract/books JELLYFIN_HOST_PORT=38096 \
    JELLYFIN_CONFIG_PATH=/tmp/dozzle-contract/jellyfin-config \
    JELLYFIN_CACHE_PATH=/tmp/dozzle-contract/jellyfin-cache \
    JELLYFIN_MEDIA_PATH=/tmp/dozzle-contract/media IMMICH_HOST_PORT=32283 \
    IMMICH_DB_NAME=contract IMMICH_DB_USERNAME=contract IMMICH_DB_PASSWORD=contract \
    PAPERLESS_HOST_PORT=38000 PAPERLESS_POSTGRES_PATH=/tmp/dozzle-contract/paperless-postgres \
    PAPERLESS_REDIS_PATH=/tmp/dozzle-contract/paperless-redis \
    PAPERLESS_DATA_PATH=/tmp/dozzle-contract/paperless-data \
    PAPERLESS_CACHE_PATH=/tmp/dozzle-contract/paperless-cache \
    PAPERLESS_TESSDATA_PATH=/tmp/dozzle-contract/paperless-tessdata \
    PAPERLESS_MEDIA_PATH=/tmp/dozzle-contract/paperless-media \
    PAPERLESS_CONSUME_PATH=/tmp/dozzle-contract/paperless-consume \
    PAPERLESS_EXPORT_PATH=/tmp/dozzle-contract/paperless-export \
    PAPERLESS_ADMIN_USER=contract PAPERLESS_ADMIN_PASSWORD=contract \
    PAPERLESS_ADMIN_MAIL=contract@example.invalid PAPERLESS_DBHOST=db \
    PAPERLESS_REDIS=redis://broker:6379 PAPERLESS_TIKA_ENDPOINT=http://tika:9998 \
    PAPERLESS_GOTENBERG_ENDPOINT=http://gotenberg:3000 PAPERLESS_AI_ENABLED=false \
    PAPERLESS_AI_LLM_ENDPOINT=http://example.invalid:11434 PAPERLESS_AI_LLM_MODEL=contract \
    PAPERLESS_SECRET_KEY=contract DB_NAME=contract DB_USER=contract DB_PASSWORD=contract \
    TINYMEDIAMANAGER_WEB_HOST_PORT=34000 TINYMEDIAMANAGER_API_HOST_PORT=37878 \
    TINYMEDIAMANAGER_DATA_PATH=/tmp/dozzle-contract/tinymediamanager-data \
    TINYMEDIAMANAGER_MOVIES_PATH=/tmp/dozzle-contract/movies \
    TINYMEDIAMANAGER_SERIES_PATH=/tmp/dozzle-contract/series \
    TINYMEDIAMANAGER_PASSWORD=contract \
    USER_ID=1000 GROUP_ID=100 TZ=UTC \
    docker compose --project-name "dozzle-contract-$stack-$variant" "$@" config --format json) ||
    fail_contract "$stack $variant Compose render failed"

  DOZZLE_RENDERED_COMPOSE=$rendered ruby -rjson - "$stack" "$variant" "$expected_group" <<'RUBY'
stack, variant, expected_group = ARGV
services = JSON.parse(ENV.fetch("DOZZLE_RENDERED_COMPOSE")).fetch("services")
services.each do |service, definition|
  matches = definition.fetch("labels", {}).select { |name, _value| name == "dev.dozzle.name" }
  abort "Dozzle contract failed: #{stack} #{variant} #{service} name label is absent" if matches.empty?
  abort "Dozzle contract failed: #{stack} #{variant} #{service} name label differs" unless
    matches == {"dev.dozzle.name" => service}
end
if expected_group.empty?
  abort "Dozzle contract failed: #{stack} #{variant} must remain a single-container stack" unless
    services.length == 1
  services.each do |service, definition|
    abort "Dozzle contract failed: #{stack} #{variant} #{service} left Running Containers grouping" if
      definition.fetch("labels", {}).key?("dev.dozzle.group")
  end
else
  abort "Dozzle contract failed: #{stack} #{variant} must remain a multi-container stack" unless
    services.length > 1
  services.each do |service, definition|
    labels = definition.fetch("labels", {})
    matches = labels.select { |name, _value| name == "dev.dozzle.group" }
    abort "Dozzle contract failed: #{stack} #{variant} #{service} group label differs" unless
      matches == {"dev.dozzle.group" => expected_group}
  end
end
RUBY
}

render_group_variants() {
  stack=$1
  expected_group=$2
  service_dir=$repo_dir/services/$stack
  render_group_contract "$stack" "$expected_group" base -f "$service_dir/compose.yml"
  render_group_contract "$stack" "$expected_group" mac \
    -f "$service_dir/compose.yml" -f "$service_dir/compose.mac.yml"
}

if [ "$mode" = static ]; then
  ruby -r"$repo_dir/tests/policy_support.rb" - \
    "$repo_dir/services/audiobookshelf/compose.yml" \
    "$repo_dir/services/beszel/compose.yml" \
    "$repo_dir/services/dozzle/compose.yml" \
    "$repo_dir/services/immich/compose.yml" \
    "$repo_dir/services/jellyfin/compose.yml" \
    "$repo_dir/services/komga/compose.yml" \
    "$repo_dir/services/ntfy/compose.yml" \
    "$repo_dir/services/paperless-ngx/compose.yml" \
    "$repo_dir/services/tinymediamanager/compose.yml" <<'RUBY'
begin
  ARGV.each do |path|
    document = Psych.parse_stream(File.read(path))
    abort "Dozzle contract failed: base Compose has duplicate dev.dozzle.name labels" if
      PolicySupport.duplicate_yaml_keys(document).include?("dev.dozzle.name")
  end
rescue Psych::Exception, SystemCallError
  abort "Dozzle contract failed: base Compose label YAML is invalid"
end
RUBY
  render_group_variants beszel beszel
  render_group_variants dozzle dozzle
  render_group_variants paperless-ngx paperless
  render_group_variants immich immich
  render_group_contract immich immich integration \
    -f "$repo_dir/services/immich/compose.yml" \
    -f "$repo_dir/services/immich/compose.integration.yml"
  render_group_variants audiobookshelf ""
  render_group_variants jellyfin ""
  render_group_variants komga ""
  render_group_variants ntfy ""
  render_group_variants tinymediamanager ""
  for stack in jellyfin tinymediamanager; do
    render_group_contract "$stack" "" integration \
      -f "$repo_dir/services/$stack/compose.yml" \
      -f "$repo_dir/services/$stack/compose.integration.yml"
  done
fi

ruby -ryaml - "$compose" "$relay_script" "$role" "$env_template" \
  "$deployment_inputs" "$deployment_bundle" <<'RUBY'
compose = YAML.safe_load_file(ARGV.fetch(0), aliases: true)
services = compose.fetch("services")
abort "Dozzle contract failed: stack must define exactly alert-relay, dozzle, and socket-proxy" unless
  services.keys.sort == %w[alert-relay dozzle socket-proxy]

dozzle = services.fetch("dozzle")
proxy = services.fetch("socket-proxy")
relay = services.fetch("alert-relay")
expected_environment = {
  "DOZZLE_AUTH_PROVIDER" => "simple",
  "DOZZLE_ENABLE_ACTIONS" => "false",
  "DOZZLE_ENABLE_MCP" => "false",
  "DOZZLE_ENABLE_SHELL" => "false",
  "DOZZLE_NO_ANALYTICS" => "true",
  "DOZZLE_REMOTE_HOST" => "tcp://socket-proxy:2375",
  "TZ" => "${TZ:?}"
}
abort "Dozzle contract failed: security environment differs" unless
  dozzle.fetch("environment") == expected_environment
abort "Dozzle contract failed: Docker socket is mounted outside socket-proxy" if
  [dozzle, relay].any? do |service|
    service.fetch("volumes", []).any? { |volume| volume.to_s.include?("docker.sock") }
  end
abort "Dozzle contract failed: proxy Docker socket must be read-only" unless
  proxy.fetch("volumes") == ["/var/run/docker.sock:/var/run/docker.sock:ro"]
abort "Dozzle contract failed: proxy permissions differ" unless
  proxy.fetch("environment").slice("CONTAINERS", "EVENTS", "INFO", "POST") == {
    "CONTAINERS" => "1", "EVENTS" => "1", "INFO" => "1", "POST" => "0"
  }
abort "Dozzle contract failed: alert relay image is not the multi-architecture Python image" unless
  relay["image"].to_s.start_with?("docker.io/library/python:")
abort "Dozzle contract failed: alert relay runtime identity differs" unless
  relay["user"] == "${NAS_UID:?}:${NAS_GID:?}" && relay["command"] == ["python", "/app/alert_relay.py"]
abort "Dozzle contract failed: alert relay environment differs" unless
  relay["environment"] == {
    "ALERT_RELAY_TOKEN" => "${ALERT_RELAY_TOKEN:?}",
    "NTFY_PUBLISH_URL" => "${NTFY_PUBLISH_URL:?}",
    "NTFY_TOPIC" => "${NTFY_TOPIC:?}",
    "NTFY_CONTAINERS_TOPIC" => "${NTFY_CONTAINERS_TOPIC:?}",
    "NTFY_TOKEN" => "${NTFY_TOKEN:?}",
    "ALERT_STATE_PATH" => "/state/alert-relay.json"
  }
abort "Dozzle contract failed: alert relay mounts differ" unless relay["volumes"] == [
  "${PLATFORM_CURRENT_DIR:?}/services/dozzle/alert_relay.py:/app/alert_relay.py:ro",
  "${DOZZLE_STATE_ROOT:?}/alert-relay:/state"
]
abort "Dozzle contract failed: alert relay must not publish a port" if
  relay.key?("ports") || relay.key?("network_mode")
abort "Dozzle contract failed: alert relay hardening differs" unless
  relay["read_only"] == true && relay["tmpfs"] == ["/tmp"] &&
  relay["security_opt"] == ["no-new-privileges:true"] && relay.key?("healthcheck") &&
  relay["restart"] == "unless-stopped" && relay["logging"] == compose["x-logging"]
abort "Dozzle contract failed: Dozzle dependency health gates differ" unless
  dozzle["depends_on"] == {
    "socket-proxy" => {"condition" => "service_healthy"},
    "alert-relay" => {"condition" => "service_healthy"}
  }
relay_source = File.read(ARGV.fetch(1))
role = File.read(ARGV.fetch(2))
env_template = File.read(ARGV.fetch(3))
deployment_inputs = File.read(ARGV.fetch(4))
deployment_bundle = File.read(ARGV.fetch(5))
abort "Dozzle contract failed: deployment inputs do not validate the alert relay" unless
  deployment_inputs.include?("services/dozzle/alert_relay.py")
abort "Dozzle contract failed: immutable release does not include the alert relay" unless
  deployment_bundle.include?("services/dozzle/alert_relay.py") &&
    deployment_bundle.include?("alert_relay.py")
# Parsed rather than substring-matched: byte offsets do not track task order once
# a task name appears in a comment or a when: expression, and a field found by
# slicing the file between two names is not necessarily on the task that needs it.
role_tasks = YAML.safe_load_file(ARGV.fetch(2), aliases: false)
role_task = lambda { |name| role_tasks.find { |task| task["name"] == name } }
role_at = lambda { |name| role_tasks.index { |task| task["name"] == name } }

revalidate = role_task.call("Revalidate deployment paths before Dozzle runtime use")
relay_inspect = role_task.call("Inspect the tracked Dozzle alert relay and selected state root")
abort "Dozzle contract failed: role does not validate the tracked relay script" unless
  Array(revalidate&.dig("vars", "deployment_target_extra_paths"))
    .include?("{{ platform_current_dir }}/services/dozzle/alert_relay.py") &&
  Array(relay_inspect&.dig("loop"))
    .include?("{{ platform_current_dir }}/services/dozzle/alert_relay.py")

parent_gate = role_task.call("Require a safe Dozzle state parent before child creation")
prepare = role_task.call("Prepare the isolated Dozzle alert relay state directory")
paths_gate = role_task.call("Require safe Dozzle alert relay deployment paths")
abort "Dozzle contract failed: role does not prepare an isolated private relay state directory" unless
  role_task.call("Inspect the selected Dozzle state parent before child creation") &&
  parent_gate && prepare && paths_gate &&
  prepare.dig("ansible.builtin.file", "path") == "{{ dozzle_state_root }}/alert-relay" &&
  prepare.dig("ansible.builtin.file", "state") == "directory" &&
  prepare.dig("ansible.builtin.file", "mode") == "0700" &&
  Array(paths_gate.dig("ansible.builtin.assert", "that"))
    .include?("dozzle_alert_relay_state_root_stat.stat.mode == '0700'") &&
  role_at.call("Require a safe Dozzle state parent before child creation") <
    role_at.call("Prepare the isolated Dozzle alert relay state directory")

child_inspect = role_task.call("Inspect the Dozzle alert relay state child before mutation")
child_gate = role_task.call("Require a safe Dozzle alert relay state child before mutation")
legacy_inspect = role_task.call("Inspect legacy and isolated Dozzle alert relay state files")
child_gate_conditions = Array(child_gate&.dig("ansible.builtin.assert", "that")).join(" ")
abort "Dozzle contract failed: role can mutate an unsafe relay state child" unless
  child_inspect && child_gate && prepare && legacy_inspect &&
  role_at.call("Inspect the Dozzle alert relay state child before mutation") <
    role_at.call("Require a safe Dozzle alert relay state child before mutation") &&
  role_at.call("Require a safe Dozzle alert relay state child before mutation") <
    role_at.call("Prepare the isolated Dozzle alert relay state directory") &&
  role_at.call("Prepare the isolated Dozzle alert relay state directory") <
    role_at.call("Inspect legacy and isolated Dozzle alert relay state files") &&
  child_inspect.dig("ansible.builtin.stat", "path") == "{{ dozzle_state_root }}/alert-relay" &&
  child_inspect.dig("ansible.builtin.stat", "follow") == false &&
  child_inspect["register"] == "dozzle_alert_relay_state_child_before_prepare" &&
  %w[exists isdir islnk mode uid gid]
    .all? { |field| child_gate_conditions.include?("stat.#{field}") } &&
  prepare.dig("ansible.builtin.file", "follow") == false

relocation_gate = role_task.call("Refuse ambiguous or unsafe Dozzle alert relay state relocation")
stop = role_task.call("Stop Dozzle alert delivery before legacy relay state relocation")
relocate = role_task.call("Relocate the legacy Dozzle alert relay state file")
relocate_argv = Array(relocate&.dig("ansible.builtin.command", "argv"))
abort "Dozzle contract failed: role does not safely relocate the legacy relay state file" unless
  legacy_inspect && relocation_gate && stop && relocate &&
  Array(legacy_inspect.dig("loop")) ==
    ["{{ dozzle_state_root }}/alert-relay.json",
     "{{ dozzle_state_root }}/alert-relay/alert-relay.json"] &&
  stop.dig("community.docker.docker_compose_v2", "services") == %w[dozzle alert-relay] &&
  stop.dig("community.docker.docker_compose_v2", "state") == "stopped" &&
  relocate_argv.first == "mv" && relocate_argv[1] == "--" &&
  relocate_argv[2] == "{{ dozzle_state_root }}/alert-relay.json" &&
  relocate_argv[3] == "{{ dozzle_state_root }}/alert-relay/alert-relay.json" &&
  relocate.dig("ansible.builtin.command", "creates") ==
    "{{ dozzle_state_root }}/alert-relay/alert-relay.json" &&
  relocate.dig("ansible.builtin.command", "removes") ==
    "{{ dozzle_state_root }}/alert-relay.json" &&
  stop["when"].to_s.include?("dozzle_alert_relay_legacy_state.stat.exists") &&
  relocate["when"].to_s.include?("dozzle_alert_relay_legacy_state.stat.exists") &&
  role_at.call("Stop Dozzle alert delivery before legacy relay state relocation") <
    role_at.call("Relocate the legacy Dozzle alert relay state file")
abort "Dozzle contract failed: environment does not render the selected state and script roots" unless
  env_template.include?("PLATFORM_CURRENT_DIR={{ platform_current_dir }}") &&
  env_template.include?("DOZZLE_STATE_ROOT={{ dozzle_state_root }}")
abort "Dozzle contract failed: relay source does not bind the private listener" unless
  relay_source.include?('create_server(("0.0.0.0", 8081), config)')
RUBY

ruby -ryaml - "$defaults" "$role" "$integration" "$mac_drift" "$mac_verify" "$mode" <<'RUBY'
defaults_path = ARGV.fetch(0)
defaults = YAML.safe_load_file(defaults_path)
role_tasks = YAML.safe_load_file(ARGV.fetch(1), aliases: false)
integration = File.read(ARGV.fetch(2))
mac_drift = File.read(ARGV.fetch(3))
mac_verify = File.read(ARGV.fetch(4))
expected = {
  "OOM" => ['name == "oom"', 300],
  "Unexpected exit" => ['name == "die" && !(attributes["exitCode"] in ["0", "130", "143", "137"])', 300],
  "Unhealthy" => ['name == "health_status" && attributes["healthStatus"] == "unhealthy"', 0],
  "Recovery" => ['name == "health_status" && attributes["healthStatus"] == "healthy"', 0]
}
alerts = defaults.fetch("dozzle_alerts")
actual = alerts.to_h { |alert| [alert.fetch("name"), [alert.fetch("eventExpression"), alert.fetch("cooldown")]] }
abort "Dozzle contract failed: exact alert definitions differ" unless actual == expected
abort "Dozzle contract failed: alerts must be enabled event-only rules over all containers" unless
  alerts.all? { |alert| alert.fetch("enabled") == true && alert.fetch("containerExpression") == "true" && alert.fetch("logExpression") == "" }
dispatcher = defaults.fetch("dozzle_dispatcher")
abort "Dozzle contract failed: managed dispatcher must target only the private alert relay" unless
  dispatcher.fetch("url") == "http://alert-relay:8081/alerts"
abort "Dozzle contract failed: managed dispatcher authorization differs" unless
  dispatcher.fetch("headers") == {"Authorization" => "Bearer {{ vault_ntfy_dozzle_token }}"}
abort "Dozzle contract failed: role does not wire the write-only ntfy token" unless
  File.read(defaults_path).include?("vault_ntfy_dozzle_token")
expected_template_fields = {
  "version" => "1",
  "rule" => ".Subscription.Name",
  "containerId" => ".Container.ID",
  "container" => ".Container.Name",
  "host" => ".Container.HostName",
  "event" => ".Event.Name",
  "healthStatus" => 'index .Event.Attributes `healthStatus`',
  "exitCode" => 'index .Event.Attributes `exitCode`',
  "timestamp" => '.Event.Timestamp.Format `2006-01-02T15:04:05.999999999Z07:00`'
}
template_source = dispatcher.fetch("template")
abort "Dozzle contract failed: managed dispatcher retains an ntfy presentation envelope" if
  %w[topic title message priority tags markdown].any? { |field| template_source.include?("'#{field}'") }
expected_template_fields.each do |field, expression|
  abort "Dozzle contract failed: managed dispatcher is missing exact #{field}" unless
    template_source.include?("'#{field}':") && template_source.include?(expression)
end
abort "Dozzle contract failed: role does not reconcile enabled state through PATCH" unless
  role_tasks.any? { |task| task.dig("ansible.builtin.uri", "method") == "PATCH" }
planned_tasks = [
  "Report planned managed Dozzle dispatcher creation",
  "Report planned managed Dozzle dispatcher repair",
  "Report planned managed Dozzle alert rule creation",
  "Report planned managed Dozzle alert rule repair",
  "Report planned managed Dozzle alert rule enabled-state repair",
  "Report planned unmanaged Dozzle alert rule removal",
  "Report planned unmanaged Dozzle dispatcher removal"
]
markers = %w[
  DOZZLE_DUPLICATE_DISPATCHER_REFUSED_WITH_SAFE_IDS
  DOZZLE_DUPLICATE_RULE_REFUSED_WITH_SAFE_IDS
  DOZZLE_SURPLUS_STATE_REMOVED
  DOZZLE_CHECK_MIXED_PLANNED_IMMUTABLE_AND_REPAIRED
  DOZZLE_CHECK_MISSING_PLANNED_IMMUTABLE_AND_REPAIRED
]
if ARGV.fetch(5) == "static"
  planned_tasks.each do |name|
    abort "Dozzle contract failed: missing #{name}" unless
      role_tasks.any? { |task| task["name"] == name }
  end
  markers.each do |marker|
    abort "Dozzle contract failed: integration is missing #{marker}" unless integration.include?(marker)
  end
  %w[check-mixed-create check-mixed-unchanged --check --diff].each do |proof|
    abort "Dozzle contract failed: Mac drift proof is missing #{proof}" unless mac_drift.include?(proof)
  end
  abort "Dozzle contract failed: Mac drift proof does not corrupt a managed group label" unless
    mac_drift.include?("dev.dozzle.group")
  abort "Dozzle contract failed: Mac drift proof does not corrupt the managed friendly name" unless
    mac_drift.include?("dev.dozzle.name: dozzle-contract-drift")
  abort "Dozzle contract failed: Mac drift proof does not install an unrelated sentinel label" unless
    mac_drift.include?("dev.dozzle.contract.sentinel")
  abort "Dozzle contract failed: Mac runtime verification does not inspect Docker labels" unless
    mac_verify.include?("docker container inspect") && mac_verify.include?("dev.dozzle.group") &&
      mac_verify.include?("dev.dozzle.name")
end
RUBY

[ "$mode" = static ] && { printf '%s\n' 'Dozzle static contract passed'; exit 0; }

case $mode in
  assert-check-mixed-output|assert-check-missing-output)
    exec ruby - "$mode" "$@" <<'RUBY'
mode, output_path = ARGV
abort "Dozzle contract failed: planned-change output path is absent" unless output_path
abort "Dozzle contract failed: planned-change output is unsafe" unless
  File.file?(output_path) && !File.symlink?(output_path)

expected_counts = {
  "DOZZLE_PLAN_DISPATCHER_CREATE" => [0, 1],
  "DOZZLE_PLAN_DISPATCHER_REPAIR" => [1, 0],
  "DOZZLE_PLAN_RULE_CREATE" => [1, 4],
  "DOZZLE_PLAN_RULE_REPAIR" => [1, 0],
  "DOZZLE_PLAN_RULE_ENABLE_REPAIR" => [1, 0],
  "DOZZLE_PLAN_RULE_REMOVE" => [1, 0],
  "DOZZLE_PLAN_DISPATCHER_REMOVE" => [1, 0]
}
scenario_index = mode == "assert-check-mixed-output" ? 0 : 1
output = File.read(output_path)
expected_counts.each do |marker, counts|
  expected = counts.fetch(scenario_index)
  actual = output.scan(/\b#{Regexp.escape(marker)}\b/).length
  abort "Dozzle contract failed: planned-change marker count differs for #{marker}" unless actual == expected
end
puts "Dozzle planned-change output contract passed"
RUBY
    ;;
esac

: "${PLATFORM_CONTRACT_VAULT_FILE:?}"
: "${PLATFORM_CONTRACT_VAULT_PASSWORD_FILE:?}"
: "${PLATFORM_REPORT_ROOT:?}"
: "${PLATFORM_DOZZLE_PORT:=8080}"
: "${PLATFORM_NTFY_PORT:=2586}"
export PLATFORM_DOZZLE_PORT PLATFORM_NTFY_PORT

exec ruby - "$mode" "$@" <<'RUBY'
require "json"
require "net/http"
require "open3"
require "securerandom"
require "timeout"
require "uri"
require "yaml"

MODE = ARGV.fetch(0)
DOZZLE = URI("http://127.0.0.1:#{Integer(ENV.fetch('PLATFORM_DOZZLE_PORT'), 10)}")
NTFY = URI("http://127.0.0.1:#{Integer(ENV.fetch('PLATFORM_NTFY_PORT'), 10)}")
# The address Dozzle dispatches to is whatever the deployment was told to use,
# not the loopback address this contract connects to, and it is not a fixed name:
# only Docker Desktop supplies host.docker.internal. Follow the precedence
# inventory/local.yml uses, and fall back to the name inventory/mac.yml hardcodes,
# which the Mac lane relies on because it exports neither variable.
CALLBACK_HOST = [ENV["PLATFORM_CALLBACK_HOST"], ENV["PLATFORM_NAS_ADDRESS"]]
                .compact.reject(&:empty?).first || "host.docker.internal"
REPORT_ROOT = ENV.fetch("PLATFORM_REPORT_ROOT")
SAFE_ID = /\A[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}\z/
ALERTS = {
  "OOM" => ['name == "oom"', 300],
  "Unexpected exit" => ['name == "die" && !(attributes["exitCode"] in ["0", "130", "143", "137"])', 300],
  "Unhealthy" => ['name == "health_status" && attributes["healthStatus"] == "unhealthy"', 0],
  "Recovery" => ['name == "health_status" && attributes["healthStatus"] == "healthy"', 0]
}.freeze

def fail_contract(message)
  warn "Dozzle contract failed: #{message}"
  exit 1
end

def safe_id(value)
  id = value.to_s
  fail_contract("API returned an unsafe identifier") unless id.match?(SAFE_ID)
  id
end

def artifact_path(name)
  fail_contract("contract report root is unavailable") unless
    File.directory?(REPORT_ROOT) && !File.symlink?(REPORT_ROOT)
  File.join(REPORT_ROOT, "dozzle-#{name}.txt")
end

def write_artifact(name, values)
  path = artifact_path(name)
  fail_contract("refusing to replace contract artifact") if File.exist?(path) || File.symlink?(path)
  body = Array(values).map { |value| safe_id(value) }.join("\n") + "\n"
  File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(body) }
end

def read_artifact(name)
  path = artifact_path(name)
  fail_contract("contract artifact is unavailable") unless File.file?(path) && !File.symlink?(path)
  values = File.readlines(path, chomp: true)
  fail_contract("contract artifact is empty") if values.empty?
  values.map { |value| safe_id(value) }
end

def remove_artifact(name)
  path = artifact_path(name)
  fail_contract("contract artifact is unavailable") unless File.file?(path) && !File.symlink?(path)
  File.unlink(path)
end

def artifact_available?(name)
  path = artifact_path(name)
  File.file?(path) && !File.symlink?(path)
end

def canonicalize(value)
  case value
  when Hash
    value.keys.sort.to_h { |key| [key, canonicalize(value.fetch(key))] }
  when Array
    value.map { |entry| canonicalize(entry) }
  else
    value
  end
end

def notification_state(dispatchers, rules)
  [dispatchers, rules].flatten.each { |entry| safe_id(entry.fetch("id")) }
  JSON.generate(canonicalize({
    "dispatchers" => dispatchers.sort_by { |entry| safe_id(entry.fetch("id")) },
    "rules" => rules.sort_by { |entry| safe_id(entry.fetch("id")) }
  }))
end

def write_state_artifact(name, dispatchers, rules)
  path = artifact_path(name)
  fail_contract("refusing to replace contract artifact") if File.exist?(path) || File.symlink?(path)
  state = notification_state(dispatchers, rules)
  File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(state) }
end

def assert_state_artifact(name, dispatchers, rules)
  path = artifact_path(name)
  fail_contract("contract state artifact is unavailable") unless File.file?(path) && !File.symlink?(path)
  fail_contract("check mode mutated API state bytes") unless
    File.binread(path) == notification_state(dispatchers, rules)
end

def require_desired_fixture_state(dispatchers, rules)
  fail_contract("check-mode fixture requires exact managed identities") unless
    dispatchers.length == 1 && dispatchers.fetch(0).fetch("name") == "ntfy nas-critical" &&
    rules.map { |entry| entry.fetch("name") }.sort == ALERTS.keys.sort
end

def assert_output_ids(artifact, output_path, diagnostic_prefix)
  fail_contract("expected-failure output path is absent") unless output_path
  fail_contract("expected-failure output is unsafe") unless
    File.file?(output_path) && !File.symlink?(output_path)
  output = File.read(output_path)
  expected = "#{diagnostic_prefix}: #{read_artifact(artifact).join(', ')}"
  fail_contract("expected-failure output omitted the safe-ID diagnostic") unless output.include?(expected)
end

vault_yaml, vault_error, status = Open3.capture3(
  "ansible-vault", "view", "--vault-password-file",
  ENV.fetch("PLATFORM_CONTRACT_VAULT_PASSWORD_FILE"),
  ENV.fetch("PLATFORM_CONTRACT_VAULT_FILE")
)
fail_contract("encrypted vault could not be read") unless status.success?
vault = YAML.safe_load(vault_yaml)
vault_yaml.replace("\0" * vault_yaml.bytesize)
vault_error.replace("\0" * vault_error.bytesize)

def endpoint(base, path)
  URI.join(base.to_s, path)
end

def request(method, uri, cookie: nil, basic: nil, bearer: nil, body: nil, form: nil, expected: [200])
  request = Net::HTTP.const_get(method.capitalize).new(uri)
  request["Cookie"] = cookie if cookie
  request.basic_auth(*basic) if basic
  request["Authorization"] = "Bearer #{bearer}" if bearer
  if body
    request["Content-Type"] = "application/json"
    request.body = JSON.generate(body)
  elsif form
    request.set_form_data(form)
  end
  response = Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 15) do |http|
    http.request(request)
  end
  fail_contract("#{method.upcase} #{uri.path} returned HTTP #{response.code}") unless expected.include?(response.code.to_i)
  parsed = if response.body.to_s.empty? || !response["Content-Type"].to_s.start_with?("application/json")
             nil
           else
             JSON.parse(response.body)
           end
  [response, parsed]
rescue JSON::ParserError
  fail_contract("#{method.upcase} #{uri.path} returned malformed JSON")
rescue SystemCallError, Timeout::Error => error
  fail_contract("#{method.upcase} #{uri.path} failed: #{error.class}")
end

def request_text(uri, basic:, expected: [200])
  request = Net::HTTP::Get.new(uri)
  request.basic_auth(*basic)
  response = Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 15) do |http|
    http.request(request)
  end
  fail_contract("GET #{uri.path} returned HTTP #{response.code}") unless expected.include?(response.code.to_i)
  response.body.to_s
rescue SystemCallError, Timeout::Error => error
  fail_contract("GET #{uri.path} failed: #{error.class}")
end

def parse_json_lines(text)
  text.lines.filter_map do |line|
    next if line.strip.empty?

    JSON.parse(line)
  rescue JSON::ParserError
    fail_contract("ntfy returned malformed JSONL")
  end
end

# Alerts are split across topics by severity, and ntfy scopes the since= id to
# one topic, so every poll names the topic it expects the message on. Watching
# the wrong topic is the failure this parameter exists to make impossible.
def ntfy_messages_since(topic, id, basic)
  query = URI.encode_www_form(poll: 1, since: id)
  parse_json_lines(request_text(endpoint(NTFY, "/#{topic}/json?#{query}"), basic: basic))
end

def wait_for_ntfy(topic, id, basic, diagnostic, timeout: 40)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
  loop do
    messages = ntfy_messages_since(topic, id, basic)
    match = yield messages
    return [match, messages] if match
    fail_contract(diagnostic) if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    sleep 2
  end
end

request("get", endpoint(DOZZLE, "/api/notifications/rules"), expected: [401])
login, = request(
  "post", endpoint(DOZZLE, "/api/token"),
  form: { username: vault.fetch("vault_dozzle_admin_username"),
          password: vault.fetch("vault_dozzle_admin_password") }
)
cookie = login.get_fields("set-cookie")&.map { |value| value.split(";", 2).first }&.join("; ")
fail_contract("vault credential did not receive an authentication cookie") if cookie.to_s.empty?
request(
  "post", endpoint(DOZZLE, "/api/token"),
  form: { username: vault.fetch("vault_dozzle_admin_username"), password: "contract-wrong-password" },
  expected: [401]
)

dispatchers = request("get", endpoint(DOZZLE, "/api/notifications/dispatchers"), cookie: cookie).last
rules = request("get", endpoint(DOZZLE, "/api/notifications/rules"), cookie: cookie).last

case MODE
when "duplicate-dispatcher-create"
  managed = dispatchers.select { |entry| entry["name"] == "ntfy nas-critical" }
  fail_contract("dispatcher duplicate fixture requires one managed identity") unless managed.length == 1
  _response, created = request(
    "post", endpoint(DOZZLE, "/api/notifications/dispatchers"), cookie: cookie,
    body: { name: "ntfy nas-critical", type: "webhook",
            url: "https://example.invalid/dozzle-duplicate", template: "{}", headers: {} },
    expected: [201]
  )
  created_id = safe_id(created.fetch("id"))
  current = request("get", endpoint(DOZZLE, "/api/notifications/dispatchers"), cookie: cookie).last
  matching_ids = current.select { |entry| entry["name"] == "ntfy nas-critical" }
                        .map { |entry| safe_id(entry.fetch("id")) }.sort
  fail_contract("dispatcher duplicate fixture was not created") unless matching_ids.length == 2 &&
    matching_ids.include?(created_id)
  write_artifact("duplicate-dispatcher-created-id", created_id)
  write_artifact("duplicate-dispatcher-matching-ids", matching_ids)
  exit 0
when "duplicate-dispatcher-verify"
  matching_ids = dispatchers.select { |entry| entry["name"] == "ntfy nas-critical" }
                            .map { |entry| safe_id(entry.fetch("id")) }.sort
  fail_contract("dispatcher duplicate fixture changed") unless
    matching_ids == read_artifact("duplicate-dispatcher-matching-ids").sort
  exit 0
when "duplicate-dispatcher-assert-output"
  assert_output_ids(
    "duplicate-dispatcher-matching-ids", ARGV[1],
    "Managed Dozzle dispatcher identity is duplicated at safe IDs"
  )
  exit 0
when "duplicate-dispatcher-cleanup"
  created_id = read_artifact("duplicate-dispatcher-created-id").fetch(0)
  request(
    "delete", endpoint(DOZZLE, "/api/notifications/dispatchers/#{created_id}"),
    cookie: cookie, expected: [204]
  )
  current = request("get", endpoint(DOZZLE, "/api/notifications/dispatchers"), cookie: cookie).last
  remaining_ids = current.select { |entry| entry["name"] == "ntfy nas-critical" }
                         .map { |entry| safe_id(entry.fetch("id")) }
  fail_contract("dispatcher duplicate cleanup did not preserve exactly the managed original") unless
    remaining_ids.length == 1 && !remaining_ids.include?(created_id)
  remove_artifact("duplicate-dispatcher-created-id")
  remove_artifact("duplicate-dispatcher-matching-ids")
  exit 0
when "duplicate-rule-create"
  managed_dispatchers = dispatchers.select { |entry| entry["name"] == "ntfy nas-critical" }
  managed_rules = rules.select { |entry| entry["name"] == "OOM" }
  fail_contract("rule duplicate fixture requires exact managed identities") unless
    managed_dispatchers.length == 1 && managed_rules.length == 1
  dispatcher_id = managed_dispatchers.fetch(0).fetch("id")
  safe_id(dispatcher_id)
  _response, created = request(
    "post", endpoint(DOZZLE, "/api/notifications/rules"), cookie: cookie,
    body: { name: "OOM", enabled: true, dispatcherId: dispatcher_id,
            containerExpression: "true", logExpression: "",
            eventExpression: 'name == "oom"', cooldown: 300 },
    expected: [201]
  )
  created_id = safe_id(created.fetch("id"))
  current = request("get", endpoint(DOZZLE, "/api/notifications/rules"), cookie: cookie).last
  matching_ids = current.select { |entry| entry["name"] == "OOM" }
                        .map { |entry| safe_id(entry.fetch("id")) }.sort
  fail_contract("rule duplicate fixture was not created") unless matching_ids.length == 2 &&
    matching_ids.include?(created_id)
  write_artifact("duplicate-rule-created-id", created_id)
  write_artifact("duplicate-rule-matching-ids", matching_ids)
  exit 0
when "duplicate-rule-verify"
  matching_ids = rules.select { |entry| entry["name"] == "OOM" }
                      .map { |entry| safe_id(entry.fetch("id")) }.sort
  fail_contract("rule duplicate fixture changed") unless
    matching_ids == read_artifact("duplicate-rule-matching-ids").sort
  exit 0
when "duplicate-rule-assert-output"
  assert_output_ids(
    "duplicate-rule-matching-ids", ARGV[1],
    "Managed Dozzle alert rule identity OOM is duplicated at safe IDs"
  )
  exit 0
when "duplicate-rule-cleanup"
  created_id = read_artifact("duplicate-rule-created-id").fetch(0)
  request(
    "delete", endpoint(DOZZLE, "/api/notifications/rules/#{created_id}"),
    cookie: cookie, expected: [204]
  )
  current = request("get", endpoint(DOZZLE, "/api/notifications/rules"), cookie: cookie).last
  remaining_ids = current.select { |entry| entry["name"] == "OOM" }
                         .map { |entry| safe_id(entry.fetch("id")) }
  fail_contract("rule duplicate cleanup did not preserve exactly the managed original") unless
    remaining_ids.length == 1 && !remaining_ids.include?(created_id)
  remove_artifact("duplicate-rule-created-id")
  remove_artifact("duplicate-rule-matching-ids")
  exit 0
when "surplus-create"
  fail_contract("surplus fixture requires exact managed state") unless
    dispatchers.length == 1 && dispatchers.fetch(0).fetch("name") == "ntfy nas-critical" &&
    rules.map { |entry| entry.fetch("name") }.sort == ALERTS.keys.sort
  _response, created_dispatcher = request(
    "post", endpoint(DOZZLE, "/api/notifications/dispatchers"), cookie: cookie,
    body: { name: "Contract surplus dispatcher", type: "webhook",
            url: "https://example.invalid/dozzle-surplus", template: "{}", headers: {} },
    expected: [201]
  )
  dispatcher_id = created_dispatcher.fetch("id")
  write_artifact("surplus-dispatcher-id", safe_id(dispatcher_id))
  _response, created_rule = request(
    "post", endpoint(DOZZLE, "/api/notifications/rules"), cookie: cookie,
    body: { name: "Contract surplus rule", enabled: true, dispatcherId: dispatcher_id,
            containerExpression: "true", logExpression: "",
            eventExpression: 'name == "oom"', cooldown: 0 },
    expected: [201]
  )
  write_artifact("surplus-rule-id", safe_id(created_rule.fetch("id")))
  exit 0
when "surplus-verify"
  dispatcher_id = read_artifact("surplus-dispatcher-id").fetch(0)
  rule_id = read_artifact("surplus-rule-id").fetch(0)
  fail_contract("surplus dispatcher fixture is absent") unless
    dispatchers.any? { |entry| safe_id(entry.fetch("id")) == dispatcher_id }
  fail_contract("surplus rule fixture is absent") unless
    rules.any? { |entry| safe_id(entry.fetch("id")) == rule_id }
  exit 0
when "surplus-removed"
  dispatcher_id = read_artifact("surplus-dispatcher-id").fetch(0)
  rule_id = read_artifact("surplus-rule-id").fetch(0)
  fail_contract("surplus dispatcher was not removed") if
    dispatchers.any? { |entry| safe_id(entry.fetch("id")) == dispatcher_id }
  fail_contract("surplus rule was not removed") if
    rules.any? { |entry| safe_id(entry.fetch("id")) == rule_id }
  remove_artifact("surplus-rule-id")
  remove_artifact("surplus-dispatcher-id")
  exit 0
when "surplus-cleanup"
  if artifact_available?("surplus-rule-id")
    rule_id = read_artifact("surplus-rule-id").fetch(0)
    if rules.any? { |entry| safe_id(entry.fetch("id")) == rule_id }
      request("delete", endpoint(DOZZLE, "/api/notifications/rules/#{rule_id}"),
              cookie: cookie, expected: [204])
    end
    remove_artifact("surplus-rule-id")
  end
  if artifact_available?("surplus-dispatcher-id")
    dispatcher_id = read_artifact("surplus-dispatcher-id").fetch(0)
    current = request("get", endpoint(DOZZLE, "/api/notifications/dispatchers"), cookie: cookie).last
    if current.any? { |entry| safe_id(entry.fetch("id")) == dispatcher_id }
      request("delete", endpoint(DOZZLE, "/api/notifications/dispatchers/#{dispatcher_id}"),
              cookie: cookie, expected: [204])
    end
    remove_artifact("surplus-dispatcher-id")
  end
  exit 0
when "check-mixed-create"
  require_desired_fixture_state(dispatchers, rules)
  dispatcher = dispatchers.fetch(0)
  request(
    "put", endpoint(DOZZLE, "/api/notifications/dispatchers/#{dispatcher.fetch('id')}"), cookie: cookie,
    body: { name: dispatcher.fetch("name"), type: "webhook",
            url: "https://example.invalid/check-mixed", template: "{}", headers: {} }
  )
  oom = rules.find { |rule| rule["name"] == "OOM" }
  request(
    "put", endpoint(DOZZLE, "/api/notifications/rules/#{oom.fetch('id')}"), cookie: cookie,
    body: { name: "OOM", enabled: false, dispatcherId: dispatcher.fetch("id"),
            containerExpression: "false", logExpression: "",
            eventExpression: 'name == "start"', cooldown: 1 }
  )
  request(
    "patch", endpoint(DOZZLE, "/api/notifications/rules/#{oom.fetch('id')}"), cookie: cookie,
    body: { enabled: false }
  )
  recovery = rules.find { |rule| rule["name"] == "Recovery" }
  request("delete", endpoint(DOZZLE, "/api/notifications/rules/#{recovery.fetch('id')}"),
          cookie: cookie, expected: [204])
  _response, surplus_dispatcher = request(
    "post", endpoint(DOZZLE, "/api/notifications/dispatchers"), cookie: cookie,
    body: { name: "Contract check-mixed dispatcher", type: "webhook",
            url: "https://example.invalid/check-mixed-surplus", template: "{}", headers: {} },
    expected: [201]
  )
  surplus_dispatcher_id = surplus_dispatcher.fetch("id")
  write_artifact("check-mixed-surplus-dispatcher-id", safe_id(surplus_dispatcher_id))
  _response, surplus_rule = request(
    "post", endpoint(DOZZLE, "/api/notifications/rules"), cookie: cookie,
    body: { name: "Contract check-mixed rule", enabled: true,
            dispatcherId: surplus_dispatcher_id, containerExpression: "true",
            logExpression: "", eventExpression: 'name == "oom"', cooldown: 0 },
    expected: [201]
  )
  write_artifact("check-mixed-surplus-rule-id", safe_id(surplus_rule.fetch("id")))
  current_dispatchers = request("get", endpoint(DOZZLE, "/api/notifications/dispatchers"), cookie: cookie).last
  current_rules = request("get", endpoint(DOZZLE, "/api/notifications/rules"), cookie: cookie).last
  write_state_artifact("check-mixed-state", current_dispatchers, current_rules)
  exit 0
when "check-mixed-unchanged"
  assert_state_artifact("check-mixed-state", dispatchers, rules)
  exit 0
when "check-mixed-cleanup"
  surplus_dispatcher_id = read_artifact("check-mixed-surplus-dispatcher-id").fetch(0)
  surplus_rule_id = read_artifact("check-mixed-surplus-rule-id").fetch(0)
  fail_contract("check-mixed surplus dispatcher remains") if
    dispatchers.any? { |entry| safe_id(entry.fetch("id")) == surplus_dispatcher_id }
  fail_contract("check-mixed surplus rule remains") if
    rules.any? { |entry| safe_id(entry.fetch("id")) == surplus_rule_id }
  remove_artifact("check-mixed-state")
  remove_artifact("check-mixed-surplus-rule-id")
  remove_artifact("check-mixed-surplus-dispatcher-id")
  exit 0
when "check-mixed-recover"
  if artifact_available?("check-mixed-surplus-rule-id")
    rule_id = read_artifact("check-mixed-surplus-rule-id").fetch(0)
    if rules.any? { |entry| safe_id(entry.fetch("id")) == rule_id }
      request("delete", endpoint(DOZZLE, "/api/notifications/rules/#{rule_id}"),
              cookie: cookie, expected: [204])
    end
    remove_artifact("check-mixed-surplus-rule-id")
  end
  if artifact_available?("check-mixed-surplus-dispatcher-id")
    dispatcher_id = read_artifact("check-mixed-surplus-dispatcher-id").fetch(0)
    current = request("get", endpoint(DOZZLE, "/api/notifications/dispatchers"), cookie: cookie).last
    if current.any? { |entry| safe_id(entry.fetch("id")) == dispatcher_id }
      request("delete", endpoint(DOZZLE, "/api/notifications/dispatchers/#{dispatcher_id}"),
              cookie: cookie, expected: [204])
    end
    remove_artifact("check-mixed-surplus-dispatcher-id")
  end
  remove_artifact("check-mixed-state") if artifact_available?("check-mixed-state")
  exit 0
when "check-missing-create"
  require_desired_fixture_state(dispatchers, rules)
  rules.each do |rule|
    request("delete", endpoint(DOZZLE, "/api/notifications/rules/#{rule.fetch('id')}"),
            cookie: cookie, expected: [204])
  end
  request("delete", endpoint(DOZZLE, "/api/notifications/dispatchers/#{dispatchers.fetch(0).fetch('id')}"),
          cookie: cookie, expected: [204])
  current_dispatchers = request("get", endpoint(DOZZLE, "/api/notifications/dispatchers"), cookie: cookie).last
  current_rules = request("get", endpoint(DOZZLE, "/api/notifications/rules"), cookie: cookie).last
  write_state_artifact("check-missing-state", current_dispatchers, current_rules)
  exit 0
when "check-missing-unchanged"
  assert_state_artifact("check-missing-state", dispatchers, rules)
  exit 0
when "check-missing-cleanup"
  remove_artifact("check-missing-state")
  exit 0
when "drift"
  dispatcher = dispatchers.fetch(0)
  request(
    "put", endpoint(DOZZLE, "/api/notifications/dispatchers/#{dispatcher.fetch('id')}"), cookie: cookie,
    body: { name: dispatcher.fetch("name"), type: "webhook",
            url: "https://example.invalid/contract-drift", template: "{}", headers: {} }
  )
  oom = rules.find { |rule| rule["name"] == "OOM" } || fail_contract("OOM rule is absent")
  request(
    "put", endpoint(DOZZLE, "/api/notifications/rules/#{oom.fetch('id')}"), cookie: cookie,
    body: { name: "OOM", enabled: false, dispatcherId: dispatcher.fetch("id"),
            containerExpression: "false", logExpression: "", eventExpression: "name == \"start\"", cooldown: 1 }
  )
  request(
    "patch", endpoint(DOZZLE, "/api/notifications/rules/#{oom.fetch('id')}"), cookie: cookie,
    body: { enabled: false }
  )
  exit 0
when "drift-verify"
  fail_contract("dispatcher drift changed") unless dispatchers.length == 1 &&
    dispatchers[0]["url"] == "https://example.invalid/contract-drift"
  oom = rules.find { |rule| rule["name"] == "OOM" }
  fail_contract("OOM drift fixture differs") unless oom && oom["enabled"] == false &&
    oom["containerExpression"] == "false" && oom["eventExpression"] == 'name == "start"' && oom["cooldown"] == 1
  exit 0
end

fail_contract("expected exactly one dispatcher") unless dispatchers.length == 1
dispatcher = dispatchers.first
expected_url = "http://alert-relay:8081/alerts"
expected_template = JSON.generate(
  version: 1,
  rule: "{{ .Subscription.Name }}",
  containerId: "{{ .Container.ID }}",
  container: "{{ .Container.Name }}",
  host: "{{ .Container.HostName }}",
  event: "{{ .Event.Name }}",
  healthStatus: '{{ index .Event.Attributes `healthStatus` }}',
  exitCode: '{{ index .Event.Attributes `exitCode` }}',
  timestamp: '{{ .Event.Timestamp.Format `2006-01-02T15:04:05.999999999Z07:00` }}'
)
fail_contract("managed dispatcher name differs") unless dispatcher["name"] == "ntfy nas-critical"
fail_contract("managed dispatcher type differs") unless dispatcher["type"] == "webhook"
fail_contract("managed dispatcher URL differs") unless dispatcher["url"] == expected_url
fail_contract("managed dispatcher template differs") unless dispatcher["template"] == expected_template
fail_contract("managed dispatcher headers differ") unless
  dispatcher["headers"] == { "Authorization" => "Bearer #{vault.fetch('vault_ntfy_dozzle_token')}" }
fail_contract("expected exactly four alert rules") unless rules.length == 4

ALERTS.each do |name, (expression, cooldown)|
  matches = rules.select { |rule| rule["name"] == name }
  fail_contract("#{name} rule is absent or duplicated") unless matches.length == 1
  rule = matches.first
  fail_contract("#{name} rule differs") unless rule["enabled"] == true &&
    rule["containerExpression"] == "true" && rule["logExpression"] == "" &&
    rule["eventExpression"] == expression && rule.fetch("cooldown", 0) == cooldown &&
    rule.dig("dispatcher", "id").to_s == dispatcher["id"].to_s
end

publisher = vault.fetch("vault_ntfy_dozzle_token")
%w[nas-critical nas-containers].each do |topic|
  request("get", endpoint(NTFY, "/#{topic}/json?poll=1"), bearer: publisher, expected: [403])
end

if MODE == "notify"
  admin = [vault.fetch("vault_ntfy_admin_user"), vault.fetch("vault_ntfy_admin_password")]
  baselines = {}
  %w[nas-critical nas-containers].each do |topic|
    baseline_message = "dozzle-contract-baseline-#{SecureRandom.hex(6)}"
    _response, baseline = request(
      "post", endpoint(NTFY, "/#{topic}"), bearer: publisher,
      body: { message: baseline_message }
    )
    baselines[topic] = baseline&.fetch("id", nil)
    fail_contract("disposable ntfy baseline publish returned no anti-replay id") unless
      baselines[topic]
  end

  image = "docker.io/binwiederhier/ntfy:v2.27.0@sha256:f2419f405127afa868f10985c1a41449e673477cee1eb19994339a5ae8b592e7"
  health_fixture = "dozzle_contract_health_#{SecureRandom.hex(6)}"
  startup_fixture = "dozzle_contract_startup_#{SecureRandom.hex(6)}"
  exit_fixture = "dozzle_contract_exit_#{SecureRandom.hex(6)}"
  initial_exit_count = rules.find { |rule| rule["name"] == "Unexpected exit" }.fetch("triggerCount")
  begin
    _out, _error, health_status = Open3.capture3(
      "docker", "run", "-d", "--name", health_fixture,
      "--health-cmd", "test -f /tmp/healthy", "--health-interval", "1s",
      "--health-timeout", "1s", "--health-retries", "1",
      "--entrypoint", "/bin/sh", image, "-c", "sleep 120"
    )
    fail_contract("disposable unhealthy fixture did not start") unless health_status.success?
    unhealthy, observed = wait_for_ntfy(
      "nas-critical", baselines["nas-critical"], admin,
      "unhealthy event did not reach the private relay and disposable ntfy"
    ) do |messages|
      messages.reverse.find { |message| message["title"] == "Unhealthy · #{health_fixture}" }
    end
    expected_unhealthy_tail = "**Container:** `#{health_fixture}`\n**Status:** `unhealthy`"
    fail_contract("unhealthy notification presentation differs") unless
      unhealthy["message"].start_with?("**Host:** `") &&
      unhealthy["message"].end_with?(expected_unhealthy_tail) &&
      unhealthy["priority"] == 5 && unhealthy["tags"] == ["rotating_light", "warning"] &&
      unhealthy["content_type"] == "text/markdown"
    fail_contract("relay exposed its event envelope as ntfy message text") if
      observed.any? { |message| message["message"].to_s.include?('"version":1') }

    baselines["nas-critical"] = unhealthy.fetch("id")
    _exec_out, _exec_error, exec_status = Open3.capture3(
      "docker", "exec", health_fixture, "/bin/sh", "-c", "touch /tmp/healthy"
    )
    fail_contract("disposable unhealthy fixture could not recover") unless exec_status.success?
    # A recovery is a record, not an emergency, so it lands on the container
    # topic rather than the critical one.
    recovered, observed = wait_for_ntfy(
      "nas-containers", baselines["nas-containers"], admin,
      "healthy transition did not produce one correlated recovery"
    ) do |messages|
      messages.reverse.find { |message| message["title"] == "Recovered · #{health_fixture}" }
    end
    expected_recovery_tail = "**Container:** `#{health_fixture}`\n**Status:** `healthy`"
    fail_contract("recovery notification presentation differs") unless
      recovered["message"].start_with?("**Host:** `") &&
      recovered["message"].end_with?(expected_recovery_tail) &&
      recovered["priority"] == 3 && recovered["tags"] == ["white_check_mark"] &&
      recovered["content_type"] == "text/markdown" &&
      observed.count { |message| message["title"] == "Recovered · #{health_fixture}" } == 1
    baselines["nas-containers"] = recovered.fetch("id")
    recovery_rules = request(
      "get", endpoint(DOZZLE, "/api/notifications/rules"), cookie: cookie
    ).last
    recovery_count = recovery_rules.find { |rule| rule["name"] == "Recovery" }.fetch("triggerCount")

    _out, _error, startup_status = Open3.capture3(
      "docker", "run", "-d", "--name", startup_fixture,
      "--health-cmd", "exit 0", "--health-interval", "1s", "--health-timeout", "1s",
      "--health-retries", "1", "--entrypoint", "/bin/sh", image, "-c", "sleep 120"
    )
    fail_contract("disposable startup-healthy fixture did not start") unless startup_status.success?
    sleep 6
    startup_rules = request(
      "get", endpoint(DOZZLE, "/api/notifications/rules"), cookie: cookie
    ).last
    startup_recovery_count = startup_rules.find { |rule| rule["name"] == "Recovery" }.fetch("triggerCount")
    fail_contract("startup healthy fixture did not exercise the managed recovery rule") unless
      startup_recovery_count > recovery_count
    startup_messages = ntfy_messages_since(
      "nas-containers", baselines["nas-containers"], admin
    )
    fail_contract("startup healthy event produced a false recovery") if
      startup_messages.any? { |message| message["title"] == "Recovered · #{startup_fixture}" }

    _out, _error, run_status = Open3.capture3(
      "docker", "run", "--name", exit_fixture, "--entrypoint", "/bin/sh", image, "-c", "exit 1"
    )
    fail_contract("disposable exit fixture did not exit with the expected status") unless
      run_status.exitstatus == 1
    exited, observed = wait_for_ntfy(
      "nas-critical", baselines["nas-critical"], admin,
      "exit-code-1 event did not reach the private relay and disposable ntfy"
    ) do |messages|
      messages.reverse.find { |message| message["title"] == "Unexpected exit · #{exit_fixture}" }
    end
    expected_exit_tail = "**Container:** `#{exit_fixture}`\n**Exit code:** `1`"
    fail_contract("unexpected-exit notification presentation differs") unless
      exited["message"].start_with?("**Host:** `") &&
      exited["message"].end_with?(expected_exit_tail) && exited["priority"] == 5 &&
      exited["tags"] == ["warning", "skull"] && exited["content_type"] == "text/markdown"
    fail_contract("relay exposed its event envelope as ntfy message text") if
      observed.any? { |message| message["message"].to_s.include?('"version":1') }
  ensure
    [health_fixture, startup_fixture, exit_fixture].each do |fixture|
      system("docker", "rm", "-f", fixture, out: File::NULL, err: File::NULL)
    end
  end
  current_rules = request("get", endpoint(DOZZLE, "/api/notifications/rules"), cookie: cookie).last
  current_exit_count = current_rules.find { |rule| rule["name"] == "Unexpected exit" }.fetch("triggerCount")
  fail_contract("unique exit event was delivered without incrementing its managed rule") unless
    exited && current_exit_count > initial_exit_count
end

puts "Dozzle contract passed"
RUBY
