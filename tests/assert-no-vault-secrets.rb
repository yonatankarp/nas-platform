#!/usr/bin/env ruby

require "open3"
require "yaml"

# These exact four paths are public database identifiers, not credentials, and
# normal Dozzle Ansible evidence emits them. Every other vault String of at
# least eight bytes remains fail-closed, so a new field cannot silently weaken
# the evidence scan.
PUBLIC_DATABASE_IDENTITY_KEYS = %w[
  vault_immich_db_name
  vault_immich_db_username
  vault_paperless_db_name
  vault_paperless_db_username
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

def assert_no_vault_secrets(argv)
  vault_file, password_file, *evidence_files = argv
  abort "usage: #{$PROGRAM_NAME} VAULT PASSWORD_FILE EVIDENCE..." if evidence_files.empty?

  vault_yaml, _error, status = Open3.capture3(
    "ansible-vault", "view", "--vault-password-file", password_file, vault_file
  )
  abort "encrypted vault could not be read" unless status.success?

  secrets = strings(YAML.safe_load(vault_yaml)).select { |value| value.bytesize >= 8 }
  vault_yaml.replace("\0" * vault_yaml.bytesize)
  evidence_files.each do |evidence_file|
    evidence = File.binread(evidence_file)
    leaked = secrets.any? { |secret| evidence.include?(secret) }
    evidence.replace("\0" * evidence.bytesize)
    abort "failure evidence contains a vault value" if leaked
  end
end

assert_no_vault_secrets(ARGV) if $PROGRAM_NAME == __FILE__
