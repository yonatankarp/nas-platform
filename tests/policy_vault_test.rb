#!/usr/bin/env ruby
# Vault contract policy.
#
# The documented example, the generator's template, the vault_contract role and
# the ephemeral test helper must all agree on one key set, the ordering that puts
# validation before the first mutation must hold, and no secret may reach the
# repository. Split out of policy_test.rb: these checks all police the same
# artifact and change together.

require "digest"
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

# The Usenet provider account is the one credential group in the acquisition path
# that no generator can mint: it belongs to a third-party subscription, so
# generate-secrets.yml writes documented stand-ins for the operator to replace
# rather than values. That is why it is pinned apart from FOUNDATION_KEYS instead
# of appended to it -- the foundation parity below asserts every foundation key
# reaches the secret generator, and a key the generator cannot produce would have
# to be faked there to pass.
#
# Two keys rather than six since #298: the host, port, connection count and TLS
# flag are not credentials and are operator policy in inventory, validated by
# POLICY_PROVIDER_SHAPE below rather than by the credential contract.
OPERATOR_SUPPLIED_KEYS = %w[
  vault_downloaders_sabnzbd_server_username
  vault_downloaders_sabnzbd_server_password
].freeze

# The other reason a credential name appears in the shared inventory, and the
# opposite one: this key is declared there with a *working* value because no
# state of the platform wants Dozzle's alert relay unauthenticated, and because
# a credential that existed only in the vault would fail vault_contract on every
# host whose vault predates it -- on a five-minute tick, with the fix locked
# inside an encrypted file (#172). It is admitted here by name rather than by
# loosening the check below to "any vault_ name", because the property #298 asked
# that check to hold is that every prefixed name in the shared inventory is one
# the credential contract actually validates.
PLATFORM_DERIVED_KEYS = %w[
  vault_dozzle_alert_relay_token
].freeze

# The operator-owned half, and the whole of what #298 corrected: four values
# that are not secret had a prefix promising they were vault-authored, and the
# prefix is the only reason the plaintext default looked wrong. Pinned as one
# literal because every part of it is load-bearing -- the empty host is the
# undeclared state roles/downloaders reads without the vault password, and the
# integer port, integer connection count and *boolean* ssl are what stop
# SABnzbd's `bool_conv(int_conv())` from storing a stringy flag as 0 and
# silently disabling TLS.
POLICY_PROVIDER_SHAPE = {
  "host" => "", "port" => 563, "connections" => 8, "ssl" => true
}.freeze

actual_foundation_expectations =
  SERVICE_EXPECTATIONS.fetch("arr").fetch("vault_keys") +
  SERVICE_EXPECTATIONS.fetch("downloaders").fetch("vault_keys")
check(failures, actual_foundation_expectations == FOUNDATION_KEYS + OPERATOR_SUPPLIED_KEYS,
      "arr and downloaders expectations must carry the exact ordered foundation key set")

# An undeclared Usenet provider is a valid state, and these two files are what
# make it one. The shared inventory has to carry both credential names as empty
# strings, because vault_contract declares them required and runs before any
# target mutation: a missing name there fails the whole converge, for every
# service, on a target that simply has no subscription. And the filter's optional
# group has to be exactly the same two, because that is what stops the empty
# strings from failing the shape rules four tasks later. Either half alone is a
# broken converge, so both are pinned here against one list.
shared_inventory = YAML.safe_load_file(
  File.join(ROOT, "inventory", "group_vars", "all", "main.yml")
)
check(failures,
      OPERATOR_SUPPLIED_KEYS.all? { |key| shared_inventory.fetch(key, :absent) == "" },
      "shared inventory must declare every operator-supplied key as an empty string")
optional_group_source = File.read(
  File.join(ROOT, "filter_plugins", "vault_credential_schema.py")
)[/^OPTIONAL_KEY_GROUPS = \((.*?)^\)$/m, 1].to_s
optional_groups = optional_group_source.scan(/"(vault_[a-z0-9_]+)"/).flatten
check(failures, optional_groups == OPERATOR_SUPPLIED_KEYS,
      "the credential filter's optional group must be exactly the operator-supplied keys")

# The policy half, pinned in the same place and for the same reason: a converge
# needs both halves to exist, and after #298 only one of them is a credential.
check(failures,
      shared_inventory.fetch("media_usenet_provider", :absent) ==
        POLICY_PROVIDER_SHAPE,
      "shared inventory must declare the undeclared Usenet provider policy with "\
      "an empty host, integer port and connections, and a boolean ssl")

