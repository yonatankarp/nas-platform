#!/usr/bin/env ruby
# Keep the canonical secrets guide aligned with the deployment vault contract.

require "yaml"

ROOT = File.expand_path("..", __dir__)
failures = []

def check(failures, condition, message)
  failures << message unless condition
end

def markdown_section(document, heading)
  heading = "## #{heading}" unless heading.start_with?("#")
  lines = document.lines
  heading_index = lines.index { |line| line.rstrip == heading }
  return "" unless heading_index

  heading_level = heading[/\A#+/].length
  section_lines = lines.drop(heading_index + 1).take_while do |line|
    next_heading = line.rstrip.match(/\A(#+)(?:\s|\z)/)
    !next_heading || next_heading[1].length > heading_level
  end
  section_lines.join
end

def shell_code_fences(markdown)
  markdown.scan(/^```sh[ \t]*\r?\n(.*?)^```[ \t]*$/m).flatten
end

def normalized_shell(block)
  block.gsub(/\\\r?\n[ \t]*/, " ")
end

def shell_block?(block, *snippets)
  normalized = normalized_shell(block)
  snippets.all? { |snippet| normalized.include?(snippet) }
end

def snippets_in_order?(text, *snippets)
  positions = snippets.map { |snippet| text.index(snippet) }
  positions.all? && positions.each_cons(2).all? { |left, right| left < right }
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

check(failures, vault_keys.length == 45,
      "vault example must contain exactly 45 vault_* keys (found #{vault_keys.length})")

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

managed_user_services = %w[
  audiobookshelf beszel dozzle immich jellyfin komga ntfy paperless_ngx
]
managed_users = vault_example["vault_managed_users"]
check(failures,
      managed_users.is_a?(Hash) && managed_users.keys.sort == managed_user_services.sort,
      "vault example managed-user services differ")
managed_user_services.each do |service|
  check(failures, secrets_guide.include?("#### #{service} managed users"),
        "canonical secrets guide must document #{service} managed users")
end

readme = File.read(File.join(ROOT, "README.md"))
check(failures, readme.include?("](docs/secrets.md)"),
      "README must link to docs/secrets.md")

%w[getting-started-mac.md getting-started-nas.md].each do |guide_name|
  guide_path = File.join(ROOT, "docs", guide_name)
  guide = File.file?(guide_path) ? File.read(guide_path) : ""
  check(failures, guide.include?("](secrets.md)"),
        "docs/#{guide_name} must link to secrets.md")
end

required_headings = [
  "## Start here: choose fresh or recovery",
  "## Brand-new platform starter",
  "## Individual secret recipes",
  "## Existing deployment recovery",
  "## Add a new secret",
  "## Use the vault",
  "### Workstation controller",
  "### NAS-local controller"
]
guide_lines = secrets_guide.lines.map(&:rstrip)
required_headings.each do |heading|
  check(failures, guide_lines.include?(heading),
        "canonical secrets guide must include heading #{heading.inspect}")
end

required_commands_by_section = {
  "## Brand-new platform starter" => [
    "python3 -m venv .venv",
    "ansible-playbook generate-secrets.yml -e generate_brand_new_platform=true",
    "ansible-vault encrypt"
  ],
  "## Individual secret recipes" => [
    "openssl rand -base64 48",
    "user hash",
    "token generate",
    "ssh-keygen"
  ]
}
required_commands_by_section.each do |heading, snippets|
  shell_blocks = shell_code_fences(markdown_section(secrets_guide, heading))
  snippets.each do |snippet|
    check(failures, shell_blocks.any? { |block| block.include?(snippet) },
          "#{heading} must include #{snippet.inspect} in a sh code fence")
  end
end

add_secret_section = markdown_section(secrets_guide, "## Add a new secret")
required_add_secret_files = [
  "inventory/group_vars/all/vault.yml.example",
  "roles/vault_contract/meta/argument_specs.yml",
  "roles/vault_contract/tasks/main.yml",
  "templates/vault-plain.yml.j2",
  "tests/generate-ephemeral-vault.sh"
]
required_add_secret_files.each do |path|
  check(failures, add_secret_section.include?(path),
        "## Add a new secret must identify #{path}")
end

required_add_secret_guidance = {
  /ciphertext.*not enough/m => "state that ciphertext alone is insufficient",
  /consuming role's.*meta\/argument_specs\.yml.*templates.*tasks/m =>
    "identify the consuming role's meta/argument_specs.yml, templates, and tasks",
  /generate-secrets\.yml/ => "identify generate-secrets.yml",
  /fresh-platform generation supports the value/ =>
    "scope generator changes to values supported by fresh-platform generation",
  /service contract and policy tests/ => "require service contract and policy tests",
  /docs\/secrets\.md/ => "identify docs/secrets.md",
  /existing integration.*recover.*deployed value/m =>
    "require existing integrations to recover their deployed value",
  /genuinely new integration.*applicable recipe/m =>
    "direct genuinely new integrations to an applicable recipe",
  /[Cc]ommit\s+only\s+the\s+encrypted/ =>
    "allow only the encrypted vault artifact to be committed"
}
required_add_secret_guidance.each do |pattern, description|
  check(failures, add_secret_section.match?(pattern),
        "## Add a new secret must #{description}")
end

add_secret_shell_blocks = shell_code_fences(add_secret_section)
check(failures,
      add_secret_shell_blocks.any? { |block| shell_block?(block, "ansible-vault edit") },
      "## Add a new secret must include ansible-vault edit in a sh code fence")
check(failures,
      add_secret_shell_blocks.any? { |block| shell_block?(block, "validate-vault.yml") },
      "## Add a new secret must include validate-vault.yml in a sh code fence")
check(failures,
      add_secret_shell_blocks.any? { |block| shell_block?(block, "tests/validate-policy.sh") },
      "## Add a new secret must include tests/validate-policy.sh in a sh code fence")

workstation_section = markdown_section(secrets_guide, "### Workstation controller")
workstation_shell_blocks = shell_code_fences(workstation_section)
workstation_check_index = workstation_shell_blocks.index do |block|
  shell_block?(block, "ansible-playbook -i inventory/remote.yml site.yml",
               "--check --diff", "--vault-password-file")
end
workstation_apply_index = workstation_shell_blocks.index do |block|
  shell_block?(block, "ansible-playbook -i inventory/remote.yml site.yml",
               "--vault-password-file") &&
    !normalized_shell(block).include?("--check") &&
    !normalized_shell(block).include?("--diff")
end
check(failures, !workstation_check_index.nil?,
      "### Workstation controller must include a remote password-file check command")
check(failures, !workstation_apply_index.nil?,
      "### Workstation controller must include a distinct remote apply command without check or diff")
check(failures,
      workstation_check_index && workstation_apply_index &&
        workstation_check_index < workstation_apply_index,
      "### Workstation controller must place the remote check before the apply command")
check(failures,
      workstation_shell_blocks.any? { |block| shell_block?(block, "ansible-vault edit") },
      "### Workstation controller must include ansible-vault edit in a sh code fence")
check(failures,
      workstation_shell_blocks.any? do |block|
        shell_block?(block, "ansible-playbook -i inventory/remote.yml site.yml",
                     "--ask-vault-pass") &&
          !normalized_shell(block).include?("--vault-password-file")
      end,
      "### Workstation controller must include a separate interactive ask-vault-pass command")
check(failures, workstation_section.match?(/decrypts\s+the\s+vault\s+locally/),
      "### Workstation controller must say decryption occurs on the workstation")
check(failures, workstation_section.match?(/NAS does not need the vault password file/),
      "### Workstation controller must say the NAS does not need the vault password file")
check(failures,
      workstation_shell_blocks.any? do |block|
        shell_block?(block, "export PLATFORM_NAS_USER='nasadmin'")
      end,
      "### Workstation controller must use the documented nasadmin SSH user example")
check(failures,
      workstation_shell_blocks.any? do |block|
        shell_block?(block, "export PLATFORM_NAS_ADDRESS=")
      end,
      "### Workstation controller must export PLATFORM_NAS_ADDRESS")
check(failures,
      workstation_section.match?(/replace it with the operator's actual NAS SSH account/),
      "### Workstation controller must explain how to select the operator SSH account")

nas_local_section = markdown_section(secrets_guide, "### NAS-local controller")
nas_local_shell_blocks = shell_code_fences(nas_local_section)
nas_local_check_index = nas_local_shell_blocks.index do |block|
  shell_block?(block, "ansible-playbook -i inventory/local.yml site.yml",
               "--check --diff", "--ask-vault-pass")
end
nas_local_apply_index = nas_local_shell_blocks.index do |block|
  shell_block?(block, "ansible-playbook -i inventory/local.yml site.yml",
               "--ask-vault-pass") &&
    !normalized_shell(block).include?("--check") &&
    !normalized_shell(block).include?("--diff")
end
check(failures, !nas_local_check_index.nil?,
      "### NAS-local controller must include a local interactive check command")
check(failures, !nas_local_apply_index.nil?,
      "### NAS-local controller must include a local interactive apply command without check or diff")
check(failures,
      nas_local_check_index && nas_local_apply_index &&
        nas_local_check_index < nas_local_apply_index,
      "### NAS-local controller must place the local check before the apply command")
check(failures,
      nas_local_shell_blocks.any? do |block|
        shell_block?(block, "export PLATFORM_NAS_ADDRESS=")
      end,
      "### NAS-local controller must export PLATFORM_NAS_ADDRESS")

required_nas_local_guidance = {
  /recommended.*interactiv/m => "recommend interactive password entry",
  /either.*mode-0600 regular, non-symlink password file.*or an executable password-manager provider/m =>
    "offer a secure password file or executable password-manager provider for unattended runs",
  /outside the repository/m => "keep unattended password providers outside the repository",
  /directory mode 0700/m => "require a mode-0700 provider directory",
  /NAS account.*root can decrypt/m =>
    "describe the NAS account and root decryption-access tradeoff"
}
required_nas_local_guidance.each do |pattern, description|
  check(failures, nas_local_section.match?(pattern),
        "### NAS-local controller must #{description}")
end

nas_guide_path = File.join(ROOT, "docs", "getting-started-nas.md")
nas_guide = File.file?(nas_guide_path) ? File.read(nas_guide_path) : ""
auto_deploy_section = markdown_section(nas_guide, "## Automatic deployment from the NAS")
auto_deploy_shell_blocks = shell_code_fences(auto_deploy_section)
verify_tags = %w[
  platform_verify_ntfy platform_verify_beszel platform_verify_dozzle
  platform_verify_audiobookshelf platform_verify_komga
  platform_verify_tinymediamanager platform_verify_jellyfin
  platform_verify_immich platform_verify_paperless
].join(",")

required_auto_deploy_commands = {
  "anonymous controller clone" => [
    "git clone https://github.com/yonatankarp/nas-platform.git",
    '$HOME/.local/share/nas-platform/controller'
  ],
  "vault validation" => [
    "ansible-playbook -i inventory/local.yml validate-vault.yml",
    '--vault-password-file "$PLATFORM_VAULT_PASSWORD_FILE"'
  ],
  "first deployment" => [
    "ansible-playbook -i inventory/local.yml site.yml",
    '--vault-password-file "$PLATFORM_VAULT_PASSWORD_FILE"'
  ],
  "full verification" => [
    "ansible-playbook -i inventory/local.yml verify.yml",
    "--tags #{verify_tags}"
  ],
  "poller installation" => [
    "ansible-playbook -i inventory/local.yml install-production-auto-deploy.yml",
    '--vault-password-file "$PLATFORM_VAULT_PASSWORD_FILE"'
  ],
  "cron inspection" => ["crontab -l"],
  "status inspection" => ['$HOME/.local/bin/nas-platform-deploy --status'],
  "no-op poll" => ['$HOME/.local/bin/nas-platform-deploy --poll'],
  "failed-SHA retry" => [
    'FAILED_SHA=',
    '$HOME/.local/bin/nas-platform-deploy --retry-failed "$FAILED_SHA"'
  ]
}
required_auto_deploy_commands.each do |description, snippets|
  check(failures,
        auto_deploy_shell_blocks.any? { |block| shell_block?(block, *snippets) },
        "NAS automatic deployment guide must include #{description}")
end

# Install from the pin file rather than restating versions, so the guide cannot
# drift away from controller-requirements.txt when Renovate bumps a pin.
check(failures,
      auto_deploy_section.include?("pip install -r controller-requirements.txt"),
      "NAS automatic deployment guide must install controller pins from " \
      "controller-requirements.txt")
controller_pins = File.readlines(File.join(ROOT, "controller-requirements.txt"), chomp: true)
controller_pins.each do |pin|
  check(failures, !auto_deploy_section.include?(pin),
        "NAS automatic deployment guide must not restate controller pin #{pin}")
end

required_auto_deploy_guidance = {
  /dedicated non-root/i => "require a dedicated non-root deployment account",
  # The tools are no longer required at fixed /usr/bin paths: the installer
  # discovers them, because NAS firmwares place them elsewhere.
  /git.*?curl.*?docker.*?records where each tool actually lives/m =>
    "require Git, curl and docker and state that their locations are recorded",
  /Python 3\.12 or newer.*pip/m => "require Python 3.12 or newer with pip",
  /effective-user.*crontab/m => "require effective-user crontab support",
  %r{outside\s+`/volume1/Docker/nas-platform`}m => "keep the controller outside service data",
  /every five minutes/i => "state the polling cadence",
  /exact.*main.*push.*CI.*success/im => "gate on exact successful main push CI",
  /no PAT/i => "state that no PAT is used",
  /same failed SHA.*not.*automatic/i => "forbid automatic same-SHA retries",
  /newer.*successful.*SHA.*proceed/im => "allow a newer successful SHA after a failure",
  /optionally disable SSH/i => "describe optional SSH disablement after bootstrap",
  /protected.*logs.*ntfy/im => "describe protected logs and ntfy outcomes",
  # The design no longer keeps immutable release directories; the boundary is
  # now services, application data, and the retained attempt logs.
  /does not delete.*services.*data.*attempt logs/im =>
    "state the safe automation removal boundary"
}
required_auto_deploy_guidance.each do |pattern, description|
  check(failures, auto_deploy_section.match?(pattern),
        "NAS automatic deployment guide must #{description}")
end

auto_deploy_secrets_section = markdown_section(
  secrets_guide,
  "### Production auto-deployment inputs"
)
check(failures,
      auto_deploy_secrets_section.include?("$HOME/.config/nas-platform/vault.yml") &&
        auto_deploy_secrets_section.include?("$HOME/.config/nas-platform/vault-password"),
      "secrets guide must name both protected NAS auto-deployment inputs")
check(failures,
      auto_deploy_secrets_section.match?(/never committed.*never logged/im) &&
        auto_deploy_secrets_section.match?(/mode-0600 regular, non-symlink/m),
      "secrets guide must protect NAS auto-deployment inputs from commits and logs")

check(failures, readme.include?("Automatic NAS deployments"),
      "README must summarize automatic NAS deployments")
check(failures,
      readme.match?(/successful.*main.*CI/im) && readme.match?(/no PAT/i) &&
        readme.include?("docs/getting-started-nas.md"),
      "README automatic deployment summary must describe the CI gate and link the NAS guide")

individual_recipes = markdown_section(secrets_guide, "## Individual secret recipes")
check(failures, individual_recipes.include?("no separate Beszel agent API secret"),
      "## Individual secret recipes must state there is no separate Beszel agent API secret")
check(failures, individual_recipes.match?(/\bpermanent\b/),
      "## Individual secret recipes must identify the token as permanent")

start_and_recovery_guidance = [
  markdown_section(secrets_guide, "## Start here: choose fresh or recovery"),
  markdown_section(secrets_guide, "## Existing deployment recovery")
].join("\n")
check(failures, start_and_recovery_guidance.include?("do not run the generator"),
      "start or recovery guidance must state do not run the generator")

vault_usage = markdown_section(secrets_guide, "## Use the vault")
vault_usage_intro = vault_usage.lines.take_while { |line| !line.start_with?("### ") }.join
check(failures, vault_usage_intro.include?("outside the repository"),
      "## Use the vault must keep the controller vault password outside the repository")
check(failures, vault_usage_intro.match?(/(?:\A|\n)Never decrypt a vault onto disk\.(?:\n|\z)/),
      "## Use the vault must state exactly: Never decrypt a vault onto disk.")

brand_new_starter = markdown_section(secrets_guide, "## Brand-new platform starter")
brand_new_shell_blocks = shell_code_fences(brand_new_starter)
password_generation_block = brand_new_shell_blocks.find do |block|
  shell_block?(block, "mktemp", "openssl rand -base64 48")
end
check(failures, password_generation_block&.include?("umask 077"),
      "brand-new password generation must protect its temporary file with umask 077")
check(failures, password_generation_block&.match?(/\[\s+!\s+-s\s+/),
      "brand-new password generation must reject an empty temporary password")
check(failures, password_generation_block&.include?("mv -n"),
      "brand-new password generation must publish with a no-clobber move")
check(failures,
      password_generation_block &&
        snippets_in_order?(password_generation_block,
                           '[ -e "$PLATFORM_VAULT_PASSWORD_FILE" ]', "mv -n"),
      "brand-new password publication must check for an existing destination before moving")
check(failures,
      password_generation_block &&
        snippets_in_order?(password_generation_block,
                           '[ -L "$PLATFORM_VAULT_PASSWORD_FILE" ]', "mv -n"),
      "brand-new password publication must reject a symlink destination before moving")

starter_symlink_paths = [
  '"$PLATFORM_VAULT_DIR"',
  '"$PLATFORM_VAULT_PASSWORD_FILE"',
  '"$PLATFORM_VAULT_FILE"',
  "inventory/group_vars/all/vault-plain.yml",
  "inventory/group_vars/all/vault.yml"
]
starter_symlink_paths.each do |path|
  check(failures, brand_new_shell_blocks.any? { |block| block.include?("[ -L #{path} ]") },
        "brand-new starter must reject symlink path #{path}")
end

plaintext_protection_block = brand_new_shell_blocks.find do |block|
  block.include?("mv -n inventory/group_vars/all/vault-plain.yml")
end
plaintext_guard_snippets = [
  '[ -e "$PLATFORM_VAULT_FILE" ]',
  '[ -L "$PLATFORM_VAULT_FILE" ]',
  "[ ! -f inventory/group_vars/all/vault-plain.yml ]",
  "[ -L inventory/group_vars/all/vault-plain.yml ]",
  "[ ! -s inventory/group_vars/all/vault-plain.yml ]"
]
plaintext_guard_snippets.each do |guard|
  check(failures, plaintext_protection_block&.include?(guard),
        "brand-new plaintext protection must include guard #{guard.inspect}")
end
check(failures,
      plaintext_protection_block &&
        snippets_in_order?(plaintext_protection_block,
                           "mv -n inventory/group_vars/all/vault-plain.yml",
                           "ansible-vault encrypt", "'$ANSIBLE_VAULT;'"),
      "brand-new plaintext must be moved, encrypted, and header-confirmed in that order")

starter_edit_block = brand_new_shell_blocks.find { |block| block.include?("ansible-vault edit") }
check(failures,
      starter_edit_block &&
        snippets_in_order?(starter_edit_block, "'$ANSIBLE_VAULT;'", "ansible-vault edit"),
      "brand-new review must confirm an encrypted header before ansible-vault edit")

recovery = markdown_section(secrets_guide, "## Existing deployment recovery")
recovery_shell_blocks = shell_code_fences(recovery)
check(failures,
      recovery_shell_blocks.any? do |block|
        block.include?('[ -L "$PLATFORM_VAULT_DIR" ]') &&
          block.include?('[ ! -d "$PLATFORM_VAULT_DIR" ]')
      end,
      "recovery must reject PLATFORM_VAULT_DIR when it is a symlink or non-directory")
check(failures,
      recovery_shell_blocks.any? do |block|
        snippets_in_order?(block, 'mkdir -p "$PLATFORM_VAULT_DIR"',
                           'chmod 700 "$PLATFORM_VAULT_DIR"', "-perm 0700")
      end,
      "recovery must establish and revalidate PLATFORM_VAULT_DIR as mode 0700")

recovery_mutations = {
  "vault password publication" => 'chmod 600 "$PLATFORM_VAULT_PASSWORD_FILE"',
  "encrypted vault creation" => "ansible-vault create"
}
recovery_mutations.each do |label, mutation|
  check(failures,
        recovery_shell_blocks.any? { |block| snippets_in_order?(block, "-perm 0700", mutation) },
        "recovery must revalidate PLATFORM_VAULT_DIR as mode 0700 before #{label}")
end

workflow_headings = [
  "## Validate without disclosure",
  "## Record and back up the encrypted vault",
  "## Preparation and validation handoff",
  "## Run the complete Mac proof",
  "## Install reviewed vault for NAS"
]
workflow_positions = workflow_headings.map { |heading| guide_lines.index(heading) }
check(failures,
      workflow_positions.all? &&
        workflow_positions.each_cons(2).all? { |left, right| left < right },
      "canonical secrets guide workflow headings must appear in order: #{workflow_headings.join(' -> ')}")

validation_section = markdown_section(secrets_guide, "## Validate without disclosure")
validation_shell_blocks = shell_code_fences(validation_section)
check(failures,
      validation_shell_blocks.any? do |block|
        shell_block?(block, "ansible-playbook validate-vault.yml", "--vault-password-file",
                     '-e @"$PLATFORM_VAULT_FILE"')
      end,
      "validation must run the redacted validate-vault playbook against the encrypted vault")
validation_edit_block = validation_shell_blocks.find { |block| block.include?("ansible-vault edit") }
check(failures,
      validation_edit_block &&
        snippets_in_order?(validation_edit_block, "'$ANSIBLE_VAULT;'", "ansible-vault edit"),
      "validation review must confirm an encrypted header before ansible-vault edit")

backup_section = markdown_section(secrets_guide, "## Record and back up the encrypted vault")
backup_shell_blocks = shell_code_fences(backup_section)
check(failures,
      backup_section.include?("SHA-256 of ciphertext") &&
        backup_shell_blocks.any? { |block| block.match?(/\b(?:shasum -a 256|sha256sum)\b/) },
      "backup workflow must record a SHA-256 checksum of ciphertext")
check(failures,
      backup_section.include?("Back up the encrypted artifact and the vault password separately"),
      "backup workflow must require separate backups of the encrypted artifact and vault password")

proof_section = markdown_section(secrets_guide, "## Run the complete Mac proof")
proof_shell_blocks = shell_code_fences(proof_section)
check(failures,
      proof_shell_blocks.any? do |block|
        shell_block?(block, "tests/mac/run.sh", "--lane fresh", "--vault-file",
                     "--vault-password-file")
      end,
      "Mac proof workflow must run the fresh lane with the vault and password file")

install_section = markdown_section(secrets_guide, "## Install reviewed vault for NAS")
install_shell_blocks = shell_code_fences(install_section)
install_guard_block = install_shell_blocks.find { |block| block.include?("install -m 600") }
check(failures, install_guard_block&.include?("[ -e inventory/group_vars/all/vault.yml ]"),
      "NAS install guard must reject an existing vault destination")
check(failures, install_guard_block&.include?("[ -L inventory/group_vars/all/vault.yml ]"),
      "NAS install guard must reject a symlink vault destination")
check(failures,
      install_section.include?("Git preserves only the executable bit") &&
        install_shell_blocks.any? do |block|
          shell_block?(block, "chmod 600 inventory/group_vars/all/vault.yml")
        end,
      "repository vault workflow must restore mode 0600 after Git materializes the file")

brand_new_platform = guide_lines.index("## Brand-new platform starter")
existing_deployment_recovery = guide_lines.index("## Existing deployment recovery")
check(failures,
      brand_new_platform && existing_deployment_recovery &&
        brand_new_platform < existing_deployment_recovery,
      "canonical secrets guide must place Brand-new platform starter before Existing deployment recovery")

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
  block.include?("protect_generated_vault()")
end.to_s
encrypt_position = encryption_block.index("ansible-vault encrypt")
publish_position = encryption_block.index(
  'mv -n "$platform_vault_encryption_input" "$PLATFORM_VAULT_FILE"'
)
check(failures,
      encryption_block.include?('[ "${brand_new_generation_ready:-false}" != true ]') &&
        encrypt_position && publish_position && encrypt_position < publish_position,
      "brand-new workflow must publish the external vault only after encryption")
check(failures,
      encryption_block.include?(
        'platform_vault_encryption_dir=$(mktemp -d "$PLATFORM_VAULT_DIR/.vault-encryption.XXXXXX")'
      ) &&
        encryption_block.include?('chmod 700 "$platform_vault_encryption_dir"') &&
        encryption_block.include?('[ ! -d "$platform_vault_encryption_dir" ]') &&
        encryption_block.include?('[ -L "$platform_vault_encryption_dir" ]'),
      "brand-new encryption must use a protected real, non-symlink temporary directory")
check(failures,
      encryption_block.include?(
        'platform_vault_encryption_input="$platform_vault_encryption_dir/vault.yml"'
      ) &&
        !encryption_block.match?(/platform_vault_encryption_input=\$\(mktemp(?:\s|\\)/),
      "brand-new encryption input must be a previously nonexistent child, not a mktemp file")
check(failures,
      snippets_in_order?(encryption_block,
                         '[ -e "$platform_vault_encryption_input" ]',
                         '[ -L "$platform_vault_encryption_input" ]',
                         'mv -n inventory/group_vars/all/vault-plain.yml'),
      "brand-new encryption must reject an existing or symlink child before moving plaintext")
plaintext_move_position = encryption_block.index(
  "if ! mv -n inventory/group_vars/all/vault-plain.yml"
)
plaintext_move_block = plaintext_move_position ? encryption_block[plaintext_move_position..] : ""
check(failures,
      snippets_in_order?(plaintext_move_block,
                         'mv -n inventory/group_vars/all/vault-plain.yml',
                         '[ -e inventory/group_vars/all/vault-plain.yml ]',
                         '[ ! -f "$platform_vault_encryption_input" ]',
                         '[ -L "$platform_vault_encryption_input" ]',
                         '[ ! -s "$platform_vault_encryption_input" ]',
                         'chmod 600 "$platform_vault_encryption_input"',
                         "ansible-vault encrypt"),
      "brand-new encryption must verify and protect the moved plaintext before encryption")
check(failures,
      publish_position &&
        snippets_in_order?(encryption_block,
                           'mv -n "$platform_vault_encryption_input" "$PLATFORM_VAULT_FILE"',
                           '[ ! -s "$PLATFORM_VAULT_FILE" ]',
                           'rmdir -- "$platform_vault_encryption_dir"') &&
        encryption_block.include?(
          'protected temporary directory remains for manual inspection: %s'
        ) &&
        encryption_block.include?(
          'published vault is valid, but its empty temporary directory could not be removed'
        ) &&
        !encryption_block.match?(/\brm\s+(?:-[^\n]*r|--recursive)\b/),
      "brand-new encryption must clean up only the empty directory after publish and report retained failures")
check(failures,
      encryption_block.include?("unset brand_new_generation_ready") &&
        encryption_block.include?("unset platform_vault_encryption_input") &&
        encryption_block.include?("unset platform_vault_encryption_dir"),
      "brand-new encryption must unset generation and temporary-path state")
check(failures,
      secrets_guide.match?(/brand_new_generation_ready=false.*?if ansible-playbook generate-secrets\.yml.*?then\s+brand_new_generation_ready=true/m),
      "brand-new workflow must stop after generator failure")

if failures.empty?
  puts "secrets docs: canonical guide and vault schema agree"
else
  failures.each { |failure| warn "FAIL #{failure}" }
  abort "#{failures.length} secrets docs violation(s)"
end
