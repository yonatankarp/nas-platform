#!/usr/bin/env ruby

require "open3"
require "yaml"

vault_file, password_file, evidence_file = ARGV
abort "usage: #{$PROGRAM_NAME} VAULT PASSWORD_FILE EVIDENCE" unless evidence_file

vault_yaml, _error, status = Open3.capture3(
  "ansible-vault", "view", "--vault-password-file", password_file, vault_file
)
abort "encrypted vault could not be read" unless status.success?

def strings(value)
  case value
  when Hash then value.values.flat_map { |entry| strings(entry) }
  when Array then value.flat_map { |entry| strings(entry) }
  when String then [value]
  else []
  end
end

secrets = strings(YAML.safe_load(vault_yaml)).select { |value| value.bytesize >= 8 }
evidence = File.binread(evidence_file)
leaked = secrets.any? { |secret| evidence.include?(secret) }
vault_yaml.replace("\0" * vault_yaml.bytesize)
evidence.replace("\0" * evidence.bytesize)
abort "failure evidence contains a vault value" if leaked
