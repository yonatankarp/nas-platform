#!/usr/bin/env ruby
# frozen_string_literal: true

# Strict contract for the protected Portainer environment mapping. The mapping
# describes identifiers only; it must never contain exported values.

require "fileutils"
require "tmpdir"
require "yaml"
require_relative "policy_support"

ROOT = File.expand_path("..", __dir__)
MAPPING_PATH = File.join(ROOT, "config", "portainer-parity.yml")
MANIFEST_PATH = File.join(ROOT, "services", "manifest.yml")
SUCCESS = "Portainer parity mapping: all nine stacks are explicit"
LEGACY_COMMIT = "400f03f276ae1bb69f5460c175b9fb923d620f1a"
EXPECTED = {
  "audiobookshelf" => %w[TZ],
  "beszel" => %w[BESZEL_AGENT_KEY BESZEL_AGENT_TOKEN BESZEL_APP_URL BESZEL_SYSTEM_NAME TZ],
  "dozzle" => %w[TZ],
  "immich" => %w[DB_DATABASE_NAME DB_PASSWORD DB_USERNAME TZ],
  "jellyfin" => %w[TZ],
  "komga" => %w[GROUP_ID TZ USER_ID],
  "ntfy" => %w[GROUP_ID NTFY_BASE_URL TZ USER_ID],
  "paperless-ngx" => %w[
    DB_NAME DB_PASSWORD DB_USER GROUP_ID PAPERLESS_AI_ENABLED
    PAPERLESS_AI_LLM_ENDPOINT PAPERLESS_AI_LLM_MODEL PAPERLESS_SECRET_KEY
    PAPERLESS_TASK_WORKERS PAPERLESS_THREADS_PER_WORKER TZ USER_ID
  ],
  "tinymediamanager" => %w[GROUP_ID PASSWORD TZ USER_ID]
}.transform_values(&:sort).freeze
ALLOWED_CLASSIFICATIONS = %w[inventory vault role excluded].freeze
CANONICAL_RULES = {
  "audiobookshelf" => { "TZ" => ["inventory", "nas_timezone"] },
  "beszel" => {
    "BESZEL_AGENT_KEY" => ["vault", "vault_beszel_agent_key"],
    "BESZEL_AGENT_TOKEN" => ["vault", "vault_beszel_universal_token"],
    "BESZEL_APP_URL" => ["role", "beszel_app_url"],
    "BESZEL_SYSTEM_NAME" => ["role", "beszel_system_name"],
    "TZ" => ["inventory", "nas_timezone"]
  },
  "dozzle" => { "TZ" => ["inventory", "nas_timezone"] },
  "immich" => {
    "DB_DATABASE_NAME" => ["vault", "vault_immich_db_name"],
    "DB_PASSWORD" => ["vault", "vault_immich_db_password"],
    "DB_USERNAME" => ["vault", "vault_immich_db_username"],
    "TZ" => ["inventory", "nas_timezone"]
  },
  "jellyfin" => { "TZ" => ["inventory", "nas_timezone"] },
  "komga" => {
    "GROUP_ID" => ["inventory", "nas_gid"], "TZ" => ["inventory", "nas_timezone"], "USER_ID" => ["inventory", "nas_uid"]
  },
  "ntfy" => {
    "GROUP_ID" => ["inventory", "nas_gid"], "NTFY_BASE_URL" => ["role", "ntfy_base_url"],
    "TZ" => ["inventory", "nas_timezone"], "USER_ID" => ["inventory", "nas_uid"]
  },
  "paperless-ngx" => {
    "DB_NAME" => ["vault", "vault_paperless_db_name"], "DB_PASSWORD" => ["vault", "vault_paperless_db_password"],
    "DB_USER" => ["vault", "vault_paperless_db_username"], "GROUP_ID" => ["inventory", "nas_gid"],
    "PAPERLESS_AI_ENABLED" => ["role", "paperless_ai_enabled"],
    "PAPERLESS_AI_LLM_ENDPOINT" => ["role", "paperless_ai_llm_endpoint"],
    "PAPERLESS_AI_LLM_MODEL" => ["role", "paperless_ai_llm_model"],
    "PAPERLESS_SECRET_KEY" => ["vault", "vault_paperless_django_secret_key"],
    "PAPERLESS_TASK_WORKERS" => ["role", "paperless_task_workers"],
    "PAPERLESS_THREADS_PER_WORKER" => ["role", "paperless_threads_per_worker"],
    "TZ" => ["inventory", "nas_timezone"], "USER_ID" => ["inventory", "nas_uid"]
  },
  "tinymediamanager" => {
    "GROUP_ID" => ["inventory", "nas_gid"], "PASSWORD" => ["vault", "vault_tinymediamanager_password"],
    "TZ" => ["inventory", "nas_timezone"], "USER_ID" => ["inventory", "nas_uid"]
  }
}.freeze

