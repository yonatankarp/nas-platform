#!/usr/bin/env ruby
# Vault contract policy.
#
# The documented example, the generator's template, the vault_contract role and
# the ephemeral test helper must all agree on one key set, the ordering that puts
# validation before the first mutation must hold, and no secret may reach the
# repository. Split out of policy_test.rb: these checks all police the same
# artifact and change together.

require "open3"
require "rbconfig"
require "set"
require "yaml"
require_relative "policy_support"

include PolicySupport
include TestScaffold

failures = []

manifest_path = File.join(ROOT, "services", "manifest.yml")
manifest = begin
  stream = Psych.parse_stream(File.read(manifest_path))
  check(failures, stream.children.length == 1,
        "service manifest must contain exactly one YAML document")
  duplicate_yaml_keys(stream).uniq.each do |key|
    check(failures, false, "service manifest contains duplicate mapping key #{key}")
  end
  YAML.safe_load_file(manifest_path)
rescue Errno::ENOENT
  check(failures, false, "service manifest is missing: services/manifest.yml")
  {}
rescue Psych::Exception => e
  check(failures, false, "service manifest is malformed: #{e.message.lines.first.strip}")
  {}
end
manifest_entries = manifest.is_a?(Hash) && manifest["services"].is_a?(Array) ? manifest["services"] : []
manifest_names = manifest_entries.filter_map { |entry| entry["name"] if entry.is_a?(Hash) }
duplicates = manifest_names.tally.select { |_name, count| count > 1 }.keys
check(failures, duplicates.empty?,
      "service manifest name values must be unique: #{duplicates.join(', ')}")
service_statuses = if manifest.is_a?(Hash) && manifest["services"].is_a?(Array) &&
                      manifest_entries.all? do |entry|
                        entry.is_a?(Hash) && entry.key?("name") && entry.key?("status")
                      end
                     manifest.fetch("services").to_h do |entry|
                       [entry.fetch("name"), entry.fetch("status")]
                     end
                   else
                     {}
                   end

# The expected key set is assembled from status-aware pinned per-service files.
SERVICE_EXPECTATIONS, expectation_problems =
  pinned_service_expectations(ROOT, service_statuses)
expectation_problems.each { |problem| check(failures, false, problem) }
EXPECTED_VAULT_KEYS = pinned_vault_keys(SERVICE_EXPECTATIONS)

FOUNDATION_KEYS = %w[
  vault_arr_radarr_api_key
  vault_arr_radarr_admin_username
  vault_arr_radarr_admin_password
  vault_arr_sonarr_api_key
  vault_arr_sonarr_admin_username
  vault_arr_sonarr_admin_password
  vault_arr_prowlarr_api_key
  vault_arr_prowlarr_admin_username
  vault_arr_prowlarr_admin_password
  vault_arr_bazarr_api_key
  vault_arr_bazarr_admin_username
  vault_arr_bazarr_admin_password
  vault_downloaders_sabnzbd_api_key
  vault_downloaders_sabnzbd_admin_username
  vault_downloaders_sabnzbd_admin_password
].freeze

actual_foundation_expectations =
  SERVICE_EXPECTATIONS.fetch("arr").fetch("vault_keys") +
  SERVICE_EXPECTATIONS.fetch("downloaders").fetch("vault_keys")
check(failures, actual_foundation_expectations == FOUNDATION_KEYS,
      "arr and downloaders expectations must carry the exact ordered foundation key set")

site_play = YAML.safe_load_file(File.join(ROOT, "site.yml")).first

# Compose interpolates $ in env files and silently truncates an unescaped bcrypt
# hash rather than rejecting it, so escaping is mandatory wherever hashes flow.
Dir[File.join(ROOT, "roles", "*", "templates", "env.j2")].each do |template|
  body = File.read(template)
  next unless body.include?("password_hash") || body.include?("AUTH_USERS")

  check(failures, body.include?("replace('$', '$$')"),
        "#{template}: bcrypt values must escape $ as $$ for Compose")
end

