#!/bin/sh
set -eu
set +x

mode=${1:-run}
repo_dir=${PLATFORM_CONTRACT_REPO_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)}
# The embedded Ruby below reads tests/policy_support.rb from here instead of
# carrying its own copy of flatten_tasks.
PLATFORM_CONTRACT_REPO_DIR=$repo_dir
export PLATFORM_CONTRACT_REPO_DIR
compose=$repo_dir/services/paperless-ngx/compose.yml
mac_compose=$repo_dir/services/paperless-ngx/compose.mac.yml
integration_compose=$repo_dir/services/paperless-ngx/compose.integration.yml
role=$repo_dir/roles/paperless_ngx/tasks/main.yml
defaults=$repo_dir/roles/paperless_ngx/defaults/main.yml
argument_specs=$repo_dir/roles/paperless_ngx/meta/argument_specs.yml
storage_inventory=$repo_dir/inventory/group_vars/all/main.yml
host_prep=$repo_dir/roles/host_prep/tasks/main.yml
generator=$repo_dir/generate-secrets.yml
snapshot=$repo_dir/tests/mac/snapshot-paperless.sh
environment_template=$repo_dir/roles/paperless_ngx/templates/env.j2
ocr_fixture=$repo_dir/tests/fixtures/paperless-ocr.png.base64

fail_contract() {
  printf 'Paperless contract failed: %s\n' "$1" >&2
  exit 1
}

[ -f "$compose" ] || fail_contract 'services/paperless-ngx/compose.yml is absent'
[ -f "$mac_compose" ] || fail_contract 'services/paperless-ngx/compose.mac.yml is absent'
[ -f "$integration_compose" ] ||
  fail_contract 'services/paperless-ngx/compose.integration.yml is absent'
[ -f "$role" ] || fail_contract 'roles/paperless_ngx/tasks/main.yml is absent'
[ -f "$defaults" ] || fail_contract 'roles/paperless_ngx/defaults/main.yml is absent'
[ -f "$argument_specs" ] || fail_contract 'roles/paperless_ngx/meta/argument_specs.yml is absent'
[ -f "$storage_inventory" ] || fail_contract 'inventory/group_vars/all/main.yml is absent'
[ -f "$host_prep" ] || fail_contract 'roles/host_prep/tasks/main.yml is absent'
[ -x "$snapshot" ] || fail_contract 'tests/mac/snapshot-paperless.sh is absent or not executable'
[ -f "$ocr_fixture" ] || fail_contract 'tests/fixtures/paperless-ocr.png.base64 is absent'
grep -qx 'DOCUMENT_INDEX_TIMEOUT_SECONDS = 600' "$0" ||
  fail_contract 'document indexing timeout differs'

render_paperless_mounts() {
  variant=$1
  shift
  cache_path=/volume1/Docker/paperless-ngx/cache
  rendered=$(env \
    PLATFORM_PROJECT_NAME=paperless-contract PLATFORM_CONTAINER_CPUSET=0-2 \
    PAPERLESS_HOST_PORT=38000 PAPERLESS_POSTGRES_PATH=/volume1/Docker/paperless-ngx/postgres \
    PAPERLESS_REDIS_PATH=/volume1/Docker/paperless-ngx/redis \
    PAPERLESS_DATA_PATH=/volume1/Docker/paperless-ngx/data \
    PAPERLESS_CACHE_PATH="$cache_path" \
    PAPERLESS_TESSDATA_PATH=/volume1/Docker/paperless-ngx/tessdata \
    PAPERLESS_MEDIA_PATH=/volume2/Documents/archive \
    PAPERLESS_CONSUME_PATH=/volume2/Documents/inbox \
    PAPERLESS_EXPORT_PATH=/volume2/Documents/export \
    PAPERLESS_ADMIN_USER=contract PAPERLESS_ADMIN_PASSWORD=contract \
    PAPERLESS_ADMIN_MAIL=contract@example.invalid PAPERLESS_DBHOST=db \
    PAPERLESS_REDIS=redis://broker:6379 PAPERLESS_TIKA_ENDPOINT=http://tika:9998 \
    PAPERLESS_GOTENBERG_ENDPOINT=http://gotenberg:3000 PAPERLESS_AI_ENABLED=false \
    PAPERLESS_AI_LLM_ENDPOINT=http://example.invalid:11434 PAPERLESS_AI_LLM_MODEL=contract \
    PAPERLESS_SECRET_KEY=contract DB_NAME=contract DB_USER=contract DB_PASSWORD=contract \
    USER_ID=1000 GROUP_ID=100 TZ=UTC \
    docker compose --project-name "paperless-contract-$variant" "$@" config --format json) ||
    fail_contract "$variant effective Compose render failed"

  PAPERLESS_RENDERED_COMPOSE=$rendered ruby -rjson -rpathname - "$variant" <<'RUBY'
variant = ARGV.fetch(0)
services = JSON.parse(ENV.fetch("PAPERLESS_RENDERED_COMPOSE")).fetch("services")
# Networking is asserted on the merged effective config rather than on the
# override's source text. Compose merges two `ports:` lists by appending them, so
# a sandbox override that publishes its allocated port without `!override`
# publishes the production 8000 alongside it and two sandboxes collide on it
# again. The source text of such an override reads correctly; only the render
# shows the merged list.
webserver_networking = services.fetch("webserver")
abort "Paperless contract failed: #{variant} effective config must not use host networking" if
  webserver_networking.key?("network_mode")
expected_published = variant == "mac" ? ["38000"] : ["8000"]
abort "Paperless contract failed: #{variant} effective webserver publication differs" unless
  webserver_networking.fetch("ports").map { |port| port.fetch("published").to_s } == expected_published
%w[broker db gotenberg tika].each do |name|
  abort "Paperless contract failed: #{variant} #{name} publishes a host port" unless
    Array(services.fetch(name)["ports"]).empty?
end
mounts = services.fetch("webserver").fetch("volumes")
by_target = mounts.group_by { |mount| mount.fetch("target") }
expected_targets = %w[
  /usr/src/paperless/data /usr/src/paperless/cache /usr/src/paperless/export
  /usr/share/tesseract-ocr/5/tessdata/heb.traineddata
  /usr/src/paperless/media /usr/src/paperless/consume
]
abort "Paperless contract failed: #{variant} duplicate or missing webserver mount targets" unless
  by_target.keys.sort == expected_targets.sort && by_target.values.all? { |entries| entries.length == 1 }

document_targets = {
  "/usr/src/paperless/media" => "/volume2/Documents/archive",
  "/usr/src/paperless/consume" => "/volume2/Documents/inbox",
  "/usr/src/paperless/export" => "/volume2/Documents/export"
}
document_sources = document_targets.map do |target, expected_source|
  mount = by_target.fetch(target).fetch(0)
  source = File.expand_path(mount.fetch("source"))
  abort "Paperless contract failed: #{variant} document mount #{target} source differs" unless
    source == expected_source
  abort "Paperless contract failed: #{variant} document mount #{target} is read-only" if
    mount["read_only"] == true
  source
end
abort "Paperless contract failed: #{variant} document sources alias or overlap" unless
  document_sources.uniq.length == document_sources.length &&
    document_sources.combination(2).none? do |left, right|
      left.start_with?(right + File::SEPARATOR) || right.start_with?(left + File::SEPARATOR)
    end
abort "Paperless contract failed: #{variant} document source resolves below volume1" if
  document_sources.any? { |source| source == "/volume1" || source.start_with?("/volume1/") }

state_sources = [
  services.fetch("broker").fetch("volumes").fetch(0).fetch("source"),
  services.fetch("db").fetch("volumes").fetch(0).fetch("source"),
  *%w[/usr/src/paperless/data /usr/src/paperless/cache
      /usr/share/tesseract-ocr/5/tessdata/heb.traineddata].map do |target|
    by_target.fetch(target).fetch(0).fetch("source")
  end
].map { |source| File.expand_path(source) }
expected_state_root = "/volume1/Docker/paperless-ngx"
abort "Paperless contract failed: #{variant} state source escapes its isolated root" unless
  state_sources.all? do |source|
    source.start_with?(expected_state_root + File::SEPARATOR)
  end
expected_state_sources = %w[postgres redis data cache].map do |relative|
  File.join(expected_state_root, relative)
end + [File.join(expected_state_root, "tessdata", "heb.traineddata")]
abort "Paperless contract failed: #{variant} effective state source list differs" unless
  state_sources.sort == expected_state_sources.sort
RUBY
}

