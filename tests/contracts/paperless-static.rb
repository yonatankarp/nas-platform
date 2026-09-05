#!/usr/bin/env ruby
# The static half of the Paperless service contract: every property it can
# decide from the repository alone, with nothing deployed.
#
# usage: ruby -ryaml paperless-static.rb COMPOSE MAC_COMPOSE INTEGRATION_COMPOSE \
#          ROLE DEFAULTS ARGUMENT_SPECS STORAGE_INVENTORY HOST_PREP GENERATOR \
#          ENVIRONMENT_TEMPLATE SNAPSHOT SNAPSHOT_PROGRAM
#
# SNAPSHOT and SNAPSHOT_PROGRAM are the two halves of the coordinated snapshot,
# and both are read: until #315 the Ruby lived in a heredoc inside the shell
# wrapper, so one `snapshot_text` covered everything this file asserts. Splitting
# them and repointing every assertion at the program would have made the one
# assertion that is genuinely the wrapper's -- the recovery deadline's default,
# which is a shell parameter expansion -- a substring search that can no longer
# match, and a positive grep that cannot fail is not a check. So the split is
# spelled out here: the recovery-deadline default is the wrapper's, and the
# ensure-block ordering, the retried flushall, the readiness wait, the deadline
# floor and the drill poll are the program's.
#
# The -ryaml preload is load-bearing: the body calls YAML.safe_load_file
# without requiring yaml itself, exactly as the heredoc it came from did, and
# raises NameError run bare. Every path is a file in the tree being inspected,
# and PLATFORM_CONTRACT_REPO_DIR -- which the require below reads
# tests/policy_support from -- names that same tree, never this checkout.
compose_path, mac_path, integration_path, role_path, defaults_path, argument_specs_path,
  storage_inventory_path, host_prep_path, generator_path, environment_template_path, snapshot_path,
  snapshot_program_path = ARGV
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
snapshot_program_text = File.read(snapshot_program_path)

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
# The two mail object names label objects the platform creates and authorise
# nothing, so they are operator policy in the shared inventory rather than vault
# keys (#353). Asserted at the layer that decides the run -- group_vars outranks
# role defaults -- and required by the role, which carries no default for them.
%w[paperless_mail_account_name paperless_mail_rule_name].each do |name|
  declared = storage_inventory[name]
  refuse("#{name} must be a nonempty operator declaration in the shared inventory") unless
    declared.is_a?(String) && !declared.empty?
  refuse("#{name} must be a required role argument") unless
    argument_options.dig(name, "type") == "str" && argument_options.dig(name, "required") == true
  refuse("#{name} must not be reintroduced as a vault credential") if
    generator_vars.key?(name) || argument_options.key?("vault_#{name}")
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

# The names below are what a task has to mention to be secret-bearing. The
# `vault_paperless_` prefix carries most of them, but not the facts derived from
# a mail-account listing: a Paperless mail account object carries `username`,
# which is the vault Gmail address, and since #353 the name those facts are
# selected by is inventory policy rather than a vault key. Naming them here is
# what keeps their redaction enforced rather than merely present.
secret_tasks = role_tasks.reject { |task| task.key?("ansible.builtin.assert") }.select do |task|
  task.to_s.match?(/vault_paperless_|paperless_api_token|paperless_mail_account_payload|paperless_mail_accounts_|paperless_managed_mail_accounts|paperless_existing_mail_account|paperless_reconciled_mail_account|paperless_managed_mail_probe_state/)
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
  snapshot_program_text.match?(/if MODE == "restore".*?begin.*?ensure.*?\["docker", "start", REDIS\].*?\["docker", "start", WEBSERVER\].*?wait_healthy\(REDIS, WEBSERVER\)/m)
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
  snapshot_program_text.include?('[["docker", "exec", REDIS, "valkey-cli", "flushall"], :until_ready]')
readiness_wait = snapshot_program_text[/^def capture_until_ready\b.*?^end$/m].to_s
refuse("Paperless recovery readiness wait is absent") if readiness_wait.empty?
refuse("Paperless recovery readiness wait must be bounded and must not die") unless
  readiness_wait.include?("limit = Time.now + deadline") &&
    readiness_wait.include?("return [stdout, stderr, status] if status.success? || Time.now >= limit") &&
    !readiness_wait.include?("die")
refuse("Paperless recovery deadline must not be configurable down to no retry") unless
  snapshot_program_text.match?(
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
drill_mutation = snapshot_program_text.scan(/^if MODE == "drill"\n.*?^end$/m).find do |block|
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
