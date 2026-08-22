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

ROOT = File.expand_path("..", __dir__)
failures = []

def check(failures, condition, message)
  failures << message unless condition
end

# The expected key set is assembled from the roster's pinned per-service files.
# Problems with that data are reported here as well as by policy_services_test.rb,
# because a script that silently proceeds on an empty expectation would report a
# vault missing every key rather than the file that failed to load.
SERVICE_EXPECTATIONS, expectation_problems = pinned_service_expectations(ROOT)
expectation_problems.each { |problem| check(failures, false, problem) }
EXPECTED_VAULT_KEYS = pinned_vault_keys(SERVICE_EXPECTATIONS)

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
example.each do |key, value|
  next unless value.is_a?(String)
  next if key == "vault_jellyfin_admin_username" && value == "Yonatan"
  next if value.match?(/^example[-_]/) || value.end_with?("@example.invalid")
  next if value.match?(/^\$2b\$12\$0{53}$/)
  next if value.match?(/^tk_[01]{29}$/)
  next if value == "ssh-ed25519 AAAA"
  next if value == "00000000-0000-4000-a000-000000000000"
  next if value.include?("example-only-not-a-real-private-key")

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
# A key is inspected either by a condition or by a set_fact expression, because
# the structured keys are validated by a filter that returns a list of violations
# rather than by one Jinja condition per field. For the scalar credentials this
# stays a real guard: deleting vault_tinymediamanager_password's condition fails
# here, and mutation-checked as such. For vault_managed_users it is only a
# presence check, since the pass-through facts in "Resolve validated managed-user
# service lists" name it too. That key's real pin is
# tests/managed_users_vault_test.rb, which requires the schema filter by name and
# runs some fifty rejection cases through the role; replacing the filter call
# with a literal passes here and fails forty checks there.
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
vault_contract_index = site_pre_tasks.index do |task|
  task.dig("ansible.builtin.include_role", "name") == "vault_contract"
end
first_mutation_guard = site_pre_tasks.index do |task|
  task.dig("ansible.builtin.include_role", "name") == "deployment_bundle"
end
check(failures, vault_contract_index == 0 && first_mutation_guard && vault_contract_index < first_mutation_guard,
      "site.yml must validate the vault contract before every target pre-task")
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

ci_body = File.read(File.join(ROOT, ".github", "workflows", "ci.yml"))
check(failures,
      ci_body.include?("tests/generate-ephemeral-vault.sh --self-test") &&
        ci_body.include?("test ! -s") &&
        %w[apache2-utils openssh-client openssl].all? { |dependency| ci_body.include?(dependency) },
      "CI must run the silent ephemeral vault self-test with explicit dependencies")
check(failures, ci_body.include?("tests/generate-secrets-redaction-test.sh"),
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


if failures.empty?
  puts "vault policy: all properties hold"
else
  failures.each { |failure| warn "FAIL #{failure}" }
  abort "#{failures.length} vault policy violation(s)"
end