render_paperless_mounts nas -f "$compose"
render_paperless_mounts mac -f "$compose" -f "$mac_compose"
render_paperless_mounts integration -f "$compose" -f "$integration_compose"

ruby -ryaml - "$compose" "$mac_compose" "$integration_compose" "$role" "$defaults" \
  "$argument_specs" "$storage_inventory" "$host_prep" "$generator" "$environment_template" "$snapshot" <<'RUBY'
compose_path, mac_path, integration_path, role_path, defaults_path, argument_specs_path,
  storage_inventory_path, host_prep_path, generator_path, environment_template_path, snapshot_path = ARGV
compose = YAML.safe_load_file(compose_path, aliases: true)
mac = YAML.safe_load_file(mac_path, aliases: true)
integration = YAML.safe_load_file(integration_path, aliases: true)

# The role is read through static_role_tasks, which assembles it the way Ansible
# does: statically imported stages spliced in where they stand, dynamic includes
# left alone. main.yml is an index of nine stage files, so loading that one file
# hands every check below an index instead of the role. This script aborts on its
# first violation and its presence invariants come first, so that mistake is loud
# here rather than silent -- but the absence invariants below ("never invokes the
# consuming mail endpoint", "never counts global processed-mail or tasks") would
# hold trivially over an index, and they are the half that would stay green if the
# ordering ever changed. Task lists are then flattened so a task on a block's
# rescue or always path is still a task the role executes.
require File.join(ENV.fetch("PLATFORM_CONTRACT_REPO_DIR"), "tests", "policy_support")
include PolicySupport

# Assertions about what the role does read the parsed structure rather than the
# file's bytes: a task name that survives only inside a comment is not a task,
# and a module argument found anywhere in the file does not belong to the request
# the assertion names. role_strings collects the strings one at a time rather than
# joining them, because a pattern matched against a joined blob spans two
# unrelated tasks and reports a violation neither of them contains.
def role_strings(node)
  case node
  when Hash then node.flat_map { |key, value| [key.to_s] + role_strings(value) }
  when Array then node.flat_map { |value| role_strings(value) }
  when String then [node]
  else []
  end
end

# A folded or literal scalar carries its line breaks into the parsed value, so a
# URL written across two lines does not match a pattern for the single-line form.
# Absence invariants are matched against the whitespace-stripped scalar as well,
# so folding a forbidden endpoint no longer hides it.
def scalar_forms(value)
  [value, value.gsub(/[[:space:]]+/, "")].uniq
end

role_tasks = flatten_tasks(static_role_tasks(role_path, aliases: true))
role_task_names = role_tasks.filter_map { |task| task["name"] }
role_scalars = role_strings(role_tasks)
defaults = YAML.safe_load_file(defaults_path)
argument_specs = YAML.safe_load_file(argument_specs_path)
storage_inventory = YAML.safe_load_file(storage_inventory_path)
host_prep = YAML.safe_load_file(host_prep_path)
generator_vars = YAML.safe_load_file(generator_path).fetch(0).fetch("vars")
# The environment file has its own grammar, so it is read as the assignments it
# declares rather than as a substring of the template. A commented-out sample of
# the right assignment satisfies a substring check while the live line exports
# something else, and an appended duplicate silently wins on the last one.
environment_assignments = File.readlines(environment_template_path).filter_map do |line|
  name, _separator, value = line.strip.partition("=")
  [name, value] if line.strip.match?(/\A[A-Z][A-Z0-9_]*=/)
end
snapshot_text = File.read(snapshot_path)

def refuse(message)
  abort "Paperless contract failed: #{message}"
end

services = compose.fetch("services")
expected_containers = %w[broker db webserver gotenberg tika].freeze
refuse("stack composition differs") unless services.keys.sort == expected_containers.sort
services.each do |name, service|
  refuse("#{name} restart policy differs") unless service.fetch("restart") == "unless-stopped"
  refuse("#{name} logging policy differs") unless service.fetch("logging") == {
    "driver" => "json-file", "options" => { "max-size" => "10m", "max-file" => "3" }
  }
end

web = services.fetch("webserver")
refuse("NAS webserver must not use host networking") if web.key?("network_mode")
refuse("NAS webserver must publish its documented port") unless web.fetch("ports") == ["8000:8000"]
web_healthcheck = web.fetch("healthcheck")
refuse("webserver startup grace must cover fresh database migrations") unless
  web_healthcheck.fetch("start_period") == "300s"
refuse("webserver runtime health threshold differs") unless
  web_healthcheck.slice("interval", "timeout", "retries") == {
    "interval" => "30s", "timeout" => "10s", "retries" => 4
  }
refuse("webserver must wait for healthy Tika") unless
  web.fetch("depends_on").fetch("tika").fetch("condition") == "service_healthy"
refuse("Tika healthcheck is absent") unless services.fetch("tika").key?("healthcheck")
# The dependencies are reached over the stack's own network, so a host
# publication for any of them is surface the platform does not need.
%w[broker db gotenberg tika].each do |name|
  refuse("#{name} must not publish a host port") if services.fetch(name).key?("ports")
end

refuse("document storage contract differs") unless web.fetch("volumes").grep(/PAPERLESS_(MEDIA|CONSUME|EXPORT)_PATH/).sort == [
  "${PAPERLESS_CONSUME_PATH:?}:/usr/src/paperless/consume",
  "${PAPERLESS_EXPORT_PATH:?}:/usr/src/paperless/export",
  "${PAPERLESS_MEDIA_PATH:?}:/usr/src/paperless/media"
]
refuse("document paths must not be read-only") if
  web.fetch("volumes").grep(/PAPERLESS_(MEDIA|CONSUME|EXPORT)_PATH/).any? { |volume| volume.end_with?(":ro") }
refuse("application-state storage contract differs") unless
  web.fetch("volumes").include?("${PAPERLESS_DATA_PATH:?}:/usr/src/paperless/data") &&
  services.fetch("broker").fetch("volumes") == ["${PAPERLESS_REDIS_PATH:?}:/data"] &&
  services.fetch("db").fetch("volumes") == ["${PAPERLESS_POSTGRES_PATH:?}:/var/lib/postgresql"]
refuse("Hebrew OCR model is not mounted read-only") unless
  web.fetch("volumes").include?("${PAPERLESS_TESSDATA_PATH:?}/heb.traineddata:/usr/share/tesseract-ocr/5/tessdata/heb.traineddata:ro")
