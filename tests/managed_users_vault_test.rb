#!/usr/bin/env ruby
# frozen_string_literal: true

require "open3"
require "tmpdir"
require "yaml"
require "fileutils"

ROOT = File.expand_path("..", __dir__)
VAULT_PATH = File.join(ROOT, "inventory", "group_vars", "all", "vault.yml.example")
SPEC_PATH = File.join(ROOT, "roles", "vault_contract", "meta", "argument_specs.yml")
TASKS_PATH = File.join(ROOT, "roles", "vault_contract", "tasks", "main.yml")
GENERATOR_PATH = File.join(ROOT, "tests", "generate-ephemeral-vault.sh")
DOCS_PATH = File.join(ROOT, "docs", "secrets.md")
POLICY_SUPPORT_PATH = File.join(ROOT, "tests", "policy_support.rb")
VALIDATE_POLICY_PATH = File.join(ROOT, "tests", "validate-policy.sh")
PLAIN_TEMPLATE_PATH = File.join(ROOT, "templates", "vault-plain.yml.j2")
SHARED_VARS_PATH = File.join(ROOT, "inventory", "group_vars", "all", "main.yml")

IMMICH_PREFERENCE_KEYS = %w[
  immich_managed_user_preference_profile_default
  immich_managed_user_preference_profile_by_email
  immich_managed_user_preference_overrides
  immich_managed_user_preference_profiles
].freeze

ENTRY_FIELDS = {
  "audiobookshelf" => %w[username password type is_active permissions],
  "beszel" => %w[email password role verified],
  "dozzle" => %w[username password password_hash email name filter roles],
  "immich" => %w[email password name quota_size],
  "jellyfin" => %w[username password policy],
  "komga" => %w[email password roles],
  "ntfy" => %w[username password password_hash role access tokens],
  "paperless_ngx" => %w[username password email is_active is_staff is_superuser groups]
}.freeze

IDENTITY_FIELDS = {
  "audiobookshelf" => "username",
  "beszel" => "email",
  "dozzle" => "username",
  "immich" => "email",
  "jellyfin" => "username",
  "komga" => "email",
  "ntfy" => "username",
  "paperless_ngx" => "username"
}.freeze

TEXT_FIELDS = {
  "audiobookshelf" => %w[username password type],
  "beszel" => %w[email password role],
  "dozzle" => %w[username password password_hash email name filter roles],
  "immich" => %w[email password name],
  "jellyfin" => %w[username password],
  "komga" => %w[email password],
  "ntfy" => %w[username password password_hash role],
  "paperless_ngx" => %w[username password email]
}.freeze

BCRYPT = /^\$2[aby]\$\d{2}\$[.\/A-Za-z0-9]{53}$/
TOKEN = /^tk_[a-z0-9]{29}$/
NTFY_USERNAME = /^[-_.+@A-Za-z0-9]+$/
NTFY_LITERAL_TOPIC = /^[-_A-Za-z0-9]{1,64}$/

ARGUMENT_FIELDS = {
  "audiobookshelf" => {
    "username" => ["str", nil], "password" => ["str", nil],
    "type" => ["str", nil], "is_active" => ["bool", nil],
    "permissions" => ["dict", nil]
  },
  "beszel" => {
    "email" => ["str", nil], "password" => ["str", nil],
    "role" => ["str", nil], "verified" => ["bool", nil]
  },
  "dozzle" => {
    "username" => ["str", nil], "password" => ["str", nil],
    "password_hash" => ["str", nil], "email" => ["str", nil],
    "name" => ["str", nil], "filter" => ["str", nil], "roles" => ["str", nil]
  },
  "immich" => {
    "email" => ["str", nil], "password" => ["str", nil],
    "name" => ["str", nil], "quota_size" => ["int", nil]
  },
  "jellyfin" => {
    "username" => ["str", nil], "password" => ["str", nil],
    "policy" => ["dict", nil]
  },
  "komga" => {
    "email" => ["str", nil], "password" => ["str", nil],
    "roles" => ["list", "str"]
  },
  "ntfy" => {
    "username" => ["str", nil], "password" => ["str", nil],
    "password_hash" => ["str", nil], "role" => ["str", nil],
    "access" => ["list", "dict"], "tokens" => ["list", "str"]
  },
  "paperless_ngx" => {
    "username" => ["str", nil], "password" => ["str", nil],
    "email" => ["str", nil], "is_active" => ["bool", nil],
    "is_staff" => ["bool", nil], "is_superuser" => ["bool", nil],
    "groups" => ["list", "str"]
  }
}.freeze

def check(failures, condition, message)
  failures << message unless condition
end

def load_mapping(path, failures, label)
  document = YAML.safe_load_file(path, aliases: false)
  return document if document.is_a?(Hash)

  failures << "#{label} must contain a mapping"
  {}
rescue Errno::ENOENT
  failures << "#{label} is missing"
  {}
rescue Psych::Exception
  failures << "#{label} is malformed"
  {}
end

def normalized(value)
  value.to_s.strip.downcase
end

