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
]
required.each do |relative|
  check(failures, File.file?(File.join(ROOT, relative)), "#{relative} must exist")
end

if failures.empty?
  source = File.read(File.join(ROOT, "roles/arr/files/configarr/config.yml"))
  config = YAML.safe_load(source.gsub(/!secret\s+/, ""), aliases: false)
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
end

if failures.empty?
  puts "configarr job: synchronous declarative profile contract holds"
else
  warn failures.join("\n")
  exit 1
end