# The vault example is the documented contract; drift means an operator follows it
# and ends up with a vault missing keys the roles require.
example_path = File.join(ROOT, "inventory", "group_vars", "all", "vault.yml.example")
example = YAML.safe_load_file(example_path)
foundation_example = FOUNDATION_KEYS.to_h do |key|
  value = if key.end_with?("_api_key")
            (FOUNDATION_KEYS.index(key) / 3).to_s * 32
          elsif key.end_with?("_admin_username")
            "nasadmin"
          else
            service = key[/vault_(?:arr_)?(?:downloaders_)?([^_]+)_admin_password/, 1]
            "example-#{service}-password"
          end
  [key, value]
end
check(failures, foundation_example.all? { |key, value| example[key] == value },
      "vault example must use the exact sanitized foundation values")
example.each do |key, value|
  next unless value.is_a?(String)
  next if key == "vault_jellyfin_admin_username" && value == "Yonatan"
  next if value.match?(/^example[-_]/) || value.end_with?("@example.invalid")
  next if value.match?(/^\$2b\$12\$0{53}$/)
  next if value.match?(/^tk_[01]{29}$/)
  next if value == "ssh-ed25519 AAAA"
  next if value == "00000000-0000-4000-a000-000000000000"
  # Bindery's key is contracted to be 32 lowercase hexadecimal characters, so it
  # cannot carry an `example-` placeholder the way an opaque string can. It
  # continues the repeated-digit series the five foundation API keys use, one
  # digit past SABnzbd's, which keeps it obviously sanitized and keeps an
  # operator who copies the file from deploying the same stand-in twice.
  next if key == "vault_bindery_api_key" && value == "5" * 32
  next if value.include?("example-only-not-a-real-private-key")
  next if foundation_example[key] == value

  check(failures, false, "#{example_path}: #{key} looks like a real value, not a placeholder")
end

# The example documents what vault must contain; the generator's template is what
# actually gets written. Drift means an operator follows the example and ends up
# with a vault missing keys the roles require, failing late and confusingly.
def vault_keys(path)
  return [] unless File.file?(path)

  File.readlines(path).filter_map { |line| line[/^\s*(vault_[a-z_]+):/, 1] }.sort
end

vault_contract_sources = {
  "vault.yml.example" => example_path,
  "vault-plain.yml.j2" => File.join(ROOT, "templates", "vault-plain.yml.j2"),
  "vault_contract argument specs" =>
    File.join(ROOT, "roles", "vault_contract", "meta", "argument_specs.yml"),
  "ephemeral vault generator" => File.join(ROOT, "tests", "generate-ephemeral-vault.sh")
}
vault_contract_sources.each do |label, path|
  keys = vault_keys(path)
  duplicate_keys = keys.tally.select { |_key, count| count > 1 }.keys
  check(failures, duplicate_keys.empty?,
        "#{label} contains duplicate vault keys: #{duplicate_keys.join(', ')}")
  (EXPECTED_VAULT_KEYS - keys.uniq).each do |key|
    check(failures, false, "#{label} is missing required portable credential #{key}")
  end
  (keys.uniq - EXPECTED_VAULT_KEYS).each do |key|
    check(failures, false, "#{label} has unexpected or non-portable vault key #{key}")
  end
end

foundation_parity_sources = vault_contract_sources.merge(
  "credential rules" => File.join(ROOT, "filter_plugins", "vault_credential_schema.py"),
  "vault contract mapping" => File.join(ROOT, "roles", "vault_contract", "tasks", "main.yml"),
  "secret generator" => File.join(ROOT, "generate-secrets.yml")
)
foundation_parity_sources.each do |label, path|
  body = File.read(path)
  positions = FOUNDATION_KEYS.map do |key|
    generator_key = key.delete_prefix("vault_")
    body.index(key) || (label == "secret generator" ? body.index(generator_key) : nil)
  end
  FOUNDATION_KEYS.zip(positions).each do |key, position|
    check(failures, !position.nil?, "#{label} is missing foundation credential #{key}")
  end
  check(failures,
        positions.none?(&:nil?) && positions.each_cons(2).all? { |left, right| left < right },
        "#{label} must carry foundation credentials in contract order")