def duplicate(document)
  Marshal.load(Marshal.dump(document))
end

def validate_with_role(document, preference_overrides = {})
  Dir.mktmpdir("nas-platform-managed-users-vault-") do |directory|
    path = File.join(directory, "vault.yml")
    playbook = File.join(directory, "validate-vault.yml")
    shared_vars = YAML.safe_load_file(SHARED_VARS_PATH, aliases: false)
    preferences = IMMICH_PREFERENCE_KEYS.to_h { |key| [key, shared_vars[key]] }
    variables = preferences.merge(document).merge(preference_overrides)
    File.write(path, YAML.dump(variables), mode: "w", perm: 0o600)
    FileUtils.cp(File.join(ROOT, "validate-vault.yml"), playbook)
    Open3.capture3(
      {
        "ANSIBLE_NOCOLOR" => "1",
        "ANSIBLE_CONFIG" => File.join(ROOT, "ansible.cfg"),
        "ANSIBLE_ROLES_PATH" => File.join(ROOT, "roles")
      },
      "ansible-playbook", "-i", "localhost,", playbook, "-e", "@#{path}",
      chdir: directory
    )
  end
end

def expect_role_rejection(failures, label, document, forbidden_value, preference_overrides = {})
  stdout, stderr, status = validate_with_role(document, preference_overrides)
  check(failures, !status.success?, "#{label} must be rejected by vault role evaluation")
  output = stdout + stderr
  check(failures, !output.include?(forbidden_value), "#{label} diagnostic disclosed a managed-user value")
end

failures = []
vault = load_mapping(VAULT_PATH, failures, "vault example")
check(failures, vault["vault_jellyfin_admin_username"] == "Yonatan",
      "Jellyfin administrator username must have exact approved casing")
%w[vault_jellyfin_opensubtitles_username vault_jellyfin_opensubtitles_password].each do |key|
  check(failures, vault[key].is_a?(String) && !vault[key].empty?,
        "vault example must declare #{key}")
end
managed = vault["vault_managed_users"]
check(failures, managed.is_a?(Hash), "vault_managed_users must be a mapping")
managed = {} unless managed.is_a?(Hash)
check(failures, managed.keys.sort == ENTRY_FIELDS.keys.sort,
      "vault_managed_users service keys differ")

ENTRY_FIELDS.each do |service, fields|
  entries = managed[service]
  check(failures, entries.is_a?(Array) && !entries.empty?,
        "#{service} must have a synthetic managed user")
  next unless entries.is_a?(Array)

  entries.each_with_index do |entry, index|
    check(failures, entry.is_a?(Hash), "#{service} entry #{index} must be a mapping")
    next unless entry.is_a?(Hash)

    check(failures, entry.keys.sort == fields.sort,
          "#{service} entry #{index} fields differ")
    check(failures, !entry["password"].to_s.empty?,
          "#{service} entry #{index} password must be non-empty")
  end

  identity = IDENTITY_FIELDS.fetch(service)
  identities = entries.filter_map { |entry| normalized(entry[identity]) if entry.is_a?(Hash) }
  check(failures, identities.none?(&:empty?) && identities.uniq.length == identities.length,
        "#{service} normalized identities must be non-empty and unique")
end

managed.fetch("audiobookshelf", []).each do |entry|
  next unless entry.is_a?(Hash)
  check(failures, %w[admin user guest].include?(entry["type"]),
        "audiobookshelf type must be supported")
  check(failures, entry["is_active"] == true,
        "audiobookshelf is_active must be true for password verification")
  permissions = entry["permissions"]
  check(failures,
        permissions.is_a?(Hash) && permissions.keys.sort ==
          %w[flags itemTagsSelected librariesAccessible].sort,
        "audiobookshelf permissions must use the pinned nested contract")
  next unless permissions.is_a?(Hash)

  flags = permissions["flags"]
  supported_flags = %w[download update delete upload createEreader accessAllLibraries
                       accessAllTags accessExplicitContent selectedTagsNotAccessible]
  check(failures,
        flags.is_a?(Hash) && (flags.keys - supported_flags).empty? &&
          flags.values.all? { |value| [true, false].include?(value) },
        "audiobookshelf permission flags must be supported booleans")
  %w[librariesAccessible itemTagsSelected].each do |field|
    values = permissions[field]
    check(failures,
          values.is_a?(Array) && values.all? { |value| value.is_a?(String) && !value.empty? } &&
            values.uniq.length == values.length,
          "audiobookshelf #{field} must contain unique non-empty strings")
  end
end

managed.fetch("beszel", []).each do |entry|
  next unless entry.is_a?(Hash)
  check(failures, %w[user admin].include?(entry["role"]), "beszel role must be supported")
  check(failures, entry["verified"] == true,
        "beszel verified must be true for password verification")
end

managed.fetch("dozzle", []).each do |entry|
  next unless entry.is_a?(Hash)
  check(failures, BCRYPT.match?(entry["password_hash"].to_s),
        "dozzle password_hash must have bcrypt shape")
  check(failures, %w[none user admin].include?(entry["roles"]),
        "dozzle roles must be supported")