def fail_contract(message)
  raise "Portainer parity mapping: #{message}"
end

def sanitize(value)
  value.to_s.gsub(/[[:cntrl:]]/, "?")
end

def mapping(value, label)
  fail_contract("#{label} must be a mapping") unless value.is_a?(Hash)

  value
end

def assert_yaml_unambiguous!(source, label)
  tree = Psych.parse_stream(source)
  duplicates = PolicySupport.duplicate_yaml_keys(tree)
  fail_contract("#{label} contains duplicate YAML keys") unless duplicates.empty?

  tree.each do |node|
    fail_contract("#{label} contains YAML aliases") if node.is_a?(Psych::Nodes::Alias) ||
                                                      (node.respond_to?(:anchor) && node.anchor)
  end
rescue Psych::Exception => error
  fail_contract("#{label} YAML is malformed (#{sanitize(error.message)})")
end

def load_yaml(path, label)
  source = File.binread(path)
  assert_yaml_unambiguous!(source, label)
  YAML.safe_load(source, aliases: false)
rescue Errno::ENOENT
  fail_contract("#{label} is missing")
rescue Psych::Exception => error
  fail_contract("#{label} YAML is malformed (#{sanitize(error.message)})")
end

def manifest_services
  document = mapping(load_yaml(MANIFEST_PATH, "service manifest"), "service manifest")
  services = document["services"]
  fail_contract("service manifest services must be a list") unless services.is_a?(Array)

  names = services.map do |entry|
    entry = mapping(entry, "service manifest entry")
    name = entry["name"]
    fail_contract("service manifest service name is invalid") unless name.is_a?(String) && !name.empty?

    name
  end
  fail_contract("service manifest has duplicate services") unless names.uniq.length == names.length
  fail_contract("service manifest services differ from protected stacks") unless names.sort == EXPECTED.keys.sort

  names
end

def vault_targets
  mapping(load_yaml(File.join(ROOT, "inventory/group_vars/all/vault.yml.example"), "vault example"), "vault example").keys
end

def inventory_targets
  mapping(load_yaml(File.join(ROOT, "inventory/group_vars/all/main.yml"), "inventory variables"), "inventory variables").keys
end

def role_target_exists?(stack, target)
  role = stack == "paperless-ngx" ? "paperless_ngx" : stack
  role_root = File.join(ROOT, "roles", role)
  return false unless File.directory?(role_root)

  role_variable_keys(role_root).include?(target) ||
    role_option_keys(role_root).include?(target) ||
    role_template_references?(role_root, target)
end

def role_variable_keys(role_root)
  %w[defaults vars].flat_map do |section|
    path = File.join(role_root, section, "main.yml")
    next [] unless File.file?(path) && !File.symlink?(path)

    mapping(load_yaml(path, "#{section} variables"), "#{section} variables").keys
  end
end

def role_option_keys(role_root)
  path = File.join(role_root, "meta", "argument_specs.yml")
  return [] unless File.file?(path) && !File.symlink?(path)

  specifications = mapping(load_yaml(path, "role argument specs"), "role argument specs")["argument_specs"]
  return [] unless specifications.is_a?(Hash)

  specifications.values.flat_map do |specification|
    next [] unless specification.is_a?(Hash)

    options = specification["options"]
    options.is_a?(Hash) ? options.keys : []
  end
end

