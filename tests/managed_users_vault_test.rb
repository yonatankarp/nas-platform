#!/usr/bin/env ruby
# frozen_string_literal: true

require "open3"
require "tmpdir"
require "yaml"

ROOT = File.expand_path("..", __dir__)
VAULT_PATH = File.join(ROOT, "inventory", "group_vars", "all", "vault.yml.example")
SPEC_PATH = File.join(ROOT, "roles", "vault_contract", "meta", "argument_specs.yml")
TASKS_PATH = File.join(ROOT, "roles", "vault_contract", "tasks", "main.yml")
GENERATOR_PATH = File.join(ROOT, "tests", "generate-ephemeral-vault.sh")
DOCS_PATH = File.join(ROOT, "docs", "secrets.md")
POLICY_PATH = File.join(ROOT, "tests", "policy_test.rb")
VALIDATE_POLICY_PATH = File.join(ROOT, "tests", "validate-policy.sh")
PLAIN_TEMPLATE_PATH = File.join(ROOT, "templates", "vault-plain.yml.j2")

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

def validate_with_role(document)
  Dir.mktmpdir("nas-platform-managed-users-vault-") do |directory|
    path = File.join(directory, "vault.yml")
    File.write(path, YAML.dump(document), mode: "w", perm: 0o600)
    Open3.capture3(
      { "ANSIBLE_NOCOLOR" => "1" },
      "ansible-playbook", File.join(ROOT, "validate-vault.yml"), "-e", "@#{path}",
      chdir: ROOT
    )
  end
end

def expect_role_rejection(failures, label, document, forbidden_value)
  stdout, stderr, status = validate_with_role(document)
  check(failures, !status.success?, "#{label} must be rejected by vault role evaluation")
  output = stdout + stderr
  check(failures, !output.include?(forbidden_value), "#{label} diagnostic disclosed a managed-user value")
end

