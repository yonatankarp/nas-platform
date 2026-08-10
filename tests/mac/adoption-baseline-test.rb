#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"
require "yaml"

ROOT = File.expand_path("../..", __dir__)
RECORDER = File.join(__dir__, "adoption-baseline.rb")
SERVICES = %w[
  audiobookshelf beszel dozzle immich jellyfin komga ntfy paperless-ngx tinymediamanager
].freeze
COMMIT = "400f03f276ae1bb69f5460c175b9fb923d620f1a"
CANARY = "baseline-canary-must-never-publish"
IMAGE_DIGEST = "sha256:#{'1' * 64}"

def evidence(service)
  identity = { "name" => "#{service}-operator", "role" => "administrator", "enabled" => true }
  case service
  when "audiobookshelf"
    identity["permissions"] = ["all"]
    { "identities" => [identity], "record_counts" => { "items" => 1, "libraries" => 1, "users" => 1 },
      "fixture_sha256" => { "audiobook" => "a" * 64 },
      "managed_settings" => { "library_name" => "Audiobooks", "media_type" => "book" } }
  when "beszel"
    { "identities" => [identity], "record_counts" => { "alerts" => 1, "systems" => 1, "users" => 1 },
      "fixture_sha256" => {}, "managed_settings" => { "system_name" => "portable-fixture" } }
  when "dozzle"
    identity["permissions"] = ["read"]
    { "identities" => [identity], "record_counts" => { "dispatchers" => 1, "rules" => 1, "users" => 1 },
      "fixture_sha256" => {}, "managed_settings" => { "dispatcher_name" => "ntfy" } }
  when "immich"
    { "identities" => [identity], "record_counts" => { "assets" => 2, "users" => 1 },
      "fixture_sha256" => { "photo" => "b" * 64, "video" => "c" * 64 },
      "managed_settings" => { "database_backup" => true, "machine_learning" => true,
                                "new_version_check" => false } }
  when "jellyfin"
    identity["permissions"] = ["IsAdministrator"]
    { "identities" => [identity], "record_counts" => { "items" => 1, "libraries" => 1, "users" => 1 },
      "fixture_sha256" => { "video" => "d" * 64 },
      "managed_settings" => { "library_name" => "Movies" } }
  when "komga"
    identity["permissions"] = ["ADMIN"]
    { "identities" => [identity], "record_counts" => { "books" => 1, "libraries" => 1, "series" => 1, "users" => 1 },
      "fixture_sha256" => { "book" => "e" * 64 },
      "managed_settings" => { "library_name" => "Books" } }
  when "ntfy"
    identity["permissions"] = ["admin"]
    { "identities" => [identity], "record_counts" => { "access_rules" => 1, "users" => 1 },
      "fixture_sha256" => {}, "managed_settings" => { "topic" => "nas-critical" } }
  when "paperless-ngx"
    { "identities" => [identity], "record_counts" => { "documents" => 1, "mail_accounts" => 1, "users" => 1 },
      "fixture_sha256" => { "document" => "f" * 64 },
      "managed_settings" => { "mail_account_name" => "paperless" } }
  when "tinymediamanager"
    { "identities" => [identity], "record_counts" => { "movies" => 1, "shows" => 1 },
      "fixture_sha256" => { "episode" => "1" * 64, "movie" => "2" * 64 },
      "managed_settings" => { "api_enabled" => true } }
  else
    raise "unknown fixture service"
  end
end

def write_executable(path, body)
  File.write(path, body)
  File.chmod(0o700, path)
end

def recorder_invocation(root, output, extra_env = {}, extra_args = [])
  env = {
    "PATH" => "#{root}/bin:#{ENV.fetch("PATH")}",
    "PLATFORM_ADOPTION_BASELINE_CANARIES" => CANARY,
    "PLATFORM_PROJECT_NAME" => "proof",
    "PLATFORM_MAC_SANDBOX" => root,
    "PLATFORM_MAC_VAULT_FILE" => "#{root}/vault.yml",
    "PLATFORM_MAC_VAULT_PASSWORD_FILE" => "#{root}/vault-password"
  }.merge(extra_env)
  arguments = [
    RECORDER, "--output", output, "--legacy-commit", COMMIT,
    "--manifest", "#{root}/manifest.json", "--legacy-root", "#{root}/legacy",
    "--override-root", "#{root}/overrides", "--env-root", "#{root}/env",
    "--probe-root", "#{root}/probes", *extra_args
  ]
  [env, arguments]
