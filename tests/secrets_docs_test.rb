#!/usr/bin/env ruby
# Keep the canonical secrets guide aligned with the deployment vault contract.

require "yaml"

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
               vault_example.keys.grep(String).select { |key| key.start_with?("vault_") }.sort
             else
               check(failures, false, "vault example must contain a mapping")
               []
             end

secrets_guide_path = File.join(ROOT, "docs", "secrets.md")
secrets_guide = File.file?(secrets_guide_path) ? File.read(secrets_guide_path) : ""
documented_key_counts = secrets_guide.scan(/`(vault_[^`]*)`/).flatten.tally

missing_keys = vault_keys.reject { |key| documented_key_counts.key?(key) }
duplicate_keys = vault_keys.filter_map do |key|
  count = documented_key_counts.fetch(key, 0)
  [key, count] if count > 1
end
unexpected_keys = documented_key_counts.keys.reject { |key| vault_keys.include?(key) }.sort
schema_diagnostic = []
schema_diagnostic << "missing: #{missing_keys.map { |key| "#{key}=0" }.join(', ')}" unless missing_keys.empty?
unless duplicate_keys.empty?
  schema_diagnostic << "duplicate: #{duplicate_keys.map { |key, count| "#{key}=#{count}" }.join(', ')}"
end
unless unexpected_keys.empty?
  schema_diagnostic << "unexpected: #{unexpected_keys.map { |key| "#{key}=#{documented_key_counts.fetch(key)}" }.join(', ')}"
end
check(failures, missing_keys.empty? && duplicate_keys.empty? && unexpected_keys.empty?,
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

migration_workflow = secrets_guide.match(/^## Migration workflow$/)&.begin(0)
brand_new_platform = secrets_guide.match(/^## Brand-new platform$/)&.begin(0)
check(failures,
      migration_workflow && brand_new_platform && migration_workflow < brand_new_platform,
      "canonical secrets guide must place Migration workflow before Brand-new platform")

mac_guide = File.read(File.join(ROOT, "docs", "getting-started-mac.md"))
check(failures, !mac_guide.include?('--phase "$phase" || break'),
      "Mac proof loop must not continue to manual review after a failed phase")
check(failures,
      secrets_guide.include?('password_lines=$(awk \'END { print NR }\' "$PLATFORM_VAULT_PASSWORD_FILE")') &&
      secrets_guide.include?('if [ "$password_lines" -ne 1 ] || [ ! -s "$PLATFORM_VAULT_PASSWORD_FILE" ]'),
      "canonical secrets guide must reject empty or multiline vault passwords")
check(failures,
      secrets_guide.include?('vault_encryption_input=$(mktemp "$PLATFORM_VAULT_DIR/.vault-encryption.XXXXXX")') &&
      secrets_guide.include?('mv "$vault_encryption_input" "$PLATFORM_VAULT_FILE"'),
      "brand-new workflow must publish the external vault only after encryption")
check(failures,
      secrets_guide.include?('if ansible-playbook generate-secrets.yml -e generate_brand_new_platform=true; then'),
      "brand-new workflow must stop after generator failure")

if failures.empty?
  puts "secrets docs: canonical guide and vault schema agree"
else
  failures.each { |failure| warn "FAIL #{failure}" }
  abort "#{failures.length} secrets docs violation(s)"
end
