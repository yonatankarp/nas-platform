#!/usr/bin/env ruby
# Stack half of the Dozzle contract: Compose definition, relay-state ordering and
# the rendered environment. Runs in every mode, since the live modes assume it.
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
  "DOZZLE_REMOTE_HOST" => "tcp://socket-proxy:2375|ASUSTOR-AS6704T",
  "DOZZLE_REMOTE_AGENT" => "${DOZZLE_REMOTE_AGENT:?}",
  "DOZZLE_CERT" => "/data/agent-cert.pem",
  "DOZZLE_KEY" => "/data/agent-key.pem",
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
    "ALERT_RELAY_PORT" => "${ALERT_RELAY_PORT:?}",
    "PUSHOVER_API_URL" => "${PUSHOVER_API_URL:?}",
    "ALERT_RELAY_LINK_BASE" => "${ALERT_RELAY_LINK_BASE:?}",
    "PUSHOVER_TOKEN" => "${PUSHOVER_TOKEN:?}",
    "PUSHOVER_ALERTS_TOKEN" => "${PUSHOVER_ALERTS_TOKEN:?}",
    "PUSHOVER_GOLEM_TOKEN" => "${PUSHOVER_GOLEM_TOKEN:?}",
    "BESZEL_LINK_BASE" => "${BESZEL_LINK_BASE:?}",
    "PUSHOVER_USER_KEY" => "${PUSHOVER_USER_KEY:?}",
    "ALERT_DAILY_CONTAINER_CEILING" => "${ALERT_DAILY_CONTAINER_CEILING:?}",
    "ALERT_DAILY_OOM_CONTAINER_CEILING" => "${ALERT_DAILY_OOM_CONTAINER_CEILING:?}",
    "ALERT_DAILY_GLOBAL_CEILING" => "${ALERT_DAILY_GLOBAL_CEILING:?}",
    "ALERT_STATE_PATH" => "/state/alert-relay.json"
  }
abort "Dozzle contract failed: alert relay mounts differ" unless relay["volumes"] == [
  "${PLATFORM_CURRENT_DIR:?}/services/dozzle/alert_relay.py:/app/alert_relay.py:ro",
  "${DOZZLE_STATE_ROOT:?}/alert-relay:/state"
]
# Loopback and the listener port only: golem's agent arrives through the NAS's
# Tailscale Serve TCP forward, and the LAN must not reach it.
abort "Dozzle contract failed: alert relay must publish only its listener port, on loopback" unless
  relay["ports"] == ["127.0.0.1:${ALERT_RELAY_PORT:?}:${ALERT_RELAY_PORT:?}"] &&
  !relay.key?("network_mode")
# The relay joins default and the external alert-relay bridge; the socket proxy
# shares only docker-api, and only with Dozzle (#829).
abort "Dozzle contract failed: alert relay must join default and the external alert-relay bridge, and nothing else may" unless
  relay["networks"] == %w[default alert-bridge] &&
  compose["networks"] == { "default" => {},
                           "alert-bridge" => { "external" => true, "name" => "${PLATFORM_ALERT_RELAY_NETWORK:?}" },
                           "docker-api" => { "internal" => true } } &&
  services.transform_values { |service| service["networks"] } ==
    { "alert-relay" => %w[default alert-bridge], "dozzle" => %w[default docker-api],
      "socket-proxy" => %w[docker-api] }
abort "Dozzle contract failed: alert relay hardening differs" unless
  relay["read_only"] == true && relay["tmpfs"] == ["/tmp"] &&
  relay["security_opt"] == ["no-new-privileges:true"] && relay.key?("healthcheck") &&
  relay["restart"] == "unless-stopped" && relay["logging"] == compose["x-logging"]
abort "Dozzle contract failed: Dozzle dependency health gates differ" unless
  dozzle["depends_on"] == {
    "socket-proxy" => {"condition" => "service_healthy"},
    "alert-relay" => {"condition" => "service_healthy"}
  }
env_template = File.read(ARGV.fetch(2))
deployment_inputs = File.read(ARGV.fetch(3))
deployment_bundle = File.read(ARGV.fetch(4))
abort "Dozzle contract failed: deployment inputs do not validate the alert relay" unless
  deployment_inputs.include?("services/dozzle/alert_relay.py")
abort "Dozzle contract failed: immutable release does not include the alert relay" unless
  deployment_bundle.include?("services/dozzle/alert_relay.py") &&
    deployment_bundle.include?("alert_relay.py")
# Parsed, not substring-matched: byte offsets do not track task order.
role_tasks = YAML.safe_load_file(ARGV.fetch(1), aliases: false)
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
# The rendered env file carries the one declared listener port to both consumers.
abort "Dozzle contract failed: environment does not render the single relay listener port" unless
  env_template.include?("ALERT_RELAY_PORT={{ dozzle_alert_relay_port }}")
# #172: the relay secret and the Pushover token must be different vault
# credentials, since the secret lands in /data and `docker inspect`.
abort "Dozzle contract failed: the relay secret is not a credential of its own" unless
  env_template.include?("ALERT_RELAY_TOKEN={{ vault_dozzle_alert_relay_token }}") &&
  env_template.include?(
    "PUSHOVER_TOKEN={{ vault_pushover_containers_token | replace('$', '$$') }}"
  ) &&
  env_template.include?(
    "PUSHOVER_ALERTS_TOKEN={{ vault_pushover_alerts_token | replace('$', '$$') }}"
  ) &&
  env_template.include?(
    "PUSHOVER_GOLEM_TOKEN={{ vault_pushover_golem_token | replace('$', '$$') }}"
  ) &&
  env_template.include?(
    "PUSHOVER_USER_KEY={{ vault_pushover_user_key | replace('$', '$$') }}"
  )

# A literal endpoint would send every lane's container churn to the household's
# real Pushover account; check defaults too, since a missing variable renders empty.
relay_defaults = File.read(ARGV.fetch(5))
abort "Dozzle contract failed: the relay publish endpoint is not redirectable" unless
  env_template.include?("PUSHOVER_API_URL={{ dozzle_pushover_api_url }}") &&
  relay_defaults.match?(/^dozzle_pushover_api_url:\s+https:\/\/api\.pushover\.net\/1\/messages\.json$/)

# Link bases come from the defining values, never literals.
abort "Dozzle contract failed: the Beszel link base is not Beszel's app URL" unless
  env_template.include?("BESZEL_LINK_BASE={{ beszel_app_url }}")

abort "Dozzle contract failed: the alert link is not built from the public host and Dozzle port" unless
  env_template.include?("ALERT_RELAY_LINK_BASE={{ dozzle_alert_relay_link_base }}") &&
  relay_defaults.include?(%(dozzle_alert_relay_link_base: "http://{{ platform_public_host }}:{{ dozzle_port }}"\n))

# The ceiling has one home in the role defaults, like the listener port.
abort "Dozzle contract failed: the alert ceiling is not rendered from the role defaults" unless
  %w[
    ALERT_DAILY_CONTAINER_CEILING=dozzle_alert_daily_container_ceiling
    ALERT_DAILY_OOM_CONTAINER_CEILING=dozzle_alert_daily_oom_container_ceiling
    ALERT_DAILY_GLOBAL_CEILING=dozzle_alert_daily_global_ceiling
  ].all? do |pair|
    name, variable = pair.split("=")
    env_template.include?("#{name}={{ #{variable} }}") &&
      relay_defaults.match?(/^#{Regexp.escape(variable)}:\s+[1-9][0-9]*$/)
  end