failures = []
vault = load_mapping(VAULT_PATH, failures, "vault example")
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
  check(failures, [true, false].include?(entry["verified"]), "beszel verified must be boolean")
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
  check(failures, %w[user admin].include?(entry["role"]), "ntfy role must be supported")
  check(failures, NTFY_USERNAME.match?(entry["username"].to_s),
        "ntfy username must use native safe characters")
  access = entry["access"]
  check(failures,
        access.is_a?(Array) && access.all? do |rule|
          rule.is_a?(Hash) && rule.keys.sort == %w[permission topic] &&
            NTFY_LITERAL_TOPIC.match?(rule["topic"].to_s) &&
            %w[read-only write-only read-write deny].include?(rule["permission"]) &&
            (entry["role"] != "admin" || rule["permission"] == "read-write")
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

tasks = File.file?(TASKS_PATH) ? File.read(TASKS_PATH) : ""
parsed_tasks = File.file?(TASKS_PATH) ? YAML.safe_load_file(TASKS_PATH, aliases: false) : []
facts = ENTRY_FIELDS.keys.map { |service| "vault_managed_#{service}_users" }
facts.each do |fact|
  check(failures, tasks.include?("#{fact}:"), "vault contract must publish named fact #{fact}")
end
validation_position = tasks.index("Validate managed-user service keys")
facts_position = tasks.index("Resolve validated managed-user service lists")
check(failures, validation_position && facts_position && validation_position < facts_position,
      "managed-user validation must precede named facts")
check(failures, tasks.scan(/name: .*managed-user/i).length >= 3 &&
                  tasks.scan(/no_log: true/).length >= 4,
      "managed-user validation must use no_log redaction")
ENTRY_FIELDS.each_key do |service|
  check(failures, tasks.include?("#{service} managed user has invalid"),
        "#{service} validation must use a value-free field diagnostic")
end
required_validation_fragments = [
  "item.keys() | list | sort",
  "map('trim') | map('lower') | list | unique",
  "vault_audiobookshelf_admin_username",
  "vault_beszel_superuser_email",
  "vault_beszel_app_user_email",
  "vault_dozzle_admin_username",
  "vault_immich_admin_email",
  "vault_jellyfin_admin_username",
  "vault_komga_admin_email",
  "vault_ntfy_admin_user",
  "vault_paperless_admin_username",
  "'dozzle' not in vault_managed_users.ntfy",
  "'beszel' not in vault_managed_users.ntfy",
  "item.password | length > 0",
  "item.password_hash is match",
  "item.type in ['admin', 'user', 'guest']",
  "item.role in ['user', 'admin']",
  "difference(['ADMIN', 'FILE_DOWNLOAD', 'PAGE_STREAMING', 'KOBO_SYNC', 'KOREADER_SYNC'])"
]
required_validation_fragments.each do |fragment|
  check(failures, tasks.include?(fragment),
        "vault contract validation is missing #{fragment}")
end
TEXT_FIELDS.each do |service, fields|
  task = parsed_tasks.find { |entry| entry["name"] == "Validate #{service} managed-user entries" }
  conditions = Array(task&.dig("ansible.builtin.assert", "that"))
  fields.each do |field|
    check(failures, conditions.include?("item.#{field} is string"),
          "#{service}.#{field} must have an explicit runtime string guard")
  end
end
{
  "Komga roles" => "item.roles | reject('string') | list | length == 0",
  "ntfy tokens" => "item.tokens | reject('string') | list | length == 0",
  "Paperless groups" => "item.groups | reject('string') | list | length == 0"
}.each do |label, condition|
  check(failures, tasks.include?(condition), "#{label} elements must have runtime string guards")
end
check(failures, tasks.include?("item.policy.keys() | reject('string') | list | length == 0"),
      "Jellyfin policy keys must have runtime string guards")
check(failures,
      tasks.include?("item.1.topic is string") && tasks.include?("item.1.permission is string"),
      "ntfy access fields must have runtime string guards")
check(failures, tasks.include?("forbidden_jellyfin_policy_fields"),
      "vault contract must reject secret-bearing Jellyfin policy keys")
check(failures, tasks.include?("vault_contract_managed_ntfy_tokens") &&
                tasks.include?("vault_ntfy_dozzle_token") && tasks.include?("vault_ntfy_beszel_token"),
      "vault contract must enforce global ntfy token uniqueness and publisher separation")

generator = File.file?(GENERATOR_PATH) ? File.read(GENERATOR_PATH) : ""
check(failures, generator.include?("vault_managed_users:"),
      "ephemeral generator must include vault_managed_users")
ENTRY_FIELDS.each_key do |service|
  check(failures, generator.match?(/^  #{Regexp.escape(service)}:\n    - /),
        "ephemeral generator must include a synthetic #{service} entry")
end

policy = File.file?(POLICY_PATH) ? File.read(POLICY_PATH) : ""
check(failures, policy.match?(/EXPECTED_VAULT_KEYS = %w\[.*?vault_managed_users.*?\]\.sort\.freeze/m),
      "policy expected vault keys must include vault_managed_users")
plain_template = File.file?(PLAIN_TEMPLATE_PATH) ? File.read(PLAIN_TEMPLATE_PATH) : ""
empty_lists = ENTRY_FIELDS.keys.map { |service| "  #{service}: []" }.join("\n")
check(failures, plain_template.include?("vault_managed_users:\n#{empty_lists}"),
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
      docs.include?("validates bcrypt shape only") &&
        docs.include?("authenticates the plaintext password") &&
        docs.include?("compares the stored hash before mutation"),
      "secrets guide must state the deferred bcrypt pair verification boundary")

_stdout, _stderr, valid_status = validate_with_role(vault)
check(failures, valid_status.success?, "vault example must pass actual role evaluation")

wrong_type = duplicate(vault)
wrong_type.dig("vault_managed_users", "audiobookshelf", 0)["permissions"] = ["wrong-type-sentinel"]
expect_role_rejection(failures, "wrong nested field type", wrong_type, "wrong-type-sentinel")

disabled_audiobookshelf = duplicate(vault)
disabled_audiobookshelf.dig("vault_managed_users", "audiobookshelf", 0)["is_active"] = false
expect_role_rejection(failures, "disabled Audiobookshelf target", disabled_audiobookshelf,
                      "example-reader-password")

disabled_jellyfin = duplicate(vault)
disabled_jellyfin.dig("vault_managed_users", "jellyfin", 0, "policy")["IsDisabled"] = true
expect_role_rejection(failures, "disabled Jellyfin target", disabled_jellyfin,
                      "example-reader-password")

unsupported_abs_permission = duplicate(vault)
unsupported_abs_permission.dig("vault_managed_users", "audiobookshelf", 0)["permissions"] = {
  "flags" => { "libraries" => true }, "librariesAccessible" => [], "itemTagsSelected" => []
}
expect_role_rejection(failures, "unsupported Audiobookshelf permission", unsupported_abs_permission,
                      "libraries")

invalid_komga_role = duplicate(vault)
invalid_komga_role.dig("vault_managed_users", "komga", 0)["roles"] = ["OPDS"]
expect_role_rejection(failures, "unsupported Komga OPDS role", invalid_komga_role, "OPDS")

koreader_komga_role = duplicate(vault)
koreader_komga_role.dig("vault_managed_users", "komga", 0)["roles"] = ["KOREADER_SYNC"]
_stdout, _stderr, koreader_status = validate_with_role(koreader_komga_role)
check(failures, koreader_status.success?, "Komga KOREADER_SYNC must pass actual role evaluation")

integer_username = duplicate(vault)
integer_username.dig("vault_managed_users", "audiobookshelf", 0)["username"] = 424_242
expect_role_rejection(failures, "integer audiobookshelf username", integer_username, "424242")

list_password = duplicate(vault)
list_password.dig("vault_managed_users", "audiobookshelf", 0)["password"] =
  ["list-password-sentinel"]
expect_role_rejection(failures, "list audiobookshelf password", list_password,
                      "list-password-sentinel")

list_dozzle_email = duplicate(vault)
list_dozzle_email.dig("vault_managed_users", "dozzle", 0)["email"] =
  ["list-email-sentinel"]
expect_role_rejection(failures, "list Dozzle email", list_dozzle_email,
                      "list-email-sentinel")

list_dozzle_name = duplicate(vault)
list_dozzle_name.dig("vault_managed_users", "dozzle", 0)["name"] =
  ["list-name-sentinel"]
expect_role_rejection(failures, "list Dozzle name", list_dozzle_name,
                      "list-name-sentinel")

list_ntfy_topic = duplicate(vault)
list_ntfy_topic.dig("vault_managed_users", "ntfy", 0, "access", 0)["topic"] =
  ["list-topic-sentinel"]
expect_role_rejection(failures, "list ntfy access topic", list_ntfy_topic,
                      "list-topic-sentinel")

%w[bad,user bad:user bad/user].each do |username|
  hostile_username = duplicate(vault)
  hostile_username.dig("vault_managed_users", "ntfy", 0)["username"] = username
  expect_role_rejection(failures, "unsafe ntfy username", hostile_username, username)
end

["bad topic", "bad/topic", "bad*topic", "bad:topic", "bad,topic"].each do |topic|
  hostile_topic = duplicate(vault)
  hostile_topic.dig("vault_managed_users", "ntfy", 0, "access", 0)["topic"] = topic
  expect_role_rejection(failures, "unsafe ntfy literal topic", hostile_topic, topic)
end

restricted_admin = duplicate(vault)
restricted_admin_entry = restricted_admin.dig("vault_managed_users", "ntfy", 0)
restricted_admin_entry["role"] = "admin"
restricted_admin_entry.dig("access", 0)["permission"] = "read-only"
expect_role_rejection(failures, "restricted ntfy administrator ACL", restricted_admin,
                      restricted_admin_entry.dig("access", 0, "topic"))

jellyfin_secret = duplicate(vault)
jellyfin_secret.dig("vault_managed_users", "jellyfin", 0, "policy")["Password"] =
  "jellyfin-secret-sentinel"
expect_role_rejection(failures, "secret-bearing Jellyfin policy", jellyfin_secret,
                      "jellyfin-secret-sentinel")

duplicate_token = duplicate(vault)
shared_token = "tk_33333333333333333333333333333"
duplicate_token.dig("vault_managed_users", "ntfy", 0, "tokens") << shared_token
second_ntfy = duplicate(duplicate_token.dig("vault_managed_users", "ntfy", 0))
second_ntfy["username"] = "second-reader-example-invalid"
duplicate_token.dig("vault_managed_users", "ntfy") << second_ntfy
expect_role_rejection(failures, "cross-user duplicate ntfy token", duplicate_token, shared_token)

publisher_collision = duplicate(vault)
publisher_token = publisher_collision.fetch("vault_ntfy_dozzle_token")
publisher_collision.dig("vault_managed_users", "ntfy", 0, "tokens") << publisher_token
expect_role_rejection(failures, "ntfy publisher token collision", publisher_collision, publisher_token)

if failures.empty?
  puts "Managed-user vault: all eight service schemas are valid"
else
  failures.each { |failure| warn "FAIL #{failure}" }
  abort "#{failures.length} managed-user vault violation(s)"
end
