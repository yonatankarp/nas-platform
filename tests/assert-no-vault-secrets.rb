#!/usr/bin/env ruby

require "open3"
require "yaml"

# Public database identifiers, not credentials, that ordinary evidence prints; every
# other vault string of 8+ bytes stays fail-closed. The Nextcloud pair is minted as the
# bare service name, which every "TASK [nextcloud : ...]" banner contains.
PUBLIC_DATABASE_IDENTITY_KEYS = %w[
  vault_immich_db_name
  vault_immich_db_username
  vault_paperless_db_name
  vault_paperless_db_username
  vault_nextcloud_db_name
  vault_nextcloud_db_username
].freeze

def strings(value, path = [])
  case value
  when Hash
    value.flat_map { |key, entry| strings(entry, path + [key.to_s]) }
  when Array
    value.each_with_index.flat_map { |entry, index| strings(entry, path + [index.to_s]) }
  when String
    PUBLIC_DATABASE_IDENTITY_KEYS.include?(path.join(".")) ? [] : [value]
  else []
  end
end

def remove_controller_repository_paths!(evidence, repository_root)
  evidence.gsub!(
    /(?<![[:alnum:]_.\/-])#{Regexp.escape(repository_root)}(?=\/(?:[^\/]|\z)|\z)/,
    ""
  )
end

def assert_no_vault_secrets(argv)
  vault_file, password_file, *evidence_files = argv
  abort "usage: #{$PROGRAM_NAME} VAULT PASSWORD_FILE EVIDENCE..." if evidence_files.empty?

  vault_yaml, _error, status = Open3.capture3(
    "ansible-vault", "view", "--vault-password-file", password_file, vault_file
  )
  abort "encrypted vault could not be read" unless status.success?

  begin
    vault = YAML.safe_load(vault_yaml)
  rescue Psych::Exception
    abort "encrypted vault contents are invalid"
  ensure
    vault_yaml.replace("\0" * vault_yaml.bytesize)
  end
  secrets = strings(vault).select { |value| value.bytesize >= 8 }
  # Ansible Origin diagnostics contain this trusted path; drop only its canonical form.
  repository_root = File.realpath(File.expand_path("..", __dir__))
  evidence_files.each do |evidence_file|
    evidence = File.binread(evidence_file)
    remove_controller_repository_paths!(evidence, repository_root)
    leaked = secrets.any? { |secret| evidence.include?(secret) }
    evidence.replace("\0" * evidence.bytesize)
    abort "failure evidence contains a vault value" if leaked
  end
end

assert_no_vault_secrets(ARGV) if $PROGRAM_NAME == __FILE__