def role_template_references?(role_root, target)
  expression = /\A\s*#{Regexp.escape(target)}(?:\s*(?:\||\z))/
  Dir.glob(File.join(role_root, "templates", "**", "*.j2")).any? do |path|
    next false if File.symlink?(path)

    source = File.binread(path).gsub(/\{#.*?#\}/m, "")
    source.scan(/\{\{(.*?)\}\}/m).any? { |content| content.first.match?(expression) }
  end
end

def expected_rule_fields(classification)
  classification == "excluded" ? %w[classification reason] : %w[classification target]
end

def validate_rule(stack, variable, rule, known_vault, known_inventory)
  rule = mapping(rule, "#{stack}.#{variable}")
  classification = rule["classification"]
  fail_contract("#{stack}.#{variable} has an invalid classification") unless ALLOWED_CLASSIFICATIONS.include?(classification)
  fail_contract("#{stack}.#{variable} has unexpected fields") unless rule.keys.sort == expected_rule_fields(classification)

  if classification == "excluded"
    reason = rule["reason"]
    fail_contract("#{stack}.#{variable} exclusion reason must be nonempty") unless reason.is_a?(String) && !reason.empty?
    fail_contract("#{stack}.#{variable} must not exclude an expected variable")
  end

  target = rule["target"]
  fail_contract("#{stack}.#{variable} target must be nonempty") unless target.is_a?(String) && !target.empty?
  case classification
  when "inventory"
    fail_contract("#{stack}.#{variable} references an unknown inventory target") unless known_inventory.include?(target)
  when "vault"
    fail_contract("#{stack}.#{variable} references an unknown vault target") unless known_vault.include?(target)
  when "role"
    fail_contract("#{stack}.#{variable} references an unknown role target") unless role_target_exists?(stack, target)
  end
end

def validate_mapping(path = MAPPING_PATH)
  document = mapping(load_yaml(path, "mapping"), "mapping")
  fail_contract("mapping root fields differ") unless document.keys.sort == %w[legacy_commit schema stacks]
  fail_contract("schema must equal 1") unless document["schema"] == 1
  fail_contract("legacy_commit differs") unless document["legacy_commit"] == LEGACY_COMMIT

  stacks = mapping(document["stacks"], "stacks")
  services = manifest_services
  fail_contract("stacks differ from service manifest") unless stacks.keys.sort == services.sort

  known_vault = vault_targets
  known_inventory = inventory_targets
  stacks.each do |stack, rules|
    rules = mapping(rules, "#{stack} rules")
    expected = EXPECTED.fetch(stack)
    fail_contract("#{stack} variables differ from protected exports") unless rules.keys.sort == expected
    rules.each do |variable, rule|
      validate_rule(stack, variable, rule, known_vault, known_inventory)
      classification, target = CANONICAL_RULES.fetch(stack).fetch(variable)
      fail_contract("#{stack}.#{variable} differs from the canonical mapping") unless rule == {
        "classification" => classification, "target" => target
      }
    end
  end
end

def mapping_source
  File.binread(MAPPING_PATH)
end

def mutate_mapping
  YAML.safe_load(mapping_source, aliases: false).tap { |document| yield document }.then { |document| YAML.dump(document) }
end

def assert_failure(label, source, message)
  Dir.mktmpdir("nas-platform-portainer-parity-") do |directory|
    path = File.join(directory, "portainer-parity.yml")
    File.binwrite(path, source)
    begin
      validate_mapping(path)
    rescue RuntimeError => error
      raise "#{label}: expected #{message.inspect}, got #{error.message.inspect}" unless error.message.include?(message)
      return
    end
    raise "#{label}: expected validation to fail"
  end
end

def with_fixture_root
  Dir.mktmpdir("nas-platform-portainer-role-target-") do |directory|
    original_root = Object.const_get(:ROOT)
    Object.send(:remove_const, :ROOT)
    Object.const_set(:ROOT, directory)
    yield directory
  ensure
    Object.send(:remove_const, :ROOT)
    Object.const_set(:ROOT, original_root)
  end
end

def write_role_fixture(root)
  role_root = File.join(root, "roles", "sample")
  FileUtils.mkdir_p(File.join(role_root, "defaults"))
  FileUtils.mkdir_p(File.join(role_root, "vars"))
  FileUtils.mkdir_p(File.join(role_root, "meta"))
  FileUtils.mkdir_p(File.join(role_root, "templates"))
  FileUtils.mkdir_p(File.join(root, "services", "sample"))
  File.write(File.join(role_root, "defaults", "main.yml"), <<~YAML)
    # yaml_comment_target
    literal_holder: yaml_literal_target
    declared_default_target: value
  YAML
  File.write(File.join(role_root, "vars", "main.yml"), "declared_var_target: value\n")
  File.write(File.join(role_root, "meta", "argument_specs.yml"), <<~YAML)
    argument_specs:
      main:
        options:
          declared_spec_target: {type: str}
  YAML
  File.write(File.join(role_root, "templates", "env.j2"), <<~JINJA)
    {# {{ template_comment_target }} #}
    DECLARED={{ declared_template_target | default('value') }}
    LITERAL=template_literal_target
  JINJA
  File.write(File.join(root, "services", "sample", "compose.yml"), "COMPOSE_ONLY_TARGET=value\n")
end

def assert_role_target(target, expected)
  actual = role_target_exists?("sample", target)
  raise "#{target}: expected role declaration #{expected}, got #{actual}" unless actual == expected
end

def self_test_role_targets
  with_fixture_root do |root|
    write_role_fixture(root)
    assert_role_target("yaml_comment_target", false)
    assert_role_target("yaml_literal_target", false)
    assert_role_target("template_comment_target", false)
    assert_role_target("template_literal_target", false)
    assert_role_target("compose_only_target", false)
    assert_role_target("declared_default_target", true)
    assert_role_target("declared_var_target", true)
    assert_role_target("declared_spec_target", true)
    assert_role_target("declared_template_target", true)
    assert_role_target("stale_target", false)
  end
  raise "Paperless role target is absent" unless role_target_exists?("paperless-ngx", "paperless_task_workers")
  raise "undeclared Paperless target passed" if role_target_exists?("paperless-ngx", "paperless_unlisted_target")
end

def self_test
  validate_mapping
  assert_failure("missing stack", mutate_mapping { |mapping| mapping["stacks"].delete("ntfy") }, "stacks differ")
  assert_failure("extra stack", mutate_mapping { |mapping| mapping["stacks"]["extra"] = {} }, "stacks differ")
  assert_failure("missing variable", mutate_mapping { |mapping| mapping["stacks"]["beszel"].delete("TZ") }, "variables differ")
  assert_failure("extra variable", mutate_mapping { |mapping| mapping["stacks"]["beszel"]["EXTRA"] = { "classification" => "role", "target" => "beszel_port" } }, "variables differ")
  assert_failure("wrong schema", mutate_mapping { |mapping| mapping["schema"] = 2 }, "schema must equal 1")
  assert_failure("wrong commit", mutate_mapping { |mapping| mapping["legacy_commit"] = "0" * 40 }, "legacy_commit differs")
  assert_failure("wrong classification", mutate_mapping { |mapping| mapping["stacks"]["ntfy"]["TZ"]["classification"] = "secret" }, "invalid classification")
  assert_failure("wrong existing target", mutate_mapping { |mapping| mapping["stacks"]["ntfy"]["TZ"]["target"] = "nas_uid" }, "canonical mapping")
  assert_failure("missing target", mutate_mapping { |mapping| mapping["stacks"]["ntfy"]["TZ"].delete("target") }, "unexpected fields")
  assert_failure("extra reason", mutate_mapping { |mapping| mapping["stacks"]["ntfy"]["TZ"]["reason"] = "no" }, "unexpected fields")
  assert_failure("excluded expected variable", mutate_mapping { |mapping| mapping["stacks"]["ntfy"]["TZ"] = { "classification" => "excluded", "reason" => "no" } }, "must not exclude")
  assert_failure("nonexistent target", mutate_mapping { |mapping| mapping["stacks"]["ntfy"]["TZ"]["target"] = "not_a_variable" }, "unknown inventory target")
  assert_failure("malformed root", "[]\n", "mapping must be a mapping")
  assert_failure("duplicate key", "schema: 1\nschema: 1\n", "contains duplicate YAML keys")
  assert_failure("alias", "schema: &schema 1\nlegacy_commit: 400f03f276ae1bb69f5460c175b9fb923d620f1a\nstacks: *schema\n", "contains YAML aliases")
  self_test_role_targets
end

if ARGV == ["--self-test"]
  self_test
  puts SUCCESS
  exit
end

abort "usage: portainer_parity_mapping_test.rb [--self-test]" unless ARGV.empty?

begin
  validate_mapping
  puts SUCCESS
rescue RuntimeError => error
  abort sanitize(error.message)
end
