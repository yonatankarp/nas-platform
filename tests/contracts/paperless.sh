#!/bin/sh
set -eu
set +x

mode=${1:-run}
repo_dir=${PLATFORM_CONTRACT_REPO_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)}
compose=$repo_dir/services/paperless-ngx/compose.yml
mac_compose=$repo_dir/services/paperless-ngx/compose.mac.yml
adoption_compose=$repo_dir/services/paperless-ngx/compose.adoption.yml
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
[ -f "$adoption_compose" ] || fail_contract 'services/paperless-ngx/compose.adoption.yml is absent'
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
  case "$variant" in
    *adoption*) cache_path=/tmp/paperless-contract/adoption/legacy/paperless-ngx/cache ;;
  esac
  rendered=$(env \
    PLATFORM_PROJECT_NAME=paperless-contract PLATFORM_ADOPTION_ROOT=/tmp/paperless-contract/adoption \
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
if variant.include?("adoption")
  document_targets.transform_values! do |source|
    "/tmp/paperless-contract/adoption/legacy/paperless-ngx/" +
      { "archive" => "media", "inbox" => "consume", "export" => "export" }.fetch(File.basename(source))
  end
end
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
unless variant.include?("adoption")
  abort "Paperless contract failed: #{variant} document source resolves below volume1" if
    document_sources.any? { |source| source == "/volume1" || source.start_with?("/volume1/") }
end

state_sources = [
  services.fetch("broker").fetch("volumes").fetch(0).fetch("source"),
  services.fetch("db").fetch("volumes").fetch(0).fetch("source"),
  *%w[/usr/src/paperless/data /usr/src/paperless/cache
      /usr/share/tesseract-ocr/5/tessdata/heb.traineddata].map do |target|
    by_target.fetch(target).fetch(0).fetch("source")
  end
].map { |source| File.expand_path(source) }
expected_state_root = variant.include?("adoption") ?
  "/tmp/paperless-contract/adoption/legacy/paperless-ngx" : "/volume1/Docker/paperless-ngx"
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
render_paperless_mounts adoption -f "$compose" -f "$adoption_compose"
render_paperless_mounts mac-adoption -f "$compose" -f "$mac_compose" -f "$adoption_compose"

ruby -ryaml - "$compose" "$mac_compose" "$adoption_compose" "$role" "$defaults" \
  "$argument_specs" "$storage_inventory" "$host_prep" "$generator" "$environment_template" "$snapshot" <<'RUBY'
compose_path, mac_path, adoption_path, role_path, defaults_path, argument_specs_path,
  storage_inventory_path, host_prep_path, generator_path, environment_template_path, snapshot_path = ARGV
compose = YAML.safe_load_file(compose_path, aliases: true)
mac = YAML.safe_load_file(mac_path, aliases: true)
adoption = YAML.safe_load_file(adoption_path, aliases: true)
role = YAML.safe_load_file(role_path, aliases: true)
role_text = File.read(role_path)
defaults = YAML.safe_load_file(defaults_path)
argument_specs = YAML.safe_load_file(argument_specs_path)
storage_inventory = YAML.safe_load_file(storage_inventory_path)
host_prep = YAML.safe_load_file(host_prep_path)
generator = File.read(generator_path)
environment_template = File.read(environment_template_path)
snapshot_text = File.read(snapshot_path)

def refuse(message)
  abort "Paperless contract failed: #{message}"
end

services = compose.fetch("services")
expected_images = {
  "broker" => "docker.io/valkey/valkey:9.1.1-alpine@sha256:ee91f7a174ac4d6a6b0685b3a60e321f0a9dbbb691f9b0e285be2ba1d1be8328",
  "db" => "docker.io/library/postgres:18.4-alpine@sha256:9a8afca54e7861fd90fab5fdf4c42477a6b1cb7d293595148e674e0a3181de15",
  "webserver" => "ghcr.io/paperless-ngx/paperless-ngx:3.0.5@sha256:65a4cabf0169ea7fbd90ab7bb28ba3f8b5909613635acda1a03ad606f34b456b",
  "gotenberg" => "docker.io/gotenberg/gotenberg:8.35.0@sha256:a16a14e1f18a71405624bc028e90d4ef50ea774c352b303639c10bf7b141f760",
  "tika" => "docker.io/apache/tika:3.3.1.0@sha256:90b7fa1dc018434075fce9e1d9b88b1e3d0ea6979d0cf86e116c79a8073ae973"
}
refuse("stack composition differs") unless services.keys.sort == expected_images.keys.sort
expected_images.each do |name, image|
  refuse("#{name} legacy image pin differs") unless services.fetch(name).fetch("image") == image
end
services.each do |name, service|
  refuse("#{name} restart policy differs") unless service.fetch("restart") == "unless-stopped"
  refuse("#{name} logging policy differs") unless service.fetch("logging") == {
    "driver" => "json-file", "options" => { "max-size" => "10m", "max-file" => "3" }
  }
end

web = services.fetch("webserver")
refuse("NAS webserver must use host networking") unless web.fetch("network_mode") == "host"
refuse("NAS webserver must not publish ports") if web.key?("ports")
refuse("webserver must wait for healthy Tika") unless
  web.fetch("depends_on").fetch("tika").fetch("condition") == "service_healthy"
refuse("Tika healthcheck is absent") unless services.fetch("tika").key?("healthcheck")
%w[broker db gotenberg tika].each do |name|
  refuse("#{name} must bind only to loopback on the NAS") unless
    services.fetch(name).fetch("ports").all? { |port| port.start_with?("127.0.0.1:") }
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
refuse("Mac webserver must reset NAS host networking") unless
  override_services.fetch("webserver").key?("network_mode") &&
  override_services.fetch("webserver")["network_mode"].nil? &&
  File.read(mac_path).match?(/^\s+network_mode: !reset null$/)
refuse("Mac webserver must publish only its configured port") unless
  override_services.fetch("webserver").fetch("ports") == ["${PAPERLESS_HOST_PORT:?}:8000"]
%w[broker db gotenberg tika].each do |name|
  refuse("Mac #{name} must not publish a port") unless override_services.fetch(name).fetch("ports") == []
end

refuse("mail probe must not inspect global processed-mail or task counts") if
  role_text.match?(%r{/api/(?:processed_mail|tasks)/}) ||
    role.any? { |task| Array(task["loop"]).sort == %w[processed_mail tasks] }

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

probe = role.find { |task| task["name"] == "Test the candidate Paperless Gmail credential before persistence" }
refuse("pinned Paperless 3.0.5 synchronous mail test endpoint differs") unless
  probe&.dig("ansible.builtin.uri", "url") == "{{ paperless_api }}/api/mail_accounts/test/" &&
    probe.dig("ansible.builtin.uri", "method") == "POST" &&
    probe.dig("ansible.builtin.uri", "timeout") == 180 &&
    probe.dig("ansible.builtin.uri", "status_code").to_s.include?("range(100, 600)") &&
    probe["failed_when"] == false
probe_assertion_index = role.index do |task|
  task["name"] == "Require the exact synchronous Paperless Gmail credential response"
end
probe_index = role.index(probe)
account_create_index = role.index do |task|
  task["name"] == "Create the managed Paperless mail account"
end
rule_create_index = role.index do |task|
  task["name"] == "Create the managed Paperless mail rule"
end
refuse("credential response is not required before managed persistence") unless
  probe_index && probe_assertion_index && account_create_index && rule_create_index &&
    probe_index < probe_assertion_index && probe_assertion_index < account_create_index &&
    probe_assertion_index < rule_create_index
probe_assertion = role.fetch(probe_assertion_index).fetch("ansible.builtin.assert")
refuse("credential success signal is not the exact synchronous response") unless
  Array(probe_assertion["that"]).any? do |condition|
    condition.to_s.include?("paperless_candidate_mail_test.json == {'success': true}")
  end
refuse("managed account/rule state is not snapshotted around the credential probe") unless
  role_text.include?("paperless_managed_mail_probe_state_before") &&
    role_text.include?("paperless_managed_mail_probe_state_after") &&
    role_text.include?("paperless_managed_mail_probe_state_before == paperless_managed_mail_probe_state_after")
refuse("managed mail schema is not validated globally before mutation") unless
  role_text.include?("Validate Paperless mail account and rule schemas before mutation")
refuse("Paperless effective state sources do not match the five Compose/env state roots") unless
  role_text.match?(/paperless_effective_state_host_paths:.*?\/postgres.*?\/redis.*?\/data.*?\/cache.*?\/tessdata/m)
storage_layout_index = role.index do |task|
  task["name"] == "Validate canonical Paperless storage source separation"
end
first_storage_mutation_index = role.index do |task|
  task["name"] == "Install the pinned Hebrew OCR model"
end
refuse("canonical Paperless storage separation is not validated before mutation") unless
  storage_layout_index && first_storage_mutation_index && storage_layout_index < first_storage_mutation_index

adoption_web_volumes = adoption.dig("services", "webserver", "volumes") || []
refuse("adoption overlay must replace every Paperless webserver mount") unless
  adoption_web_volumes.any? { |mount| mount.include?(":/usr/src/paperless/cache") }

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
required_tasks.each { |name| refuse("missing #{name}") unless role_text.include?("- name: #{name}") }
refuse("role must never invoke the consuming mail endpoint") if role_text.match?(%r{/mail_accounts/.+/process/})

secret_tasks = role.reject { |task| task.key?("ansible.builtin.assert") }.select do |task|
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
  task = role.find { |candidate| candidate["name"] == name }
  refuse("missing visible Paperless assertion #{name}") unless task
  refuse("Paperless assertion #{name} must keep static failures visible") if task["no_log"] == true
end
refuse("Paperless restore must recover both services from an ensure block") unless
  snapshot_text.match?(/if MODE == "restore".*?begin.*?ensure.*?\["docker", "start", REDIS\].*?\["docker", "start", WEBSERVER\].*?wait_healthy\(REDIS, WEBSERVER\)/m)
admin_create = role.find { |task| task["name"] == "Create the absent vault Paperless administrator" }
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
  "Check for a Paperless platform override",
  "Select the Paperless Compose definitions",
  "Inspect the installed Paperless Gmail credential fingerprint",
  "Read the installed Paperless Gmail credential fingerprint",
  "Resolve the installed Paperless Gmail credential fingerprint",
  "Require the installed Paperless Gmail credential fingerprint",
  "Read the reconciled Paperless mail account",
  "Require complete reconciled Paperless mail account listing",
  "Read the exact reconciled Paperless mail rule",
  "Require complete reconciled Paperless mail rule listing"
].each do |name|
  task = role.find { |candidate| candidate["name"] == name }
  refuse("#{name} must run during tagged Paperless verification") unless
    Array(task && task["tags"]).include?("platform_verify_paperless")
