#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "tmpdir"

SOURCE = File.join(__dir__, "hooks/fixtures-recreate")
STACKS = {
  "10-beszel.sh" => ["beszel", "beszel", %w[hub agent-portable socket-proxy]],
  "15-ntfy.sh" => ["ntfy", "ntfy", %w[ntfy]],
  "20-dozzle.sh" => ["dozzle", "dozzle", %w[dozzle socket-proxy]],
  "30-audiobookshelf.sh" => ["audiobookshelf", "audiobookshelf", %w[audiobookshelf]],
  "40-komga.sh" => ["komga", "komga", %w[komga]],
  "50-tinymediamanager.sh" => ["tinymediamanager", "tinymediamanager", %w[tinymediamanager]],
  "60-jellyfin.sh" => ["jellyfin", "jellyfin", %w[jellyfin]],
  "70-immich.sh" => ["immich", "immich", %w[immich-server immich-machine-learning redis database]],
  "80-paperless.sh" => ["paperless", "paperless-ngx", %w[broker db webserver gotenberg tika]]
}.freeze

def executable(path, body)
  File.write(path, body)
  File.chmod(0o700, path)
end

failures = []
Dir.mktmpdir("adoption-recreate-test-") do |temporary|
  root = File.realpath(temporary)
  mac = File.join(root, "tests/mac")
  hooks = File.join(mac, "hooks/fixtures-recreate")
  bin = File.join(root, "bin")
  docker_root = File.join(root, "docker")
  FileUtils.mkdir_p([hooks, bin, docker_root], mode: 0o700)
  Dir.glob(File.join(SOURCE, "*.sh")).each { |source| FileUtils.cp(source, hooks, preserve: true) }

  STACKS.each_value do |_project_suffix, service_dir, _services|
    current = File.join(docker_root, "nas-platform/current/services", service_dir)
    runtime = File.join(docker_root, "nas-platform/runtime/services", service_dir)
    FileUtils.mkdir_p([current, runtime], mode: 0o700)
    %w[compose.yml compose.mac.yml compose.adoption.yml].each { |name| File.write(File.join(current, name), "---\n") }
    File.write(File.join(runtime, ".env"), "FIXTURE=true\n")
  end

  command_log = File.join(root, "docker.jsonl")
  order_log = File.join(root, "order.log")
  stop_log = File.join(root, "stop.log")
  executable(File.join(bin, "docker"), <<~'SH')
    #!/bin/sh
    ruby -rjson -e 'File.open(ENV.fetch("COMMAND_LOG"), "a") { |file| file.puts(JSON.generate(ARGV)) }' -- "$@"
    printf 'docker:%s\n' "${CURRENT_STACK:?}" >> "${ORDER_LOG:?}"
    [ "${FAIL_STACK:-}" != "$CURRENT_STACK" ] || exit 23
  SH
  executable(File.join(mac, "adoption-container-attest.sh"), <<~'SH')
    #!/bin/sh
    printf 'attest:%s\n' "${CURRENT_STACK:?}" >> "${ORDER_LOG:?}"
  SH
  executable(File.join(mac, "adoption-stop-targets.sh"), <<~'SH')
    #!/bin/sh
    printf '%s\n' "${CURRENT_STACK:?}" >> "${STOP_LOG:?}"
  SH
  %w[beszel ntfy dozzle audiobookshelf komga tinymediamanager jellyfin immich paperless].each do |service|
    executable(File.join(mac, "run-#{service}-contract.sh"), <<~'SH')
      #!/bin/sh
      printf 'contract:%s\n' "${CURRENT_STACK:?}" >> "${ORDER_LOG:?}"
    SH
  end

  environment = {
    "PATH" => "#{bin}:#{ENV.fetch('PATH')}",
    "PLATFORM_PROOF_LANE" => "adoption",
    "PLATFORM_DOCKER_ROOT" => docker_root,
    "PLATFORM_PROJECT_NAME" => "nas-platform-mac-recreate",
    "COMMAND_LOG" => command_log, "ORDER_LOG" => order_log, "STOP_LOG" => stop_log
  }
  STACKS.each do |hook_name, (project_suffix, service_dir, services)|
    hook = File.join(hooks, hook_name)
    unless File.file?(hook) && File.executable?(hook)
      failures << "#{hook_name} is missing or non-executable"
      next
    end
    stack_environment = environment.merge("CURRENT_STACK" => project_suffix)
    calls_before = File.file?(command_log) ? File.readlines(command_log).length : 0
    order_before = File.file?(order_log) ? File.readlines(order_log).length : 0
    _stdout, stderr, status = Open3.capture3(stack_environment, hook)
    failures << "#{hook_name} failed: #{stderr}" unless status.success?
    current = File.join(docker_root, "nas-platform/current/services", service_dir)
    runtime = File.join(docker_root, "nas-platform/runtime/services", service_dir, ".env")
    expected = [
      "compose", "--project-name", "nas-platform-mac-recreate-#{project_suffix}",
      "--env-file", runtime,
      "-f", File.join(current, "compose.yml"),
      "-f", File.join(current, "compose.mac.yml"),
      "-f", File.join(current, "compose.adoption.yml"),
      "up", "-d", "--force-recreate", "--wait", *services
    ]
    calls = File.file?(command_log) ? File.readlines(command_log, chomp: true).map { |line| JSON.parse(line) } : []
    failures << "#{hook_name} did not invoke Docker exactly once" unless calls.length == calls_before + 1
    failures << "#{hook_name} Compose command differs" unless calls.last == expected
    expected_order = ["docker:#{project_suffix}", "attest:#{project_suffix}"]
    expected_order << "contract:#{project_suffix}" unless project_suffix == "ntfy"
    order = File.file?(order_log) ? File.readlines(order_log, chomp: true).drop(order_before) : []
    failures << "#{hook_name} recreation order differs" unless order == expected_order
  end

  %w[beszel ntfy].each do |project_suffix|
    hook_name = STACKS.find { |_name, value| value.fetch(0) == project_suffix }&.first
    next unless hook_name && File.file?(File.join(hooks, hook_name))
    before = File.file?(order_log) ? File.readlines(order_log).length : 0
    stack_environment = environment.merge("CURRENT_STACK" => project_suffix, "FAIL_STACK" => project_suffix)
    _stdout, _stderr, status = Open3.capture3(stack_environment, File.join(hooks, hook_name))
    failures << "#{project_suffix} accepted failed recreation" if status.success?
    stops = File.file?(stop_log) ? File.readlines(stop_log, chomp: true) : []
    failures << "#{project_suffix} did not stop all adoption targets" unless stops.last == project_suffix
    failure_order = File.readlines(order_log, chomp: true).drop(before)
    failures << "#{project_suffix} ran attestation or contract after failure" unless
      failure_order == ["docker:#{project_suffix}"]
  end
end

abort failures.join("\n") unless failures.empty?
puts "adoption recreation tests: nine exact target projects hold"
