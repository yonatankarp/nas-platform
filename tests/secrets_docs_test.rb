#!/usr/bin/env ruby
# Keep the canonical secrets guide aligned with the deployment vault contract.

require "yaml"
require_relative "policy_support"

include PolicySupport

ROOT = File.expand_path("..", __dir__)
failures = []

def check(failures, condition, message)
  failures << message unless condition
end

vault_example_path = File.join(ROOT, "inventory", "group_vars", "all", "vault.yml.example")
vault_example = begin
  YAML.safe_load_file(vault_example_path)
rescue Errno::ENOENT
  check(failures, false, "vault example is missing")
  {}
rescue Psych::Exception
  check(failures, false, "vault example is malformed")
  {}
end

vault_keys = if vault_example.is_a?(Hash)
               vault_example.keys.grep(String).select { |key| key.start_with?("vault_") }.uniq.sort
             else
               check(failures, false, "vault example must contain a mapping")
               []
             end

secrets_guide_path = File.join(ROOT, "docs", "secrets.md")
secrets_guide = File.file?(secrets_guide_path) ? File.read(secrets_guide_path) : ""
documented_keys = secrets_guide.scan(/`(vault_[a-z0-9_]+)`/).flatten.uniq.sort

missing_keys = vault_keys - documented_keys
unexpected_keys = documented_keys - vault_keys
schema_diagnostic = []
schema_diagnostic << "missing: #{missing_keys.join(', ')}" unless missing_keys.empty?
schema_diagnostic << "unexpected: #{unexpected_keys.join(', ')}" unless unexpected_keys.empty?
check(failures, missing_keys.empty? && unexpected_keys.empty?,
      "canonical secrets guide vault keys differ (#{schema_diagnostic.join('; ')})")

readme = File.read(File.join(ROOT, "README.md"))
check(failures, readme.include?("](docs/secrets.md)"),
      "README must link to docs/secrets.md")

%w[getting-started-mac.md getting-started-nas.md].each do |guide_name|
  guide_path = File.join(ROOT, "docs", guide_name)
  guide = File.file?(guide_path) ? File.read(guide_path) : ""
  check(failures, guide.include?("](secrets.md)"),
        "docs/#{guide_name} must link to secrets.md")
end

migration_workflow = secrets_guide.index("Migration workflow")
brand_new_platform = secrets_guide.index("Brand-new platform")
check(failures,
      migration_workflow && brand_new_platform && migration_workflow < brand_new_platform,
      "canonical secrets guide must place Migration workflow before Brand-new platform")

if failures.empty?
  puts "secrets docs: canonical guide and vault schema agree"
else
  failures.each { |failure| warn "FAIL #{failure}" }
  abort "#{failures.length} secrets docs violation(s)"
end