end
fingerprint_assertion = role.find do |task|
  task["name"] == "Require the installed Paperless Gmail credential fingerprint"
end
refuse("Paperless credential fingerprint verification must remain redacted") unless
  fingerprint_assertion && fingerprint_assertion["no_log"] == true
refuse("Paperless credential fingerprint assertion must remain verify-only") unless
  Array(fingerprint_assertion["tags"]).sort == %w[never platform_verify_paperless] &&
    fingerprint_assertion["when"] == "'platform_verify_paperless' in ansible_run_tags"
refuse("Gmail app password must be a visible sentinel in the new-platform generator") unless
  generator.include?("paperless_gmail_app_password: replace-with-google-app-password")
refuse("generator must not synthesize a Gmail app password") if
  generator.match?(/paperless_gmail_app_password:\s*[\"']?\{\{/)
refuse("role must accept Google's grouped app-password display") unless
  role_text.include?("vault_paperless_gmail_app_password | replace(' ', '')")
refuse("host-network endpoint selection must cover NAS and integration") unless
  environment_template.include?("platform_compose_kind in ['nas', 'integration']")
%w[
  vault_paperless_db_password vault_paperless_django_secret_key
  vault_paperless_admin_username vault_paperless_admin_password vault_paperless_admin_email
].each do |variable|
  refuse("#{variable} is not protected from Compose interpolation") unless
    environment_template.include?("#{variable} | replace('$', '$$')")
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
. "${PLATFORM_LEGACY_FIXTURE_HELPER_FILE:-$repo_dir/tests/contracts/legacy-fixture-paths.sh}"
legacy_fixture_validate PLATFORM_PAPERLESS_CONSUME_ROOT legacy/paperless-ngx/consume ||
  fail_contract 'legacy consume root is unsafe'
legacy_fixture_validate PLATFORM_PAPERLESS_EXPORT_ROOT legacy/paperless-ngx/export ||
  fail_contract 'legacy export root is unsafe'

: "${PLATFORM_CONTRACT_VAULT_FILE:=${PLATFORM_MAC_VAULT_FILE:-}}"
: "${PLATFORM_CONTRACT_VAULT_PASSWORD_FILE:=${PLATFORM_MAC_VAULT_PASSWORD_FILE:-}}"
: "${PLATFORM_MEDIA_ROOT:?}"
: "${PLATFORM_REPORT_ROOT:?}"
: "${PLATFORM_PAPERLESS_PORT:=8000}"
: "${PLATFORM_PAPERLESS_WEBSERVER_CONTAINER:=paperless_webserver}"
PLATFORM_CONTRACT_REPO_DIR=$repo_dir
export PLATFORM_CONTRACT_VAULT_FILE PLATFORM_CONTRACT_VAULT_PASSWORD_FILE
export PLATFORM_MEDIA_ROOT PLATFORM_REPORT_ROOT PLATFORM_PAPERLESS_PORT
export PLATFORM_PAPERLESS_WEBSERVER_CONTAINER PLATFORM_CONTRACT_REPO_DIR

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

consume = CONSUME_ROOT
if MODE == "seed"
  write_fixture(consume.join("task-13-contract.pdf"), pdf_bytes("Paperless PDF #{PDF_MARKER}"))
  write_fixture(
    consume.join("task-13-contract.png"),
    REPO_ROOT.join("tests/fixtures/paperless-ocr.png.base64").read.delete("\n").unpack1("m0")
  )
  write_fixture(consume.join("task-13-contract.docx"), docx_bytes(OFFICE_TEXT))
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
