#!/usr/bin/env ruby
# The stack half of the Dozzle service contract: the Compose definition, the
# role's relay-state safety ordering, and the rendered environment file.
#
# Runs in every mode, not only `static`, because these are the properties the
# live modes below assume: a relay that cannot see the Docker socket, a state
# child prepared before anything is moved into it, and an environment that
# carries the one declared listener port to both of its consumers.
#
# Refusals here are `abort`, but the parsed-document fetches are not guarded:
# a Compose file without a `services` key raises KeyError and names this file.
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
    "ALERT_RELAY_PORT" => "${ALERT_RELAY_PORT:?}",
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
env_template = File.read(ARGV.fetch(2))
deployment_inputs = File.read(ARGV.fetch(3))
deployment_bundle = File.read(ARGV.fetch(4))
abort "Dozzle contract failed: deployment inputs do not validate the alert relay" unless
  deployment_inputs.include?("services/dozzle/alert_relay.py")
abort "Dozzle contract failed: immutable release does not include the alert relay" unless
  deployment_bundle.include?("services/dozzle/alert_relay.py") &&
    deployment_bundle.include?("alert_relay.py")
# Parsed rather than substring-matched: byte offsets do not track task order once
# a task name appears in a comment or a when: expression, and a field found by
# slicing the file between two names is not necessarily on the task that needs it.
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
# The third leg of the single listener port: the rendered environment file is how
# the value in roles/dozzle/defaults/main.yml reaches both consumers inside the
# container. The rendered Compose document is checked against a probe port above,
# and the live modes below dispatch through the URL built from the same default.
abort "Dozzle contract failed: environment does not render the single relay listener port" unless
  env_template.include?("ALERT_RELAY_PORT={{ dozzle_alert_relay_port }}")
# The separation #172 was filed for, asserted in the one file that renders both
# credentials side by side. The relay's shared secret ends up at rest in Dozzle's
# /data volume and in a second container's `docker inspect` environment; the ntfy
# publish token must reach neither, so these two lines have to name two different
# vault credentials rather than the same one twice.
abort "Dozzle contract failed: the relay secret is not a credential of its own" unless
  env_template.include?("ALERT_RELAY_TOKEN={{ vault_dozzle_alert_relay_token }}") &&
  env_template.include?("NTFY_TOKEN={{ vault_ntfy_dozzle_token }}")