refuse("OCR languages differ") unless web.fetch("environment").fetch("PAPERLESS_OCR_LANGUAGE") == "deu+eng+heb"
refuse("optional Ollama configuration differs from the canonical stack") unless
  web.fetch("environment").slice(
    "PAPERLESS_AI_ENABLED", "PAPERLESS_AI_LLM_BACKEND", "PAPERLESS_AI_LLM_CONTEXT_SIZE",
    "PAPERLESS_AI_LLM_ENDPOINT", "PAPERLESS_AI_LLM_MODEL", "PAPERLESS_AI_LLM_REQUEST_TIMEOUT"
  ) == {
    "PAPERLESS_AI_ENABLED" => "${PAPERLESS_AI_ENABLED:?}",
    "PAPERLESS_AI_LLM_BACKEND" => "ollama", "PAPERLESS_AI_LLM_CONTEXT_SIZE" => 4096,
    "PAPERLESS_AI_LLM_ENDPOINT" => "${PAPERLESS_AI_LLM_ENDPOINT:?}",
    "PAPERLESS_AI_LLM_MODEL" => "${PAPERLESS_AI_LLM_MODEL:?}",
    "PAPERLESS_AI_LLM_REQUEST_TIMEOUT" => 300
  }

override_services = mac.fetch("services")
refuse("Mac override must provide all services") unless override_services.keys.sort == services.keys.sort
refuse("Mac webserver must publish only its configured port") unless
  override_services.fetch("webserver").fetch("ports") == ["${PAPERLESS_HOST_PORT:?}:8000"]
%w[broker db gotenberg tika].each do |name|
  refuse("Mac #{name} must not reintroduce a host port") if override_services.fetch(name).key?("ports")
end

# The integration sandbox keeps the production port, exactly as the Immich and
# Jellyfin overrides do, so only container names move. Anything else it sets is a
# divergence between the two non-NAS platforms that nothing else would catch.
integration_services = integration.fetch("services")
refuse("integration override must provide all services") unless
  integration_services.keys.sort == services.keys.sort
integration_services.each do |name, definition|
  refuse("integration #{name} must move only its container name") unless
    definition.keys == ["container_name"]
end

refuse("mail probe must not inspect global processed-mail or task counts") if
  role_scalars.any? { |value| scalar_forms(value).any? { |form| form.match?(%r{/api/(?:processed_mail|tasks)/}) } } ||
    role_tasks.any? { |task| Array(task["loop"]).sort == %w[processed_mail tasks] }

expected_storage_defaults = {
  "paperless_archive_host_path" => "/volume2/Documents/archive",
  "paperless_consume_host_path" => "/volume2/Documents/inbox",
  "paperless_export_host_path" => "/volume2/Documents/export",
  "paperless_state_host_path" => "/volume1/Docker/paperless-ngx"
}
refuse("Paperless host storage defaults differ") unless
  defaults.slice(*expected_storage_defaults.keys) == expected_storage_defaults
argument_options = argument_specs.dig("argument_specs", "main", "options")
expected_storage_defaults.each do |name, path|
  refuse("#{name} argument validation differs") unless
    argument_options.dig(name, "type") == "str" &&
      argument_options.dig(name, "choices") == [path]
end
expected_storage_inventory = {
  "{{ nas_media_root }}/Documents/archive" => "critical",
  "{{ nas_media_root }}/Documents/inbox" => "critical",
  "{{ nas_media_root }}/Documents/export" => "critical",
  "{{ nas_docker_root }}/paperless-ngx/postgres" => "critical",
  "{{ nas_docker_root }}/paperless-ngx/redis" => "cache",
  "{{ nas_docker_root }}/paperless-ngx/data" => "critical",
  "{{ nas_docker_root }}/paperless-ngx/cache" => "cache",
  "{{ nas_docker_root }}/paperless-ngx/tessdata" => "cache"
}
storage_entries = storage_inventory.fetch("nas_storage")
expected_storage_inventory.each do |path, recovery|
  matches = storage_entries.select { |entry| entry["path"] == path }
  refuse("central storage declaration differs for #{path}") unless
    matches.length == 1 && matches.first["mode"] == "0755" &&
      matches.first["recovery"] == recovery
end
storage_validation_index = host_prep.index do |task|
  task["name"] == "Validate central storage targets before directory creation"
end
storage_creation_index = host_prep.index { |task| task["name"] == "Create service state directories" }
storage_validation = storage_validation_index && host_prep.fetch(storage_validation_index)
refuse("central storage targets are not validated before mkdir") unless
  storage_validation_index && storage_creation_index && storage_validation_index < storage_creation_index &&
    storage_validation.dig("ansible.builtin.include_role", "name") == "deployment_bundle" &&
    storage_validation.dig("ansible.builtin.include_role", "tasks_from") == "target" &&
    storage_validation.dig("vars", "deployment_target_extra_paths").include?("nas_storage")

probe = role_tasks.find { |task| task["name"] == "Test the candidate Paperless Gmail credential before persistence" }
refuse("pinned Paperless 3.0.5 synchronous mail test endpoint differs") unless
  probe&.dig("ansible.builtin.uri", "url") == "{{ paperless_api }}/api/mail_accounts/test/" &&
    probe.dig("ansible.builtin.uri", "method") == "POST" &&
    probe.dig("ansible.builtin.uri", "timeout") == 180 &&
    probe.dig("ansible.builtin.uri", "status_code").to_s.include?("range(100, 600)") &&
    probe["failed_when"] == false
probe_assertion_index = role_tasks.index do |task|
  task["name"] == "Require the exact synchronous Paperless Gmail credential response"
end
probe_index = role_tasks.index(probe)
account_create_index = role_tasks.index do |task|
  task["name"] == "Create the managed Paperless mail account"
end
rule_create_index = role_tasks.index do |task|
  task["name"] == "Create the managed Paperless mail rule"
end
refuse("credential response is not required before managed persistence") unless
  probe_index && probe_assertion_index && account_create_index && rule_create_index &&
    probe_index < probe_assertion_index && probe_assertion_index < account_create_index &&
    probe_assertion_index < rule_create_index
probe_assertion = role_tasks.fetch(probe_assertion_index).fetch("ansible.builtin.assert")
refuse("credential success signal is not the exact synchronous response") unless
  Array(probe_assertion["that"]).any? do |condition|
    condition.to_s.include?("paperless_candidate_mail_test.json == {'success': true}")
  end
# The point of the snapshot pair is that both halves straddle the probe and that
# something compares them afterwards. Three whole-file substrings could not say
# that: they passed with the two facts set in either order, with the comparison
# ahead of the probe, or with all three living in a comment.
def set_fact_index(tasks, name)
  tasks.index { |task| Hash(task["ansible.builtin.set_fact"]).key?(name) }
end

probe_state_before_index = set_fact_index(role_tasks, "paperless_managed_mail_probe_state_before")
probe_state_after_index = set_fact_index(role_tasks, "paperless_managed_mail_probe_state_after")
probe_state_comparison_index = role_tasks.index do |task|
  Array(task.dig("ansible.builtin.assert", "that")).any? do |condition|
    condition.to_s.split.join(" ") ==
      "paperless_managed_mail_probe_state_before == paperless_managed_mail_probe_state_after"
  end
end
refuse("managed account/rule state is not snapshotted around the credential probe") unless
  probe_state_before_index && probe_state_after_index && probe_state_comparison_index &&
    probe_state_before_index < probe_index && probe_index < probe_state_after_index &&
    probe_state_after_index < probe_state_comparison_index
