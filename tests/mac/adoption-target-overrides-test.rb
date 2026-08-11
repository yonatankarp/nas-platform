#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require "pathname"

ROOT = Pathname(__dir__).join("../..").realpath
SERVICES = %w[audiobookshelf beszel dozzle immich jellyfin komga ntfy paperless-ngx tinymediamanager].freeze
ADOPTION_ROOT = "/private/tmp/nas-platform-adoption-root"

def refuse(message)
  warn "Adoption target override failed: #{message}"
  exit 1
end

def required_environment(paths)
  names = paths.flat_map { |path| path.binread.scan(/\$\{([A-Z][A-Z0-9_]*)(?::[-?][^}]*)?\}/).flatten }.uniq
  names.to_h do |name|
    value = case name
            when "PLATFORM_ADOPTION_ROOT" then ADOPTION_ROOT
            when "NAS_DOCKER_ROOT" then "/private/tmp/unused-docker-root"
            when "NAS_MEDIA_ROOT" then "/private/tmp/unused-media-root"
            when /(?:PATH|ROOT)\z/ then "/private/tmp/unused-#{name.downcase.tr('_', '-')}"
            when /PORT/ then "39000"
            when /(?:UID|GID|USER_ID|GROUP_ID)/ then "501"
            when "PLATFORM_PROJECT_NAME" then "nas-platform-adoption-test"
            else "fixture"
            end
    [name, value]
  end
end

expected = SERVICES.flat_map do |service|
  ROOT.join("tests/mac/legacy-overrides/#{service}.yml").each_line.filter_map do |line|
    match = line.match(%r{\$\{PLATFORM_MAC_SANDBOX:\?\}/(?<source>legacy/[^:]+):(?<target>/[^:]+)})
    [match[:source], match[:target].strip] if match
  end
end.sort
refuse("reviewed legacy source inventory differs") unless expected.length == 32 && expected.uniq.length == 32

actual = []
SERVICES.each do |service|
  directory = ROOT.join("services", service)
  files = %w[compose.yml compose.mac.yml compose.adoption.yml].map { |name| directory.join(name) }
  refuse("#{service} adoption override is unavailable") unless files.all?(&:file?)
  env = required_environment(files)
  command = ["docker", "compose", *files.flat_map { |path| ["-f", path.to_s] }, "config", "--format", "json"]
  stdout, stderr, status = Open3.capture3(env, *command)
  refuse("#{service} target merge failed: #{stderr.strip}") unless status.success? && stderr.empty?
  merged = JSON.parse(stdout)

  base_stdout, base_stderr, base_status = Open3.capture3(
    required_environment(files.first(2)), "docker", "compose",
    "-f", files[0].to_s, "-f", files[1].to_s, "config", "--format", "json"
  )
  refuse("#{service} target base merge failed: #{base_stderr.strip}") unless base_status.success? && base_stderr.empty?
  target_owned = JSON.parse(base_stdout)
  [merged, target_owned].each do |document|
    document.fetch("services").each_value { |definition| definition.delete("volumes") }
    document.delete("name")
  end
  refuse("#{service} adoption override changes non-volume target semantics") unless merged == target_owned

  configured = JSON.parse(stdout).fetch("services")
  active_services = service == "beszel" ? %w[hub agent-portable socket-proxy] : configured.keys
  active_services.each do |name|
    configured.fetch(name).fetch("volumes", []).each do |mount|
      next unless mount.fetch("type") == "bind" && mount.fetch("source").start_with?("#{ADOPTION_ROOT}/legacy/")

      actual << [mount.fetch("source").delete_prefix("#{ADOPTION_ROOT}/"), mount.fetch("target")]
    end
  end
end

unless actual.sort == expected
  refuse("adoption target bind multiset differs: missing=#{expected - actual} extra=#{actual - expected}")
end

runner = ROOT.join("tests/mac/run.sh").binread
refuse("cutover does not export protected adoption mapping") unless
  runner.include?("PLATFORM_ADOPTION_ROOT") && runner.include?("PLATFORM_ADOPTION_MARKER")
refuse("fresh lane does not reject ambient adoption mapping") unless
  runner.include?("reserved adoption mapping environment")
roles = SERVICES.map { |service| service.tr("-", "_") }.map { |role| ROOT.join("roles", role, "tasks/main.yml").binread }
refuse("not every target role selects the staged adoption override") unless
  roles.all? { |source| source.scan("compose.adoption.yml").length >= 2 }
bundle = ROOT.join("roles/deployment_bundle/tasks/main.yml").binread
refuse("deployment bundle does not stage the adoption override") unless
  bundle.include?("deployment_bundle_adoption_sources") && bundle.include?("compose.adoption.yml")
inputs = ROOT.join("roles/deployment_bundle/tasks/inputs.yml").binread
target = ROOT.join("roles/deployment_bundle/tasks/target.yml").binread
refuse("controller validation omits adoption inputs") unless inputs.include?("compose.adoption.yml")
refuse("target validation does not bind root, marker bytes, and checksum") unless
  target.include?("deployment_adoption_root") && target.include?("deployment_adoption_binding_content") &&
  target.include?("deployment_adoption_binding.stat.checksum == platform_adoption_marker")
hooks = ROOT.join("tests/mac/hooks/fixtures-recreate").children.select do |path|
  path.extname == ".sh" && path.binread.include?("docker compose")
end
refuse("adoption recreation hooks cannot discover the staged override") unless
  hooks.all? { |path| path.binread.include?("compose.adoption.yml") }

puts "Adoption target overrides: exact legacy binds with target semantics hold"
