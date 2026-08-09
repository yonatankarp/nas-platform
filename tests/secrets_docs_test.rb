#!/usr/bin/env ruby
# Keep the canonical secrets guide aligned with the deployment vault contract.

require "yaml"

ROOT = File.expand_path("..", __dir__)
failures = []

def check(failures, condition, message)
  failures << message unless condition
end

def markdown_section(document, heading)
  document.match(/^## #{Regexp.escape(heading)}\n(.*?)(?=^## |\z)/m)&.[](1).to_s
end

def shell_syntax_valid?(source)
  IO.popen(["sh", "-n"], "r+") do |shell|
    shell.write(source)
    shell.close_write
    shell.read
  end
  $?.success?
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
parity_guide_path = File.join(ROOT, "docs", "portainer-parity.md")
parity_guide = File.file?(parity_guide_path) ? File.read(parity_guide_path) : ""
parity_prose = parity_guide.gsub(/\s+/, " ")
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

portainer_exports = %w[
  audiobookshelf.env
  beszel.env
  dozzle.env
  immich.env
  jellyfin.env
  komga.env
  ntfy.env
  paperless-ngx.env
  tinymediamanager.env
]
check(failures, File.file?(parity_guide_path),
      "Portainer parity guide is missing")
portainer_exports.each do |filename|
  check(failures, parity_guide.include?(filename),
        "Portainer parity guide must name #{filename}")
end
check(failures,
      parity_prose.include?("All three paths must remain outside the repository") &&
      parity_guide.include?("PORTAINER_ENV_DIR") &&
      parity_guide.include?("PORTAINER_PARITY_FILE") &&
      parity_guide.include?("PORTAINER_PARITY_PASSWORD_FILE"),
      "Portainer sources, output, and password must remain outside the repository")
check(failures,
      parity_prose.include?("does not source or evaluate") &&
      parity_prose.include?("never overwrites an existing parity vault"),
      "Portainer guide must promise literal parsing and no overwrite")
check(failures,
      parity_prose.include?("SHA-256 checksum of the ciphertext") &&
      parity_prose.include?("Only after verification") &&
      parity_prose.include?("operator explicitly removes the protected plaintext exports"),
      "Portainer guide must verify ciphertext before operator-only plaintext deletion")
check(failures,
      parity_prose.include?("rollback window expires") &&
      parity_prose.include?("operator explicitly destroys the parity vault and every backup"),
      "Portainer guide must retire parity material after rollback expiry")
check(failures,
      secrets_guide.include?("](portainer-parity.md)") &&
      secrets_guide.include?("deployment vault") &&
      secrets_guide.include?("temporary Portainer parity vault"),
      "canonical secrets guide must distinguish and link deployment and parity vaults")

parity_setup = markdown_section(parity_guide, "Prepare protected external inputs")
parity_import = markdown_section(parity_guide, "Import and validate")
parity_retirement = markdown_section(parity_guide, "Remove plaintext and retire the vault")
setup_block = parity_setup.scan(/```sh\n(.*?)```/m).flatten.find do |block|
  block.include?('PORTAINER_ENV_DIR=')
end.to_s
verification_block = parity_import.scan(/```sh\n(.*?)```/m).flatten.find do |block|
  block.include?('IFS= read -r parity_header')
end.to_s

check(failures,
      !setup_block.empty? && shell_syntax_valid?(setup_block) &&
      setup_block.include?("umask 077") &&
      setup_block.match?(/if \[ -e "\$PORTAINER_ENV_DIR" \].*?\[ -e "\$PORTAINER_PARITY_FILE" \].*?\[ -e "\$PORTAINER_PARITY_PASSWORD_FILE" \]/m) &&
      setup_block.include?('mkdir -p "$PORTAINER_PROTECTED_DIR"') &&
      setup_block.include?('chmod 700 "$PORTAINER_PROTECTED_DIR" "$PORTAINER_ENV_DIR"') &&
      setup_block.include?('chmod 600 "$PORTAINER_PARITY_PASSWORD_FILE"'),
      "Portainer setup must be executable, private, and refuse existing protected paths")
check(failures,
      setup_block.include?('password_lines=$(awk \'END { print NR }\' "$PORTAINER_PARITY_PASSWORD_FILE")') &&
      setup_block.include?('[ "$password_lines" -ne 1 ] || [ ! -s "$PORTAINER_PARITY_PASSWORD_FILE" ]') &&
      setup_block.include?("exit 1"),
      "Portainer setup must fail closed for an empty or multiline password")
check(failures,
      shell_syntax_valid?(verification_block) &&
      verification_block.match?(/case "\$parity_header" in.*?'\$ANSIBLE_VAULT;'.*?\*\).*?STOP:.*?exit 1.*?esac/m),
      "Portainer header verification must stop on an invalid header")