end

def run_recorder(root, output, extra_env = {}, extra_args = [])
  env, arguments = recorder_invocation(root, output, extra_env, extra_args)
  Open3.capture3(env, *arguments)
end

failures = []
adoption_source = File.read(File.join(__dir__, "adoption.sh"))
failures << "adoption coordinator omits capture-baseline" unless adoption_source.include?("preflight|render|legacy-deploy|legacy-seed|capture-baseline)")
failures << "adoption coordinator does not invoke recorder" unless adoption_source.include?('"$script_dir/adoption-baseline.rb"')
failures << "adoption coordinator publishes outside the sandbox" unless adoption_source.include?('"$sandbox/baseline.json"')
recorder_prefix = File.read(RECORDER).split(/^def emit_probe\b/, 2).first
probe_library = File.read(RECORDER).split(/^if ARGV.first == "--emit-probe"/, 2).first
ntfy_collision_contract = recorder_prefix + <<~'RUBY'
  input = <<~LIST
    user * (role: anonymous, tier: none)
    - no access to any (other) topics (server config)
    user Reader (role: user, tier: none)
    - no topic-specific permissions
    user reader (role: user, tier: none)
    - no topic-specific permissions
  LIST
  begin
    ntfy_live_users(input)
  rescue StandardError
    exit 0
  end
  exit 1
RUBY
_parser_output, _parser_diagnostic, parser_status = Open3.capture3(
  RbConfig.ruby, "-e", ntfy_collision_contract
)
failures << "ntfy parser collapsed mixed-case identities" unless parser_status.success?
ntfy_acl_contract = recorder_prefix + <<~'RUBY'
  input = <<~LIST
    user * (role: anonymous, tier: none)
    - no access to any (other) topics (server config)
    user Reader (role: user, tier: none)
    - read-only access to topic nas-critical
    - write-only access to topic side-channel
    user Unmanaged (role: user, tier: none)
    - no topic-specific permissions
  LIST
  expected = [
    { "name" => "Reader", "role" => "user", "permissions" => [
      "read-only access to topic nas-critical", "write-only access to topic side-channel"
    ] },
    { "name" => "Unmanaged", "role" => "user", "permissions" => ["no topic-specific permissions"] }
  ]
  exit(ntfy_live_users(input) == expected ? 0 : 1)
RUBY
_acl_output, _acl_diagnostic, acl_status = Open3.capture3(RbConfig.ruby, "-e", ntfy_acl_contract)
failures << "ntfy parser did not preserve multiple ACLs/unmanaged users" unless acl_status.success?
casefold_contract = recorder_prefix + <<~'RUBY'
  exit(canonical_identity_name("Straße") == canonical_identity_name("STRASSE") ? 0 : 1)
RUBY
_fold_output, _fold_diagnostic, fold_status = Open3.capture3(RbConfig.ruby, "-e", casefold_contract)
failures << "identity normalization does not use full case folding" unless fold_status.success?
Dir.mktmpdir("beszel-probe-test-") do |probe_root|
  FileUtils.mkdir_p("#{probe_root}/bin")
  File.write("#{probe_root}/vault.yml", "encrypted\n")
  File.write("#{probe_root}/vault-password", "internal\n")
  File.chmod(0o600, "#{probe_root}/vault.yml")
  File.chmod(0o600, "#{probe_root}/vault-password")
  write_executable("#{probe_root}/bin/ansible-vault", <<~'SH')
    #!/bin/sh
    printf '%s\n' 'vault_beszel_superuser_email: root@example.test'
    printf '%s\n' 'vault_beszel_superuser_password: internal-only'
  SH
  beszel_contract = probe_library + <<~'RUBY'
    def http_json(method, url, **_options)
      payload = case url
                when /auth-with-password/ then { "token" => "internal-token" }
                when %r{/_superusers/records} then {
                  "totalPages" => 1, "items" => [
                    { "email" => "root@example.test", "verified" => true },
                    { "email" => "audit@example.test", "verified" => true }
                  ]
                }
                when %r{/users/records} then {
                  "totalPages" => 1, "items" => [
                    { "email" => "reader@example.test", "role" => "user", "verified" => true }
                  ]
                }
                when %r{/systems/records} then {
                  "totalPages" => 1, "items" => [{ "name" => "ASUSTOR-AS6704T" }]
                }
                when %r{/alerts/records} then { "totalPages" => 1, "items" => [{ "id" => "alert" }] }
                else raise "unexpected request: #{url}"
                end
      [Object.new, payload]
    end
    emit_probe("beszel")
  RUBY
  probe_env = {
    "PATH" => "#{probe_root}/bin:#{ENV.fetch('PATH')}",
    "PLATFORM_MAC_VAULT_FILE" => "#{probe_root}/vault.yml",
    "PLATFORM_MAC_VAULT_PASSWORD_FILE" => "#{probe_root}/vault-password",
    "PLATFORM_MAC_SANDBOX" => probe_root,
    "PLATFORM_BESZEL_PORT" => "18090",
    "PLATFORM_PROJECT_NAME" => "proof"
  }
  beszel_output, beszel_error, beszel_status = Open3.capture3(probe_env, RbConfig.ruby, "-e", beszel_contract)
  if beszel_status.success?
    identities = JSON.parse(beszel_output).fetch("identities")
    failures << "Beszel probe omitted live superusers" unless identities.map { |entry| entry.fetch("name") }.sort == [
      "audit@example.test", "reader@example.test", "root@example.test"
    ]
  else
    failures << "Beszel live superuser contract failed: #{beszel_error}"
  end
