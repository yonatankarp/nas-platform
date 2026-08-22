#!/usr/bin/env ruby

require "fileutils"
require "digest"
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
    result = Open3.capture3(
      { "PATH" => "#{fake_bin}:#{ENV.fetch("PATH")}", "SYNTHETIC_VAULT" => vault },
      scanner, vault_file, password_file, evidence_file
    )
    inspection = yield(evidence_file) if block_given?
    result + [inspection]
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

malformed_tag_sentinel = "SyntheticVaultTagMustRemainPrivate"
stdout, stderr, status = run_scanner(
  "--- !ruby/object:#{malformed_tag_sentinel} {}\n",
  "unrelated evidence\n"
)
failures << "rejected YAML tag was accepted" if status.success?
failures << "rejected YAML tag wrote to stdout" unless stdout.empty?
failures << "rejected YAML tag changed the fixed diagnostic" unless
  stderr == "encrypted vault contents are invalid\n"
failures << "rejected YAML tag disclosed its synthetic sentinel" if
  (stdout + stderr).include?(malformed_tag_sentinel)

Dir.mktmpdir("assert-no-vault-controller-path") do |directory|
  synthetic_identity = "synthetic-controller-identity"
  synthetic_root = File.join(directory, synthetic_identity, "repository")
  FileUtils.mkdir_p(File.join(synthetic_root, "tests"))
  synthetic_root = File.realpath(synthetic_root)
  synthetic_scanner = File.join(synthetic_root, "tests", "assert-no-vault-secrets.rb")
  FileUtils.cp(SCANNER, synthetic_scanner, preserve: true)
  vault = "vault_service_username: #{synthetic_identity}\n"

  exact_evidence = "Origin: #{synthetic_root}/roles/service/tasks/main.yml\n"
  exact_digest = Digest::SHA256.hexdigest(exact_evidence)
  stdout, stderr, status, exact_inspection = run_scanner(
    vault,
    exact_evidence,
    scanner: synthetic_scanner
  ) do |evidence_file|
    bytes = File.binread(evidence_file)
    [bytes, Digest::SHA256.hexdigest(bytes)]
  end
  failures << "trusted controller repository path produced a false positive" unless
    status.success? && stdout.empty? && stderr.empty?
  failures << "successful scan changed the evidence artifact" unless
    exact_inspection == [exact_evidence, exact_digest]

  outside_evidence = "diagnostic disclosed #{synthetic_identity}\n"
  outside_digest = Digest::SHA256.hexdigest(outside_evidence)
  stdout, stderr, status, outside_inspection = run_scanner(
    vault,
    outside_evidence,
    scanner: synthetic_scanner
  ) do |evidence_file|
    bytes = File.binread(evidence_file)
    [bytes, Digest::SHA256.hexdigest(bytes)]
  end
  failures << "controller-path identity was ignored outside the trusted path" if status.success?
  failures << "controller-path identity rejection disclosed evidence" unless stdout.empty?
  failures << "controller-path identity rejection changed the fixed diagnostic" unless
    stderr == "failure evidence contains a vault value\n"
  failures << "failed scan changed the evidence artifact" unless
    outside_inspection == [outside_evidence, outside_digest]

  stdout, stderr, status = run_scanner(
    vault,
    "Origin: #{synthetic_root}/roles/service/tasks/main.yml\n" \
      "diagnostic disclosed #{synthetic_identity}\n",
    scanner: synthetic_scanner
  )
  failures << "controller-path normalization hid a second identity occurrence" if status.success?
  failures << "second identity occurrence rejection disclosed evidence" unless stdout.empty?
  failures << "second identity occurrence changed the fixed diagnostic" unless
    stderr == "failure evidence contains a vault value\n"

  near_paths = [
    "prefix#{synthetic_root}/roles/service/tasks/main.yml",
    "/#{synthetic_root}/roles/service/tasks/main.yml",
    "file://#{synthetic_root}/roles/service/tasks/main.yml",
    "#{synthetic_root}-suffix/roles/service/tasks/main.yml",
    "#{synthetic_root}//roles/service/tasks/main.yml",
    "#{synthetic_root}://roles/service/tasks/main.yml",
    "#{File.dirname(synthetic_root)}/repository-near/roles/service/tasks/main.yml"
  ]
  near_paths.each do |near_path|
    stdout, stderr, status = run_scanner(
      vault,
      "Origin: #{near_path}\n",
      scanner: synthetic_scanner
    )
    failures << "near controller path was normalized: #{File.basename(near_path)}" if status.success?
    failures << "near controller path rejection disclosed evidence" unless stdout.empty?
    failures << "near controller path changed the fixed diagnostic" unless
      stderr == "failure evidence contains a vault value\n"
  end

  credential = "synthetic-credential-must-fail"
  stdout, stderr, status = run_scanner(
    "#{vault}vault_service_password: #{credential}\n",
    "Origin: #{synthetic_root}/roles/service/tasks/main.yml\ncredential=#{credential}\n",
    scanner: synthetic_scanner
  )
  failures << "controller-path normalization hid a credential" if status.success?
  failures << "credential rejection disclosed evidence" unless stdout.empty?
  failures << "credential rejection changed the fixed diagnostic" unless
    stderr == "failure evidence contains a vault value\n"
end

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