end

managed.fetch("immich", []).each do |entry|
  next unless entry.is_a?(Hash)
  check(failures, entry["quota_size"].is_a?(Integer) && entry["quota_size"] >= 0,
        "immich quota_size must be a non-negative integer")
end

managed.fetch("jellyfin", []).each do |entry|
  next unless entry.is_a?(Hash)
  check(failures, entry["policy"].is_a?(Hash), "jellyfin policy must be a mapping")
  check(failures, entry.dig("policy", "IsDisabled") != true,
        "jellyfin managed policy must not disable password verification")
end

managed.fetch("komga", []).each do |entry|
  next unless entry.is_a?(Hash)
  roles = entry["roles"]
  supported = %w[ADMIN FILE_DOWNLOAD PAGE_STREAMING KOBO_SYNC KOREADER_SYNC]
  check(failures, roles.is_a?(Array) && !roles.empty? && (roles - supported).empty?,
        "komga roles must be supported")
end

managed.fetch("ntfy", []).each do |entry|
  next unless entry.is_a?(Hash)
  check(failures, BCRYPT.match?(entry["password_hash"].to_s),
        "ntfy password_hash must have bcrypt shape")
  check(failures, entry["role"] == "user", "ntfy role must be nonadministrative")
  check(failures, NTFY_USERNAME.match?(entry["username"].to_s),
        "ntfy username must use native safe characters")
  access = entry["access"]
  check(failures,
        access.is_a?(Array) && access.all? do |rule|
          rule.is_a?(Hash) && rule.keys.sort == %w[permission topic] &&
            NTFY_LITERAL_TOPIC.match?(rule["topic"].to_s) &&
            %w[read-only write-only read-write deny].include?(rule["permission"])
        end,
        "ntfy access rules must have supported values")
  tokens = entry["tokens"]
  check(failures, tokens.is_a?(Array) && tokens.all? { |token| TOKEN.match?(token.to_s) } &&
                    tokens.uniq.length == tokens.length,
        "ntfy tokens must be unique and have supported shape")
end

managed.fetch("paperless_ngx", []).each do |entry|
  next unless entry.is_a?(Hash)
  %w[is_active is_staff is_superuser].each do |field|
    check(failures, [true, false].include?(entry[field]), "paperless_ngx #{field} must be boolean")
  end
  check(failures, entry["groups"].is_a?(Array) && entry["groups"].all? { |group| !group.to_s.empty? },
        "paperless_ngx groups must be a list of names")
end

admin_identities = {
  "audiobookshelf" => vault["vault_audiobookshelf_admin_username"],
  "beszel" => vault["vault_beszel_superuser_email"],
  "dozzle" => vault["vault_dozzle_admin_username"],
  "immich" => vault["vault_immich_admin_email"],
  "jellyfin" => vault["vault_jellyfin_admin_username"],
  "komga" => vault["vault_komga_admin_email"],
  "ntfy" => vault["vault_ntfy_admin_user"],
  "paperless_ngx" => vault["vault_paperless_admin_username"]
}
admin_identities.each do |service, administrator|
  identity = IDENTITY_FIELDS.fetch(service)
  actual = managed.fetch(service, []).filter_map { |entry| normalized(entry[identity]) if entry.is_a?(Hash) }
  check(failures, !actual.include?(normalized(administrator)),
        "#{service} managed identity must differ from its primary administrator")
end

beszel_identities = managed.fetch("beszel", []).filter_map do |entry|
  normalized(entry["email"]) if entry.is_a?(Hash)
end
check(failures, !beszel_identities.include?(normalized(vault["vault_beszel_app_user_email"])),
      "beszel managed identity must differ from the primary app user")

ntfy_identities = managed.fetch("ntfy", []).filter_map do |entry|
  normalized(entry["username"]) if entry.is_a?(Hash)
end
check(failures, (ntfy_identities & %w[dozzle beszel]).empty?,
      "ntfy managed identity must differ from publishers")

spec = load_mapping(SPEC_PATH, failures, "vault argument spec")
managed_spec = spec.dig("argument_specs", "main", "options", "vault_managed_users")
check(failures, managed_spec.is_a?(Hash) && managed_spec["type"] == "dict" && managed_spec["required"] == true,
      "vault_managed_users argument must be a required dict")
managed_options = managed_spec.is_a?(Hash) ? managed_spec["options"] : nil
check(failures, managed_options.is_a?(Hash) && managed_options.keys.sort == ARGUMENT_FIELDS.keys.sort,
      "vault_managed_users argument service options differ")
