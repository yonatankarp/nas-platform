#!/usr/bin/env ruby
# frozen_string_literal: true

require "tmpdir"
require "yaml"
require_relative "policy_support"

ROOT = File.expand_path("..", __dir__)
CAPABILITIES_PATH = File.join(ROOT, "config", "managed-user-capabilities.yml")
SUCCESS = "Managed-user capabilities: all eight service contracts are pinned"

MULTI_USER_DEFAULTS = {
  "preserves_unmanaged_users" => true,
  "password_rotation" => "refuse",
  "existing_identity_password_update" => "forbidden"
}.freeze

EXPECTED_SERVICES = {
  "audiobookshelf" => MULTI_USER_DEFAULTS.merge(
    "mode" => "api",
    "interfaces" => {
      "list" => "api/users",
      "create" => "api/users",
      "authenticate" => "login",
      "reconcile" => "api/users/{id}"
    }
  ),
  "beszel" => MULTI_USER_DEFAULTS.merge(
    "mode" => "api",
    "interfaces" => {
      "list" => "PocketBase users collection",
      "create" => "PocketBase users collection",
      "authenticate" => "PocketBase users collection",
      "reconcile" => "PocketBase users collection"
    }
  ),
  "dozzle" => MULTI_USER_DEFAULTS.merge(
    "mode" => "declarative_file",
    "interfaces" => {
      "list" => "data/users.yml",
      "create" => "data/users.yml",
      "authenticate" => "api/token",
      "reconcile" => "data/users.yml"
    }
  ),
  "immich" => MULTI_USER_DEFAULTS.merge(
    "mode" => "api",
    "interfaces" => {
      "list" => "admin/users",
      "create" => "admin/users",
      "authenticate" => "auth/login",
      "reconcile" => "admin/users"
    }
  ),
  "jellyfin" => MULTI_USER_DEFAULTS.merge(
    "mode" => "api",
    "interfaces" => {
      "list" => "Users",
      "create" => "Users/New",
      "authenticate" => "Users/AuthenticateByName",
      "reconcile" => "Users/{id}/Policy"
    }
  ),
  "komga" => MULTI_USER_DEFAULTS.merge(
    "mode" => "api",
    "interfaces" => {
      "list" => "api/v2/users",
      "create" => "api/v2/users",
      "authenticate" => "api/v2/users/me",
      "reconcile" => "api/v2/users/{id}"
    }
  ),
  "ntfy" => MULTI_USER_DEFAULTS.merge(
    "mode" => "declarative_environment",
    "interfaces" => {
      "list" => "NTFY_AUTH_USERS and ntfy user list",
      "create" => "NTFY_AUTH_USERS/NTFY_AUTH_ACCESS/NTFY_AUTH_TOKENS",
      "authenticate" => "Basic authentication",
      "reconcile" => "NTFY_AUTH_USERS/NTFY_AUTH_ACCESS/NTFY_AUTH_TOKENS"
    }
  ),
  "paperless-ngx" => MULTI_USER_DEFAULTS.merge(
    "mode" => "django_cli",
    "interfaces" => {
      "list" => "get_user_model",
      "create" => "get_user_model",
      "authenticate" => "api/token",
      "reconcile" => "get_user_model"
    }
  )
}.freeze

def fail_contract(message)
  raise "Managed-user capabilities: #{message}"
end

def sanitize(value)
  value.to_s.gsub(/[[:cntrl:]]/, "?")
end

def mapping(value, label)
  fail_contract("#{label} must be a mapping") unless value.is_a?(Hash)

  value
end

def load_document(path)
  source = File.binread(path)
  tree = Psych.parse_stream(source)
  fail_contract("matrix must contain exactly one YAML document") unless tree.children.length == 1
  fail_contract("matrix contains duplicate YAML keys") unless PolicySupport.duplicate_yaml_keys(tree).empty?

  tree.each do |node|
    if node.is_a?(Psych::Nodes::Alias) || (node.respond_to?(:anchor) && node.anchor)
      fail_contract("matrix contains YAML aliases")
    end
  end
  YAML.safe_load(source, aliases: false)