# The correction itself, asserted rather than described. #298 was filed because
# `grep -c '^vault_'` on the shared inventory returned six, four of which were
# not credentials. Every name that keeps the prefix here has to be one the
# credential contract actually validates, or the prefix is lying again.
inventory_vault_keys =
  shared_inventory.keys.select { |key| key.start_with?("vault_") }
check(failures,
      inventory_vault_keys.sort ==
        (OPERATOR_SUPPLIED_KEYS + PLATFORM_DERIVED_KEYS).sort,
      "every vault_-prefixed name in the shared inventory must be a credential "\
      "the contract validates")

# And the platform-derived half has to stay derived. The shared inventory is
# committed in the clear, so a literal here would be a plaintext credential in
# the repository -- the one thing the security boundary forbids outright -- and
# a value that is not a template is exactly that. The one-way derivation is
# asserted for its own sake: #172 exists because Dozzle persists this token in
# its /data volume and serves it back over its API, so what that volume holds
# must not be reversible to the ntfy publish token it is derived from.
PLATFORM_DERIVED_KEYS.each do |key|
  value = shared_inventory.fetch(key, nil)
  check(failures, EXPECTED_VAULT_KEYS.include?(key),
        "platform-derived credential #{key} must be one the contract validates")
  check(failures,
        value.is_a?(String) && value.start_with?("{{") && value.end_with?("}}"),
        "platform-derived credential #{key} must be a template, not a literal")
  check(failures, value.to_s.match?(/\|\s*hash\('sha256'\)/),
        "platform-derived credential #{key} must be a one-way derivation")
end

# And the four must be gone from the credential side entirely, not merely
# dropped from the optional group: a rule left behind in CREDENTIAL_RULES would
# make vault_contract demand a key nothing authors any more.
credential_schema_source = File.read(
  File.join(ROOT, "filter_plugins", "vault_credential_schema.py")
)
%w[host port connections ssl].each do |field|
  check(failures,
        !credential_schema_source.include?(
          "vault_downloaders_sabnzbd_server_#{field}"
        ),
        "the credential filter must not name the non-credential provider "\
        "field #{field}")
end

