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

def recorder_invocation(root, output, extra_env = {}, extra_args = [], path_overrides = {})
  env = {
    "PATH" => "#{root}/bin:#{ENV.fetch("PATH")}",
    "PLATFORM_ADOPTION_BASELINE_CANARIES" => CANARY,
    "PLATFORM_PROJECT_NAME" => "proof",
    "PLATFORM_MAC_SANDBOX" => root,
    "PLATFORM_MAC_VAULT_FILE" => "#{root}/vault.yml",
    "PLATFORM_MAC_VAULT_PASSWORD_FILE" => "#{root}/vault-password"
  }.merge(extra_env)
  arguments = [
    path_overrides.fetch(:recorder, RECORDER), "--output", output, "--legacy-commit", COMMIT,
    "--manifest", path_overrides.fetch(:manifest, "#{root}/manifest.json"),
    "--legacy-root", path_overrides.fetch(:legacy_root, "#{root}/legacy"),
    "--override-root", path_overrides.fetch(:override_root, "#{root}/overrides"),
    "--env-root", path_overrides.fetch(:env_root, "#{root}/env"),
    "--probe-root", path_overrides.fetch(:probe_root, "#{root}/probes"), *extra_args
  ]
  [env, arguments]
end

def run_recorder(root, output, extra_env = {}, extra_args = [], path_overrides = {})
  env, arguments = recorder_invocation(root, output, extra_env, extra_args, path_overrides)
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
ancestor_policy_contract = recorder_prefix + <<~'RUBY'
  stat = Struct.new(:uid, :mode) do
    def directory? = true
  end
  directory = 0o040000
  cases = [
    [stat.new(0, directory | 0o1777), false, true],
    [stat.new(0, directory | 0o0777), false, false],
    [stat.new(Process.uid, directory | 0o1777), false, false],
    [stat.new(0, directory | 0o1777), true, false],
    [stat.new(Process.uid, directory | 0o0755), true, true]
  ]
  descriptor_safe = Dir.mktmpdir do |root|
    File.binwrite(File.join(root, "input"), "x")
    parent = File.open(root, File::RDONLY)
    opened = open_component(parent, "input")
    opened.close_on_exec?
  ensure
    opened&.close
    parent&.close
  end
  valid = cases.all? do |entry, trusted, expected|
    safe_capture_directory?(entry, trusted: trusted) == expected
  end
  exit(valid && descriptor_safe ? 0 : 1)
RUBY
_policy_output, _policy_diagnostic, policy_status = Open3.capture3(
  RbConfig.ruby, "-e", ancestor_policy_contract
)
failures << "sticky temporary ancestor policy differs" unless policy_status.success?
tmm_fixture_contract = recorder_prefix + <<~'RUBY'
  root = ENV.fetch("TMM_MEDIA_ROOT")
  relative = "Task 10 Contract Movie (2024)/Task 10 Contract Movie (2024).mp4"
  expected = Digest::SHA256.hexdigest("fixture")
  exit 2 unless tmm_fixture_digest(root, relative) == expected
  class File
    alias adoption_original_read read

    def read(*arguments)
      if ENV["TMM_MUTATE"] == "1" && stat.ino == Integer(ENV.fetch("TMM_FIXTURE_INODE"))
        ENV["TMM_MUTATE"] = "done"
        parent = ENV.fetch("TMM_FIXTURE_PARENT")
        File.rename(parent, "#{parent}.saved")
        File.symlink("#{parent}.saved", parent)
        File.unlink(parent)
        File.rename("#{parent}.saved", parent)
      end
      adoption_original_read(*arguments)
    end
  end
  ENV["TMM_MUTATE"] = "1"
  begin
    tmm_fixture_digest(root, relative)
  rescue StandardError
    exit 0
  end
  exit 1