end

check(failures, vault_contract_sources.values.map { |path| vault_keys(path) }.uniq.length == 1,
      "vault example, template, validation role, and ephemeral generator must have exact schema parity")

vault_contract_spec_path = vault_contract_sources.fetch("vault_contract argument specs")
vault_contract_options = if File.file?(vault_contract_spec_path)
                           YAML.safe_load_file(vault_contract_spec_path)
                               .dig("argument_specs", "main", "options") || {}
                         else
                           {}
                         end
EXPECTED_VAULT_KEYS.each do |key|
  option = vault_contract_options[key]
  check(failures, option.is_a?(Hash) && option["required"] == true,
        "vault contract must require #{key}")
end

vault_contract_tasks_path = File.join(ROOT, "roles", "vault_contract", "tasks", "main.yml")
vault_contract_tasks = File.file?(vault_contract_tasks_path) ?
  YAML.safe_load_file(vault_contract_tasks_path) : []
check(failures, !vault_contract_tasks.empty? && vault_contract_tasks.all? { |task| task["no_log"] == true },
      "every vault contract task must use no_log")
# A key is inspected by a set_fact expression rather than by a Jinja condition,
# because both the structured keys and the scalar credentials are validated by
# filters that return a list of violations. For the scalar credentials this stays
# a real guard: the role passes them to the filter as a mapping of variable name
# to value, so deleting a scalar entry stops it being inspected. For
# vault_managed_users it is only a presence check, since the pass-through facts in
# "Resolve validated managed-user service lists" name it too. That key's real pin
# is tests/managed_users_vault_test.rb, which requires the schema filter by name
# and runs some fifty rejection cases through the role; replacing the filter call
# with a literal passes here and fails forty checks there. The scalar credentials
# have the same backstop in that file, which runs the role over a vault whose
# OpenSubtitles values are still the documented placeholders.
shape_conditions = vault_contract_tasks.flat_map do |task|
  Array(task.dig("ansible.builtin.assert", "that")) +
    Array(task["ansible.builtin.set_fact"]&.values)