schema_validation_index = role_tasks.index do |task|
  task["name"] == "Validate Paperless mail account and rule schemas before mutation"
end
refuse("managed mail schema is not validated globally before mutation") unless
  schema_validation_index && schema_validation_index < account_create_index &&
    schema_validation_index < rule_create_index
# The five state roots are read off the fact that declares them, so an appended
# sixth source or a renamed root is a difference rather than extra text the old
# ordered regex skipped over on its way to the next landmark.
state_paths_task = role_tasks.find do |task|
  Hash(task["ansible.builtin.set_fact"]).key?("paperless_effective_state_host_paths")
end
refuse("Paperless effective state sources do not match the five Compose/env state roots") unless
  state_paths_task &&
    state_paths_task.fetch("ansible.builtin.set_fact")
                    .fetch("paperless_effective_state_host_paths") == [
                      "{{ paperless_effective_state_host_path }}/postgres",
                      "{{ paperless_effective_state_host_path }}/redis",
                      "{{ paperless_effective_state_host_path }}/data",
                      "{{ paperless_effective_cache_host_path }}",
                      "{{ paperless_effective_state_host_path }}/tessdata"
                    ]
storage_layout_index = role_tasks.index do |task|
  task["name"] == "Validate canonical Paperless storage source separation"
end
first_storage_mutation_index = role_tasks.index do |task|
  task["name"] == "Install the pinned Hebrew OCR model"
end
refuse("canonical Paperless storage separation is not validated before mutation") unless
  storage_layout_index && first_storage_mutation_index && storage_layout_index < first_storage_mutation_index

required_tasks = [
  "Render the Paperless environment",
  "Deploy the Paperless data services",
  "Refuse a rotated Paperless database credential",
  "Deploy Paperless",
  "Create the absent vault Paperless administrator",
  "Authenticate the vault Paperless administrator",
  "Repair the vault Paperless administrator",
  "Refuse duplicate managed Paperless mail accounts",
  "Inspect the installed Paperless Gmail credential fingerprint",
  "Validate Paperless mail account and rule schemas before mutation",
  "Test the candidate Paperless Gmail credential before persistence",
  "Require the exact synchronous Paperless Gmail credential response",
  "Require credential testing to preserve managed Paperless mail state",
  "Create the managed Paperless mail account",
  "Repair the managed Paperless mail account",
  "Refuse duplicate managed Paperless mail rules",
  "Create the managed Paperless mail rule",
  "Repair the managed Paperless mail rule",
  "Require exact Paperless administrator, mail account, and mail rule",
  "Record the verified Paperless Gmail credential fingerprint"
]
required_tasks.each { |name| refuse("missing #{name}") unless role_task_names.include?(name) }
refuse("role must never invoke the consuming mail endpoint") if
  role_scalars.any? { |value| scalar_forms(value).any? { |form| form.match?(%r{/mail_accounts/.+/process/}) } }

secret_tasks = role_tasks.reject { |task| task.key?("ansible.builtin.assert") }.select do |task|
  task.to_s.match?(/vault_paperless_|paperless_api_token|paperless_mail_account_payload/)
end
secret_tasks.each do |task|
  refuse("secret-bearing task #{task['name']} is not redacted") unless task["no_log"] == true
end
[
  "Require the vault Paperless administrator",
  "Require one vault Paperless administrator identity",
  "Require exact Paperless administrator identity",
  "Require the exact synchronous Paperless Gmail credential response",
  "Require credential testing to preserve managed Paperless mail state",
  "Require exact Paperless administrator, mail account, and mail rule"
].each do |name|
  task = role_tasks.find { |candidate| candidate["name"] == name }
  refuse("missing visible Paperless assertion #{name}") unless task
  refuse("Paperless assertion #{name} must keep static failures visible") if task["no_log"] == true
end
refuse("Paperless restore must recover both services from an ensure block") unless
  snapshot_text.match?(/if MODE == "restore".*?begin.*?ensure.*?\["docker", "start", REDIS\].*?\["docker", "start", WEBSERVER\].*?wait_healthy\(REDIS, WEBSERVER\)/m)
# The ordering above is necessary but was not sufficient: it matched equally well
# when the flushall between the two starts was a one-shot exec, and a one-shot
# exec there races the socket. docker start returns once the container process
# has been launched, not once valkey has bound 127.0.0.1:6379, which is how CI
# run 32590260858 reported "Connection refused" and then "application recovery
# failed" on a restore that had succeeded, after seven clean runs.
#
# So the flushall has to carry the retried marker, and the wait it selects has to
# hand a timeout back to its caller: the caller is an ensure block that may
# already be unwinding a restore failure, and a die there would replace the real
# diagnosis with a recovery one. Both properties are proved behaviourally by
# tests/mac/snapshot-paperless-recovery-test.sh, which drives the real script
# against a valkey that refuses a chosen number of connections. These assertions
# exist so the mechanism cannot be deleted between runs of that proof.
refuse("Paperless recovery must wait for valkey rather than one-shot the flushall") unless
  snapshot_text.include?('[["docker", "exec", REDIS, "valkey-cli", "flushall"], :until_ready]')
readiness_wait = snapshot_text[/^def capture_until_ready\b.*?^end$/m].to_s
refuse("Paperless recovery readiness wait is absent") if readiness_wait.empty?
refuse("Paperless recovery readiness wait must be bounded and must not die") unless
  readiness_wait.include?("limit = Time.now + deadline") &&
    readiness_wait.include?("return [stdout, stderr, status] if status.success? || Time.now >= limit") &&
    !readiness_wait.include?("die")
refuse("Paperless recovery deadline must not be configurable down to no retry") unless
  snapshot_text.match?(
    /Integer\(ENV\.fetch\("PLATFORM_PAPERLESS_RECOVERY_DEADLINE"\), 10\), 1\s*\n\]\.max/
  )
# The default is pinned as well as the floor, because shortening it is the silent
# half of this failure mode. Deleting the assignment is loud: ENV.fetch raises
# and every invocation dies. Changing 60 to 2 breaks nothing any check can see,
# and leaves a wait too short to survive a loaded runner, which is the same race
# arriving again months later with a green suite behind it.
refuse("Paperless recovery deadline default differs") unless
  snapshot_text.include?(': "${PLATFORM_PAPERLESS_RECOVERY_DEADLINE:=60}"')
# The drill waits for its deletion to settle by re-reading the catalogue every two
# seconds for up to two minutes. Authenticating on every pass is thirty POSTs to
# /api/token/ a minute from inside one loop, and Paperless throttles that endpoint
# at five a minute by default, so the drill aborted the suite with "POST
# /api/token/ returned HTTP 429" about ten seconds into the loop, before it
# reached the restore it exists to prove.
#
# The poll is asserted as a whole rather than by looking for a login it must not
# contain, because the absence of one spelling is satisfied by any rewrite that
# spells the login differently, and a guard that both the broken and the fixed
# form satisfy is not a guard. The budget itself is proved behaviourally by
# tests/mac/snapshot-paperless-drill-throttle-test.sh, which drives the real
# script against a stub that throttles the way Paperless does; this assertion
# keeps the shape from being edited back between runs of that proof.
drill_mutation = snapshot_text.scan(/^if MODE == "drill"\n.*?^end$/m).find do |block|
  block.include?('request("delete", "/api/documents/')