end
Dir.mktmpdir("tmm-probe-test-") do |probe_root|
  FileUtils.mkdir_p([
    "#{probe_root}/bin", "#{probe_root}/legacy/tinymediamanager/data/templates",
    "#{probe_root}/legacy/tinymediamanager/movies/Task 10 Contract Movie (2024)",
    "#{probe_root}/legacy/tinymediamanager/series/Task 10 Contract Series/Season 01"
  ])
  File.write("#{probe_root}/vault.yml", "encrypted\n")
  File.write("#{probe_root}/vault-password", "internal\n")
  File.chmod(0o600, "#{probe_root}/vault.yml")
  File.chmod(0o600, "#{probe_root}/vault-password")
  File.binwrite(
    "#{probe_root}/legacy/tinymediamanager/movies/Task 10 Contract Movie (2024)/Task 10 Contract Movie (2024).mp4",
    "movie"
  )
  File.binwrite(
    "#{probe_root}/legacy/tinymediamanager/series/Task 10 Contract Series/Season 01/Task 10 Contract Series - S01E01.mp4",
    "episode"
  )
  write_executable("#{probe_root}/bin/ansible-vault", <<~'SH')
    #!/bin/sh
    printf '%s\n' 'vault_tinymediamanager_password: internal-only'
  SH
  tmm_contract = probe_library + <<~RUBY
    def http_json(_method, url, body:, headers:, **_options)
      raise "missing tinyMediaManager API key" unless headers == { "api-key" => "internal-only" }
      module_name = url.end_with?("/movie") ? "movie" : "tvshow"
      count = module_name == "movie" ? 3 : 2
      host_root = File.join(ENV.fetch("PLATFORM_MAC_SANDBOX"), "legacy/tinymediamanager/data")
      output_name = File.basename(body.fetch("args").fetch("exportPath"))
      File.binwrite(File.join(host_root, output_name, "index.html"), "record\n" * count)
      [Object.new, nil]
    end
    emit_probe("tinymediamanager")
  RUBY
  probe_env = {
    "PATH" => "#{probe_root}/bin:#{ENV.fetch('PATH')}",
    "PLATFORM_MAC_VAULT_FILE" => "#{probe_root}/vault.yml",
    "PLATFORM_MAC_VAULT_PASSWORD_FILE" => "#{probe_root}/vault-password",
    "PLATFORM_MAC_SANDBOX" => probe_root,
    "PLATFORM_TINYMEDIAMANAGER_API_PORT" => "17878",
    "PLATFORM_PROJECT_NAME" => "proof"
  }
  tmm_output, tmm_error, tmm_status = Open3.capture3(
    probe_env, RbConfig.ruby, "-e", tmm_contract, chdir: __dir__
  )
  if tmm_status.success?
    counts = JSON.parse(tmm_output).fetch("record_counts")
    failures << "tinyMediaManager probe did not use indexed export counts" unless counts == {
      "movies" => 3, "shows" => 2
    }
    leftovers = Dir.glob("#{probe_root}/legacy/tinymediamanager/data/{.nas-adoption-*,templates/nas-adoption-*}")
    failures << "tinyMediaManager probe left export artifacts" unless leftovers.empty?
  else
    failures << "tinyMediaManager export contract failed: #{tmm_error}"
  end
