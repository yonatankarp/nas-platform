#!/usr/bin/env ruby

require "fileutils"
require "open3"
require "tmpdir"

ROOT = File.expand_path("..", __dir__)
SCANNER = File.join(ROOT, "tests", "assert-no-vault-secrets.rb")

def run_scanner(vault, evidence)
  Dir.mktmpdir("assert-no-vault-secrets") do |directory|
    fake_bin = File.join(directory, "bin")
    FileUtils.mkdir(fake_bin)
    File.write(
      File.join(fake_bin, "ansible-vault"),
      <<~SH
        #!/bin/sh
        printf '%s' "$SYNTHETIC_VAULT"
      SH
    )
    FileUtils.chmod(0o755, File.join(fake_bin, "ansible-vault"))
    vault_file = File.join(directory, "vault.yml")
    password_file = File.join(directory, "password")
    evidence_file = File.join(directory, "evidence")
    File.write(vault_file, "synthetic encrypted vault placeholder")
    File.write(password_file, "synthetic password placeholder")
    File.write(evidence_file, evidence)
    Open3.capture3(
      { "PATH" => "#{fake_bin}:#{ENV.fetch("PATH")}", "SYNTHETIC_VAULT" => vault },
      SCANNER, vault_file, password_file, evidence_file
    )
  end
end

failures = []

non_secret_database_identity = "public-database-identity"
stdout, stderr, status = run_scanner(
  <<~YAML,
    vault_immich_db_name: #{non_secret_database_identity}
    vault_immich_db_username: #{non_secret_database_identity}
    vault_paperless_db_name: #{non_secret_database_identity}
    vault_paperless_db_username: #{non_secret_database_identity}
  YAML
  "Dozzle check output names #{non_secret_database_identity}\n"
)
failures << "public database identity produced a false positive" unless
  status.success? && stdout.empty? && stderr.empty?

{
  "top-level password" => "vault_service_password: synthetic-password-value\n",
  "nested managed-user password" => <<~YAML,
    vault_managed_users:
      service:
        - username: synthetic-user-value
          password: synthetic-managed-password
  YAML
  "unknown field" => "vault_future_field: synthetic-unknown-value\n",
  "identity field" => "vault_service_username: synthetic-user-value\n"
}.each do |label, vault|
  value = vault.lines.grep(/:/).last.split(":", 2).last.strip
  stdout, stderr, status = run_scanner(vault, "diagnostic contains #{value}\n")
  failures << "#{label} was not rejected" if status.success?
  failures << "#{label} rejection disclosed evidence" unless stdout.empty?
  failures << "#{label} rejection changed the fixed diagnostic" unless
    stderr == "failure evidence contains a vault value\n"
end

if failures.empty?
  puts "vault evidence scanner: explicit public database identities and fail-closed secrets hold"
else
  warn failures.join("\n")
  exit 1
end