end.to_s
refuse("Paperless drill mutation block is absent") if drill_mutation.empty?
drill_poll = drill_mutation[/^  loop do\n.*?^  end$/m].to_s
refuse("Paperless drill deletion poll is absent") if drill_poll.empty?
refuse("Paperless drill poll must reuse the drill token rather than log in again") unless
  drill_poll.include?("break if catalogue(drill_token).empty?") &&
    !drill_poll.include?("authenticate")
admin_create = role_tasks.find { |task| task["name"] == "Create the absent vault Paperless administrator" }
admin_argv = admin_create.dig("community.docker.docker_compose_v2_exec", "argv")
refuse("Paperless administrator creation must use the container password environment") unless
  admin_argv.join(" ").include?('DJANGO_SUPERUSER_PASSWORD="$PAPERLESS_ADMIN_PASSWORD"')
refuse("Paperless administrator password must not be copied into docker exec argv") if
  admin_argv.any? { |argument| argument.to_s.include?("vault_paperless_admin_password") }
[
  "Resolve Paperless mail account reconciliation",
  "Resolve Paperless mail account repair requirement",
  "Resolve Paperless mail rule reconciliation",
  "Resolve Paperless mail rule repair requirement",
  "Inspect the installed Paperless Gmail credential fingerprint",
  "Read the installed Paperless Gmail credential fingerprint",
  "Resolve the installed Paperless Gmail credential fingerprint",
  "Require the installed Paperless Gmail credential fingerprint",
  "Read the reconciled Paperless mail account",
  "Require complete reconciled Paperless mail account listing",
  "Read the exact reconciled Paperless mail rule",
  "Require complete reconciled Paperless mail rule listing"
].each do |name|
  task = role_tasks.find { |candidate| candidate["name"] == name }
  refuse("#{name} must run during tagged Paperless verification") unless
    Array(task && task["tags"]).include?("platform_verify_paperless")
end
fingerprint_assertion = role_tasks.find do |task|
  task["name"] == "Require the installed Paperless Gmail credential fingerprint"
end
refuse("Paperless credential fingerprint verification must remain redacted") unless
  fingerprint_assertion && fingerprint_assertion["no_log"] == true
refuse("Paperless credential fingerprint assertion must remain verify-only") unless
  Array(fingerprint_assertion["tags"]).sort == %w[never platform_verify_paperless] &&
    fingerprint_assertion["when"] == "'platform_verify_paperless' in ansible_run_tags"
# The sentinel is read off the play variable the generator actually resolves, so
# a commented-out sample no longer satisfies it and a value that resolves a
# template is a difference rather than one spelling of one regex.
refuse("Gmail app password must be a visible sentinel in the new-platform generator") unless
  generator_vars["paperless_gmail_app_password"] == "replace-with-google-app-password"
refuse("generator must not synthesize a Gmail app password") if
  generator_vars["paperless_gmail_app_password"].to_s.include?("{{")
# Google displays the app password in four groups of four. The role has to strip
# the spaces, and it has to do it in the payload it sends and in the fingerprint
# it records, which is what the whole-file substring could not say.
gmail_password_expression = "vault_paperless_gmail_app_password | replace(' ', '')"
payload_task = role_tasks.find do |task|
  Hash(task["ansible.builtin.set_fact"]).key?("paperless_mail_account_payload")
end
payload_facts = Hash(payload_task && payload_task["ansible.builtin.set_fact"])
refuse("role must accept Google's grouped app-password display") unless
  payload_facts.fetch("paperless_mail_account_payload", "").split.join(" ")
              .include?("'password': #{gmail_password_expression}") &&
    payload_facts.fetch("paperless_mail_account_credential_fingerprint", "").split.join(" ")
                 .include?("(#{gmail_password_expression})")
# The env file is asserted as the assignments it declares. Every dependency
# endpoint has to name its Compose service, not just the first one a substring
# found, and every secret-bearing assignment has to be the escaped form exactly
# once, so an appended unescaped duplicate is rejected rather than shadowed.
{
  "PAPERLESS_DBHOST" => "db",
  "PAPERLESS_REDIS" => "redis://broker:6379",
  "PAPERLESS_TIKA_ENDPOINT" => "http://tika:9998",
  "PAPERLESS_GOTENBERG_ENDPOINT" => "http://gotenberg:3000"
}.each do |name, value|
  refuse("#{name} must address its Compose service by name on every platform") unless
    environment_assignments.select { |assignment, _| assignment == name } == [[name, value]]
end
{
  "DB_PASSWORD" => "vault_paperless_db_password",
  "PAPERLESS_SECRET_KEY" => "vault_paperless_django_secret_key",
  "PAPERLESS_ADMIN_USER" => "vault_paperless_admin_username",
  "PAPERLESS_ADMIN_PASSWORD" => "vault_paperless_admin_password",
  "PAPERLESS_ADMIN_MAIL" => "vault_paperless_admin_email"
}.each do |name, variable|
  refuse("#{variable} is not protected from Compose interpolation") unless
    environment_assignments.select { |assignment, _| assignment == name } ==
      [[name, "{{ #{variable} | replace('$', '$$') }}"]]
end

account = defaults.fetch("paperless_mail_account")
refuse("Gmail IMAP settings differ") unless account == {
  "imap_server" => "imap.gmail.com", "imap_port" => 993, "imap_security" => 2,
  "is_token" => false, "account_type" => 1, "character_set" => "UTF-8"
}
rule = defaults.fetch("paperless_mail_rule")
refuse("managed mail rule must be enabled and non-destructive") unless
  rule.fetch("enabled") == true && rule.fetch("folder") == "INBOX" &&
  rule.fetch("action") == 3 && rule.fetch("consumption_scope") == 1
RUBY

grep -qF 'run_paperless_contract seed' "$repo_dir/tests/integration.sh" ||
  fail_contract 'integration does not exercise Paperless document fixtures'
grep -qF '"$repo_dir/tests/contracts/paperless.sh" seed-fixture-only' \
  "$repo_dir/tests/integration.sh" ||
  fail_contract 'integration does not prepare Paperless fixtures on the Docker host'
grep -qF 'run_paperless_snapshot drill' "$repo_dir/tests/integration.sh" ||
  fail_contract 'integration does not exercise coordinated Paperless recovery'
grep -qF 'run("docker", "stop", WEBSERVER, REDIS)' "$snapshot" ||
  fail_contract 'Paperless snapshot does not quiesce writers'
grep -qF 'wait_healthy(REDIS, WEBSERVER)' "$snapshot" ||
  fail_contract 'Paperless restore does not wait for application health'
grep -qF 'request("delete", "/api/documents/' "$snapshot" ||
  fail_contract 'Paperless rollback drill does not destructively test restoration'
if [ "$mode" = static ]; then
  grep -F 'MAIL_PROBE_READ_TIMEOUT = 180' "$0" >/dev/null ||
    fail_contract 'runtime Gmail probe timeout constant differs'
  grep -F 'read_timeout: MAIL_PROBE_READ_TIMEOUT' "$0" >/dev/null ||
    fail_contract 'runtime Gmail probe lacks its explicit bounded timeout'
  printf '%s\n' 'Paperless static contract passed'
  exit 0
fi

