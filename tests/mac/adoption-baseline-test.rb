#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "tmpdir"

ROOT = File.expand_path("../..", __dir__)
RECORDER = File.join(__dir__, "adoption-baseline.rb")
SERVICES = %w[
  audiobookshelf beszel dozzle immich jellyfin komga ntfy paperless-ngx tinymediamanager
].freeze
COMMIT = "400f03f276ae1bb69f5460c175b9fb923d620f1a"
CANARY = "baseline-canary-must-never-publish"

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

def run_recorder(root, output, extra_env = {})
  env = {
    "PATH" => "#{root}/bin:#{ENV.fetch("PATH")}",
    "PLATFORM_ADOPTION_BASELINE_CANARIES" => CANARY,
    "PLATFORM_PROJECT_NAME" => "proof",
    "PLATFORM_MAC_SANDBOX" => root
  }.merge(extra_env)
  Open3.capture3(env, RECORDER, "--output", output, "--legacy-commit", COMMIT,
                 "--manifest", "#{root}/manifest.json", "--legacy-root", "#{root}/legacy",
                 "--override-root", "#{root}/overrides", "--env-root", "#{root}/env",
                 "--probe-root", "#{root}/probes")
end

failures = []
adoption_source = File.read(File.join(__dir__, "adoption.sh"))
failures << "adoption coordinator omits capture-baseline" unless adoption_source.include?("preflight|render|legacy-deploy|legacy-seed|capture-baseline)")
failures << "adoption coordinator does not invoke recorder" unless adoption_source.include?('"$script_dir/adoption-baseline.rb"')
failures << "adoption coordinator publishes outside the sandbox" unless adoption_source.include?('"$sandbox/baseline.json"')
Dir.mktmpdir("adoption-baseline-test-") do |root|
  root = File.realpath(root)
  FileUtils.mkdir_p(["#{root}/bin", "#{root}/legacy", "#{root}/committed", "#{root}/overrides", "#{root}/env", "#{root}/probes"])
  manifest = { "legacy_source" => { "commit" => COMMIT }, "services" => SERVICES.map { |name| { "name" => name, "legacy_path" => "#{name}.yml" } } }
  File.write("#{root}/manifest.json", JSON.generate(manifest))
  SERVICES.each do |service|
    File.write("#{root}/legacy/#{service}.yml", "services: {}\n")
    File.write("#{root}/committed/#{service}.yml", "services: {}\n")
    File.write("#{root}/overrides/#{service}.yml", "services: {}\n")
    File.write("#{root}/env/#{service}.env", "SAFE=1\n")
    write_executable("#{root}/probes/#{service}.sh", <<~SH)
      #!/bin/sh
      printf '%s\\n' '#{JSON.generate(evidence(service))}'
      printf '%s\\n' 'probe-ok: #{service}' >&2
    SH
  end
  write_executable("#{root}/bin/docker", <<~'SH')
    #!/bin/sh
    project=
    while [ "$#" -gt 0 ]; do
      [ "$1" = --project-name ] && { project=$2; shift 2; continue; }
      shift
    done
    service=${project##*-legacy-}
    printf 'registry.invalid/%s:one\n' "$service"
    [ "$service" = immich ] && printf 'registry.invalid/shared:one\nregistry.invalid/shared:one\n'
    exit 0
  SH
  write_executable("#{root}/bin/git", <<~'SH')
    #!/bin/sh
    root=$2
    shift 2
    case "$1:$2" in
      rev-parse:--show-toplevel) printf '%s\n' "$root" ;;
      rev-parse:HEAD) printf '%s\n' '400f03f276ae1bb69f5460c175b9fb923d620f1a' ;;
      status:--porcelain=v1) : ;;
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
    git_fixture_status.success? && git_fixture == "services: {}\n"

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
      "registry.invalid/immich:one", "registry.invalid/shared:one", "registry.invalid/shared:one"
    ]
    failures << "baseline mode differs" unless (File.stat(output).mode & 0o777) == 0o600
    failures << "baseline contains canary" if File.binread(output).include?(CANARY)
  end

  original = File.binread(output)
  original_mode = File.stat(output).mode & 0o777
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
    "noncanonical count" => evidence("beszel").merge("record_counts" => { "alerts" => 1.0, "systems" => 1, "users" => 1 })
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