ARGUMENT_FIELDS.each do |service, expected_fields|
  service_spec = managed_options.is_a?(Hash) ? managed_options[service] : nil
  check(failures,
        service_spec.is_a?(Hash) && service_spec["type"] == "list" &&
          service_spec["elements"] == "dict" && service_spec["required"] == true,
        "#{service} argument must be a required list of dictionaries")
  field_specs = service_spec.is_a?(Hash) ? service_spec["options"] : nil
  check(failures, field_specs.is_a?(Hash) && field_specs.keys.sort == expected_fields.keys.sort,
        "#{service} argument fields differ")
  expected_fields.each do |field, (type, elements)|
    field_spec = field_specs.is_a?(Hash) ? field_specs[field] : nil
    valid = field_spec.is_a?(Hash) && field_spec["type"] == type && field_spec["required"] == true
    valid &&= field_spec["elements"] == elements if elements
    check(failures, valid, "#{service}.#{field} argument type differs")
  end
end
access_spec = managed_options.is_a?(Hash) ? managed_options.dig("ntfy", "options", "access") : nil
access_options = access_spec.is_a?(Hash) ? access_spec["options"] : nil
check(failures,
      access_options.is_a?(Hash) && access_options.keys.sort == %w[permission topic] &&
        access_options.values.all? { |option| option == { "type" => "str", "required" => true } },
      "ntfy access argument fields must be required strings")
abs_permissions_spec = managed_options.is_a?(Hash) ?
  managed_options.dig("audiobookshelf", "options", "permissions") : nil
check(failures,
      abs_permissions_spec.is_a?(Hash) &&
        abs_permissions_spec.dig("options", "flags", "type") == "dict" &&
        abs_permissions_spec.dig("options", "librariesAccessible") ==
          { "type" => "list", "elements" => "str", "required" => true } &&
        abs_permissions_spec.dig("options", "itemTagsSelected") ==
          { "type" => "list", "elements" => "str", "required" => true },
      "audiobookshelf nested permissions argument contract differs")
check(failures,
      managed_options.dig("audiobookshelf", "options", "is_active", "choices") == [true],
      "audiobookshelf is_active argument must only accept true")
check(failures,
      managed_options.dig("beszel", "options", "verified", "choices") == [true],
      "beszel verified argument must only accept true")
check(failures,
      managed_options.dig("ntfy", "options", "role", "choices") == ["user"],
      "ntfy managed role argument must only accept user")
immich_fields = managed_options.is_a?(Hash) ?
  managed_options.dig("immich", "options")&.keys&.sort : nil
check(failures, immich_fields == %w[email name password quota_size],
      "Immich preference policy must not enter the encrypted user records")

vault_options = spec.dig("argument_specs", "main", "options") || {}
%w[vault_jellyfin_opensubtitles_username vault_jellyfin_opensubtitles_password].each do |key|
  check(failures,
        vault_options[key] == { "type" => "str", "required" => true },
        "vault argument spec must require #{key}")
end

parsed_tasks = File.file?(TASKS_PATH) ? YAML.safe_load_file(TASKS_PATH, aliases: false) : []

# What the role does is read off its parsed tasks. A fact assigned in a comment
# is not a fact the role publishes, a task named in a comment sorts ahead of the
# task it names when positions are byte offsets, and no_log counted over a file's
# text counts the ones in comments too.
def task_scalars(node)
  case node
  when Hash then node.flat_map { |key, value| [key.to_s] + task_scalars(value) }
  when Array then node.flat_map { |value| task_scalars(value) }
  when String then [node]
  else []
  end
end
task_strings = task_scalars(parsed_tasks)
reserved_identities = parsed_tasks.filter_map do |task|
  task.dig("vars", "vault_contract_reserved_identities")
end.first
reserved_identity_values = Array(reserved_identities&.values).flatten

published_facts = parsed_tasks.flat_map do |task|
  set_fact = task["ansible.builtin.set_fact"]
  set_fact.is_a?(Hash) ? set_fact.keys : []
end
facts = ENTRY_FIELDS.keys.map { |service| "vault_managed_#{service}_users" }
facts.each do |fact|
  check(failures, published_facts.include?(fact),
        "vault contract must publish named fact #{fact}")
end
validation_position = parsed_tasks.index do |task|
  task["name"] == "Require a valid managed-user vault schema"
end
facts_position = parsed_tasks.index do |task|
  task["name"] == "Resolve validated managed-user service lists"
end
check(failures, validation_position && facts_position && validation_position < facts_position,
      "managed-user validation must precede named facts")
check(failures, parsed_tasks.count { |task| task["name"].to_s.match?(/managed-user/i) } >= 3 &&
                  parsed_tasks.count { |task| task["no_log"] == true } >= 4,
      "managed-user validation must use no_log redaction")
# The per-service fail_msg moved into filter_plugins/vault_managed_user_schema.py,
# which reports field paths rather than one generic message per service. Per-service
# coverage is still required, now by asserting the filter dispatches for each one.
schema_filter_path = File.join(ROOT, "filter_plugins", "vault_managed_user_schema.py")
schema_filter_source = File.file?(schema_filter_path) ? File.read(schema_filter_path) : ""
check(failures, task_strings.any? { |value| value.include?("vault_managed_user_errors") },
      "vault contract must validate managed users with the schema filter")
schema_assertion = parsed_tasks.find do |task|
  task["name"] == "Require a valid managed-user vault schema"