rescue Errno::ENOENT
  fail_contract("matrix is missing")
rescue Psych::Exception => error
  fail_contract("matrix YAML is malformed (#{sanitize(error.message)})")
end

def validate_capabilities(path = CAPABILITIES_PATH)
  document = mapping(load_document(path), "matrix")
  fail_contract("root fields differ") unless document.keys.sort == %w[schema services]
  fail_contract("schema must equal 1") unless document["schema"] == 1

  services = mapping(document["services"], "services")
  fail_contract("service entries differ") unless services.keys.sort == EXPECTED_SERVICES.keys.sort

  EXPECTED_SERVICES.each do |service, expected|
    actual = mapping(services[service], service)
    fail_contract("#{service} contract differs") unless actual == expected
  end
end

def matrix_source
  File.binread(CAPABILITIES_PATH)
end

def mutate_matrix
  document = YAML.safe_load(matrix_source, aliases: false)
  yield document
  YAML.dump(document)
end

def assert_failure(label, source, message)
  Dir.mktmpdir("nas-platform-managed-user-capabilities-") do |directory|
    path = File.join(directory, "managed-user-capabilities.yml")
    File.binwrite(path, source)
    begin
      validate_capabilities(path)
    rescue RuntimeError => error
      unless error.message.include?(message)
        raise "#{label}: expected #{message.inspect}, got #{error.message.inspect}"
      end
      return
    end
    raise "#{label}: expected validation to fail"
  end
end

def self_test
  validate_capabilities
  assert_failure("missing service", mutate_matrix { |matrix| matrix["services"].delete("ntfy") }, "service entries differ")
  assert_failure("extra service", mutate_matrix { |matrix| matrix["services"]["extra"] = {} }, "service entries differ")
  assert_failure("wrong mode", mutate_matrix { |matrix| matrix["services"]["dozzle"]["mode"] = "api" }, "dozzle contract differs")
  assert_failure("missing interface", mutate_matrix { |matrix| matrix["services"]["komga"]["interfaces"].delete("authenticate") }, "komga contract differs")
  assert_failure("renamed interface", mutate_matrix { |matrix| matrix["services"]["jellyfin"]["interfaces"]["create"] = "Users/Create" }, "jellyfin contract differs")
  assert_failure("unmanaged deletion", mutate_matrix { |matrix| matrix["services"]["immich"]["preserves_unmanaged_users"] = false }, "immich contract differs")
  assert_failure("password rotation", mutate_matrix { |matrix| matrix["services"]["paperless-ngx"]["password_rotation"] = "replace" }, "paperless-ngx contract differs")
  assert_failure("password update enabled", mutate_matrix { |matrix| matrix["services"]["audiobookshelf"]["existing_identity_password_update"] = "allowed" }, "audiobookshelf contract differs")
  assert_failure("wrong schema", mutate_matrix { |matrix| matrix["schema"] = 2 }, "schema must equal 1")
  assert_failure("extra field", mutate_matrix { |matrix| matrix["services"]["beszel"]["extra"] = true }, "beszel contract differs")
  assert_failure("malformed root", "[]\n", "matrix must be a mapping")
  assert_failure("duplicate key", "schema: 1\nschema: 1\nservices: {}\n", "duplicate YAML keys")
  assert_failure("alias", "schema: &schema 1\nservices: *schema\n", "YAML aliases")
  assert_failure("multiple documents", "#{matrix_source}\n---\nignored: true\n", "exactly one YAML document")
end

if ARGV == ["--self-test"]
  self_test
  puts SUCCESS
  exit
end

abort "usage: managed_user_capabilities_test.rb [--self-test]" unless ARGV.empty?

begin
  validate_capabilities
  puts SUCCESS
rescue RuntimeError => error
  abort sanitize(error.message)
end