end.join(" ")
EXPECTED_VAULT_KEYS.each do |key|
  check(failures, shape_conditions.match?(/\b#{Regexp.escape(key)}\b/),
        "vault contract shape validation must inspect #{key}")
end
check(failures, vault_contract_tasks.none? { |task| task.to_s.match?(/vault_[a-z_]+\s*\|\s*hash/) },
      "vault contract must never hash an individual plaintext credential")

vault_metadata_index = vault_contract_tasks.index do |task|
  task["name"] == "Inspect the candidate vault artifact without hashing"
end
vault_header_index = vault_contract_tasks.index do |task|
  task["name"] == "Read only the encrypted vault format header"
end
vault_encryption_guard_index = vault_contract_tasks.index do |task|
  task["name"] == "Require the reported vault artifact to be encrypted"
end
vault_checksum_index = vault_contract_tasks.index do |task|
  task["name"] == "Compute the encrypted vault artifact SHA-256"
end
vault_metadata_task = vault_metadata_index && vault_contract_tasks[vault_metadata_index]
vault_order_indexes = [
  vault_metadata_index,
  vault_header_index,
  vault_encryption_guard_index,
  vault_checksum_index
]
check(failures,
      vault_metadata_task&.dig("ansible.builtin.stat", "get_checksum") == false &&
        vault_order_indexes.all? { |index| index.is_a?(Integer) } &&
        vault_order_indexes.each_cons(2).all? { |left, right| left < right },
      "vault contract must verify encryption header before computing SHA-256")

site_pre_tasks = Array(site_play["pre_tasks"])
target_dependency_index = site_pre_tasks.index do |task|
  task.dig("ansible.builtin.include_role", "name") == "preflight" &&
    task.dig("ansible.builtin.include_role", "tasks_from") == "target_docker_dependencies"
end
vault_contract_index = site_pre_tasks.index do |task|
  task.dig("ansible.builtin.include_role", "name") == "vault_contract"
end
first_mutation_guard = site_pre_tasks.index do |task|
  task.dig("ansible.builtin.include_role", "name") == "deployment_bundle"
end
check(failures,
      target_dependency_index == 0 && vault_contract_index == 1 &&
        first_mutation_guard && vault_contract_index < first_mutation_guard,
      "site.yml must validate target dependencies, then the vault contract, before mutation")
site_vault_contract = vault_contract_index && site_pre_tasks[vault_contract_index]
check(failures, site_vault_contract&.dig("ansible.builtin.include_role", "apply", "no_log") == true,
      "site.yml must redact vault role argument validation")

validate_vault_play = if File.file?(File.join(ROOT, "validate-vault.yml"))
                        YAML.safe_load_file(File.join(ROOT, "validate-vault.yml")).first
                      else
                        {}
                      end
validate_vault_role = Array(validate_vault_play["roles"]).find do |role|
  role.is_a?(Hash) && role["role"] == "vault_contract"
end
check(failures, validate_vault_role && validate_vault_role["no_log"] == true,
      "validate-vault.yml must redact vault role argument validation")

secret_generator_path = File.join(ROOT, "generate-secrets.yml")
secret_generator = YAML.safe_load_file(secret_generator_path).first
check(failures, secret_generator.dig("vars", "generate_brand_new_platform") == false,
      "generate-secrets.yml must default brand-new-platform confirmation to false")
brand_new_guard = Array(secret_generator["tasks"]).find do |task|
  task["name"] == "Require explicit confirmation of a brand-new platform"
end
guard_conditions = Array(brand_new_guard&.dig("ansible.builtin.assert", "that")).join(" ")
guard_message = brand_new_guard&.dig("ansible.builtin.assert", "fail_msg").to_s
check(failures, guard_conditions.include?("generate_brand_new_platform | bool") &&
                guard_message.include?("password manager") &&
                guard_message.include?("deployed"),
      "generate-secrets.yml must refuse recovery credential generation explicitly")

secret_generator_tasks = Array(secret_generator["tasks"]).to_h { |task| [task["name"], task] }
secret_bearing_generator_tasks = [
  "Generate passwords",
  "Read the Beszel hub keypair",
  "Hash the ntfy passwords with ntfy's own hasher",
  "Generate the ntfy access tokens with ntfy's own generator",
  "Collect the generated material",
  "Fail loudly if any value did not parse",
  "Write the plaintext vars file for encryption"
]
secret_bearing_generator_tasks.each do |task_name|
  check(failures, secret_generator_tasks.dig(task_name, "no_log") == true,
        "generate-secrets.yml must redact secret-bearing task #{task_name}")
end

# The workflow is read as the scripts its steps run. A command named in a step's
# comment, or in a step whose `if:` never fires, is not a command CI executes,
# and the whole-file substring could not tell those from a real `run:`.
ci_workflow = YAML.safe_load_file(File.join(ROOT, ".github", "workflows", "ci.yml"), aliases: true)
ci_run_scripts = Array(ci_workflow["jobs"]).flat_map do |_name, job|
  Array(job.is_a?(Hash) ? job["steps"] : nil).filter_map do |step|
    step["run"].to_s if step.is_a?(Hash) && step.key?("run")
  end
end
ci_commands = ci_run_scripts.flat_map { |script| script.lines.map(&:strip) }
                            .reject { |line| line.empty? || line.start_with?("#") }
check(failures,
      ci_commands.any? { |line| line.include?("tests/generate-ephemeral-vault.sh --self-test") } &&
        ci_commands.any? { |line| line.include?("test ! -s") } &&
        %w[apache2-utils openssh-client openssl].all? do |dependency|
          ci_commands.any? { |line| line.include?(dependency) }
        end,
      "CI must run the silent ephemeral vault self-test with explicit dependencies")
check(failures, ci_commands.any? { |line| line.include?("tests/generate-secrets-redaction-test.sh") },
      "CI must execute the generated-secret redaction test")

ephemeral_helper = File.read(File.join(ROOT, "tests", "generate-ephemeral-vault.sh"))
helper_safety_evidence = {
  "pre-existing output refusal" => "self-test generation accepted a pre-existing output",
  "vault leaf symlink refusal" => "self-test generation accepted a vault output symlink",
  "password leaf symlink refusal" => "self-test generation accepted a password output symlink",
  "unexpected entry refusal" => "self-test generation accepted an unexpected entry",
  "in-repository refusal" => "self-test generation accepted an in-repository directory",
  "TMPDIR symlink refusal" => "self-test accepted a symlink temporary parent",
  "trailing-slash symlink refusal" => "self-test cleanup accepted a trailing-slash symlink alias",
  "lexical alias refusal" => "self-test cleanup accepted a non-normalized lexical alias",
  "trailing-slash TMPDIR refusal" => "self-test accepted a trailing-slash symlink temporary parent",
  "unsafe mode refusal" => "self-test generation accepted a world-writable directory",
  "ownership refusal" => "self-test generation accepted a foreign-owned directory",
  "failure cleanup" => "self-test failed generation left credential material",
  "mid-validation cleanup" => "self-test mid-validation failure left credential material"
}
helper_safety_evidence.each do |property, evidence|
  check(failures, ephemeral_helper.include?(evidence),
        "ephemeral vault self-test must cover #{property}")
end
helper_guard_sources = {
  "requested-path lexical guard" => 'validate_lexical_path "$requested"',
  "temporary-parent lexical guard" => 'validate_lexical_path "$temporary_parent_input"',
  "temporary-parent symlink guard" => '[ ! -L "$temporary_parent_input" ]',
  "directory symlink guard" => '[ ! -L "$requested" ]',
  "directory ownership guard" => '[ "$(owner_id "$physical")" = "$(id -u)" ]',
  "directory mode guard" => '[ "$(file_mode "$physical")" = 700 ]',
  "repository containment guard" => '"$repo_dir/"*) die',
  "output overwrite and symlink guard" => '[ ! -e "$candidate" ] && [ ! -L "$candidate" ]',
  "empty-directory guard" => '[ -z "$(find "$directory" -mindepth 1 -maxdepth 1 -print -quit)" ]',
  "cleanup unexpected-entry guard" => '! -name vault.yml ! -name password -print -quit',
  "cleanup leaf-symlink guard" => '[ ! -L "$directory/vault.yml" ] && [ ! -L "$directory/password" ]',
  "failure trap isolation" => "generate_vault() (",
  "failure cleanup trap" => 'trap \'rm -f -- "$plain" "$private_key" "$private_key.pub" "$password_file" "$output"\' EXIT',
  "self-test cleanup trap" => "trap self_test_cleanup_on_exit EXIT"
}
helper_guard_sources.each do |property, source|
  check(failures, ephemeral_helper.include?(source),
        "ephemeral vault helper must preserve #{property}")
end
check(failures,
      ephemeral_helper.include?('kernel_name=$(uname -s)') &&
        ephemeral_helper.include?('stat -f') && ephemeral_helper.include?('stat -c') &&
        ephemeral_helper.include?("refusing symlink temporary parent"),
      "ephemeral vault helper must preserve GNU/BSD checks and refuse TMPDIR symlinks")

# Redaction is only for credentials, in both directions.
#
# `no_log` on a task replaces its whole result with "censored", so applying it
# where no credential can appear costs a failed converge its diagnosis and buys
# nothing. Applying it where one can appear is mandatory. Both directions are
# checked here, against what ansible-core 2.21 actually renders, measured rather
# than assumed:
#
#   * a module result renders its arguments, so a credential in a `uri` url,
#     header or body, or in a rendered file, reaches the log;
#   * `assert` renders only the *source text* of the failing condition plus its
#     rendered `fail_msg`/`success_msg`. `that: [x == vault_y]` prints
#     "x == vault_y", never the value, so only the messages can leak;
#   * `debug` renders only `msg`/`var`, and cannot fail;
#   * a looped task that *fails* prints `item` in full, and `loop_control.label`
#     does not suppress it, so a credential-bearing loop needs redaction on
#     anything that can fail;
#   * `when`, `changed_when`, `failed_when` and `until` are conditions: a skip
#     prints their source text, never their values.
#
# Credentials are the `vault_` namespace plus the three acquisition declarations
# that docs/media-acquisition-phase1.md authors in the vault under their own
# names.
REDACTION_CREDENTIAL_NAMES = %w[
  media_arr_indexers
  media_bazarr_providers
  media_bazarr_languages
].freeze

# Keys that are the task's control flow rather than the module's arguments.
REDACTION_CONTROL_KEYS = %w[
  name tags when register no_log block rescue always loop loop_control with_items
  with_dict with_subelements with_nested with_together changed_when failed_when
  until retries delay check_mode ignore_errors vars notify listen become
  become_user delegate_to run_once any_errors_fatal environment args
].freeze

# Modules that render less than their whole argument set.
REDACTION_RENDERED_ARGUMENTS = {
  "ansible.builtin.assert" => %w[fail_msg success_msg msg],
  "ansible.builtin.debug" => %w[msg var],
  "ansible.builtin.fail" => %w[msg]
}.freeze

# Includes render nothing themselves; their `apply` carries redaction inward.
REDACTION_TRANSPARENT_MODULES = %w[
  ansible.builtin.include_role ansible.builtin.include_tasks
  ansible.builtin.import_role ansible.builtin.import_tasks
].freeze

# Two asserts name a credential in a message on purpose. Pinned rather than
# excused by a weaker rule, and asserted to be exactly this pair below, so an
# entry that stops being needed fails here instead of quietly widening the rule.
REDACTION_MESSAGE_EXCEPTIONS = {
  ["roles/beszel/tasks/main.yml",
   "Verify the advertised key matches vault, proving no read-back is needed"] =>
    "prints the public half of the agent keypair so the operator can compare it",
  ["roles/beszel/tasks/main.yml",
   "Refuse duplicate managed application users after reconciliation"] =>
    "names the vault email inside a filter chain that emits only record IDs"
}.freeze

# Assertions that stay redacted although they can render nothing. Each is held
# there by a dedicated behaviour or contract test that treats the whole
# credential path it guards as private, which is a reviewed per-task decision
# rather than a consequence of this rule. Pinned by name with the test that
# holds them, and asserted to still exist below, so retiring one of those tests
# surfaces the redaction rather than leaving it unexplained.
REDACTION_ASSERTION_EXCEPTIONS = {
  ["roles/arr/tasks/verify.yml", "Verify Configarr complete owned state"] =>
    "tests/media_acquisition_reconciliation_core_test.rb",
  ["roles/arr/tasks/verify.yml", "Verify Bazarr authentication and identical-path connections"] =>
    "tests/media_acquisition_reconciliation_core_test.rb",
  ["roles/downloaders/tasks/verify.yml",
   "Require current opaque Servarr desired-input fingerprint in verify-only runs"] =>
    "tests/media_acquisition_reconciliation_core_test.rb",
  ["roles/downloaders/tasks/verify.yml", "Verify SABnzbd owned settings and category paths"] =>
    "tests/media_acquisition_reconciliation_core_test.rb",
  ["roles/immich/tasks/configured_password.yml", "Require unique desired configured Immich identities"] =>
    "tests/contracts/immich.sh",
  ["roles/immich/tasks/configured_password.yml",
   "Require a complete configured-password Immich user listing"] => "tests/contracts/immich.sh",
  ["roles/immich/tasks/configured_password.yml",
   "Require unique configured-password Immich target identifiers"] => "tests/contracts/immich.sh",
  ["roles/immich/tasks/configured_password.yml",
   "Require a complete authoritative configured-password user listing"] => "tests/contracts/immich.sh",
  ["roles/immich/tasks/configured_password.yml",
   "Require unique authoritative configured-password target identifiers"] => "tests/contracts/immich.sh",
  ["roles/paperless_ngx/tasks/main.yml", "Require the installed Paperless Gmail credential fingerprint"] =>
    "tests/contracts/paperless.sh",
  ["roles/arr/tasks/reconciliation_fingerprints.yml",
   "Validate the selected Arr desired-input fingerprint subset"] =>
    "tests/media_acquisition_reconciliation_core_test.rb",
  ["roles/arr/tasks/record_reconciliation_fingerprints.yml",
   "Validate the recorded Arr reconciliation hash subset"] =>
    "tests/media_acquisition_reconciliation_core_test.rb"
}.freeze

def redaction_credential?(node)
  text = node.to_s
  text.match?(/\bvault_[a-z0-9_]+\b/) ||
    REDACTION_CREDENTIAL_NAMES.any? { |name| text.include?(name) }
end

# Redaction is the literal `true` and nothing else. A templated value such as
# `no_log: "{{ some_flag | default(true) }}"` reads as redaction but is one
# `-e some_flag=false` away from printing every credential the task carries, and
# the run that would do it is the one whose output is kept the longest. Anything
# other than `true` therefore does not declare redaction here, and the check
# below names it rather than letting it pass as one.
def redaction_declared?(value)
  value == true
end

def redaction_walk(tasks, relative, redacted, collected)
  Array(tasks).each do |task|
    next unless task.is_a?(Hash)

    inherited = redacted || redaction_declared?(task["no_log"])
    collected << [relative, task, inherited]
    %w[block rescue always].each do |section|
      redaction_walk(task[section], relative, inherited, collected)
    end
  end
  collected
end

# Whatever key is left once the control flow is removed is the module, dotted
# collection name or bare custom module from library/ alike.
def redaction_module(task)
  (task.keys - REDACTION_CONTROL_KEYS).first
end

def redaction_loop(task)
  (task["loop"] || task["with_items"] || task["with_dict"] || task["with_subelements"] ||
   task["with_nested"] || task["with_together"]).to_s
end

redaction_sources = (Dir[File.join(ROOT, "roles", "**", "{tasks,handlers}", "*.yml")].sort +
                     [File.join(ROOT, "site.yml"), File.join(ROOT, "verify.yml")])
redaction_tasks = []
redaction_sources.each do |path|
  relative = path.delete_prefix("#{ROOT}/")
  document = begin
    YAML.safe_load_file(path, aliases: true)
  rescue Psych::Exception
    check(failures, false, "#{relative} is malformed YAML")
    nil
  end
  next unless document.is_a?(Array)

  if document.first.is_a?(Hash) && document.first.key?("hosts")
    document.each do |play|
      next unless play.is_a?(Hash)

      %w[pre_tasks tasks post_tasks handlers].each do |section|
        redaction_walk(play[section], relative, false, redaction_tasks)
      end
    end
  else
    redaction_walk(document, relative, false, redaction_tasks)
  end
end
# The mutation harness copies a curated subset of role files into its sandbox and
# rewrites some of the ones it does copy, so this cannot assert a full-tree
# count; it only catches a glob that matches nothing at all. The two
# "must all still exist" checks below are skipped on such a tree for the same
# reason: they say nothing about a role file that was never copied or was
# replaced by a fixture stub. Both are redundant as leak guards anyway — renaming
# a pinned task also trips the rule that exempted it — so skipping them costs
# only the detection of an entry left behind by a deleted task.
check(failures, !redaction_tasks.empty?,
      "redaction policy found no tasks to inspect; the source glob is wrong")

# `no_log` is a decision taken in the repository, not an input to the run.
# `true` redacts and `false` is a reviewed, explicit exposure; a template is
# neither, because whoever runs the play chooses which one it means.
templated_redactions = redaction_tasks.filter_map do |relative, task, _redacted|
  "#{relative}: #{task['name']}" unless [true, false, nil].include?(task["no_log"])
end
check(failures, templated_redactions.empty?,
      "no_log must be a literal true or false, never a runtime opt-out: " \
      "#{templated_redactions.join('; ')}")
redaction_pinned_files =
  (REDACTION_MESSAGE_EXCEPTIONS.keys + REDACTION_ASSERTION_EXCEPTIONS.keys).map(&:first).uniq
redaction_whole_tree = redaction_pinned_files.all? do |relative|
  File.file?(File.join(ROOT, relative))
end

unredacted_credentials = []
redaction_tasks.each do |relative, task, redacted|
  next if redacted

  module_name = redaction_module(task)
  next if module_name.nil? || REDACTION_TRANSPARENT_MODULES.include?(module_name)

  arguments = task[module_name]
  rendered = if REDACTION_RENDERED_ARGUMENTS.key?(module_name) && arguments.is_a?(Hash)
               REDACTION_RENDERED_ARGUMENTS.fetch(module_name).filter_map { |key| arguments[key] }
             else
               [arguments]
             end
  # A failed iteration prints `item`; `debug` has no failing iteration.
  looped_credential = module_name != "ansible.builtin.debug" &&
                      redaction_credential?(redaction_loop(task))
  next unless rendered.any? { |value| redaction_credential?(value) } || looped_credential
  next if REDACTION_MESSAGE_EXCEPTIONS.key?([relative, task["name"]])

  unredacted_credentials << "#{relative}: #{task['name']}"
end
check(failures, unredacted_credentials.empty?,
      "tasks that render a credential must set no_log: " \
      "#{unredacted_credentials.join('; ')}")

if redaction_whole_tree
  pinned_exceptions = REDACTION_MESSAGE_EXCEPTIONS.keys.to_set
  observed_exceptions = redaction_tasks.filter_map do |relative, task, _redacted|
    [relative, task["name"]] if pinned_exceptions.include?([relative, task["name"]])
  end.to_set
  check(failures, observed_exceptions == pinned_exceptions,
        "pinned redaction exceptions must all still exist: " \
        "#{(pinned_exceptions - observed_exceptions).map { |entry| entry.join(': ') }.join('; ')}")
end

# The other direction. An unlooped `assert` that names no credential anywhere
# renders nothing but its own source text, so redacting it only hides which of
# its conditions failed. roles/vault_contract is exempt: the check earlier in
# this file requires every task there to be redacted regardless.
overredacted_assertions = redaction_tasks.filter_map do |relative, task, _redacted|
  next unless redaction_declared?(task["no_log"])
  next if relative.start_with?("roles/vault_contract/")
  next unless redaction_module(task) == "ansible.builtin.assert"
  next unless redaction_loop(task).empty?
  next if redaction_credential?(task)
  next if REDACTION_ASSERTION_EXCEPTIONS.key?([relative, task["name"]])

  "#{relative}: #{task['name']}"
end
check(failures, overredacted_assertions.empty?,
      "assertions that can render no credential must not set no_log: " \
      "#{overredacted_assertions.join('; ')}")

if redaction_whole_tree
  pinned_assertions = REDACTION_ASSERTION_EXCEPTIONS.keys.to_set
  observed_assertions = redaction_tasks.filter_map do |relative, task, _redacted|
    [relative, task["name"]] if pinned_assertions.include?([relative, task["name"]])
  end.to_set
  check(failures, observed_assertions == pinned_assertions,
        "pinned redacted assertions must all still exist: " \
        "#{(pinned_assertions - observed_assertions).map { |entry| entry.join(': ') }.join('; ')}")
end

repository_vault_nas_references = Dir[File.join(ROOT, "{inventory,roles,templates,tests}", "**", "*")]
                                  .select { |path| File.file?(path) }
                                  .filter_map do |path|
  relative = path.delete_prefix("#{ROOT}/")
  next if %w[tests/policy_test.rb tests/policy_manifest_test.rb].include?(relative)

  relative if File.binread(path).match?(/\bvault_nas_[a-z_]+\b/n)
end
check(failures, repository_vault_nas_references.empty?,
      "NAS connection coordinates must stay in inventory, not shared vault: " \
      "#{repository_vault_nas_references.join(', ')}")

vault_path = File.join(ROOT, "inventory", "group_vars", "all", "vault.yml")
if File.file?(vault_path)
  first = File.open(vault_path, &:readline).strip
  check(failures, first.start_with?("$ANSIBLE_VAULT;"), "vault.yml is present but not encrypted")
end


report(failures, "vault policy: all properties hold", "vault policy violation(s)")
