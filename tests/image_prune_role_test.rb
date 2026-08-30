#!/usr/bin/env ruby
# frozen_string_literal: true

# Verifies the prune installer's observable outcome: private directories, an
# exact configuration contract, a protected publisher, and an installed prune
# that runs. The cron task is checked structurally rather than executed, so
# running this suite never writes a crontab on a developer machine.

require "fileutils"
require "json"
require "open3"
require "tmpdir"
require "yaml"

require_relative "policy_support"

include TestScaffold

ROLE_TASKS = File.join(ROOT, "roles/image_prune/tasks/main.yml")
PRUNE_SOURCE = File.join(ROOT, "scripts/image_prune.py")
TOKEN = "tk_#{'r' * 29}"

# Deliberately restated rather than derived from the script: this list is the
# drift screen. A field added to image_prune.py's Config without a matching key
# in the template makes every scheduled prune fail to start, a week later, on
# the NAS.
CONFIG_KEYS = %w[
  curl_path dangling_retention_hours deployment_lock
  deployment_lock_wait_seconds docker_path log_retention_days log_root
  ntfy_curl_config ntfy_topic_critical ntfy_topic_deployment retention_hours
  state_root tool_path
].freeze

failures = []

def command_path(name)
  ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |directory|
    path = File.join(directory, name)
    return path if File.executable?(path)
  end
  nil
end

ansible = command_path("ansible-playbook")
abort "image prune role test requires ansible-playbook" unless ansible

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
check(failures, cron.fetch("job", "").end_with?("--prune"),
      "the cron entry must invoke the launcher with --prune")
check(failures, cron["state"] == "present", "the cron entry must be declared present")
# Weekly, not "whenever cron feels like it": an entry that omits any of the three
# fields inherits `*`, which is how a weekly prune silently becomes hourly.
%w[minute hour weekday].each do |field|
  check(failures, cron.fetch(field, "*").to_s.strip != "*",
        "the cron entry must pin its #{field} rather than defaulting to every one")
end
check(failures,
      cron_tasks.fetch(0, {}).dig("when").to_s.include?("image_prune_external_scheduler"),
      "cron installation must be skipped when scheduling is external")

declared_modes = tasks.flat_map do |task|
  task.values.filter_map { |arguments| arguments["mode"] if arguments.is_a?(Hash) }
end
check(failures, declared_modes.count { |mode| mode.to_s.match?(/\A0[0-7]{3}\z/) } >= 5,
      "every managed path must declare an explicit mode")

task_names = tasks.map { |task| task["name"] }
probe_index = task_names.index { |name| name.to_s.include?("manage its own crontab") }
first_mutation = task_names.index { |name| name.to_s.start_with?("Create the private") }
check(failures, !probe_index.nil?, "the role must probe crontab usability")
check(failures, probe_index.nil? || first_mutation.nil? || probe_index < first_mutation,
      "the crontab probe must run before the role creates anything")

# The prune is only safe because it holds the deployment lock while Docker runs:
# between a deployment pulling an image and starting its container, that image
# is referenced by nothing, and Docker's `until` filter does not exclude it
# because it compares upstream creation time, not pull time. A role that
# installed a prune with no lock to take would remove that guarantee silently,
# so the probe and the assertion that consumes it are both required, before the
# schedule goes in.
lock_probe = tasks.find do |task|
  task.dig("ansible.builtin.stat", "path").to_s.include?("image_prune_deployment_lock")
end
lock_register = lock_probe.to_h["register"].to_s
lock_refusal = tasks.index do |task|
  !lock_register.empty? &&
    Array(task.dig("ansible.builtin.assert", "that")).any? do |clause|
      clause.to_s.include?("#{lock_register}.stat.exists")
    end
end
cron_installation = tasks.index { |task| task.key?("ansible.builtin.cron") }
check(failures,
      !lock_probe.nil? && !lock_refusal.nil? && !cron_installation.nil? &&
        lock_refusal < cron_installation,
      "the role must require the deployment lock it serialises against before installing")

# --- drift screens: values duplicated across artifacts -----------------------

defaults = YAML.safe_load_file(File.join(ROOT, "roles/image_prune/defaults/main.yml"))
retention = defaults.fetch("image_prune_retention_hours")
dangling = defaults.fetch("image_prune_dangling_retention_hours")
check(failures, retention.is_a?(Integer) && retention >= 24,
      "the default unused window must be at least a day, found #{retention.inspect}")
check(failures, dangling.is_a?(Integer) && dangling <= retention,
      "the dangling window must not exceed the unused window: " \
      "#{dangling.inspect} > #{retention.inspect}")