: "${PLATFORM_CONTRACT_VAULT_FILE:=${PLATFORM_MAC_VAULT_FILE:-}}"
: "${PLATFORM_CONTRACT_VAULT_PASSWORD_FILE:=${PLATFORM_MAC_VAULT_PASSWORD_FILE:-}}"
: "${PLATFORM_MEDIA_ROOT:?}"
: "${PLATFORM_REPORT_ROOT:?}"
: "${PLATFORM_PAPERLESS_PORT:=8000}"
: "${PLATFORM_PAPERLESS_WEBSERVER_CONTAINER:=paperless_webserver}"
: "${PLATFORM_PAPERLESS_FIXTURE_PRESEEDED:=false}"
PLATFORM_CONTRACT_REPO_DIR=$repo_dir
export PLATFORM_CONTRACT_VAULT_FILE PLATFORM_CONTRACT_VAULT_PASSWORD_FILE
export PLATFORM_MEDIA_ROOT PLATFORM_REPORT_ROOT PLATFORM_PAPERLESS_PORT
export PLATFORM_PAPERLESS_WEBSERVER_CONTAINER PLATFORM_CONTRACT_REPO_DIR
export PLATFORM_PAPERLESS_FIXTURE_PRESEEDED

shift || true
exec ruby - "$mode" "$@" <<'RUBY'
require "digest"
require "json"
require "net/http"
require "open3"
require "pathname"
require "tempfile"
require "timeout"
require "uri"
require "yaml"
require "zlib"

MODE = ARGV.fetch(0)
DOCUMENT_INDEX_TIMEOUT_SECONDS = 600
BASE = URI("http://127.0.0.1:#{Integer(ENV.fetch('PLATFORM_PAPERLESS_PORT'), 10)}")
MEDIA_ROOT = Pathname.new(ENV.fetch("PLATFORM_MEDIA_ROOT")).expand_path
REPORT_ROOT = Pathname.new(ENV.fetch("PLATFORM_REPORT_ROOT")).expand_path
REPO_ROOT = Pathname.new(ENV.fetch("PLATFORM_CONTRACT_REPO_DIR", Dir.pwd)).expand_path
WEBSERVER = ENV.fetch("PLATFORM_PAPERLESS_WEBSERVER_CONTAINER")
STATE_PATH = REPORT_ROOT.join("paperless-persistence.json")
EXPORT_ROOT = Pathname.new(
  ENV.fetch("PLATFORM_PAPERLESS_EXPORT_ROOT", MEDIA_ROOT.join("Documents", "export").to_s)
).expand_path
CONSUME_ROOT = Pathname.new(
  ENV.fetch("PLATFORM_PAPERLESS_CONSUME_ROOT", MEDIA_ROOT.join("Documents", "inbox").to_s)
).expand_path
EXPORT_PATH = EXPORT_ROOT.join("task-13-contract-export")
PDF_MARKER = "paperlesscontractenglish"
IMAGE_MARKER = "paperless contract image ocr"
OFFICE_MARKER = "paperlesscontracthebrew"
OFFICE_TEXT = "Paperless contract English Deutsch Überprüfung Hebrew שלום #{OFFICE_MARKER}"
MAIL_PROBE_READ_TIMEOUT = 180

def fail_contract(message)
  warn "Paperless contract failed: #{message}"
  exit 1
end

def endpoint(path)
  URI.join(BASE.to_s, path)
end

def request(method, path, token: nil, body: nil, expected: [200], parse_json: true, read_timeout: 60)
  uri = endpoint(path)
  request = Net::HTTP.const_get(method.capitalize).new(uri)
  request["Authorization"] = "Token #{token}" if token
  if body
    request["Content-Type"] = "application/json"
    request.body = JSON.generate(body)
  end
  response = Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: read_timeout) do |http|
    http.request(request)
  end
  fail_contract("#{method.upcase} #{uri.path} returned HTTP #{response.code}") unless
    expected.include?(response.code.to_i)
  payload = if parse_json
              response.body.to_s.empty? ? nil : JSON.parse(response.body)
            else
              response.body.to_s
            end
  [response, payload]
rescue JSON::ParserError
  fail_contract("#{method.upcase} #{uri.path} returned malformed JSON")
rescue SystemCallError, Timeout::Error => error
  fail_contract("#{method.upcase} #{uri.path} failed: #{error.class}")
end

def results(payload)
  payload.fetch("results")
end

def pdf_bytes(text)
  escaped = text.gsub(/[\\()]/) { |character| "\\#{character}" }
  stream = "BT /F1 18 Tf 72 720 Td (#{escaped}) Tj ET\n"
  objects = [
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
    "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    "<< /Length #{stream.bytesize} >>\nstream\n#{stream}endstream"
  ]
  body = "%PDF-1.4\n"
  offsets = [0]
  objects.each_with_index do |object, index|
    offsets << body.bytesize
    body << "#{index + 1} 0 obj\n#{object}\nendobj\n"
  end
  xref = body.bytesize
  body << "xref\n0 #{objects.length + 1}\n0000000000 65535 f \n"
  offsets.drop(1).each { |offset| body << format("%010d 00000 n \n", offset) }
  body << "trailer\n<< /Size #{objects.length + 1} /Root 1 0 R >>\nstartxref\n#{xref}\n%%EOF\n"
end

def zip_entries(entries)
  local = +"".b
  central = +"".b
  entries.each do |name, contents|
    name = name.b
    contents = contents.b
    crc = Zlib.crc32(contents)
    offset = local.bytesize
    local << [0x04034b50, 20, 0, 0, 0, 0, crc, contents.bytesize, contents.bytesize,
              name.bytesize, 0].pack("VvvvvvVVVvv") << name << contents
    central << [0x02014b50, 20, 20, 0, 0, 0, 0, crc, contents.bytesize, contents.bytesize,
                name.bytesize, 0, 0, 0, 0, 0, offset].pack("VvvvvvvVVVvvvvvVV") << name
  end
  local + central +
    [0x06054b50, 0, 0, entries.length, entries.length, central.bytesize,
     local.bytesize, 0].pack("VvvvvVVv")
end

def docx_bytes(text)
  escaped = text.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
  zip_entries([
    ["[Content_Types].xml", <<~XML],
      <?xml version="1.0" encoding="UTF-8"?>
      <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
      </Types>
    XML
    ["_rels/.rels", <<~XML],
      <?xml version="1.0" encoding="UTF-8"?>
      <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
      </Relationships>
    XML
    ["word/document.xml", <<~XML]
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>#{escaped}</w:t></w:r></w:p></w:body></w:document>
    XML
  ])
end

def write_fixture(path, bytes)
  path.dirname.mkpath
  if path.exist?
    fail_contract("fixture bytes drifted: #{path.basename}") unless path.file? && path.binread == bytes
  else
    path.open(File::WRONLY | File::CREAT | File::EXCL, 0o644) { |file| file.write(bytes) }
  end
end

def seed_document_fixtures
  write_fixture(
    CONSUME_ROOT.join("task-13-contract.pdf"),
    pdf_bytes("Paperless PDF #{PDF_MARKER}")
  )
  write_fixture(
    CONSUME_ROOT.join("task-13-contract.png"),
    REPO_ROOT.join("tests/fixtures/paperless-ocr.png.base64").read.delete("\n").unpack1("m0")
  )
  write_fixture(CONSUME_ROOT.join("task-13-contract.docx"), docx_bytes(OFFICE_TEXT))
end

