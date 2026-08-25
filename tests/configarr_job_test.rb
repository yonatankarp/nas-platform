#!/usr/bin/env ruby

require "yaml"

ROOT = File.expand_path("..", __dir__)
failures = []

def check(failures, condition, message)
  failures << message unless condition
end

required = %w[
  roles/arr/files/configarr/config.yml
  roles/arr/templates/configarr-secrets.yml.j2
  roles/arr/tasks/configarr.yml
  services/arr/compose.jobs.yml
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
    check(failures, instance["media_naming"].is_a?(Hash),
          "#{application} must declare media naming")
    check(failures, Array(instance["custom_formats"]).any?,
          "#{application} must assign custom formats")
  end
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
    check(failures, run["files"].to_s.include?("compose.jobs.yml"),
          "Configarr job must include the jobs Compose file")
  end
  check(failures, run_task&.fetch("failed_when", "").to_s.include?("rc"),
        "Configarr job must fail on a nonzero result")
  check(failures, run_task&.fetch("failed_when", "").to_s.include?("Failure during configuring:"),
        "Configarr job must reject upstream instance failures even when Configarr exits zero")
  check(failures, run_task&.fetch("no_log", false) == true,
        "Configarr captured output must remain redacted")

  secrets = File.read(File.join(ROOT, "roles/arr/templates/configarr-secrets.yml.j2"))
  check(failures, secrets.lines.grep(/API_KEY:/).length == 2,
        "Configarr secrets file must contain exactly two keys")
  jobs = YAML.safe_load_file(File.join(ROOT, "services/arr/compose.jobs.yml"), aliases: true)
  check(failures,
        Array(jobs.dig("services", "configarr", "volumes")).include?(
          "${CONFIGARR_REPOS_PATH:?}:/app/repos"
        ), "Configarr must mount a writable repository cache at /app/repos")
  check(failures, jobs.dig("services", "configarr", "environment") == {
          "GIT_CONFIG_COUNT" => "2",
          "GIT_CONFIG_KEY_0" => "safe.directory",
          "GIT_CONFIG_VALUE_0" => "/app/repos/trash-guides",
          "GIT_CONFIG_KEY_1" => "safe.directory",
          "GIT_CONFIG_VALUE_1" => "/app/repos/recyclarr-config"
        }, "Configarr must trust only its two exact bind-mounted repositories")
  manifest_verifier = File.read(File.join(ROOT, "tests/verify_deployment_manifest.rb"))
  check(failures,
        manifest_verifier.include?('"arr" => ["configarr.yml"]') &&
          manifest_verifier.include?('compose.jobs.yml'),
        "deployment manifest verification must cover Configarr inputs")
end

if failures.empty?
  puts "configarr job: synchronous declarative profile contract holds"
else
  warn failures.join("\n")
  exit 1
end