# The script refuses a configuration below its own floor. A default under it
# would install a schedule that fails on its first run.
floor = File.read(PRUNE_SOURCE)[/^MINIMUM_RETENTION_HOURS = (\d+)$/, 1].to_i
check(failures, floor.positive? && retention >= floor,
      "the default window must satisfy the script's floor of #{floor}h")

lock_default = defaults.fetch("image_prune_deployment_lock").to_s
check(failures, lock_default.include?("production_auto_deploy_state_root"),
      "the lock must be the poller's own, derived from its state root")
check(failures, lock_default.strip.end_with?("/deployment.lock"),
      "the lock must be the file the poller actually takes")

# The prune reports through the same least-privilege publisher as the poller,
# and the same rules apply: ntfy only parses a JSON publish document posted to
# the server root, and a leaked token must not carry rights its owner never had.
notifier = File.read(File.join(ROOT, "roles/image_prune/templates/ntfy.curl.j2"))
notifier_url = notifier.lines.find { |line| line.start_with?("url") }.to_s
check(failures, notifier_url.include?("ntfy_port"),
      "the ntfy.curl url must derive its port from ntfy_port, found: #{notifier_url.strip}")
check(failures, notifier_url.match?(%r{/"\s*$}),
      "the ntfy.curl url must address the ntfy root so the topic travels in " \
      "the body, found: #{notifier_url.strip}")
check(failures, !notifier_url.include?("ntfy_topic"),
      "the ntfy.curl url must not carry a topic, found: #{notifier_url.strip}")
check(failures, notifier_url.include?("127.0.0.1"),
      "the ntfy.curl url must stay on loopback, found: #{notifier_url.strip}")
notifier_directives = notifier.lines.filter_map do |line|
  key, separator, value = line.strip.partition(" = ")
  [key, value] unless separator.empty?
end
check(failures,
      notifier_directives.select { |key, value| key == "header" && value.start_with?('"Authorization:') } ==
        [["header", '"Authorization: Bearer {{ vault_ntfy_deploy_token }}"']],
      "the ntfy.curl config must present exactly the deploy publisher's own bearer token")

# The schedule is installed by the playbook the poller replays on every
# deployment. Installed anywhere else it would drift the moment someone edited
# the role, which is the failure this repository exists to prevent.
installer = YAML.safe_load_file(File.join(ROOT, "install-production-auto-deploy.yml"))
installed_roles = Array(installer.fetch(0, {})["roles"]).map do |entry|
  entry.is_a?(Hash) ? entry["role"] : entry
end
check(failures, installed_roles.include?("image_prune"),
      "install-production-auto-deploy.yml must install the prune schedule")
check(failures,
      installed_roles.index("image_prune").to_i >
        installed_roles.index("production_auto_deploy").to_i,
      "the prune must be installed after the poller whose lock and state it uses")

# --- real role run -----------------------------------------------------------

Dir.mktmpdir("image-prune-role") do |root|
  home = File.join(root, "home")
  checkout = File.join(home, ".local/share/nas-platform/controller")
  config_root = File.join(home, ".config/nas-platform")
  poller_state = File.join(home, ".local/share/nas-platform/state")
  FileUtils.mkdir_p([File.join(checkout, "scripts"), config_root, poller_state])
  FileUtils.cp(PRUNE_SOURCE, File.join(checkout, "scripts/image_prune.py"))

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
    - name: Install the prune schedule
      hosts: platform_hosts
      gather_facts: true
      roles:
        - role: image_prune
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
    # The cron tag is skipped so the suite never writes a developer's crontab;
    # declare external scheduling so the matching precondition is skipped too.
    "--skip-tags", "image_prune_cron",
    "-e", "image_prune_home=#{home}",
    "-e", "vault_ntfy_deploy_token=#{TOKEN}",
    "-e", "image_prune_external_scheduler=true",
  ]
  output, status = Open3.capture2e(environment, *arguments)
  check(failures, status.success?, "the role must converge: #{output.lines.last(12).join}")

  if status.success?
    %w[
      .local/share/nas-platform/prune
      .local/share/nas-platform/prune-state
      .local/share/nas-platform/prune-logs
      .config/nas-platform
    ].each do |relative|
      path = File.join(home, relative)
      mode = File.stat(path).mode & 0o777
      check(failures, mode == 0o700, "#{relative} must be mode 0700, found #{format('%04o', mode)}")
    end

    config_path = File.join(config_root, "image-prune.json")
    check(failures, (File.stat(config_path).mode & 0o777) == 0o600,
          "image-prune.json must be mode 0600")
    config = JSON.parse(File.read(config_path))
    check(failures, config.keys.sort == CONFIG_KEYS,
          "image-prune.json keys must match the script's Config exactly; " \
          "extra=#{(config.keys - CONFIG_KEYS).inspect} " \
          "missing=#{(CONFIG_KEYS - config.keys).inspect}")
    check(failures, config.values.none? { |value| value.to_s.include?(TOKEN) },
          "the non-secret configuration must never contain the ntfy token")

    # The prune runs with a narrow PATH from cron, so the installer must record
    # where the tools really are rather than assuming /usr/bin.
    %w[docker_path curl_path].each do |key|
      check(failures, config[key].to_s.start_with?("/") && File.executable?(config[key].to_s),
            "#{key} must be an absolute path to an executable, got #{config[key].inspect}")
    end
    entries = config["tool_path"].to_s.split(":")
    %w[docker curl].each do |tool|
      located = `command -v #{tool} 2>/dev/null`.strip
      next if located.empty?
      check(failures, entries.include?(File.dirname(located)),
            "tool_path must contain #{File.dirname(located)} where #{tool} lives, got " \
            "#{config['tool_path'].inspect}")
    end
    check(failures, entries.all? { |entry| entry.start_with?("/") },
          "every tool_path entry must be absolute")

    %w[retention_hours dangling_retention_hours log_retention_days
       deployment_lock_wait_seconds].each do |key|
      check(failures, config[key].is_a?(Integer),
            "#{key} must be a JSON integer, not a string")
    end
    check(failures, config["deployment_lock"] == File.join(poller_state, "deployment.lock"),
          "the configured lock must be the poller's own, got #{config['deployment_lock'].inspect}")
    check(failures, !config["deployment_lock"].to_s.include?("\n"),
          "the configured lock must be a single line")

    script = File.join(home, ".local/share/nas-platform/prune/image_prune.py")
    check(failures, (File.stat(script).mode & 0o777) == 0o700, "the prune must be mode 0700")

    launcher = File.join(home, ".local/bin/nas-platform-prune")
    check(failures, (File.stat(launcher).mode & 0o777) == 0o700, "the launcher must be mode 0700")
    launcher_body = File.read(launcher)
    check(failures, launcher_body.include?(script), "the launcher must exec the installed prune")
    check(failures, launcher_body.include?(config_path), "the launcher must pass the config path")
    check(failures, !launcher_body.include?(TOKEN), "the launcher must not contain the token")

    notifier_path = File.join(config_root, "ntfy-prune.curl")
    check(failures, (File.stat(notifier_path).mode & 0o777) == 0o600,
          "ntfy-prune.curl must be mode 0600")
    check(failures, File.read(notifier_path).include?(TOKEN),
          "ntfy-prune.curl must carry the publisher token")
    check(failures, notifier_path != File.join(config_root, "ntfy.curl"),
          "the prune must not overwrite the poller's own publisher configuration")

    # --status reads the installed configuration through the installed script,
    # takes no lock and touches no image, so a fresh installation can prove
    # itself without pruning anything.
    status_output, status_result = Open3.capture2e(
      { "PATH" => ENV.fetch("PATH", "") }, launcher, "--status"
    )
    check(failures, status_result.success?,
          "the installed launcher must run --status: #{status_output}")
    check(failures, status_output.include?("last prune: none"),
          "a fresh installation must report no prune yet: #{status_output}")
    check(failures, status_output.include?("unused retention: #{retention}h"),
          "--status must report the window it will apply: #{status_output}")

    # Reviewing an installed host is the case --check exists for, and the one
    # the operator guide requires before every production run. It is also where
    # a read-only probe skipped under check mode shows up: the assertion that
    # consumes its result fails on a value that was never registered, so the
    # review reports a template error rather than what the run would do.
    review_output, review_status = Open3.capture2e(
      environment, *arguments, "--check", "--diff"
    )
    check(failures, review_status.success?,
          "the role must survive --check --diff on an installed host: " \
          "#{review_output.lines.last(12).join}")
    check(failures, review_output.match?(/changed=0\s/),
          "reviewing an installed host must predict no change: " \
          "#{review_output.lines.last(3).join}")
  end
end

if failures.empty?
  puts "image prune role: installed contract holds"
else
  failures.each { |failure| puts "FAIL #{failure}" }
  puts "#{failures.length} image prune role violation(s)"
  exit 1
end
