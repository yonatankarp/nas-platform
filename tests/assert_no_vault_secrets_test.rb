#!/usr/bin/env ruby

require "fileutils"
require "open3"
require "tmpdir"

ROOT = File.expand_path("..", __dir__)
SCANNER = File.join(ROOT, "tests", "assert-no-vault-secrets.rb")

def run_scanner(vault, evidence, scanner: SCANNER)
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
      scanner, vault_file, password_file, evidence_file
    )
  end
end

def allowlist_contract(scanner)
  expected = %w[
    vault_immich_db_name
    vault_immich_db_username
    vault_paperless_db_name
    vault_paperless_db_username
  ]
  Open3.capture3(
    "ruby", "-e",
    <<~RUBY,
      require ARGV.fetch(0)
      abort "unexpected public database identity allowlist" unless
        PUBLIC_DATABASE_IDENTITY_KEYS == #{expected.inspect}
    RUBY
    scanner
  )
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

%w[
  vault_immich_db_name
  vault_immich_db_username
  vault_paperless_db_name
  vault_paperless_db_username
].each do |key|
  relocated_value = "synthetic-relocated-#{key}"
  [
    "wrapper:\n  #{key}: #{relocated_value}\n",
    "wrapper:\n  - #{key}: #{relocated_value}\n"
  ].each do |vault|
    stdout, stderr, status = run_scanner(vault, "diagnostic contains #{relocated_value}\n")
    failures << "relocated #{key} was not rejected" if status.success?
    failures << "relocated #{key} rejection disclosed evidence" unless stdout.empty?
    failures << "relocated #{key} rejection changed the fixed diagnostic" unless
      stderr == "failure evidence contains a vault value\n"
  end
end

{
  "top-level password" => "vault_service_password: synthetic-password-value\n",
  "top-level token" => "vault_service_token: synthetic-token-value\n",
  "top-level private key" => "vault_service_private_key: synthetic-private-key-value\n",
  "top-level secret" => "vault_service_secret: synthetic-secret-value\n",
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

stdout, stderr, status = run_scanner("vault_short_secret: '1234567'\n", "1234567\n")
failures << "seven-byte scalar did not retain the established ignore policy" unless
  status.success? && stdout.empty? && stderr.empty?

stdout, stderr, status = run_scanner("vault_short_secret: '12345678'\n", "12345678\n")
failures << "eight-byte scalar was not rejected" if status.success?
failures << "eight-byte scalar rejection disclosed evidence" unless stdout.empty?
failures << "eight-byte scalar rejection changed the fixed diagnostic" unless
  stderr == "failure evidence contains a vault value\n"

stdout, stderr, status = allowlist_contract(SCANNER)
failures << "scanner does not expose exactly the four approved public database identities" unless
  status.success? && stdout.empty? && stderr.empty?

Dir.mktmpdir("assert-no-vault-secrets-mutant") do |directory|
  mutant = File.join(directory, "assert-no-vault-secrets.rb")
  File.write(
    mutant,
    <<~RUBY
      require #{SCANNER.inspect}
      mutated_allowlist = PUBLIC_DATABASE_IDENTITY_KEYS + ["vault_future_public_identity"]
      Object.send(:remove_const, :PUBLIC_DATABASE_IDENTITY_KEYS)
      PUBLIC_DATABASE_IDENTITY_KEYS = mutated_allowlist.freeze
    RUBY
  )
  stdout, stderr, status = allowlist_contract(mutant)
  failures << "a fifth public database identity allowlist entry escaped detection" if status.success?
  failures << "allowlist mutation contract wrote to stdout" unless stdout.empty?
end

if failures.empty?
  puts "vault evidence scanner: explicit public database identities and fail-closed secrets hold"
else
  warn failures.join("\n")
  exit 1
end