end
Dir.mktmpdir("adoption-baseline-test-") do |root|
  root = File.realpath(root)
  FileUtils.mkdir_p(["#{root}/bin", "#{root}/legacy", "#{root}/committed", "#{root}/overrides", "#{root}/env", "#{root}/probes"])
  manifest = {
    "legacy_source" => { "repository" => "example/legacy", "commit" => COMMIT },
    "services" => SERVICES.map { |name| { "name" => name, "legacy_path" => "#{name}.yml" } }
  }
  File.write("#{root}/manifest.json", JSON.generate(manifest))
  File.write("#{root}/vault.yml", "encrypted\n")
  File.write("#{root}/vault-password", "protected\n")
  File.chmod(0o600, "#{root}/vault.yml")
  File.chmod(0o600, "#{root}/vault-password")
  SERVICES.each do |service|
    images = service == "immich" ? ["immich", "shared", "shared"] : [service]
    compose = {
      "services" => images.each_with_index.to_h do |image, index|
        ["container#{index}", { "image" => "registry.invalid/#{image}@#{IMAGE_DIGEST}" }]
      end
    }.to_yaml
    File.write("#{root}/legacy/#{service}.yml", compose)
    File.write("#{root}/committed/#{service}.yml", compose)
    File.write("#{root}/overrides/#{service}.yml", "services: {}\n")
    File.write("#{root}/env/#{service}.env", "SAFE=1\n")
    write_executable("#{root}/probes/#{service}.sh", <<~SH)
      #!/bin/sh
      case "$0" in '#{root}'/.adoption-inputs-*/#{service}.sh) ;; *) exit 70 ;; esac
      case "$PLATFORM_MAC_VAULT_FILE" in '#{root}'/.adoption-private-*/vault.yml) ;; *) exit 73 ;; esac
      mv '#{root}/probes/#{service}.sh' '#{root}/probes/#{service}.saved'
      printf '%s\n' '#!/bin/sh' 'exit 71' > '#{root}/probes/#{service}.sh'
      mv '#{root}/probes/#{service}.saved' '#{root}/probes/#{service}.sh'
      printf '%s\\n' '#{JSON.generate(evidence(service))}'
      printf '%s\\n' 'probe-ok: #{service}' >&2
    SH
  end
  write_executable("#{root}/bin/docker", <<~SH)
    #!/bin/sh
    case "$*" in *'#{root}/.adoption-inputs-'*) ;; *) exit 72 ;; esac
    project=
    while [ "$#" -gt 0 ]; do
      [ "$1" = --project-name ] && { project=$2; shift 2; continue; }
      shift
    done
    service=${project##*-legacy-}
    printf 'registry.invalid/%s@#{IMAGE_DIGEST}\n' "$service"
    [ "$service" = immich ] && printf 'registry.invalid/shared@#{IMAGE_DIGEST}\nregistry.invalid/shared@#{IMAGE_DIGEST}\n'
    exit 0
  SH
  write_executable("#{root}/bin/ansible-vault", <<~'SH')
    #!/bin/sh
    printf '%s\n' 'vault_test_password: recorder-private-canary'
  SH
  write_executable("#{root}/bin/git", <<~'SH')
    #!/bin/sh
    root=$2
    shift 2
    case "$1:$2" in
      remote:get-url)
        parent=${root%/legacy}
        count=0
        [ ! -f "$parent/git-origin-count" ] || count=$(cat "$parent/git-origin-count")
        count=$((count + 1))
        printf '%s\n' "$count" > "$parent/git-origin-count"
        if [ "$count" -ge 3 ] && [ -f "$parent/race-output-final" ]; then
          printf '%s\n' 'external-baseline' > "$parent/baseline.json"
        fi
        if [ "$count" -ge 3 ] && [ -f "$parent/race-staging-final" ]; then
          for staging in "$parent"/.adoption-baseline-*.json; do
            [ ! -f "$staging" ] || printf '%s\n' 'corrupted-staging' > "$staging"
          done
        fi
        if [ -f "$parent/git-origin" ]; then cat "$parent/git-origin"; else printf '%s\n' 'https://github.com/example/legacy.git'; fi
        ;;
      rev-parse:--show-toplevel) printf '%s\n' "$root" ;;
      rev-parse:HEAD)
        parent=${root%/legacy}
        if [ -f "$parent/git-head" ]; then cat "$parent/git-head"; else printf '%s\n' '400f03f276ae1bb69f5460c175b9fb923d620f1a'; fi
        ;;
      status:--porcelain=v1)
        parent=${root%/legacy}
        [ ! -f "$parent/git-dirty" ] || printf '%s\n' ' M beszel.yml'
        ;;
      cat-file:blob)
        relative=${3#*:}
        parent=${root%/legacy}
        cat "$parent/committed/$relative"
        ;;
      *) exit 2 ;;
    esac
  SH
  git_fixture, git_fixture_error, git_fixture_status = Open3.capture3(
    { "PATH" => "#{root}/bin:#{ENV.fetch('PATH')}" },
    "git", "-C", "#{root}/legacy", "cat-file", "blob", "#{COMMIT}:beszel.yml"
  )
  abort "fake git fixture failed: #{git_fixture_error}" unless
    git_fixture_status.success? && git_fixture == File.binread("#{root}/committed/beszel.yml")

  output = "#{root}/baseline.json"
  stdout, stderr, status = run_recorder(root, output)
  failures << "valid capture failed: #{stdout} #{stderr}" unless status.success?
  abort failures.join("\n") unless File.exist?(output)
  if status.success?
    parsed = JSON.parse(File.read(output))
    failures << "root schema differs" unless parsed.keys == %w[schema legacy_commit legacy_images services]
    failures << "schema differs" unless parsed["schema"] == 1
    failures << "commit differs" unless parsed["legacy_commit"] == COMMIT
    failures << "service set differs" unless parsed.fetch("services").keys == SERVICES
    failures << "image service set differs" unless parsed.fetch("legacy_images").keys == SERVICES
    failures << "duplicate images were collapsed" unless parsed.dig("legacy_images", "immich") == [
      "registry.invalid/immich@#{IMAGE_DIGEST}", "registry.invalid/shared@#{IMAGE_DIGEST}",
      "registry.invalid/shared@#{IMAGE_DIGEST}"
    ]
    failures << "baseline mode differs" unless (File.stat(output).mode & 0o777) == 0o600
    failures << "baseline contains canary" if File.binread(output).include?(CANARY)
  end

  original = File.binread(output)
  original_mode = File.stat(output).mode & 0o777
  lock_path = "#{root}/.baseline.json.lock"
  File.unlink(lock_path) if File.exist?(lock_path)
  File.symlink("#{root}/sentinel-lock", lock_path)
  _lock_out, _lock_error, lock_status = run_recorder(root, output)
  failures << "symlink publication lock was accepted" if lock_status.success?
  failures << "symlink publication lock replaced baseline" unless File.binread(output) == original
  File.unlink(lock_path)
  duplicate_output = "#{root}/duplicate-output.json"
  _duplicate_out, _duplicate_error, duplicate_status = run_recorder(
    root, output, {}, ["--output", duplicate_output]
  )
  failures << "duplicate CLI option was accepted" if duplicate_status.success?
  failures << "duplicate CLI option published output" if File.exist?(duplicate_output)
  failures << "duplicate CLI option replaced baseline" unless File.binread(output) == original
  first_concurrent = evidence("beszel").merge(
    "record_counts" => { "alerts" => 2, "systems" => 1, "users" => 1 }
  )
  second_concurrent = evidence("beszel").merge(
    "record_counts" => { "alerts" => 3, "systems" => 1, "users" => 1 }
  )
  write_executable("#{root}/probes/beszel.sh", <<~SH)
    #!/bin/sh
    count=0
    [ ! -f '#{root}/concurrent-count' ] || count=$(cat '#{root}/concurrent-count')
    count=$((count + 1))
    printf '%s\n' "$count" > '#{root}/concurrent-count'
    if [ "$count" -eq 1 ]; then
      : > '#{root}/concurrent-started'
      while [ ! -f '#{root}/concurrent-release' ]; do sleep 0.02; done
      printf '%s\n' '#{JSON.generate(first_concurrent)}'
    else
      printf '%s\n' '#{JSON.generate(second_concurrent)}'
    fi
  SH
  concurrent_env, concurrent_arguments = recorder_invocation(root, output)
  first_pid = Process.spawn(concurrent_env, *concurrent_arguments, out: File::NULL, err: File::NULL)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
  until File.exist?("#{root}/concurrent-started")
    raise "concurrent recorder did not reach probe" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    sleep 0.02
  end
  second_pid = Process.spawn(concurrent_env, *concurrent_arguments, out: File::NULL, err: File::NULL)
  sleep 0.2
  File.write("#{root}/concurrent-release", "release\n")
  _, first_status = Process.wait2(first_pid)
  _, second_status = Process.wait2(second_pid)
  failures << "concurrent recorders failed" unless first_status.success? && second_status.success?
  final_alerts = JSON.parse(File.binread(output)).dig("services", "beszel", "record_counts", "alerts")
  failures << "concurrent recorder lost the serialized update" unless final_alerts == 3
  File.binwrite(output, original)
  File.chmod(original_mode, output)
  %w[concurrent-count concurrent-started concurrent-release].each do |name|
    File.unlink("#{root}/#{name}") if File.exist?("#{root}/#{name}")
  end
  write_executable("#{root}/probes/beszel.sh", <<~SH)
    #!/bin/sh
    printf '%s\n' '#{JSON.generate(evidence("beszel"))}'
  SH
  File.unlink("#{root}/git-origin-count") if File.exist?("#{root}/git-origin-count")
  race_evidence = evidence("beszel").merge(
    "record_counts" => { "alerts" => 2, "systems" => 1, "users" => 1 }
  )
  race_mutations = {
    "origin swap" => "printf '%s\\n' 'https://github.com/example/other.git' > '#{root}/git-origin'",
    "HEAD swap" => "printf '%s\\n' '#{'f' * 40}' > '#{root}/git-head'",
    "dirty checkout" => ": > '#{root}/git-dirty'",
    "pinned blob replacement" => "printf '%s\\n' 'services: {changed: {}}' > '#{root}/committed/beszel.yml'",
    "tracked source replacement" => "printf '%s\\n' 'services: {changed: {}}' > '#{root}/legacy/beszel.yml'",
    "vault snapshot replacement" => "mv \"$PLATFORM_MAC_VAULT_FILE\" \"$PLATFORM_MAC_VAULT_FILE.saved\"; " \
                                    "printf '%s\\n' 'replacement' > \"$PLATFORM_MAC_VAULT_FILE\"; " \
                                    "mv \"$PLATFORM_MAC_VAULT_FILE.saved\" \"$PLATFORM_MAC_VAULT_FILE\""
  }
  race_mutations.each do |label, mutation|
    File.unlink("#{root}/git-origin-count") if File.exist?("#{root}/git-origin-count")
    write_executable("#{root}/probes/beszel.sh", <<~SH)
      #!/bin/sh
      printf '%s\\n' '#{JSON.generate(race_evidence)}'
      #{mutation}
    SH
    _out, _diagnostic, rejected = run_recorder(root, output)
    failures << "#{label} during probe was accepted" if rejected.success?
    failures << "#{label} during probe replaced baseline" unless File.binread(output) == original
    failures << "#{label} during probe changed baseline mode" unless
      (File.stat(output).mode & 0o777) == original_mode
    failures << "#{label} left baseline staging files" unless
      Dir.glob("#{root}/.adoption-baseline-*.json").empty?
    File.unlink("#{root}/git-origin") if File.exist?("#{root}/git-origin")
    File.unlink("#{root}/git-head") if File.exist?("#{root}/git-head")
    File.unlink("#{root}/git-dirty") if File.exist?("#{root}/git-dirty")
    File.write("#{root}/committed/beszel.yml", {
      "services" => { "container0" => { "image" => "registry.invalid/beszel@#{IMAGE_DIGEST}" } }
    }.to_yaml)
    FileUtils.cp("#{root}/committed/beszel.yml", "#{root}/legacy/beszel.yml")
    File.binwrite(output, original)
    File.chmod(original_mode, output)
  end

  {
    "existing baseline final-window mutation" => ["race-output-final", "external-baseline\n"],
    "staging final-window mutation" => ["race-staging-final", original]
  }.each do |label, (marker, expected_bytes)|
    File.unlink("#{root}/git-origin-count") if File.exist?("#{root}/git-origin-count")
    write_executable("#{root}/probes/beszel.sh", <<~SH)
      #!/bin/sh
      printf '%s\\n' '#{JSON.generate(race_evidence)}'
      : > '#{root}/#{marker}'
    SH
    _out, _diagnostic, rejected = run_recorder(root, output)
    failures << "#{label} was accepted" if rejected.success?
    failures << "#{label} published unexpected bytes" unless File.binread(output) == expected_bytes
    failures << "#{label} left baseline staging files" unless
      Dir.glob("#{root}/.adoption-baseline-*.json").empty?
    File.unlink("#{root}/#{marker}")
    File.binwrite(output, original)
    File.chmod(original_mode, output)
  end
  write_executable("#{root}/probes/beszel.sh", <<~SH)
    #!/bin/sh
    printf '%s\\n' '#{JSON.generate(evidence("beszel"))}'
  SH

  SERVICES.each do |service|
    duplicate = evidence(service)
    second = duplicate.fetch("identities").first.merge(
      "name" => duplicate.fetch("identities").first.fetch("name").upcase
    )
    duplicate["identities"] = duplicate.fetch("identities") + [second]
    write_executable("#{root}/probes/#{service}.sh", <<~SH)
      #!/bin/sh
      printf '%s\\n' '#{JSON.generate(duplicate)}'
    SH
    _out, _diagnostic, rejected = run_recorder(root, output)
    failures << "#{service} mixed-case duplicate identity was accepted" if rejected.success?
    failures << "#{service} mixed-case duplicate replaced baseline" unless File.binread(output) == original
    File.binwrite(output, original)
    File.chmod(original_mode, output)
    write_executable("#{root}/probes/#{service}.sh", <<~SH)
      #!/bin/sh
      printf '%s\\n' '#{JSON.generate(evidence(service))}'
    SH
  end

  unicode_duplicate = evidence("audiobookshelf")
  unicode_duplicate.fetch("identities").first["name"] = "RÉADER"
  unicode_duplicate["identities"] << unicode_duplicate.fetch("identities").first.merge(
    "name" => "re\u0301ader"
  )
  write_executable("#{root}/probes/audiobookshelf.sh", <<~SH)
    #!/bin/sh
    printf '%s\\n' '#{JSON.generate(unicode_duplicate)}'
  SH
  _out, _diagnostic, rejected = run_recorder(root, output)
  failures << "Unicode-normalized duplicate identity was accepted" if rejected.success?
  failures << "Unicode-normalized duplicate replaced baseline" unless File.binread(output) == original
  write_executable("#{root}/probes/audiobookshelf.sh", <<~SH)
    #!/bin/sh
    printf '%s\\n' '#{JSON.generate(evidence("audiobookshelf"))}'
  SH

  File.open("#{root}/legacy/beszel.yml", "a") { |file| file.write("# changed\n") }
  _out, _diagnostic, rejected = run_recorder(root, output)
  failures << "changed pinned compose file was accepted" if rejected.success?
  failures << "changed pinned compose file replaced baseline" unless File.binread(output) == original
  FileUtils.cp("#{root}/committed/beszel.yml", "#{root}/legacy/beszel.yml")

  short_evidence = evidence("beszel").merge("managed_settings" => { "system_name" => "short" })
  write_executable("#{root}/probes/beszel.sh", "#!/bin/sh\nprintf '%s\\n' '#{JSON.generate(short_evidence)}'\n")
  _out, diagnostic, rejected = run_recorder(
    root, output, "PLATFORM_ADOPTION_BASELINE_CANARIES" => "short"
  )
  failures << "short secret canary was accepted" if rejected.success?
  failures << "short secret canary leaked" if diagnostic.include?("short")
  failures << "short secret canary replaced baseline" unless File.binread(output) == original

  rejection_cases = {
    "unknown field" => evidence("beszel").merge("unexpected" => true),
    "secret-like nested key" => evidence("beszel").merge("managed_settings" => { "private_note" => "x" }),
    "secret canary value" => evidence("beszel").merge("managed_settings" => { "system_name" => CANARY }),
    "noncanonical count" => evidence("beszel").merge("record_counts" => { "alerts" => 1.0, "systems" => 1, "users" => 1 }),
    "identity count mismatch" => evidence("beszel").merge("record_counts" => { "alerts" => 1, "systems" => 1, "users" => 2 })
  }
  rejection_cases.each do |label, bad_evidence|
    write_executable("#{root}/probes/beszel.sh", "#!/bin/sh\nprintf '%s\\n' '#{JSON.generate(bad_evidence)}'\n")
    _out, diagnostic, rejected = run_recorder(root, output)
    failures << "#{label} was accepted" if rejected.success?
    failures << "#{label} leaked canary" if diagnostic.include?(CANARY)
    failures << "#{label} replaced baseline" unless File.binread(output) == original
    failures << "#{label} changed baseline mode" unless (File.stat(output).mode & 0o777) == original_mode
  end

  duplicate_json = JSON.generate(evidence("beszel")).sub('"system_name":"portable-fixture"', '"system_name":"portable-fixture","system_name":"other"')
  write_executable("#{root}/probes/beszel.sh", "#!/bin/sh\nprintf '%s\\n' '#{duplicate_json}'\n")
  _out, _diagnostic, rejected = run_recorder(root, output)
  failures << "duplicate JSON key was accepted" if rejected.success?
  failures << "duplicate JSON key replaced baseline" unless File.binread(output) == original

  write_executable("#{root}/probes/beszel.sh", "#!/bin/sh\nprintf '%s\\n' '#{JSON.generate(evidence("beszel"))}'\nprintf '%s\\n' '#{CANARY}' >&2\n")
  _out, diagnostic, rejected = run_recorder(root, output)
  failures << "diagnostic canary was accepted" if rejected.success?
  failures << "diagnostic canary leaked" if diagnostic.include?(CANARY)
  failures << "diagnostic canary replaced baseline" unless File.binread(output) == original

  {
    "multiple JSON objects" => "#{JSON.generate(evidence("beszel"))}\n{}",
    "NaN value" => JSON.generate(evidence("beszel")).sub('"alerts":1', '"alerts":NaN')
  }.each do |label, raw_json|
    write_executable("#{root}/probes/beszel.sh", "#!/bin/sh\nprintf '%s\\n' '#{raw_json}'\n")
    _out, _diagnostic, rejected = run_recorder(root, output)
    failures << "#{label} was accepted" if rejected.success?
    failures << "#{label} replaced baseline" unless File.binread(output) == original
    File.binwrite(output, original)
    File.chmod(original_mode, output)
  end
  write_executable("#{root}/probes/beszel.sh", <<~SH)
    #!/bin/sh
    printf '%s\n' '#{JSON.generate(evidence("beszel"))}'
  SH
  _out, _diagnostic, valid_again = run_recorder(root, output)
  failures << "image test precondition failed" unless valid_again.success?

  {
    "mutable image" => "registry.invalid/beszel:latest",
    "override image substitution" => "registry.invalid/beszel@sha256:#{'2' * 64}"
  }.each do |label, bad_image|
    write_executable("#{root}/bin/docker", <<~SH)
      #!/bin/sh
      project=
      files=0
      while [ "$#" -gt 0 ]; do
        [ "$1" = --project-name ] && { project=$2; shift 2; continue; }
        [ "$1" = -f ] && { files=$((files + 1)); shift 2; continue; }
        shift
      done
      service=${project##*-legacy-}
      if [ "$service" = beszel ] && [ "$files" -gt 1 ]; then
        printf '%s\n' '#{bad_image}'
      else
        printf 'registry.invalid/%s@#{IMAGE_DIGEST}\n' "$service"
        [ "$service" = immich ] && printf 'registry.invalid/shared@#{IMAGE_DIGEST}\nregistry.invalid/shared@#{IMAGE_DIGEST}\n'
      fi
      exit 0
    SH
    _out, _diagnostic, rejected = run_recorder(root, output)
    failures << "#{label} was accepted" if rejected.success?
    failures << "#{label} replaced baseline" unless File.binread(output) == original
    File.binwrite(output, original)
    File.chmod(original_mode, output)
  end

  write_executable("#{root}/bin/docker", "#!/bin/sh\nprintf '%s\\n' '#{CANARY}'\n")
  _out, diagnostic, rejected = run_recorder(root, output)
  failures << "image canary was accepted" if rejected.success?
  failures << "image canary leaked" if diagnostic.include?(CANARY)
  failures << "image canary replaced baseline" unless File.binread(output) == original

  File.unlink(output)
  File.symlink("#{root}/sentinel", output)
  _out, _diagnostic, rejected = run_recorder(root, output)
  failures << "symlink output was accepted" if rejected.success?
end

abort failures.join("\n") unless failures.empty?
puts "adoption baseline tests: passed"
