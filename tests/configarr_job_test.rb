#!/usr/bin/env ruby

require "yaml"

require_relative "policy_support"

include TestScaffold

failures = []

required = %w[
  roles/arr/files/configarr/config.yml
  roles/arr/templates/configarr-secrets.yml.j2
  roles/arr/tasks/configarr.yml
  services/arr/compose.yml
]
required.each do |relative|
  check(failures, File.file?(File.join(ROOT, relative)), "#{relative} must exist")
end

if failures.empty?
  source = File.read(File.join(ROOT, "roles/arr/files/configarr/config.yml"))
  config = YAML.safe_load(source.gsub(/!secret\s+/, ""), aliases: false)
  %w[trashRevision recyclarrRevision].each do |revision|
    check(failures, config[revision].to_s.match?(/\A[0-9a-f]{40}\z/),
          "Configarr #{revision} must pin a full immutable commit")
  end
  %w[radarr sonarr].each do |application|
    instances = config.fetch(application)
    check(failures, instances.is_a?(Hash) && instances.length == 1,
          "Configarr must declare exactly one #{application} instance")
    instance = instances.values.first
    check(failures, instance["api_key"] == "#{application.upcase}_API_KEY",
          "#{application} API key must use only its !secret reference")
    check(failures, instance.dig("quality_definition", "type").is_a?(String),
          "#{application} must declare a quality definition")
    profiles = Array(instance["quality_profiles"])
    check(failures, profiles.map { |profile| profile["name"] } == ["HD Bluray + WEB 1080p"],
          "#{application} must declare the one Phase 1 1080p profile")
    check(failures, instance["media_naming_api"].is_a?(Hash) &&
                    !instance.key?("media_naming"),
          "#{application} must declare literal naming through media_naming_api")
    check(failures, Array(instance["custom_formats"]).any?,
          "#{application} must assign custom formats")
  end
  # Deliberately source text. !secret is a Configarr YAML tag that the loader
  # above strips before parsing, exactly so the document is loadable, so the
  # parsed config cannot say which values were tagged. That erasure is the whole
  # subject of this check: a value that lost its tag reads as a plain string.
  check(failures, source.scan(/!secret\s+[A-Z_]+/).sort ==
                  ["!secret RADARR_API_KEY", "!secret SONARR_API_KEY"],
        "Configarr must use only the two declared secret references")
  check(failures, Array(config["customFormatDefinitions"]).any?,
        "Configarr must define at least one owned custom format")

  tasks = YAML.safe_load_file(File.join(ROOT, "roles/arr/tasks/configarr.yml"), aliases: true)
  main_tasks = YAML.safe_load_file(File.join(ROOT, "roles/arr/tasks/main.yml"), aliases: true)
  repo_cache_task = main_tasks.find { |task| task["name"] == "Create the Configarr repository cache" }
  check(failures, repo_cache_task&.dig("ansible.builtin.file", "owner").to_s.include?("nas_uid") &&
                  repo_cache_task&.dig("ansible.builtin.file", "group").to_s.include?("nas_gid"),
        "Configarr repository cache must be writable only by the shared service identity")
  run_task = tasks.find { |task| task["community.docker.docker_compose_v2_run"] }
  run = run_task&.fetch("community.docker.docker_compose_v2_run", nil)
  check(failures, run.is_a?(Hash), "Configarr must use docker_compose_v2_run")
  if run
    check(failures, run["service"] == "configarr", "Configarr job service must be exact")
    check(failures, run["profiles"] == ["jobs"], "Configarr job must enable only jobs profile")
    check(failures, run["cleanup"] == true && run["no_deps"] == true,
          "Configarr job must remove its container and avoid dependency startup")
    check(failures, run["detach"] == false && run["service_ports"] == false,
          "Configarr job must run synchronously without published ports")
    check(failures, run["files"] == "{{ platform_service_compose_files['arr'] }}",
          "Configarr job must use only the canonical Arr Compose files")
  end
  check(failures, run_task&.fetch("failed_when", "").to_s.include?("rc"),
        "Configarr job must fail on a nonzero result")
  check(failures, run_task&.fetch("failed_when", "").to_s.include?("Failure during configuring:"),
        "Configarr job must reject upstream instance failures even when Configarr exits zero")
  check(failures, run_task&.fetch("no_log", false) == true,
        "Configarr captured output must remain redacted")
  read_before = tasks.find do |task|
    task["name"] == "Read Configarr-owned Arr resources before reconciliation"
  end
  read_after = tasks.find do |task|
    task["name"] == "Read Configarr-owned Arr resources after reconciliation"
  end
  run_index = tasks.index(run_task)
  check(failures,
        read_before && read_after && run_index &&
          tasks.index(read_before) < run_index && run_index < tasks.index(read_after),
        "Configarr must read complete owned state before and after its job")
  check(failures, Array(run_task&.fetch("when", nil)).join(" ").include?("arr_configarr_run_required"),
        "Configarr job must run only when input or verified owned state drifts")
  check(failures,
        tasks.to_s.include?("arr_verified_reconciliation_state_fingerprints") &&
          tasks.to_s.include?("configarr_owned_state"),
        "Configarr must expose a distinct verified owned-state hash after complete readback")

  secrets = File.read(File.join(ROOT, "roles/arr/templates/configarr-secrets.yml.j2"))
  check(failures, secrets.lines.grep(/API_KEY:/).length == 2,
        "Configarr secrets file must contain exactly two keys")
  check(failures, !File.exist?(File.join(ROOT, "services/arr/compose.jobs.yml")),
        "services/arr/compose.jobs.yml must be absent")
  compose = YAML.safe_load_file(File.join(ROOT, "services/arr/compose.yml"), aliases: true)
  configarr = compose.dig("services", "configarr") || {}
  check(failures, configarr["profiles"] == ["jobs"],
        "Configarr must use only the jobs profile")
  check(failures, configarr["user"] == "${NAS_UID:?}:${NAS_GID:?}",
        "Configarr must derive its user from NAS_UID and NAS_GID")
  check(failures,
        configarr["image"].to_s.match?(/:[A-Za-z0-9][A-Za-z0-9_.-]*@sha256:[0-9a-f]{64}\z/),
        "Configarr image must carry a readable tag and sha256 digest")
  # Read rather than restated: tests/expected/arr.yml is the one home of an arr
  # CPU ceiling, and tests/policy_test.rb pins Compose to it and measures it
  # against the container CPU budget. A literal here would be a copy to keep
  # equal, not an independent check.
  configarr_cpus = YAML.safe_load_file(File.join(ROOT, "tests", "expected", "arr.yml"))
                       .fetch("container_cpus").fetch("configarr")
  check(failures, configarr["cpuset"] == "${PLATFORM_CONTAINER_CPUSET:?}" &&
                  configarr["cpus"] == configarr_cpus,
        "Configarr must use the platform CPU set and its pinned CPU ceiling")
  check(failures, configarr["logging"] == {
          "driver" => "json-file",
          "options" => { "max-size" => "10m", "max-file" => "3" }
        }, "Configarr logging must use the exact bounded json-file policy")
  check(failures, configarr["networks"] == ["media-control"],
        "Configarr must join only media-control")
  %w[restart ports healthcheck].each do |key|
    check(failures, !configarr.key?(key), "Configarr must not define #{key}")
  end
  check(failures,
        Array(configarr["volumes"]).include?(
          "${CONFIGARR_REPOS_PATH:?}:/app/repos"
        ), "Configarr must mount a writable repository cache at /app/repos")
  check(failures, configarr["volumes"] == [
          "${CONFIGARR_CONFIG_PATH:?}:/app/config/config.yml:ro",
          "${CONFIGARR_SECRETS_PATH:?}:/app/config/secrets.yml:ro",
          "${CONFIGARR_REPOS_PATH:?}:/app/repos"
        ], "Configarr must mount only its declaration, secrets, and repository cache")
  check(failures, configarr["environment"] == {
          "GIT_CONFIG_COUNT" => "2",
          "GIT_CONFIG_KEY_0" => "safe.directory",
          "GIT_CONFIG_VALUE_0" => "/app/repos/trash-guides",
          "GIT_CONFIG_KEY_1" => "safe.directory",
          "GIT_CONFIG_VALUE_1" => "/app/repos/recyclarr-config"
        }, "Configarr must trust only its two exact bind-mounted repositories")
  manifest_verifier = File.read(File.join(ROOT, "tests/verify_deployment_manifest.rb"))
  check(failures,
        manifest_verifier.include?('"arr" => ["configarr.yml"]') &&
          !manifest_verifier.include?('compose.jobs.yml'),
        "deployment manifest verification must discover Configarr from canonical Compose")
end

if failures.empty?
  puts "configarr job: synchronous declarative profile contract holds"
else
  warn failures.join("\n")
  exit 1
end
