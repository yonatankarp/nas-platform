#!/usr/bin/env ruby
# frozen_string_literal: true

require "yaml"

ROOT = File.expand_path("..", __dir__)
VAULT_PATH = File.join(ROOT, "inventory", "group_vars", "all", "vault.yml.example")
SPEC_PATH = File.join(ROOT, "roles", "vault_contract", "meta", "argument_specs.yml")
TASKS_PATH = File.join(ROOT, "roles", "vault_contract", "tasks", "main.yml")
GENERATOR_PATH = File.join(ROOT, "tests", "generate-ephemeral-vault.sh")
DOCS_PATH = File.join(ROOT, "docs", "secrets.md")

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

BCRYPT = /^\$2[aby]\$\d{2}\$[.\/A-Za-z0-9]{53}$/
TOKEN = /^tk_[a-z0-9]{29}$/

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
  check(failures, [true, false].include?(entry["is_active"]),
        "audiobookshelf is_active must be boolean")
  check(failures, entry["permissions"].is_a?(Hash),
        "audiobookshelf permissions must be a mapping")
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
end

managed.fetch("komga", []).each do |entry|
  next unless entry.is_a?(Hash)
  roles = entry["roles"]
  supported = %w[ADMIN FILE_DOWNLOAD PAGE_STREAMING KOBO_SYNC OPDS]
  check(failures, roles.is_a?(Array) && !roles.empty? && (roles - supported).empty?,
        "komga roles must be supported")
end

managed.fetch("ntfy", []).each do |entry|
  next unless entry.is_a?(Hash)
  check(failures, BCRYPT.match?(entry["password_hash"].to_s),
        "ntfy password_hash must have bcrypt shape")
  check(failures, %w[user admin].include?(entry["role"]), "ntfy role must be supported")
  access = entry["access"]
  check(failures,
        access.is_a?(Array) && access.all? do |rule|
          rule.is_a?(Hash) && rule.keys.sort == %w[permission topic] &&
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

tasks = File.file?(TASKS_PATH) ? File.read(TASKS_PATH) : ""
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
  "difference(['ADMIN', 'FILE_DOWNLOAD', 'PAGE_STREAMING', 'KOBO_SYNC', 'OPDS'])"
]
required_validation_fragments.each do |fragment|
  check(failures, tasks.include?(fragment),
        "vault contract validation is missing #{fragment}")
end

generator = File.file?(GENERATOR_PATH) ? File.read(GENERATOR_PATH) : ""
check(failures, generator.include?("vault_managed_users:"),
      "ephemeral generator must include vault_managed_users")
ENTRY_FIELDS.each_key do |service|
  check(failures, generator.match?(/^  #{Regexp.escape(service)}:\n    - /),
        "ephemeral generator must include a synthetic #{service} entry")
end

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

if failures.empty?
  puts "Managed-user vault: all eight service schemas are valid"
else
  failures.each { |failure| warn "FAIL #{failure}" }
  abort "#{failures.length} managed-user vault violation(s)"
end