# The one agreement the whole tolerance argument rests on, and the one nothing
# else can see. Every lane's vault declares vault_dozzle_alert_relay_token --
# tests/generate-ephemeral-vault.sh writes it -- so no lane ever converges the
# state the NAS will actually be in on the first run after this merges, which is
# the vault that omits it and takes the derived default. That is #295's shape
# exactly: a fixture that supplies a credential cannot catch a bug about its
# absence. What would break in that state is the derivation disagreeing with the
# rule the contract applies to the key it defaults, so the disagreement is
# checked directly.
#
# Computed here rather than by booting Ansible: Jinja's hash('sha256') and
# Digest::SHA256 emit the same hexdigest, and what is at risk is the shape
# agreement rather than the filter. The derivation's exact form is pinned in the
# same breath, which is what makes it a pure function of vault material -- a
# lookup or a timestamp in there would repair the dispatcher on every converge
# and idempotence would never hold.
relay_derivation = shared_inventory.fetch("vault_dozzle_alert_relay_token", "").to_s
check(failures,
      relay_derivation.match?(
        /\A\{\{ \('[^']*' ~ vault_ntfy_dozzle_token\) \| hash\('sha256'\) \}\}\z/
      ),
      "the derived relay token must be a salted hash of the ntfy publish token "\
      "and nothing else")
relay_rule = credential_schema_source[
  /^\s*"vault_dozzle_alert_relay_token": \(\(PATTERN, ([A-Z_0-9]+)\),\),$/, 1
].to_s
relay_pattern = credential_schema_source[
  /^#{Regexp.escape(relay_rule)} = re\.compile\(r"([^"]+)"\)$/, 1
].to_s
check(failures, !relay_pattern.empty?,
      "the derived relay token must carry a pinned pattern rule")
check(failures,
      !relay_pattern.empty? &&
        Regexp.new(relay_pattern.sub('\\Z', '\\z')).match?(
          Digest::SHA256.hexdigest("policy-sample")
        ),
      "the derived relay token must satisfy the rule its own key carries")

# There is a third half, and it is the one issue #295 was filed about: a fixture
# that supplies a credential can never catch a bug about that credential's
# absence. The ephemeral generator has to know which groups may legitimately be
# left undeclared, or no lane can be asked to converge the state their absence
# describes -- which is how #274 merged with every lane green and then failed the
# NAS's next converge in vault_contract before any service could deploy.
#
# The group *names* cannot be derived from the filter's key tuples, so what is
# pinned is that the generator carries one name per tuple. A group added to the
# filter with no name added here is a state nothing converges.
ephemeral_generator_source =
  File.read(File.join(ROOT, "tests", "generate-ephemeral-vault.sh"))
generator_optional_groups =
  ephemeral_generator_source[/^optional_credential_groups='([^']*)'$/, 1].to_s.split
check(failures,
      generator_optional_groups.length == optional_group_source.scan(/\(/).length &&
        generator_optional_groups == %w[usenet],
      "the ephemeral generator must name one optional credential group per filter group")

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
# The Radarr and Sonarr keys are the two this platform POSTs to Bazarr's settings
# form, and Bazarr casts every submitted value with int() unless the last
# dash-segment of its key is one of config.py's str_keys -- `apikey` is not -- so
# a key of only decimal digits fails the schema's is_type_of str and is refused
# with 406 for as long as it is deployed. Both keep the repeated-digit series
# that makes every example key obviously sanitized and end in the one
# hexadecimal letter that keeps an operator who copies the file deployable.
BAZARR_SUBMITTED_EXAMPLE_KEYS = %w[
  vault_arr_radarr_api_key
  vault_arr_sonarr_api_key
].freeze

# Pinned the way the foundation values are, because these two are the ones an
# operator has to bring: a value that stopped being an obvious stand-in is how a
# real provider account reaches the repository.
OPERATOR_SUPPLIED_EXAMPLE = {
  "vault_downloaders_sabnzbd_server_username" => "example-usenet-username",
  "vault_downloaders_sabnzbd_server_password" => "example-usenet-password"
}.freeze
check(failures,
      OPERATOR_SUPPLIED_EXAMPLE.keys == OPERATOR_SUPPLIED_KEYS &&
        OPERATOR_SUPPLIED_EXAMPLE.all? { |key, value| example[key] == value },
      "vault example must use the exact sanitized operator-supplied values")

foundation_example = FOUNDATION_KEYS.to_h do |key|
  value = if key.end_with?("_api_key")
            digit = (FOUNDATION_KEYS.index(key) / 3).to_s
            if BAZARR_SUBMITTED_EXAMPLE_KEYS.include?(key)
              "#{digit * 31}a"
            else
              digit * 32
            end
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
  # Trailarr's key is contracted the same way and takes the next digit in that
  # series, so no two services ship the same stand-in.
  next if key == "vault_trailarr_api_key" && value == "6" * 32
  # Seerr's takes the digit after Trailarr's, and closes the series: it is the
  # last acquisition project.
  next if key == "vault_seerr_api_key" && value == "7" * 32
  # The Dozzle alert relay's shared secret is contracted to 64 lowercase
  # hexadecimal characters, twice the width of that series, so it takes the
  # all-zero stand-in the bcrypt hashes and ntfy tokens use instead. It is
  # quoted in the example because 64 zeros is otherwise a YAML integer, and an
  # operator copying an integer would fail the contract's text rule.
  next if key == "vault_dozzle_alert_relay_token" && value == "0" * 64
  next if value.include?("example-only-not-a-real-private-key")
  next if foundation_example[key] == value
  next if OPERATOR_SUPPLIED_EXAMPLE[key] == value

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

operator_supplied_parity_sources =
  foundation_parity_sources.reject { |label, _path| label == "secret generator" }
operator_supplied_parity_sources.each do |label, path|
  body = File.read(path)
  positions = OPERATOR_SUPPLIED_KEYS.map { |key| body.index(key) }
  OPERATOR_SUPPLIED_KEYS.zip(positions).each do |key, position|
    check(failures, !position.nil?, "#{label} is missing operator-supplied credential #{key}")
  end
  check(failures,
        positions.none?(&:nil?) && positions.each_cons(2).all? { |left, right| left < right },
        "#{label} must carry operator-supplied credentials in contract order")
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

ephemeral_helper = ephemeral_generator_source
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
  "mid-validation cleanup" => "self-test mid-validation failure left credential material",
  # The undeclared shape's own three properties. Proved here rather than only in
  # the integration lane that consumes it, because a break in it would otherwise
  # be visible only after a Docker suite has run: that all six provider values
  # really come out empty, that the resulting vault still satisfies the shared
  # credential contract, and that a group list the generator cannot honour is
  # refused rather than silently standing everything in.
  "undeclared provider emptiness" =>
    "self-test undeclared vault still declares a Usenet provider",
  "undeclared vault contract" =>
    "self-test undeclared vault fell outside the shared contract",
  "undeclared group refusal" =>
    "self-test accepted an invalid undeclared credential group list"
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
  # An ephemeral Radarr or Sonarr key of only decimal digits is cast to an int by
  # Bazarr's settings form and refused with 406 for the life of that vault. The
  # redraw is what stops it; dropping it back to a bare `openssl rand -hex 16`
  # would pass every run but the one in 3e-7 that matters.
  "Bazarr all-digit API key redraw" => "*[abcdef]*)",
  "Bazarr API key computed before the heredoc" =>
    "radarr_api_key=$(random_api_key) || die"
}
helper_guard_sources.each do |property, source|
  check(failures, ephemeral_helper.include?(source),
        "ephemeral vault helper must preserve #{property}")
end

# The self-test's cleanup trap is counted rather than merely found. Each fixture
# region names its directory to the handler and must arm the handler on the very
# next line, because between those two lines an interrupt leaves credential
# material behind. Asserting the trap string appears *somewhere* is what let a
# second region land relying on the first region's install: removing either one
# left the other for `include?` to find, so the mutation that plants exactly that
# removal went undetected. The floor is asserted too -- a regex that silently
# stops matching would otherwise pass on nothing at all.
named_fixture_regions =
  ephemeral_helper.scan(/^[ \t]*self_test_fixture_directory=\$\S+$/).length
armed_fixture_regions = ephemeral_helper.scan(
  /^[ \t]*self_test_fixture_directory=\$\S+\n[ \t]*trap self_test_cleanup_on_exit EXIT$/
).length
check(failures,
      named_fixture_regions >= 2 &&
        armed_fixture_regions == named_fixture_regions,
      "ephemeral vault helper must preserve self-test cleanup trap")
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
  ["roles/beszel/tasks/superuser.yml",
   "Verify the advertised key matches vault, proving no read-back is needed"] =>
    "prints the public half of the agent keypair so the operator can compare it",
  ["roles/beszel/tasks/application_user.yml",
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
    "tests/contracts/immich-static.rb",
  ["roles/immich/tasks/configured_password.yml",
   "Require a complete configured-password Immich user listing"] => "tests/contracts/immich-static.rb",
  ["roles/immich/tasks/configured_password.yml",
   "Require unique configured-password Immich target identifiers"] => "tests/contracts/immich-static.rb",
  ["roles/immich/tasks/configured_password.yml",
   "Require a complete authoritative configured-password user listing"] => "tests/contracts/immich-static.rb",
  ["roles/immich/tasks/configured_password.yml",
   "Require unique authoritative configured-password target identifiers"] => "tests/contracts/immich-static.rb",
  ["roles/paperless_ngx/tasks/mail_state.yml",
   "Require the installed Paperless Gmail credential fingerprint"] =>
    "tests/contracts/paperless-static.rb",
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

VAULT_NAS_TREES = %w[inventory roles templates tests].freeze
nas_coordinate_scan = VAULT_NAS_TREES.to_h do |tree|
  [tree, Dir[File.join(ROOT, tree, "**", "*")].select { |path| File.file?(path) }]
end
# The assertion below is that the sweep found nothing, so an empty sweep is
# indistinguishable from a clean tree and this is the only thing standing
# between the two. Per tree first, because a renamed tree is the failure the
# glob's brace expansion cannot report -- `templates/` holds a single file, so
# there is no useful per-tree number above one -- and then a total, which is
# what a tree collapsing rather than disappearing looks like.
#
# 100 is sized against the mutation fixture, not the tree. The harness copies a
# curated subset of the repository into its sandbox, where these four trees hold
# 275 files against the tree's 497, and every mutation runs this script there;
# a floor sized to the tree would fail every one of them for a reason that has
# nothing to do with the mutation under test.
VAULT_NAS_TREES.each do |tree|
  check_floor(failures, nas_coordinate_scan.fetch(tree).length, 1,
              "the vault_nas_ leak sweep of #{tree}/ matched no file")
end
check_floor(failures, nas_coordinate_scan.values.sum(&:length), 100,
            "the vault_nas_ leak sweep read too few files across #{VAULT_NAS_TREES.join(', ')}")

repository_vault_nas_references = nas_coordinate_scan.values.flatten
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
