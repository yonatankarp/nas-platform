#!/usr/bin/env ruby
# frozen_string_literal: true

# Verifies the installer role's observable outcome: private directories, an
# exact configuration contract, protected credentials, and a poller that runs.
# The cron task is checked structurally rather than executed, so running this
# suite never writes a crontab on a developer machine.

require "fileutils"
require "json"
require "open3"
require "tmpdir"
require "yaml"

ROOT = File.expand_path("..", __dir__)
ROLE_TASKS = File.join(ROOT, "roles/production_auto_deploy/tasks/main.yml")
POLLER_SOURCE = File.join(ROOT, "scripts/production_auto_deploy.py")
TOKEN = "tk_#{'r' * 29}"
TIMEOUT_SECONDS = 300

CONFIG_KEYS = %w[
  branch checkout github_api_base log_retention_days log_root ntfy_curl_config
  platform_callback_host platform_nas_address platform_public_host repository
  repository_url state_root vault_file vault_password_file verify_tags workflow
  workflow_name
].freeze

failures = []

def check(failures, condition, message)
  failures << message unless condition
end

def command_path(name)
  ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |directory|
    path = File.join(directory, name)
    return path if File.executable?(path)
  end
  nil
end

ansible = command_path("ansible-playbook")
abort "production auto-deploy role test requires ansible-playbook" unless ansible

tasks = YAML.safe_load_file(ROLE_TASKS)

# --- structural contract -----------------------------------------------------

notifier_tasks = tasks.select do |task|
  task.dig("ansible.builtin.template", "src") == "ntfy.curl.j2"
end
check(failures, notifier_tasks.length == 1,
      "the role must render ntfy.curl exactly once")
check(failures, notifier_tasks.all? { |task| task["no_log"] == true },
      "the ntfy.curl task must set no_log so the token never reaches a log")

cron_tasks = tasks.select { |task| task.key?("ansible.builtin.cron") }
check(failures, cron_tasks.length == 1, "the role must install exactly one cron entry")
cron = cron_tasks.fetch(0, {}).fetch("ansible.builtin.cron", {})
check(failures, cron["minute"] == "*/5", "the cron entry must poll every five minutes")
check(failures, cron.fetch("job", "").end_with?("--poll"),
      "the cron entry must invoke the launcher with --poll")
check(failures, cron["state"] == "present", "the cron entry must be declared present")

python_floor = tasks.any? do |task|
  Array(task.dig("ansible.builtin.assert", "that")).any? do |clause|
    clause.to_s.include?("is version('3.12', '>=')")
  end
end
check(failures, python_floor,
      "the role must gate on a Python floor with >=, never an exact version")

check(failures, File.read(ROLE_TASKS).scan(/\bmode:\s*"0[0-7]{3}"/).length >= 5,
      "every managed path must declare an explicit mode")

# --- real role run -----------------------------------------------------------

Dir.mktmpdir("auto-deploy-role") do |root|
  home = File.join(root, "home")
  checkout = File.join(home, ".local/share/nas-platform/controller")
  config_root = File.join(home, ".config/nas-platform")
  FileUtils.mkdir_p([File.join(checkout, ".git"), File.join(checkout, "scripts"),
                     config_root])
  FileUtils.cp(POLLER_SOURCE, File.join(checkout, "scripts/production_auto_deploy.py"))
  %w[vault.yml vault-password].each do |name|
    path = File.join(config_root, name)
    File.write(path, "placeholder\n")
    File.chmod(0o600, path)
  end

  inventory = File.join(root, "inventory.yml")
  File.write(inventory, <<~YAML)
    platform_hosts:
      hosts:
        localhost:
          ansible_connection: local
          platform_kind: nas
  YAML
  play = File.join(root, "play.yml")
  File.write(play, <<~YAML)
    - name: Install the poller
      hosts: platform_hosts
      gather_facts: true
      roles:
        - role: production_auto_deploy
  YAML

  environment = {
    "ANSIBLE_CONFIG" => File.join(ROOT, "ansible.cfg"),
    "ANSIBLE_ROLES_PATH" => File.join(ROOT, "roles"),
    "ANSIBLE_STDOUT_CALLBACK" => "default",
    "PATH" => ENV.fetch("PATH", ""),
    "HOME" => ENV.fetch("HOME", ""),
  }
  arguments = [
    ansible, "-i", inventory, play,
    "--skip-tags", "production_auto_deploy_cron",
    "-e", "production_auto_deploy_home=#{home}",
    "-e", "vault_ntfy_dozzle_token=#{TOKEN}",
  ]
  output, status = Open3.capture2e(environment, *arguments)
  check(failures, status.success?, "the role must converge: #{output.lines.last(12).join}")

  if status.success?
    %w[
      .local/share/nas-platform
      .local/share/nas-platform/poller
      .local/share/nas-platform/state
      .local/share/nas-platform/logs
      .config/nas-platform
    ].each do |relative|
      path = File.join(home, relative)
      mode = File.stat(path).mode & 0o777
      check(failures, mode == 0o700, "#{relative} must be mode 0700, found #{format('%04o', mode)}")
    end

    config_path = File.join(config_root, "deployer.json")
    check(failures, (File.stat(config_path).mode & 0o777) == 0o600,
          "deployer.json must be mode 0600")
    config = JSON.parse(File.read(config_path))
    check(failures, config.keys.sort == CONFIG_KEYS,
          "deployer.json keys must match the poller's Config exactly; " \
          "extra=#{(config.keys - CONFIG_KEYS).inspect} " \
          "missing=#{(CONFIG_KEYS - config.keys).inspect}")
    check(failures, config["log_retention_days"].is_a?(Integer),
          "log_retention_days must be JSON integer, not a string")
    check(failures, !config["verify_tags"].include?("\n"),
          "verify_tags must be a single line")
    check(failures, config.values.none? { |value| value.to_s.include?(TOKEN) },
          "the non-secret configuration must never contain the ntfy token")

    notifier = File.join(config_root, "ntfy.curl")
    check(failures, (File.stat(notifier).mode & 0o777) == 0o600,
          "ntfy.curl must be mode 0600")
    check(failures, File.read(notifier).include?(TOKEN),
          "ntfy.curl must carry the publisher token")

    poller = File.join(home, ".local/share/nas-platform/poller/production_auto_deploy.py")
    check(failures, (File.stat(poller).mode & 0o777) == 0o700, "the poller must be mode 0700")

    launcher = File.join(home, ".local/bin/nas-platform-deploy")
    check(failures, (File.stat(launcher).mode & 0o777) == 0o700, "the launcher must be mode 0700")
    launcher_body = File.read(launcher)
    check(failures, launcher_body.include?(poller), "the launcher must exec the installed poller")
    check(failures, launcher_body.include?(config_path), "the launcher must pass the config path")
    check(failures, !launcher_body.include?(TOKEN), "the launcher must not contain the token")

    status_output, status_result = Open3.capture2e(
      { "PATH" => ENV.fetch("PATH", "") }, launcher, "--status"
    )
    check(failures, status_result.success?,
          "the installed launcher must run --status: #{status_output}")
    check(failures, status_output.include?("last successful: none"),
          "a fresh installation must report no successful deployment")
  end
end

if failures.empty?
  puts "production auto-deploy role: installed contract holds"
else
  failures.each { |failure| puts "FAIL #{failure}" }
  puts "#{failures.length} production auto-deploy role violation(s)"
  exit 1
end