def run_bounded(seconds, *argv, input: nil, label:)
  reader, writer = IO.pipe if input
  Tempfile.create("paperless-contract-command") do |stderr|
    spawn_options = { pgroup: true, out: File::NULL, err: stderr }
    spawn_options[:in] = reader if input
    pid = Process.spawn(*argv, **spawn_options)
    reader&.close
    if input
      writer.write(input)
      writer.close
    end
    status = nil
    begin
      Timeout.timeout(seconds) { _waited, status = Process.wait2(pid) }
    rescue Timeout::Error
      begin
        Process.kill("TERM", -pid)
      rescue Errno::ESRCH
        nil
      end
      begin
        Timeout.timeout(5) { Process.wait(pid) }
      rescue Timeout::Error
        begin
          Process.kill("KILL", -pid)
        rescue Errno::ESRCH
          nil
        end
        begin
          Process.wait(pid)
        rescue Errno::ECHILD
          nil
        end
      rescue Errno::ECHILD, Errno::ESRCH
        nil
      end
      fail_contract("#{label} timed out")
    ensure
      reader&.close unless reader&.closed?
      writer&.close unless writer&.closed?
    end
    unless status.success?
      stderr.flush
      stderr.rewind
      diagnostic_bytes = stderr.read
      diagnostic = if diagnostic_bytes.bytesize > 4096
                     diagnostic_bytes.byteslice(diagnostic_bytes.bytesize - 4096, 4096)
                   else
                     diagnostic_bytes
                   end
      diagnostic = diagnostic.encode("UTF-8", invalid: :replace, undef: :replace)
      secret = input.to_s.strip
      diagnostic.gsub!(secret, "[REDACTED]") unless secret.empty?
      warn "Paperless #{label} diagnostic: #{diagnostic.strip}" unless diagnostic.strip.empty?
      fail_contract("#{label} failed")
    end
  end
end

def wait_healthy(container, deadline:)
  loop do
    stdout, _stderr, status = Open3.capture3(
      "docker", "inspect", "--format", "{{.State.Health.Status}}", container
    )
    return if status.success? && stdout.strip == "healthy"
    fail_contract("#{container} did not become healthy") if Time.now >= deadline
    sleep 2
  end
end

def document_for(token, marker, deadline:)
  loop do
    _response, payload = request(
      "get", "/api/documents/?query=#{URI.encode_www_form_component(marker)}&page_size=100",
      token: token
    )
    match = results(payload).find { |document| document.fetch("content", "").downcase.include?(marker.downcase) }
    return match if match
    fail_contract("document marker #{marker} was not indexed") if Time.now >= deadline
    sleep 3
  end
end

def canonical_documents(pdf_document, image_document, office_document)
  JSON.generate({
    "pdf_id" => pdf_document.fetch("id"), "image_id" => image_document.fetch("id"),
    "office_id" => office_document.fetch("id"),
    "pdf_checksum" => document_checksum(pdf_document),
    "image_checksum" => document_checksum(image_document),
    "office_checksum" => document_checksum(office_document)
  }.sort.to_h)
end

def document_checksum(document)
  root_version = document.fetch("versions").find { |version| version.fetch("is_root") }
  checksum = root_version&.fetch("checksum")
  fail_contract("document root-version checksum is absent") if checksum.to_s.empty?
  checksum
end

if MODE == "seed-fixture-only"
  seed_document_fixtures
  puts "Paperless document fixtures prepared before deployment"
  exit 0
end

vault_yaml, vault_error, vault_status = Open3.capture3(
  "ansible-vault", "view", "--vault-password-file",
  ENV.fetch("PLATFORM_CONTRACT_VAULT_PASSWORD_FILE"),
  ENV.fetch("PLATFORM_CONTRACT_VAULT_FILE")
)
fail_contract("encrypted vault could not be read") unless vault_status.success?
vault = YAML.safe_load(vault_yaml)
export_passphrase = Digest::SHA256.hexdigest(
  "paperless-portable-export:\0#{vault.fetch('vault_paperless_django_secret_key')}"
)
vault_yaml.replace("\0" * vault_yaml.bytesize)
vault_error.replace("\0" * vault_error.bytesize)

_token_response, token_payload = request(
  "post", "/api/token/",
  body: {
    "username" => vault.fetch("vault_paperless_admin_username"),
    "password" => vault.fetch("vault_paperless_admin_password")
  }
)
token = token_payload.fetch("token")

_users_response, users_payload = request("get", "/api/users/?page_size=1000", token: token)
admins = results(users_payload).select do |user|
  user["username"] == vault.fetch("vault_paperless_admin_username")
end
fail_contract("vault administrator identity differs") unless
  admins.length == 1 && admins.first["email"] == vault.fetch("vault_paperless_admin_email") &&
  admins.first["is_superuser"] && admins.first["is_staff"] && admins.first["is_active"]

_accounts_response, accounts_payload = request("get", "/api/mail_accounts/?page_size=1000", token: token)
accounts = results(accounts_payload).select do |account|
  account["name"] == vault.fetch("vault_paperless_mail_account_name")
end
fail_contract("managed Gmail account is absent or duplicated") unless accounts.length == 1
account = accounts.first
expected_account = {
  "name" => vault.fetch("vault_paperless_mail_account_name"),
  "imap_server" => "imap.gmail.com", "imap_port" => 993, "imap_security" => 2,
  "username" => vault.fetch("vault_paperless_gmail_account"), "character_set" => "UTF-8",
  "is_token" => false, "account_type" => 1, "owner" => admins.first.fetch("id")
}
expected_account.each do |key, value|
  fail_contract("managed Gmail account #{key} differs") unless account[key] == value
end

_rules_response, rules_payload = request("get", "/api/mail_rules/?page_size=1000", token: token)
rules = results(rules_payload).select { |rule| rule["name"] == vault.fetch("vault_paperless_mail_rule_name") }
fail_contract("managed Gmail rule is absent or duplicated") unless rules.length == 1
rule = rules.first
expected_rule = {
  "account" => account.fetch("id"), "enabled" => true, "folder" => "INBOX",
  "action" => 3, "consumption_scope" => 1, "attachment_type" => 1,
  "owner" => admins.first.fetch("id")
}

if MODE == "drift"
  request("patch", "/api/mail_rules/#{rule.fetch('id')}/", token: token,
          body: { "enabled" => false }, expected: [200])
  puts "Paperless mail-rule drift installed"
  exit
end
if MODE == "drift-verify"
  fail_contract("Paperless drift fixture was not installed") unless rule["enabled"] == false
  puts "Paperless mail-rule drift is present"
  exit
end
expected_rule.each do |key, value|
  fail_contract("managed Gmail rule #{key} differs") unless rule[key] == value
end

unless ENV["PLATFORM_KIND"] == "integration"
  managed_mail_before = {
    "accounts" => accounts.sort_by { |entry| entry.fetch("id") },
    "rules" => rules.sort_by { |entry| entry.fetch("id") }
  }
  test_payload = expected_account.merge("id" => account.fetch("id"), "password" => "**********")
  _test_response, test_result = request(
    "post", "/api/mail_accounts/test/", token: token, body: test_payload, expected: [200],
    read_timeout: MAIL_PROBE_READ_TIMEOUT
  )
  fail_contract("Gmail connection test did not return exact success") unless test_result == { "success" => true }
  _accounts_after_response, accounts_after_payload = request(
    "get", "/api/mail_accounts/?page_size=1000", token: token
  )
  _rules_after_response, rules_after_payload = request(
    "get", "/api/mail_rules/?page_size=1000", token: token
  )
  managed_mail_after = {
    "accounts" => results(accounts_after_payload).select do |entry|
      entry["name"] == vault.fetch("vault_paperless_mail_account_name")
    end.sort_by { |entry| entry.fetch("id") },
    "rules" => results(rules_after_payload).select do |entry|
      entry["name"] == vault.fetch("vault_paperless_mail_rule_name")
    end.sort_by { |entry| entry.fetch("id") }
  }
  fail_contract("Gmail connection test altered managed mail state") unless
    managed_mail_before == managed_mail_after