RUBY
Dir.mktmpdir("tmm-fixture-reader-") do |fixture_root|
  fixture_root = File.realpath(fixture_root)
  movie_root = File.join(fixture_root, "movies")
  fixture_parent = File.join(movie_root, "Task 10 Contract Movie (2024)")
  FileUtils.mkdir_p(fixture_parent)
  File.chmod(0o700, movie_root)
  File.chmod(0o777, fixture_parent)
  fixture = File.join(fixture_parent, "Task 10 Contract Movie (2024).mp4")
  File.binwrite(fixture, "fixture")
  _output, _diagnostic, fixture_status = Open3.capture3({
    "TMM_MEDIA_ROOT" => movie_root,
    "TMM_FIXTURE_PARENT" => fixture_parent,
    "TMM_FIXTURE_INODE" => File.stat(fixture).ino.to_s
  }, RbConfig.ruby, "-e", tmm_fixture_contract)
  failures << "tinyMediaManager writable fixture parent swap was accepted" unless fixture_status.success?
end
sticky_tmp = ["/private/tmp", "/tmp"].filter_map do |candidate|
  next unless File.exist?(candidate)
  canonical = File.realpath(candidate)
  stat = File.stat(canonical)
  canonical if stat.uid.zero? && (stat.mode & 0o7777) == 0o1777
end.uniq.first
failures << "standard root-owned sticky temporary directory is unavailable" unless sticky_tmp
if sticky_tmp && ENV["ADOPTION_STICKY_FULL_RECORDER_CHILD"] != "1" &&
   File.realpath(Dir.tmpdir) != sticky_tmp
  sticky_output, sticky_error, sticky_status = Open3.capture3({
    "TMPDIR" => sticky_tmp,
    "ADOPTION_STICKY_FULL_RECORDER_CHILD" => "1"
  }, RbConfig.ruby, __FILE__)
  failures << "full recorder rejected a safe sticky temporary ancestor: #{sticky_error}#{sticky_output}" unless
    sticky_status.success?