end
check(failures,
      schema_assertion.to_h.dig("ansible.builtin.assert", "fail_msg").to_s
        .include?("values not shown"),
      "managed-user schema failure must state that values are not shown")
ENTRY_FIELDS.each_key do |service|
  check(failures, schema_filter_source.match?(/^\s*"#{Regexp.escape(service)}": _/),
        "#{service} validation must use a value-free field diagnostic")
end
required_validation_fragments = [
  "vault_audiobookshelf_admin_username",
  "vault_beszel_superuser_email",
  "vault_beszel_app_user_email",
  "vault_dozzle_admin_username",
  "vault_immich_admin_email",
  "vault_jellyfin_admin_username",
  "vault_komga_admin_email",
  "vault_ntfy_admin_user",
  "vault_paperless_admin_username"
]
required_validation_fragments.each do |fragment|
  check(failures, reserved_identity_values.any? { |value| value.include?(fragment) },
        "vault contract validation is missing #{fragment}")
end
# Identity uniqueness and separation moved into the same schema filter, so the
# trim-and-lower normalization is asserted where it now lives. The role no longer
# repeats one uniqueness condition per service; it declares which identities the
# platform owns and the filter applies the rule.
check(failures, schema_filter_source.include?("strip().lower()"),
      "identity comparison must normalize by trimming and lowercasing")
IDENTITY_FIELDS.each do |service, field|
  check(failures, schema_filter_source.match?(/^\s*"#{Regexp.escape(service)}": "#{Regexp.escape(field)}",$/),
        "#{service} identity uniqueness must key on #{field}")
end
check(failures, reserved_identities.is_a?(Hash) &&
                  reserved_identities.keys.sort == ENTRY_FIELDS.keys.sort,
      "vault contract must reserve identities for every managed service")
%w[dozzle beszel].each do |published|
  check(failures, Array(reserved_identities&.fetch("ntfy", nil)).include?(published),
        "ntfy must reserve the #{published} publisher username")
end
# Field-level guards moved from Jinja conditions into the schema filter, so they
# are asserted where they now live. The exhaustive per-field type coverage is in
# tests/vault_managed_user_schema_test.py, which substitutes an incompatible type
# for every field of every service and requires a rejection that names the field;
# dropping the string guard there fails thirty subtests. These checks keep the
# schema's *declarations* pinned so a field cannot quietly lose its constraints.
TEXT_FIELDS.each do |service, fields|
  fields.each do |field|
    check(failures, schema_filter_source.match?(/f"\{path\}\.#{Regexp.escape(field)}"/),
          "#{service}.#{field} must have an explicit runtime string guard")
  end
end
{
  "Komga roles" => 'string_list(errors, f"{path}.roles"',
  "ntfy tokens" => 'string_list(errors, f"{path}.tokens"',
  "Paperless groups" => 'string_list(errors, f"{path}.groups"'
}.each do |label, declaration|
  check(failures, schema_filter_source.include?(declaration),
        "#{label} elements must have runtime string guards")
end
check(failures, schema_filter_source.include?('errors.append(f"{path}.policy: every key must be a string")'),
      "Jellyfin policy keys must have runtime string guards")
check(failures,
      schema_filter_source.include?('f"{access_path}.topic"') &&
      schema_filter_source.include?('f"{access_path}.permission"'),
      "ntfy access fields must have runtime string guards")
check(failures, schema_filter_source.match?(/in JELLYFIN_FORBIDDEN_POLICY_FIELDS\b/),
      "vault contract must reject secret-bearing Jellyfin policy keys")
schema_errors_expression = parsed_tasks.filter_map do |task|
  task.dig("ansible.builtin.set_fact", "vault_contract_schema_errors")
end.first.to_s
check(failures, schema_filter_source.include?("_ntfy_token_ownership") &&
                schema_errors_expression.include?("vault_ntfy_dozzle_token") &&
                schema_errors_expression.include?("vault_ntfy_beszel_token"),
      "vault contract must enforce global ntfy token uniqueness and publisher separation")
# The scalar credential shape rules moved into
# filter_plugins/vault_credential_schema.py, which reports the offending variable
# name rather than one generic message for all 49 of them. The role still names
# every credential, in the mapping it hands the filter; the pinned literals are
# asserted where they now live. tests/vault_credential_schema_test.py runs the
# rejection cases, and the role-level backstop is the placeholder rejection below,
# which drives the real role over the documented vault.
credential_filter_path = File.join(ROOT, "filter_plugins", "vault_credential_schema.py")
credential_filter_source = File.file?(credential_filter_path) ? File.read(credential_filter_path) : ""
credential_mapping = parsed_tasks.filter_map do |task|
  task.dig("ansible.builtin.set_fact", "vault_contract_credential_errors")
end.first.to_s
check(failures, credential_mapping.include?("vault_credential_errors"),
      "vault contract must validate portable credentials with the shape filter")
credential_assertion = parsed_tasks.find do |task|
  task["name"] == "Validate credential shapes without disclosing credential material"
