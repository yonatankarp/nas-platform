#!/usr/bin/env ruby
# frozen_string_literal: true

require "open3"
require "tmpdir"
require "yaml"
require "fileutils"

require_relative "nas_storage_support"
require_relative "policy_support"

include TestScaffold

VAULT_PATH = File.join(ROOT, "inventory", "group_vars", "all", "vault.yml.example")
SPEC_PATH = File.join(ROOT, "roles", "vault_contract", "meta", "argument_specs.yml")
TASKS_PATH = File.join(ROOT, "roles", "vault_contract", "tasks", "main.yml")
GENERATOR_PATH = File.join(ROOT, "tests", "generate-ephemeral-vault.sh")
DOCS_PATH = File.join(ROOT, "docs", "secrets.md")
POLICY_SUPPORT_PATH = File.join(ROOT, "tests", "policy_support.rb")
VALIDATE_POLICY_PATH = File.join(ROOT, "tests", "validate-policy.sh")
PLAIN_TEMPLATE_PATH = File.join(ROOT, "templates", "vault-plain.yml.j2")
# The non-secret inventory is a directory now, and the Immich preference keys
# this reads live in service_immich.yml with the rest of that service.

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
  "paperless_ngx" => %w[username password email is_active is_staff is_superuser groups]
}.freeze

IDENTITY_FIELDS = {
  "audiobookshelf" => "username",
  "beszel" => "email",
  "dozzle" => "username",
  "immich" => "email",
  "jellyfin" => "username",
  "komga" => "email",
  "paperless_ngx" => "username"
}.freeze

TEXT_FIELDS = {
  "audiobookshelf" => %w[username password type],
  "beszel" => %w[email password role],
  "dozzle" => %w[username password password_hash email name filter roles],
  "immich" => %w[email password name],
  "jellyfin" => %w[username password],
  "komga" => %w[email password],
  "paperless_ngx" => %w[username password email]
}.freeze

BCRYPT = /^\$2[aby]\$\d{2}\$[.\/A-Za-z0-9]{53}$/

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
    "name" => ["str", nil], "quota_size" => ["raw", nil]
  },
  "jellyfin" => {
    "username" => ["str", nil], "password" => ["str", nil],
    "policy" => ["dict", nil]
  },
  "komga" => {
    "email" => ["str", nil], "password" => ["str", nil],
    "roles" => ["list", "str"]
  },
  "paperless_ngx" => {
    "username" => ["str", nil], "password" => ["str", nil],
    "email" => ["str", nil], "is_active" => ["bool", nil],
    "is_staff" => ["bool", nil], "is_superuser" => ["bool", nil],
    "groups" => ["list", "str"]
  }
}.freeze

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
    shared_vars = NasStorage.shared_inventory(ROOT)
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
%w[
  vault_jellyfin_opensubtitles_username vault_jellyfin_opensubtitles_password
  vault_kapowarr_comicvine_api_key
  vault_pushover_alerts_token vault_pushover_containers_token
  vault_pushover_deployments_token vault_pushover_media_token
  vault_pushover_user_key
].each do |key|
  check(failures, vault[key].is_a?(String) && !vault[key].empty?,
        "vault example must declare #{key}")
end
MANAGED_LIST_KEYS = ENTRY_FIELDS.keys.to_h { |service| [service, "vault_managed_#{service}_users"] }.freeze
check(failures, vault.keys.grep(/\Avault_managed_/).sort == MANAGED_LIST_KEYS.values.sort,
      "vault example managed-user list variables differ")
managed = MANAGED_LIST_KEYS.select { |_service, key| vault.key?(key) }
                           .transform_values { |key| vault[key] }

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
  # null is Immich's own representation of an unlimited quota and the only value
  # that lifts the limit; 0 is its opposite and refuses every non-empty upload.
  quota = entry["quota_size"]
  check(failures, quota.nil? || (quota.is_a?(Integer) && quota >= 0),
        "immich quota_size must be a non-negative integer or null")
  check(failures, quota != 0,
        "immich quota_size must not be 0, which rejects every upload")
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

spec = load_mapping(SPEC_PATH, failures, "vault argument spec")
spec_options = spec.dig("argument_specs", "main", "options")
spec_options = {} unless spec_options.is_a?(Hash)
check(failures, spec_options.keys.grep(/\Avault_managed_/).sort == MANAGED_LIST_KEYS.values.sort,
      "vault argument spec managed-user list options differ")