end
Dir.mktmpdir("beszel-probe-test-") do |probe_root|
  probe_root = File.realpath(probe_root)
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
    "TMPDIR" => sticky_tmp,
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
  probe_root = File.realpath(probe_root)
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
  dependency_repo = "#{root}/dependency-repo"
  FileUtils.mkdir_p(dependency_repo)
  %w[tests services roles].each do |name|
    FileUtils.cp_r(File.join(ROOT, name), dependency_repo, preserve: true)
  end
  FileUtils.cp(File.join(ROOT, "generate-secrets.yml"), dependency_repo, preserve: true)
  dependency_recorder = "#{dependency_repo}/tests/mac/adoption-baseline.rb"
  dependency_mutations = {
    "recorder" => dependency_recorder,
    "contract" => "#{dependency_repo}/tests/contracts/beszel.sh",
    "template" => "#{dependency_repo}/tests/mac/adoption-probes/tinymediamanager-templates/movie/list.jmte"
  }
  dependency_mutations.each do |label, dependency|
    saved_dependency = File.binread(dependency)
    write_executable("#{root}/probes/beszel.sh", <<~SH)
      #!/bin/sh
      printf '%s\\n' '#{JSON.generate(evidence("beszel"))}'
      mv '#{dependency}' '#{dependency}.saved'
      printf '%s\\n' '# schema-valid dependency replacement' > '#{dependency}'
      mv '#{dependency}.saved' '#{dependency}'
    SH
    _out, _diagnostic, rejected = run_recorder(
      root, output, {}, [], recorder: dependency_recorder
    )
    failures << "live #{label} dependency mutation was accepted" if rejected.success?
    failures << "live #{label} dependency mutation replaced baseline" unless File.binread(output) == original
    File.binwrite(dependency, saved_dependency)
    File.chmod(0o700, dependency) if dependency.end_with?(".rb", ".sh")
  end
  write_executable("#{root}/probes/beszel.sh", <<~SH)
    #!/bin/sh
    printf '%s\\n' '#{JSON.generate(evidence("beszel"))}'
  SH
  Dir.mktmpdir("adoption-sticky-manifest-", sticky_tmp) do |sticky_root|
    sticky_root = File.realpath(sticky_root)
    File.chmod(0o700, sticky_root)
    sticky_manifest = File.join(sticky_root, "manifest.json")
    FileUtils.cp("#{root}/manifest.json", sticky_manifest)
    _out, _diagnostic, accepted = run_recorder(
      root, output, {}, [], manifest: sticky_manifest
    )
    failures << "root-owned sticky temporary ancestor was rejected" unless accepted.success?
    failures << "sticky temporary capture changed baseline mode" unless
      (File.stat(output).mode & 0o777) == original_mode
  end
  File.binwrite(output, original)
  File.chmod(original_mode, output)
  [0o1777, 0o0777].each do |unsafe_mode|
    unsafe_parent = "#{root}/unsafe-ancestor-#{unsafe_mode.to_s(8)}"
    manifest_parent = "#{unsafe_parent}/owned"
    FileUtils.mkdir_p(manifest_parent)
    File.chmod(unsafe_mode, unsafe_parent)
    File.chmod(0o700, manifest_parent)
    unsafe_manifest = "#{manifest_parent}/manifest.json"
    FileUtils.cp("#{root}/manifest.json", unsafe_manifest)
    _out, _diagnostic, rejected = run_recorder(
      root, output, {}, [], manifest: unsafe_manifest
    )
    failures << "user-owned writable ancestor #{unsafe_mode.to_s(8)} was accepted" if rejected.success?
    failures << "user-owned writable ancestor replaced baseline" unless File.binread(output) == original
    File.chmod(0o700, unsafe_parent)
  end
  parent_link_cases = {
    "manifest" => [:manifest, "manifest-parent", "manifest.json"],
    "override" => [:override_root, "overrides", nil],
    "environment" => [:env_root, "env", nil],
    "probe" => [:probe_root, "probes", nil]
  }
  FileUtils.mkdir_p("#{root}/manifest-parent")
  FileUtils.cp("#{root}/manifest.json", "#{root}/manifest-parent/manifest.json")
  parent_link_cases.each do |label, (option, directory, leaf)|
    source = "#{root}/#{directory}"
    saved = "#{root}/#{directory}.saved"
    File.rename(source, saved)
    File.symlink(saved, source)
    override = { option => leaf ? File.join(source, leaf) : source }
    _out, _diagnostic, rejected = run_recorder(root, output, {}, [], override)
    failures << "symlinked #{label} parent was accepted" if rejected.success?
    failures << "symlinked #{label} parent replaced baseline" unless File.binread(output) == original
  ensure
    File.unlink(source) if File.symlink?(source)
    File.rename(saved, source) if File.directory?(saved)
  end

  FileUtils.mkdir_p("#{root}/vault-parent")
  FileUtils.cp("#{root}/vault.yml", "#{root}/vault-parent/vault.yml")
  FileUtils.cp("#{root}/vault-password", "#{root}/vault-parent/vault-password")
  File.chmod(0o600, "#{root}/vault-parent/vault.yml")
  File.chmod(0o600, "#{root}/vault-parent/vault-password")
  File.rename("#{root}/vault-parent", "#{root}/vault-parent.saved")
  File.symlink("#{root}/vault-parent.saved", "#{root}/vault-parent")
  _out, _diagnostic, rejected = run_recorder(root, output, {
    "PLATFORM_MAC_VAULT_FILE" => "#{root}/vault-parent/vault.yml",
    "PLATFORM_MAC_VAULT_PASSWORD_FILE" => "#{root}/vault-parent/vault-password"
  })
  failures << "symlinked protected-input parent was accepted" if rejected.success?
  failures << "symlinked protected-input parent replaced baseline" unless File.binread(output) == original
  File.unlink("#{root}/vault-parent")
  File.rename("#{root}/vault-parent.saved", "#{root}/vault-parent")

  fsync_fault = "#{root}/fsync-fault.rb"
  File.write(fsync_fault, <<~'RUBY')
    class File
      alias adoption_original_fsync fsync

      def fsync
        target_path = ENV["ADOPTION_FSYNC_PARENT"]
        $adoption_target_directory ||= File.stat(target_path)
        current = stat
        target = $adoption_target_directory
        if current.directory? && [current.dev, current.ino] == [target.dev, target.ino]
          $adoption_directory_sync_count ||= 0
          $adoption_directory_sync_count += 1
          if $adoption_directory_sync_count == 1 && ENV["ADOPTION_REPLACE_PARENT"] == "1"
            saved = "#{target_path}.publication-saved"
            File.rename(target_path, saved)
            Dir.mkdir(target_path, 0o700)
            replacement = File.join(target_path, "baseline.json")
            File.binwrite(replacement, "newer-external-baseline\n")
            File.chmod(0o600, replacement)
          end
          failures = ENV.fetch("ADOPTION_FAIL_DIRECTORY_SYNC_AT").split(",").map { |value| Integer(value) }
          if failures.include?($adoption_directory_sync_count)
            raise Errno::EIO, "injected directory sync failure"
          end
        end
        adoption_original_fsync
      end
    end
  RUBY
  [1, 2, 3].each do |failure_index|
    File.binwrite(output, original)
    File.chmod(original_mode, output)
    _out, diagnostic, rejected = run_recorder(root, output, {
      "RUBYOPT" => "-r#{fsync_fault}",
      "ADOPTION_FSYNC_PARENT" => root,
      "ADOPTION_FAIL_DIRECTORY_SYNC_AT" => failure_index.to_s
    })
    failures << "directory fsync failure #{failure_index} was accepted" if rejected.success?
    failures << "directory fsync failure #{failure_index} diagnostic was not fixed" unless
      diagnostic == "adoption-baseline-error: capture refused\n"
    failures << "directory fsync failure #{failure_index} replaced baseline" unless
      File.binread(output) == original && (File.stat(output).mode & 0o777) == original_mode
    failures << "directory fsync failure #{failure_index} left publication artifacts" unless
      Dir.glob("#{root}/.adoption-{baseline,backup,recovery}-*").empty?
  end
  File.binwrite(output, original)
  File.chmod(original_mode, output)
  _out, diagnostic, rejected = run_recorder(root, output, {
    "RUBYOPT" => "-r#{fsync_fault}",
    "ADOPTION_FSYNC_PARENT" => root,
    "ADOPTION_FAIL_DIRECTORY_SYNC_AT" => "2,3"
  })
  failures << "publication and rollback fsync failures were accepted" if rejected.success?
  failures << "rollback fsync failure diagnostic was not fixed" unless
    diagnostic == "adoption-baseline-error: capture refused\n"
  failures << "rollback fsync failure lost the prior baseline" unless
    File.binread(output) == original && (File.stat(output).mode & 0o777) == original_mode
  failures << "rollback fsync failure left publication artifacts" unless
    Dir.glob("#{root}/.adoption-{baseline,backup,recovery}-*").empty?
  File.binwrite(output, original)
  File.chmod(original_mode, output)
  saved_parent = "#{root}.publication-saved"
  _out, _diagnostic, _parent_race_status = run_recorder(root, output, {
    "RUBYOPT" => "-r#{fsync_fault}",
    "ADOPTION_FSYNC_PARENT" => root,
    "ADOPTION_FAIL_DIRECTORY_SYNC_AT" => "999",
    "ADOPTION_REPLACE_PARENT" => "1"
  })
  failures << "publication parent replacement overwrote newer output" unless
    File.binread(output) == "newer-external-baseline\n"
  original_output = File.join(saved_parent, "baseline.json")
  failures << "publication parent replacement changed bound baseline" unless
    File.binread(original_output) == original
  FileUtils.remove_entry(root)
  File.rename(saved_parent, root)
  Dir.glob("#{root}/.adoption-private-*").each { |path| FileUtils.remove_entry_secure(path) }
  publication_artifacts = Dir.glob("#{root}/.adoption-{baseline,backup,recovery}-*")
  failures << "publication parent replacement left publication artifacts" unless publication_artifacts.empty?
  publication_artifacts.each { |path| File.unlink(path) }
  capture_saved_parent = "#{root}.capture-saved"
  write_executable("#{root}/probes/beszel.sh", <<~SH)
    #!/bin/sh
    printf '%s\\n' '#{JSON.generate(evidence("beszel"))}'
    mv '#{root}' '#{capture_saved_parent}'
    mkdir -m 700 '#{root}'
    printf '%s\\n' 'newer-capture-baseline' > '#{output}'
    chmod 600 '#{output}'
  SH
  _out, _diagnostic, capture_parent_status = run_recorder(root, output)
  failures << "capture parent replacement was accepted" if capture_parent_status.success?
  failures << "capture parent replacement overwrote newer output" unless
    File.binread(output) == "newer-capture-baseline\n"
  failures << "capture parent replacement changed bound baseline" unless
    File.binread(File.join(capture_saved_parent, "baseline.json")) == original
  FileUtils.remove_entry(root)
  File.rename(capture_saved_parent, root)
  Dir.glob("#{root}/.adoption-private-*").each { |path| FileUtils.remove_entry_secure(path) }
  Dir.glob("#{root}/.adoption-{baseline,backup,recovery}-*").each { |path| File.unlink(path) }
  write_executable("#{root}/probes/beszel.sh", <<~SH)
    #!/bin/sh
    printf '%s\\n' '#{JSON.generate(evidence("beszel"))}'
  SH
  File.unlink(output)
  _out, _diagnostic, rejected = run_recorder(root, output, {
    "RUBYOPT" => "-r#{fsync_fault}",
    "ADOPTION_FSYNC_PARENT" => root,
    "ADOPTION_FAIL_DIRECTORY_SYNC_AT" => "1"
  })
  failures << "first-publication directory fsync failure was accepted" if rejected.success?
  failures << "first-publication directory fsync failure left output" if File.exist?(output)
  failures << "first-publication directory fsync failure left publication artifacts" unless
    Dir.glob("#{root}/.adoption-{baseline,backup,recovery}-*").empty?
  File.binwrite(output, original)
  File.chmod(original_mode, output)
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
  first_log = "#{root}/concurrent-first.log"
  second_log = "#{root}/concurrent-second.log"
  first_pid = Process.spawn(concurrent_env, *concurrent_arguments, out: first_log, err: first_log)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
  until File.exist?("#{root}/concurrent-started")
    raise "concurrent recorder did not reach probe" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    sleep 0.02
  end
  second_pid = Process.spawn(concurrent_env, *concurrent_arguments, out: second_log, err: second_log)
  sleep 0.2
  File.write("#{root}/concurrent-release", "release\n")
  _, first_status = Process.wait2(first_pid)
  _, second_status = Process.wait2(second_pid)
  unless first_status.success? && second_status.success?
    failures << "concurrent recorders failed: #{File.binread(first_log)} #{File.binread(second_log)}"
  end
  final_alerts = JSON.parse(File.binread(output)).dig("services", "beszel", "record_counts", "alerts")
  failures << "concurrent recorder lost the serialized update" unless final_alerts == 3
  File.binwrite(output, original)
  File.chmod(original_mode, output)
  %w[concurrent-count concurrent-started concurrent-release concurrent-first.log concurrent-second.log].each do |name|
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
                                    "mv \"$PLATFORM_MAC_VAULT_FILE.saved\" \"$PLATFORM_MAC_VAULT_FILE\"",
    "vault snapshot parent swap" => "parent=${PLATFORM_MAC_VAULT_FILE%/*}; mv \"$parent\" \"$parent.saved\"; " \
                                    "ln -s \"$parent.saved\" \"$parent\"; rm \"$parent\"; mv \"$parent.saved\" \"$parent\"",
    "probe snapshot parent swap" => "parent=${0%/*}; mv \"$parent\" \"$parent.saved\"; " \
                                    "ln -s \"$parent.saved\" \"$parent\"; rm \"$parent\"; mv \"$parent.saved\" \"$parent\""
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
    File.unlink("#{root}/#{marker}") if File.exist?("#{root}/#{marker}")
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