end
check(failures,
      credential_assertion.to_h.dig("ansible.builtin.assert", "fail_msg").to_s
        .include?("Offending keys, values"),
      "credential shape failure must state that values are not shown")
check(failures, credential_filter_source.include?('JELLYFIN_ADMIN_USERNAME = "Yonatan"') &&
                credential_filter_source.match?(
                  /^\s*"vault_jellyfin_admin_username": \(\(EXACT, JELLYFIN_ADMIN_USERNAME\),\),$/
                ),
      "vault contract must require the exact Jellyfin administrator username")
# The scalar rule table must cover every scalar the role declares. A credential
# the table forgets is one the filter reports as unexpected rather than one it
# validates, and the role would fail closed for the wrong reason.
scalar_vault_keys = vault_options.keys.grep(/\Avault_/) - ["vault_managed_users"]
scalar_vault_keys.each do |key|
  check(failures, credential_filter_source.match?(/^\s*"#{Regexp.escape(key)}": \(/),
        "credential shape filter must carry a rule for #{key}")
  check(failures, credential_mapping.include?("'#{key}': #{key}"),
        "vault contract must submit #{key} for shape validation")
end
%w[vault_jellyfin_opensubtitles_username vault_jellyfin_opensubtitles_password].each do |key|
  suffix = key.end_with?("username") ? "username" : "password"
  check(failures, credential_filter_source.match?(/"#{Regexp.escape(key)}": \(\n\s*\(NONEMPTY, None\),/),
        "vault contract must reject empty #{key}")
  check(failures, credential_filter_source.include?("\"example-opensubtitles-#{suffix}\"") &&
                  credential_filter_source.include?(
                    "(NOT_PLACEHOLDER, OPENSUBTITLES_#{suffix.upcase}_PLACEHOLDERS)"
                  ),
        "vault contract must reject the documented #{key} placeholder")
end

generator = File.file?(GENERATOR_PATH) ? File.read(GENERATOR_PATH) : ""
check(failures, generator.include?("vault_managed_users:"),
      "ephemeral generator must include vault_managed_users")
ENTRY_FIELDS.each_key do |service|
  check(failures, generator.match?(/^  #{Regexp.escape(service)}:\n    - /),
        "ephemeral generator must include a synthetic #{service} entry")
end

policy = File.file?(POLICY_SUPPORT_PATH) ? File.read(POLICY_SUPPORT_PATH) : ""
# vault_managed_users is platform-wide rather than owned by one service, so it is the
# one pinned key that stayed in the policy source when the per-service keys moved out
# to tests/expected/<service>.yml. GLOBAL_VAULT_KEYS is concatenated into
# EXPECTED_VAULT_KEYS, so pinning it here still pins the full expected set.
check(failures, policy.match?(/GLOBAL_VAULT_KEYS = %w\[[^\]]*vault_managed_users[^\]]*\]\.freeze/m),
      "policy expected vault keys must include vault_managed_users")
plain_template = File.file?(PLAIN_TEMPLATE_PATH) ? File.read(PLAIN_TEMPLATE_PATH) : ""
# The template as a whole is Jinja, but this block carries no substitutions, so
# the block the template writes is parsed as the mapping it will be. The exact
# eight-line string this replaced also pinned the key order, which YAML does not
# make meaningful, and would have been satisfied by the same eight lines sitting
# in a comment.
plain_lines = plain_template.lines.map(&:chomp)
managed_start = plain_lines.index("vault_managed_users:")
managed_block = if managed_start
                  [plain_lines[managed_start]] +
                    plain_lines[(managed_start + 1)..].to_a.take_while do |line|
                      line.start_with?("  ")
                    end
                else
                  []
                end
managed_defaults = begin
  managed_block.empty? ? nil : YAML.safe_load(managed_block.join("\n"))["vault_managed_users"]
rescue Psych::SyntaxError
  nil
end
check(failures,
      managed_defaults == ENTRY_FIELDS.keys.each_with_object({}) { |service, empty| empty[service] = [] },
      "brand-new vault template must render eight empty managed-user lists")
validate_policy = File.file?(VALIDATE_POLICY_PATH) ? File.read(VALIDATE_POLICY_PATH) : ""
check(failures, validate_policy.lines.include?("ruby tests/managed_users_vault_test.rb\n"),
      "policy validation must run the managed-user vault test")

docs = File.file?(DOCS_PATH) ? File.read(DOCS_PATH) : ""
check(failures, docs.scan(/`vault_managed_users`/).length == 1,
      "secrets guide must document vault_managed_users exactly once")
ENTRY_FIELDS.each do |service, fields|
  service_section = docs.match(/^#### #{Regexp.escape(service)} managed users\n(.*?)(?=^#### |^### |^## |\z)/m)&.[](1).to_s
  check(failures, !service_section.empty?, "secrets guide must document #{service} managed users")
  fields.each do |field|
    check(failures, service_section.include?("`#{field}`"),
          "secrets guide must document #{service}.#{field}")
  end
end
check(failures,
      docs.include?("`verified` must be `true`") &&
        docs.include?("Beszel 0.18.7 password authentication requires verified users"),
      "secrets guide must document the Beszel verified authentication prerequisite")
check(failures,
      docs.include?("validates bcrypt shape only") &&
        docs.include?("authenticates the plaintext password") &&
        docs.include?("compares the stored hash before mutation"),
      "secrets guide must state the deferred bcrypt pair verification boundary")

runtime_vault = duplicate(vault)
runtime_vault["vault_jellyfin_opensubtitles_username"] = "runtime-opensubtitles-user"
runtime_vault["vault_jellyfin_opensubtitles_password"] = "runtime-opensubtitles-password"
_stdout, _stderr, valid_status = validate_with_role(runtime_vault)
check(failures, valid_status.success?, "vault example with runtime integrations must pass role evaluation")
expect_role_rejection(failures, "documented OpenSubtitles placeholders", vault,
                      "example-opensubtitles-password")

empty_immich = duplicate(runtime_vault)
empty_immich.dig("vault_managed_users", "immich").clear
expect_role_rejection(failures, "missing Immich family account", empty_immich,
                      runtime_vault.fetch("vault_immich_admin_email"))

wrong_type = duplicate(runtime_vault)
wrong_type.dig("vault_managed_users", "audiobookshelf", 0)["permissions"] = ["wrong-type-sentinel"]
expect_role_rejection(failures, "wrong nested field type", wrong_type, "wrong-type-sentinel")

disabled_audiobookshelf = duplicate(runtime_vault)
disabled_audiobookshelf.dig("vault_managed_users", "audiobookshelf", 0)["is_active"] = false
expect_role_rejection(failures, "disabled Audiobookshelf target", disabled_audiobookshelf,
                      "example-reader-password")

unverified_beszel = duplicate(runtime_vault)
unverified_beszel.dig("vault_managed_users", "beszel", 0)["verified"] = false
expect_role_rejection(failures, "unverified Beszel target", unverified_beszel,
                      "example-reader-password")

disabled_jellyfin = duplicate(runtime_vault)
disabled_jellyfin.dig("vault_managed_users", "jellyfin", 0, "policy")["IsDisabled"] = true
expect_role_rejection(failures, "disabled Jellyfin target", disabled_jellyfin,
                      "example-reader-password")

unsupported_abs_permission = duplicate(runtime_vault)
unsupported_abs_permission.dig("vault_managed_users", "audiobookshelf", 0)["permissions"] = {
  "flags" => { "libraries" => true }, "librariesAccessible" => [], "itemTagsSelected" => []
}
expect_role_rejection(failures, "unsupported Audiobookshelf permission", unsupported_abs_permission,
                      "libraries")

invalid_komga_role = duplicate(runtime_vault)
invalid_komga_role.dig("vault_managed_users", "komga", 0)["roles"] = ["OPDS"]
expect_role_rejection(failures, "unsupported Komga OPDS role", invalid_komga_role, "OPDS")

koreader_komga_role = duplicate(runtime_vault)
koreader_komga_role.dig("vault_managed_users", "komga", 0)["roles"] = ["KOREADER_SYNC"]
_stdout, _stderr, koreader_status = validate_with_role(koreader_komga_role)
check(failures, koreader_status.success?, "Komga KOREADER_SYNC must pass actual role evaluation")

integer_username = duplicate(runtime_vault)
integer_username.dig("vault_managed_users", "audiobookshelf", 0)["username"] = 424_242
expect_role_rejection(failures, "integer audiobookshelf username", integer_username, "424242")

list_password = duplicate(runtime_vault)
list_password.dig("vault_managed_users", "audiobookshelf", 0)["password"] =
  ["list-password-sentinel"]
expect_role_rejection(failures, "list audiobookshelf password", list_password,
                      "list-password-sentinel")

list_dozzle_email = duplicate(runtime_vault)
list_dozzle_email.dig("vault_managed_users", "dozzle", 0)["email"] =
  ["list-email-sentinel"]
expect_role_rejection(failures, "list Dozzle email", list_dozzle_email,
                      "list-email-sentinel")

list_dozzle_name = duplicate(runtime_vault)
list_dozzle_name.dig("vault_managed_users", "dozzle", 0)["name"] =
  ["list-name-sentinel"]
expect_role_rejection(failures, "list Dozzle name", list_dozzle_name,
                      "list-name-sentinel")

list_ntfy_topic = duplicate(runtime_vault)
list_ntfy_topic.dig("vault_managed_users", "ntfy", 0, "access", 0)["topic"] =
  ["list-topic-sentinel"]
expect_role_rejection(failures, "list ntfy access topic", list_ntfy_topic,
                      "list-topic-sentinel")

%w[bad,user bad:user bad/user].each do |username|
  hostile_username = duplicate(runtime_vault)
  hostile_username.dig("vault_managed_users", "ntfy", 0)["username"] = username
  expect_role_rejection(failures, "unsafe ntfy username", hostile_username, username)
end

["bad topic", "bad/topic", "bad*topic", "bad:topic", "bad,topic"].each do |topic|
  hostile_topic = duplicate(runtime_vault)
  hostile_topic.dig("vault_managed_users", "ntfy", 0, "access", 0)["topic"] = topic
  expect_role_rejection(failures, "unsafe ntfy literal topic", hostile_topic, topic)
end

restricted_admin = duplicate(runtime_vault)
restricted_admin_entry = restricted_admin.dig("vault_managed_users", "ntfy", 0)
restricted_admin_entry["role"] = "admin"
restricted_admin_entry.dig("access", 0)["permission"] = "read-only"
expect_role_rejection(failures, "restricted ntfy administrator ACL", restricted_admin,
                      restricted_admin_entry.dig("access", 0, "topic"))

jellyfin_secret = duplicate(runtime_vault)
jellyfin_secret.dig("vault_managed_users", "jellyfin", 0, "policy")["Password"] =
  "jellyfin-secret-sentinel"
expect_role_rejection(failures, "secret-bearing Jellyfin policy", jellyfin_secret,
                      "jellyfin-secret-sentinel")

duplicate_token = duplicate(runtime_vault)
shared_token = "tk_33333333333333333333333333333"
duplicate_token.dig("vault_managed_users", "ntfy", 0, "tokens") << shared_token
second_ntfy = duplicate(duplicate_token.dig("vault_managed_users", "ntfy", 0))
second_ntfy["username"] = "second-reader-example-invalid"
duplicate_token.dig("vault_managed_users", "ntfy") << second_ntfy
expect_role_rejection(failures, "cross-user duplicate ntfy token", duplicate_token, shared_token)

publisher_collision = duplicate(runtime_vault)
publisher_token = publisher_collision.fetch("vault_ntfy_dozzle_token")
publisher_collision.dig("vault_managed_users", "ntfy", 0, "tokens") << publisher_token
expect_role_rejection(failures, "ntfy publisher token collision", publisher_collision, publisher_token)

expect_role_rejection(
  failures,
  "unknown Immich preference profile",
  runtime_vault,
  "unknown-profile-sentinel",
  "immich_managed_user_preference_profile_default" => "unknown-profile-sentinel"
)

expect_role_rejection(
  failures,
  "preference override for unmanaged Immich email",
  runtime_vault,
  "unmanaged-preference@example.invalid",
  "immich_managed_user_preference_overrides" => {
    "unmanaged-preference@example.invalid" => { "albums" => { "defaultAssetOrder" => "asc" } }
  }
)

managed_immich_email = runtime_vault.dig("vault_managed_users", "immich", 0, "email")
normalized_collision_email = " #{managed_immich_email.upcase} "
expect_role_rejection(
  failures,
  "normalized Immich preference profile selector collision",
  runtime_vault,
  normalized_collision_email,
  "immich_managed_user_preference_profile_by_email" => {
    managed_immich_email => "standard",
    normalized_collision_email => "standard"
  }
)

expect_role_rejection(
  failures,
  "normalized Immich preference override collision",
  runtime_vault,
  normalized_collision_email,
  "immich_managed_user_preference_overrides" => {
    managed_immich_email => { "albums" => { "defaultAssetOrder" => "desc" } },
    normalized_collision_email => { "albums" => { "defaultAssetOrder" => "asc" } }
  }
)

expect_role_rejection(
  failures,
  "Immich administrator preference field",
  runtime_vault,
  managed_immich_email,
  "immich_managed_user_preference_overrides" => {
    managed_immich_email => { "isAdmin" => true }
  }
)

expect_role_rejection(
  failures,
  "unknown Immich preference schema field",
  runtime_vault,
  "unsupported-preference-sentinel",
  "immich_managed_user_preference_overrides" => {
    managed_immich_email => { "albums" => { "unsupported-preference-sentinel" => true } }
  }
)

empty_avatar_preferences = {
  "immich_managed_user_preference_profiles" => { "empty-avatar" => { "avatar" => {} } },
  "immich_managed_user_preference_profile_default" => "empty-avatar",
  "immich_managed_user_preference_profile_by_email" => {},
  "immich_managed_user_preference_overrides" => {}
}
_stdout, _stderr, empty_avatar_status = validate_with_role(runtime_vault, empty_avatar_preferences)
check(failures, empty_avatar_status.success?, "empty Immich avatar scope must remain unowned and valid")

expect_role_rejection(
  failures,
  "unsupported Immich avatar color",
  runtime_vault,
  "cyan-avatar-sentinel",
  "immich_managed_user_preference_profiles" => {
    "invalid-avatar" => { "avatar" => { "color" => "cyan-avatar-sentinel" } }
  },
  "immich_managed_user_preference_profile_default" => "invalid-avatar",
  "immich_managed_user_preference_profile_by_email" => {},
  "immich_managed_user_preference_overrides" => {}
)

if failures.empty?
  puts "Managed-user vault: all eight service schemas are valid"
else
  failures.each { |failure| warn "FAIL #{failure}" }
  abort "#{failures.length} managed-user vault violation(s)"
end