end

unrelated_account_name = "paperless-contract-unrelated-account"
unrelated_rule_name = "paperless-contract-unrelated-rule"
if MODE == "seed"
  unrelated_accounts = results(accounts_payload).select { |entry| entry["name"] == unrelated_account_name }
  fail_contract("unrelated mail-account fixture is duplicated") if unrelated_accounts.length > 1
  if unrelated_accounts.empty?
    _response, unrelated_account = request(
      "post", "/api/mail_accounts/", token: token, expected: [201],
      body: expected_account.merge(
        "name" => unrelated_account_name, "username" => "unrelated@example.invalid",
        "password" => "not-a-live-credential"
      ).reject { |key, _value| key == "id" }
    )
  else
    unrelated_account = unrelated_accounts.fetch(0)
  end
  unrelated_rules = results(rules_payload).select { |entry| entry["name"] == unrelated_rule_name }
  fail_contract("unrelated mail-rule fixture is duplicated") if unrelated_rules.length > 1
  if unrelated_rules.empty?
    request(
      "post", "/api/mail_rules/", token: token, expected: [201],
      body: {
        "name" => unrelated_rule_name, "account" => unrelated_account.fetch("id"),
        "enabled" => false, "folder" => "Contract-Unrelated", "maximum_age" => 1,
        "action" => 1, "assign_title_from" => 1, "assign_tags" => [],
        "assign_correspondent_from" => 1, "assign_owner_from_rule" => true,
        "order" => 99, "attachment_type" => 1, "consumption_scope" => 1,
        "pdf_layout" => 0, "stop_processing" => true, "owner" => admins.first.fetch("id")
      }
    )
  end
elsif STATE_PATH.exist?
  unrelated_accounts = results(accounts_payload).select { |entry| entry["name"] == unrelated_account_name }
  unrelated_rules = results(rules_payload).select { |entry| entry["name"] == unrelated_rule_name }
  fail_contract("reconciliation did not preserve the unrelated mail account and rule") unless
    unrelated_accounts.length == 1 && unrelated_rules.length == 1 &&
      unrelated_rules.first["account"] == unrelated_accounts.first.fetch("id") &&
      unrelated_rules.first["enabled"] == false
end

if MODE == "run"
  puts "Paperless login, Gmail, and non-consuming connection contract passed"
  exit
end
fail_contract("unknown mode: #{MODE}") unless %w[seed assert-persistence].include?(MODE)

if MODE == "seed" && ENV.fetch("PLATFORM_PAPERLESS_FIXTURE_PRESEEDED") != "true"
  seed_document_fixtures
end

processing_deadline = Time.now + DOCUMENT_INDEX_TIMEOUT_SECONDS
pdf_document = document_for(token, PDF_MARKER, deadline: processing_deadline)
image_document = document_for(token, IMAGE_MARKER, deadline: processing_deadline)
office_document = document_for(token, OFFICE_MARKER, deadline: processing_deadline)
[pdf_document, image_document, office_document].each do |document|
  preview_response, preview_body = request(
    "get", "/api/documents/#{document.fetch('id')}/preview/", token: token, parse_json: false
  )
  fail_contract("document preview was not a PDF") unless
    preview_response["Content-Type"].to_s.split(";", 2).first == "application/pdf" &&
    preview_body.start_with?("%PDF")
end
fail_contract("image OCR did not preserve German text") unless
  image_document.fetch("content", "").downcase.include?("überprüfung")
fail_contract("image OCR did not preserve Hebrew text") unless
  image_document.fetch("content", "").include?("עברית")
fail_contract("Office conversion did not preserve German text") unless
  office_document.fetch("content", "").include?("Überprüfung")
fail_contract("Office conversion did not preserve Hebrew text") unless
  office_document.fetch("content", "").include?("שלום")

canonical = canonical_documents(pdf_document, image_document, office_document)

case MODE
when "seed"
  fail_contract("report root is unavailable or unsafe") unless REPORT_ROOT.directory? && !REPORT_ROOT.symlink?
  fail_contract("refusing to replace Paperless persistence artifact") if STATE_PATH.exist? || STATE_PATH.symlink?
  STATE_PATH.open(File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(canonical) }
  fail_contract("refusing to replace Paperless export fixture") if EXPORT_PATH.exist? || EXPORT_PATH.symlink?
  EXPORT_PATH.mkdir(0o700)
  run_bounded(
    120,
    "docker", "exec", "-i", WEBSERVER, "sh", "-ec",
    'IFS= read -r passphrase; exec python manage.py document_exporter --passphrase "$passphrase" --no-progress-bar "$1"',
    "paperless-exporter", "/usr/src/paperless/export/task-13-contract-export",
    input: "#{export_passphrase}\n", label: "document exporter"
  )
  puts "Paperless encrypted portable export created"
  fail_contract("portable export was not created") unless EXPORT_PATH.directory? && EXPORT_PATH.children.any?
  document_ids = [pdf_document, image_document, office_document].map { |document| document.fetch("id") }
  document_ids.each do |document_id|
    request("delete", "/api/documents/#{document_id}/", token: token, expected: [204])
  end
  request(
    "post", "/api/trash/", token: token,
    body: { "action" => "empty", "documents" => document_ids }, expected: [200]
  )
  deletion_deadline = Time.now + 120
  loop do
    remaining = [PDF_MARKER, IMAGE_MARKER, OFFICE_MARKER].sum do |marker|
      _response, payload = request(
        "get", "/api/documents/?query=#{URI.encode_www_form_component(marker)}&page_size=100",
        token: token
      )
      results(payload).length
    end
    break if remaining.zero?
    fail_contract("portable export mutation did not remove the documents") if Time.now >= deletion_deadline
    sleep 2
  end
  run_bounded(
    120,
    "docker", "exec", "-i", WEBSERVER, "sh", "-ec",
    'IFS= read -r passphrase; exec python manage.py document_importer --passphrase "$passphrase" --no-progress-bar "$1"',
    "paperless-importer", "/usr/src/paperless/export/task-13-contract-export",
    input: "#{export_passphrase}\n", label: "document importer"
  )
  run_bounded(120, "docker", "restart", WEBSERVER, label: "webserver restart")
  wait_healthy(WEBSERVER, deadline: Time.now + 120)
  puts "Paperless encrypted portable export imported"
  import_deadline = Time.now + DOCUMENT_INDEX_TIMEOUT_SECONDS
  imported_pdf = document_for(token, PDF_MARKER, deadline: import_deadline)
  imported_image = document_for(token, IMAGE_MARKER, deadline: import_deadline)
  imported_office = document_for(token, OFFICE_MARKER, deadline: import_deadline)
  fail_contract("portable export did not restore exact records") unless
    canonical_documents(imported_pdf, imported_image, imported_office) == canonical
  puts "Paperless PDF, Office, OCR, search, preview, export, and import fixtures seeded"
when "assert-persistence"
  fail_contract("Paperless persistence artifact is unavailable or unsafe") unless STATE_PATH.file? && !STATE_PATH.symlink?
  fail_contract("Paperless documents changed across recreation") unless STATE_PATH.binread == canonical
  fail_contract("Paperless portable export did not persist") unless EXPORT_PATH.directory? && EXPORT_PATH.children.any?
  puts "Paperless documents, search index, previews, and export persisted"
end
RUBY