check(failures,
      verification_block.include?("ansible-vault view") &&
      verification_block.include?("scripts/portainer-parity.rb --validate-stdin") &&
      parity_import.include?("Portainer parity: decrypted schema is valid"),
      "Portainer guide must require a concrete successful schema validation before deletion")

import_position = parity_prose.index("scripts/import-portainer-parity.sh")
verification_position = parity_prose.index("Portainer parity: decrypted schema is valid")
plaintext_deletion_position = parity_prose.index("operator explicitly removes the protected plaintext exports")
rollback_expiry_position = parity_prose.index("rollback window expires")
destruction_position = parity_prose.index("operator explicitly destroys the parity vault and every backup")
check(failures,
      [import_position, verification_position, plaintext_deletion_position,
       rollback_expiry_position, destruction_position].all? &&
      import_position < verification_position &&
      verification_position < plaintext_deletion_position &&
      plaintext_deletion_position < rollback_expiry_position &&
      rollback_expiry_position < destruction_position &&
      parity_prose.include?("removes the parity password if no other vault uses it"),
      "Portainer lifecycle must order import, verification, plaintext deletion, rollback expiry, and retirement")

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
mac_proof_block = mac_guide.scan(/```sh\n(.*?)```/m).flatten.find do |block|
  block.include?("for phase in deploy seed verify")
end.to_s
check(failures,
      mac_proof_block.match?(/if ! tests\/mac\/run\.sh.*?proof_status=1.*?break.*?if \[ "\$proof_status" -ne 0 \].*?STOP:.*?else.*?All automated phases passed/m),
      "Mac proof loop must not continue to manual review after a failed phase")
check(failures,
      secrets_guide.include?('password_lines=$(awk \'END { print NR }\' "$PLATFORM_VAULT_PASSWORD_FILE")') &&
      secrets_guide.include?('if [ "$password_lines" -ne 1 ] || [ ! -s "$PLATFORM_VAULT_PASSWORD_FILE" ]'),
      "canonical secrets guide must reject empty or multiline vault passwords")
encryption_block = secrets_guide.scan(/```sh\n(.*?)```/m).flatten.find do |block|
  block.include?('vault_encryption_input=$(mktemp')
end.to_s
encrypt_position = encryption_block.index("ansible-vault encrypt")
publish_position = encryption_block.index('mv "$vault_encryption_input" "$PLATFORM_VAULT_FILE"')
check(failures,
      encryption_block.include?('[ "${brand_new_generation_ready:-false}" != true ]') &&
      encrypt_position && publish_position && encrypt_position < publish_position,
      "brand-new workflow must publish the external vault only after encryption")
check(failures,
      secrets_guide.match?(/brand_new_generation_ready=false.*?if ansible-playbook generate-secrets\.yml.*?then\s+brand_new_generation_ready=true/m),
      "brand-new workflow must stop after generator failure")

if failures.empty?
  puts "secrets docs: canonical guide and vault schema agree"
else
  failures.each { |failure| warn "FAIL #{failure}" }
  abort "#{failures.length} secrets docs violation(s)"
end