managed_options = MANAGED_LIST_KEYS.transform_values { |key| spec_options[key] }
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
immich_fields = managed_options.is_a?(Hash) ?
  managed_options.dig("immich", "options")&.keys&.sort : nil
check(failures, immich_fields == %w[email name password quota_size],
      "Immich preference policy must not enter the encrypted user records")

vault_options = spec.dig("argument_specs", "main", "options") || {}
%w[
  vault_jellyfin_opensubtitles_username vault_jellyfin_opensubtitles_password
  vault_kapowarr_comicvine_api_key
  vault_pushover_alerts_token vault_pushover_containers_token
  vault_pushover_deployments_token vault_pushover_media_token
  vault_pushover_user_key
].each do |key|
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

# The seven lists are group_vars of their own now, authored in each service's
# vault_<role>.yml, so the role publishes nothing: it assembles them inward into
# the one mapping the schema filter reads. Each has to be submitted under its own
# service, because a list the mapping omits is a list nothing validates -- the
# filter reports it missing only for as long as its rule table still names it.
submitted_lists = parsed_tasks.filter_map do |task|
  task.dig("ansible.builtin.set_fact", "vault_contract_schema_errors")
end.first.to_s
MANAGED_LIST_KEYS.each do |service, key|
  check(failures, submitted_lists.match?(/'#{Regexp.escape(service)}': #{Regexp.escape(key)}\b/),
        "vault contract must submit #{key} for schema validation")
end
# The other direction. Argument validation requires the seven names and says
# nothing about a ninth, so a leftover vault_managed_users from an un-migrated
# vault, or a misspelt list, would otherwise load, go unread and validate. The
# floor asks Ansible which vault_managed_ names are in scope and refuses any the
# contract does not name, before the schema is resolved.
floor_task = parsed_tasks.find do |task|
  task["name"] == "Refuse managed-user variables the contract does not name"
end
floor_expression = floor_task.to_h.dig("vars", "vault_contract_unexpected_managed_lists").to_s
check(failures,
      floor_expression.include?("q('varnames', '^vault_managed_')") &&
        MANAGED_LIST_KEYS.values.all? { |key| floor_expression.include?("'#{key}'") } &&
        floor_task.to_h.dig("ansible.builtin.assert", "that").to_a ==
          ["vault_contract_unexpected_managed_lists | length == 0"],
      "vault contract must refuse vault_managed_ variables outside the seven lists")
floor_position = parsed_tasks.index(floor_task)
validation_position = parsed_tasks.index do |task|
  task["name"] == "Resolve managed-user vault schema violations"
end
check(failures, floor_position && validation_position && floor_position < validation_position,
      "the unexpected managed-user variable floor must precede schema validation")
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
  "Paperless groups" => 'string_list(errors, f"{path}.groups"'
}.each do |label, declaration|
  check(failures, schema_filter_source.include?(declaration),
        "#{label} elements must have runtime string guards")
end
check(failures, schema_filter_source.include?('errors.append(f"{path}.policy: every key must be a string")'),
      "Jellyfin policy keys must have runtime string guards")
check(failures, schema_filter_source.match?(/in JELLYFIN_FORBIDDEN_POLICY_FIELDS\b/),
      "vault contract must reject secret-bearing Jellyfin policy keys")
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
scalar_vault_keys = vault_options.keys.grep(/\Avault_/) - MANAGED_LIST_KEYS.values
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
# ComicVine issues its key to a human account, so the platform cannot generate
# one either. Its stand-in is refused for the same reason: a Kapowarr holding it
# can identify nothing it downloads.
check(failures,
      credential_filter_source.match?(
        /"vault_kapowarr_comicvine_api_key": \(\n\s*\(NONEMPTY, None\),/
      ) &&
        credential_filter_source.include?('"example-comicvine-api-key"') &&
        credential_filter_source.include?(
          "(NOT_PLACEHOLDER, COMICVINE_API_KEY_PLACEHOLDERS)"
        ),
      "vault contract must reject the documented ComicVine placeholder")
# Pushover issues the user key and all four application tokens to a human
# account as well, and each token is the one a publisher sends with. A stand-in
# that reached a deployment would leave that publisher sending messages Pushover
# rejects, with nothing on this platform observing the rejection -- the
# OpenSubtitles failure mode exactly. Each name is checked in both its places, the rule and the literal, so
# a rule that loses its NOT_PLACEHOLDER clause fails here rather than quietly
# admitting the example file.
{ "vault_pushover_alerts_token" => %w[PUSHOVER_ALERTS_TOKEN_PLACEHOLDERS example-pushover-alerts-token],
  "vault_pushover_containers_token" =>
    %w[PUSHOVER_CONTAINERS_TOKEN_PLACEHOLDERS example-pushover-containers-token],
  "vault_pushover_deployments_token" =>
    %w[PUSHOVER_DEPLOYMENTS_TOKEN_PLACEHOLDERS example-pushover-deployments-token],
  "vault_pushover_media_token" =>
    %w[PUSHOVER_MEDIA_TOKEN_PLACEHOLDERS example-pushover-media-token],
  "vault_pushover_user_key" =>
    %w[PUSHOVER_USER_KEY_PLACEHOLDERS example-pushover-user-key] }.each do |key, (constant, literal)|
  check(failures,
        credential_filter_source.match?(
          /"#{Regexp.escape(key)}": \(\n\s*\(NONEMPTY, None\),/
        ) &&
          credential_filter_source.include?("\"#{literal}\"") &&
          credential_filter_source.include?("(NOT_PLACEHOLDER, #{constant})"),
        "vault contract must reject the documented #{key} placeholder")
end

generator = File.file?(GENERATOR_PATH) ? File.read(GENERATOR_PATH) : ""
MANAGED_LIST_KEYS.each do |service, key|
  check(failures, generator.match?(/^#{Regexp.escape(key)}:\n  - /),
        "ephemeral generator must include a synthetic #{service} entry")
end

policy = File.file?(POLICY_SUPPORT_PATH) ? File.read(POLICY_SUPPORT_PATH) : ""
# The eight lists stay in the policy source rather than in
# tests/expected/<service>.yml, for the reason GLOBAL_VAULT_KEYS states: their names
# invert the per-service prefix that file's entries must carry. The Pushover keys
# share the list, so this pin asserts membership rather than the list's whole
# contents; GLOBAL_VAULT_KEYS is concatenated into EXPECTED_VAULT_KEYS, so pinning
# it here still pins the full expected set.
global_vault_keys = policy[/GLOBAL_VAULT_KEYS = %w\[([^\]]*)\]\.freeze/m, 1].to_s.split
MANAGED_LIST_KEYS.each_value do |key|
  check(failures, global_vault_keys.include?(key),
        "policy expected vault keys must include #{key}")
end
plain_template = File.file?(PLAIN_TEMPLATE_PATH) ? File.read(PLAIN_TEMPLATE_PATH) : ""
# The template as a whole is Jinja, but this block carries no substitutions, so
# the lines the template writes for the eight lists are parsed as the mapping
# they will be. An exact string would also pin the key order, which YAML does not
# make meaningful, and would be satisfied by the same eight lines in a comment.
managed_block = plain_template.lines.grep(/\Avault_managed_[a-z_]+:/)
managed_defaults = begin
  YAML.safe_load(managed_block.join)
rescue Psych::SyntaxError
  nil
end
check(failures,
      managed_defaults == MANAGED_LIST_KEYS.values.to_h { |key| [key, []] },
      "brand-new vault template must render eight empty managed-user lists")
validate_policy = File.file?(VALIDATE_POLICY_PATH) ? File.read(VALIDATE_POLICY_PATH) : ""
check(failures, validate_policy.lines.include?("ruby tests/managed_users_vault_test.rb\n"),
      "policy validation must run the managed-user vault test")

docs = File.file?(DOCS_PATH) ? File.read(DOCS_PATH) : ""
check(failures, !docs.include?("vault_managed_users"),
      "secrets guide must not document the retired vault_managed_users mapping")
ENTRY_FIELDS.each do |service, fields|
  service_section = docs.match(/^#### #{Regexp.escape(service)} managed users\n(.*?)(?=^#### |^### |^## |\z)/m)&.[](1).to_s
  check(failures, !service_section.empty?, "secrets guide must document #{service} managed users")
  check(failures, service_section.include?("`#{MANAGED_LIST_KEYS.fetch(service)}`"),
        "secrets guide must name #{MANAGED_LIST_KEYS.fetch(service)} in the #{service} section")
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
runtime_vault["vault_kapowarr_comicvine_api_key"] = "runtime-comicvine-api-key"
runtime_vault["vault_pushover_alerts_token"] = "runtime-pushover-alerts-token"
runtime_vault["vault_pushover_containers_token"] = "runtime-pushover-containers-token"
runtime_vault["vault_pushover_deployments_token"] = "runtime-pushover-deployments-token"
runtime_vault["vault_pushover_media_token"] = "runtime-pushover-media-token"
runtime_vault["vault_pushover_user_key"] = "runtime-pushover-user-key"
runtime_vault["vault_healthchecks_poller_ping_url"] = "https://hc-ping.invalid/runtime-poller"
runtime_vault["vault_healthchecks_verify_ping_url"] = "https://hc-ping.invalid/runtime-verify"
# The relay token is documented as a stand-in the contract refuses, for the same
# reason those five are: it is a value that would otherwise deploy. So the
# runtime vault has to replace it too, or this whole block would be measuring
# that refusal rather than what it means to measure.
runtime_vault["vault_dozzle_alert_relay_token"] = "b" * 64
_stdout, _stderr, valid_status = validate_with_role(runtime_vault)
check(failures, valid_status.success?, "vault example with runtime integrations must pass role evaluation")
expect_role_rejection(failures, "documented OpenSubtitles placeholders", vault,
                      "example-opensubtitles-password")
# Only the ComicVine half is left documented, so the refusal is attributable to
# it rather than to the OpenSubtitles pair above.
comicvine_placeholder = duplicate(runtime_vault)
comicvine_placeholder["vault_kapowarr_comicvine_api_key"] =
  vault["vault_kapowarr_comicvine_api_key"]
expect_role_rejection(failures, "documented ComicVine placeholder", comicvine_placeholder,
                      "runtime-opensubtitles-password")
# One Pushover key at a time, for the same attribution reason: with the others
# runtime-valued, a refusal can only be this one. All five are exercised because
# the rules are separate entries carrying separate placeholder tuples, and a key
# checked only through another's rule would let its own lose its clause.
{ "vault_pushover_alerts_token" => "documented Pushover Alerts application token placeholder",
  "vault_pushover_containers_token" => "documented Pushover Containers application token placeholder",
  "vault_pushover_deployments_token" => "documented Pushover Deployments application token placeholder",
  "vault_pushover_media_token" => "documented Pushover Media application token placeholder",
  "vault_pushover_user_key" => "documented Pushover user key placeholder" }.each do |key, label|
  pushover_placeholder = duplicate(runtime_vault)
  pushover_placeholder[key] = vault[key]
  expect_role_rejection(failures, label, pushover_placeholder, "runtime-opensubtitles-password")
end
# The healthchecks.io ping URLs the same way, one at a time and through the role,
# plus the one refusal their pair adds: a single URL in both places.
%w[vault_healthchecks_poller_ping_url vault_healthchecks_verify_ping_url].each do |key|
  healthchecks_placeholder = duplicate(runtime_vault)
  healthchecks_placeholder[key] = vault[key]
  expect_role_rejection(failures, "documented #{key} placeholder", healthchecks_placeholder,
                        "runtime-poller")
end
shared_ping_url = duplicate(runtime_vault)
shared_ping_url["vault_healthchecks_verify_ping_url"] =
  shared_ping_url["vault_healthchecks_poller_ping_url"]
expect_role_rejection(failures, "one healthchecks.io ping URL for both checks", shared_ping_url,
                      "runtime-poller")

empty_immich = duplicate(runtime_vault)
empty_immich.dig("vault_managed_immich_users").clear
expect_role_rejection(failures, "missing Immich family account", empty_immich,
                      runtime_vault.fetch("vault_immich_admin_email"))

wrong_type = duplicate(runtime_vault)
wrong_type.dig("vault_managed_audiobookshelf_users", 0)["permissions"] = ["wrong-type-sentinel"]
expect_role_rejection(failures, "wrong nested field type", wrong_type, "wrong-type-sentinel")

disabled_audiobookshelf = duplicate(runtime_vault)
disabled_audiobookshelf.dig("vault_managed_audiobookshelf_users", 0)["is_active"] = false
expect_role_rejection(failures, "disabled Audiobookshelf target", disabled_audiobookshelf,
                      "example-reader-password")

unverified_beszel = duplicate(runtime_vault)
unverified_beszel.dig("vault_managed_beszel_users", 0)["verified"] = false
expect_role_rejection(failures, "unverified Beszel target", unverified_beszel,
                      "example-reader-password")

disabled_jellyfin = duplicate(runtime_vault)
disabled_jellyfin.dig("vault_managed_jellyfin_users", 0, "policy")["IsDisabled"] = true
expect_role_rejection(failures, "disabled Jellyfin target", disabled_jellyfin,
                      "example-reader-password")

unsupported_abs_permission = duplicate(runtime_vault)
unsupported_abs_permission.dig("vault_managed_audiobookshelf_users", 0)["permissions"] = {
  "flags" => { "libraries" => true }, "librariesAccessible" => [], "itemTagsSelected" => []
}
expect_role_rejection(failures, "unsupported Audiobookshelf permission", unsupported_abs_permission,
                      "libraries")

invalid_komga_role = duplicate(runtime_vault)
invalid_komga_role.dig("vault_managed_komga_users", 0)["roles"] = ["OPDS"]
expect_role_rejection(failures, "unsupported Komga OPDS role", invalid_komga_role, "OPDS")

koreader_komga_role = duplicate(runtime_vault)
koreader_komga_role.dig("vault_managed_komga_users", 0)["roles"] = ["KOREADER_SYNC"]
_stdout, _stderr, koreader_status = validate_with_role(koreader_komga_role)
check(failures, koreader_status.success?, "Komga KOREADER_SYNC must pass actual role evaluation")

# The argument spec runs before any task, so a schema that accepts null is not
# enough on its own: `type: int` rejected an explicit null outright and failed
# the run before vault_managed_user_errors was ever reached. Only role
# evaluation proves the whole path accepts an unlimited quota.
unlimited_immich_quota = duplicate(runtime_vault)
unlimited_immich_quota.dig("vault_managed_immich_users", 0)["quota_size"] = nil
_stdout, _stderr, unlimited_status = validate_with_role(unlimited_immich_quota)
check(failures, unlimited_status.success?,
      "unlimited Immich quota must pass actual role evaluation")

# `type: raw` buys that null, at the cost of the coercion `type: int` performed.
# The schema filter is what refuses a non-integer now, so prove it still does
# through the role rather than in isolation.
string_immich_quota = duplicate(runtime_vault)
string_immich_quota.dig("vault_managed_immich_users", 0)["quota_size"] = "1073741824"
expect_role_rejection(failures, "string Immich quota", string_immich_quota,
                      "example-reader-password")

integer_username = duplicate(runtime_vault)
integer_username.dig("vault_managed_audiobookshelf_users", 0)["username"] = 424_242
expect_role_rejection(failures, "integer audiobookshelf username", integer_username, "424242")

list_password = duplicate(runtime_vault)
list_password.dig("vault_managed_audiobookshelf_users", 0)["password"] =
  ["list-password-sentinel"]
expect_role_rejection(failures, "list audiobookshelf password", list_password,
                      "list-password-sentinel")

list_dozzle_email = duplicate(runtime_vault)
list_dozzle_email.dig("vault_managed_dozzle_users", 0)["email"] =
  ["list-email-sentinel"]
expect_role_rejection(failures, "list Dozzle email", list_dozzle_email,
                      "list-email-sentinel")

list_dozzle_name = duplicate(runtime_vault)
list_dozzle_name.dig("vault_managed_dozzle_users", 0)["name"] =
  ["list-name-sentinel"]
expect_role_rejection(failures, "list Dozzle name", list_dozzle_name,
                      "list-name-sentinel")

jellyfin_secret = duplicate(runtime_vault)
jellyfin_secret.dig("vault_managed_jellyfin_users", 0, "policy")["Password"] =
  "jellyfin-secret-sentinel"
expect_role_rejection(failures, "secret-bearing Jellyfin policy", jellyfin_secret,
                      "jellyfin-secret-sentinel")

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

managed_immich_email = runtime_vault.dig("vault_managed_immich_users", 0, "email")
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

report(failures, "Managed-user vault: all seven service schemas are valid",
       "managed-user vault violation(s)")
