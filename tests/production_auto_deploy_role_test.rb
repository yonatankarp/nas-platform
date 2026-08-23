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
PUBLIC_HOST = "100.64.0.1"
TIMEOUT_SECONDS = 300

CONFIG_KEYS = %w[
  ansible_locale branch checkout curl_path external_scheduler git_path
  github_api_base
  log_retention_days log_root
  ntfy_curl_config ntfy_topic_critical ntfy_topic_deployment
  platform_callback_host platform_nas_address
  platform_public_host repository repository_url state_root tool_path
  vault_password_file verify_tags workflow workflow_name
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

# Counted off the module arguments rather than the file's bytes: scanning the
# text counted a mode written in a comment or handed to an included role as a
# variable, neither of which declares a permission on anything.
declared_modes = tasks.flat_map do |task|
  task.values.filter_map { |arguments| arguments["mode"] if arguments.is_a?(Hash) }
end
check(failures, declared_modes.count { |mode| mode.to_s.match?(/\A0[0-7]{3}\z/) } >= 5,
      "every managed path must declare an explicit mode")

# An unprivileged account cannot always manage its own crontab. The role must
# say so before installing anything, not at its final task.
task_names = tasks.map { |task| task["name"] }
probe_index = task_names.index { |name| name.to_s.include?("manage its own crontab") }
first_mutation = task_names.index { |name| name.to_s.start_with?("Create the private") }
check(failures, !probe_index.nil?, "the role must probe crontab usability")
check(failures, probe_index.nil? || first_mutation.nil? || probe_index < first_mutation,
      "the crontab probe must run before the role creates anything")

cron_task = tasks.find { |task| task.key?("ansible.builtin.cron") }
check(failures, cron_task&.dig("when").to_s.include?("production_auto_deploy_external_scheduler"),
      "cron installation must be skipped when scheduling is external")

# --- drift screens: values duplicated across artifacts -----------------------

# The poller passes a fixed tag list to verify.yml. If a service role gains a
# verification tag and this list is not updated, automatic deployments silently
# verify less than the documented manual command does.
defaults = YAML.safe_load_file(File.join(ROOT, "roles/production_auto_deploy/defaults/main.yml"))
declared_tags = defaults.fetch("production_auto_deploy_verify_tags").split(",").map(&:strip).reject(&:empty?)
# Tags the roles actually declare, read off the parsed tasks. Scanning the text
# of every YAML file under roles/ counted three things that are not tags: a tag
# named in a komga comment, one named inside a paperless `when:` expression, and
# every tag in this role's own defaults, which the glob also matched. That last
# one made the comparison partly self-satisfying, because the declared list was
# being checked against a set it belonged to.
def declared_verify_tags(node)
  case node
  when Hash
    node.flat_map do |key, value|
      declared = key == "tags" ? Array(value).grep(/\Aplatform_verify_[a-z_]+\z/) : []
      declared + declared_verify_tags(value)
    end
  when Array then node.flat_map { |value| declared_verify_tags(value) }
  else []
  end
end
existing_tags = Dir.glob(File.join(ROOT, "roles/*/{tasks,handlers}/*.yml")).flat_map do |path|
  declared_verify_tags(YAML.safe_load_file(path, aliases: true))
end.uniq
check(failures, declared_tags.sort == existing_tags.sort,
      "the poller's verify tags must match the service roles exactly; " \
      "missing=#{(existing_tags - declared_tags).inspect} " \
      "stale=#{(declared_tags - existing_tags).inspect}")

doc_tags = File.read(File.join(ROOT, "docs/getting-started-nas.md"))
              .scan(/platform_verify_[a-z_]+/).uniq
check(failures, doc_tags.sort == declared_tags.sort,
      "the operator guide's manual verify tags must match the poller's list; " \
      "difference=#{((doc_tags | declared_tags) - (doc_tags & declared_tags)).inspect}")

# The poller selects CI runs by workflow file and display name. A rename in
# either direction makes it stop finding runs and stall without an error.
workflow_file = defaults.fetch("production_auto_deploy_workflow")
workflow_path = File.join(ROOT, ".github/workflows", workflow_file)
check(failures, File.exist?(workflow_path),
      "the configured workflow #{workflow_file} must exist")
if File.exist?(workflow_path)
  workflow_name = YAML.safe_load_file(workflow_path)["name"]
  check(failures, workflow_name == defaults.fetch("production_auto_deploy_workflow_name"),
        "workflow_name must equal #{workflow_file}'s name, found " \
        "#{workflow_name.inspect} vs #{defaults.fetch('production_auto_deploy_workflow_name').inspect}")
end

# Every playbook and inventory the poller invokes must exist under this name.
%w[
  validate-vault.yml site.yml verify.yml install-production-auto-deploy.yml
  inventory/local.yml
].each do |relative|
  check(failures, File.exist?(File.join(ROOT, relative)),
        "the poller invokes #{relative}, which must exist")
end

# The notifier must derive the port rather than restating it, and must address
# the ntfy root. ntfy only parses a JSON publish document posted to the root; a
# document posted to /<topic> is delivered as literal JSON text, which is how
# deploy alerts became unreadable. Inspect the url line itself: a comment
# mentioning ntfy_port must not satisfy this check, or the guard passes while
# the value is hardcoded.
notifier = File.read(File.join(ROOT, "roles/production_auto_deploy/templates/ntfy.curl.j2"))
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

# The deployer is its own publisher. Borrowing dozzle's token would give a
# leaked deploy token dozzle's rights, which is exactly what per-publisher
# identities exist to prevent.
check(failures, notifier.include?("vault_ntfy_deploy_token"),
      "the ntfy.curl config must use the deploy publisher's own token")
check(failures, !notifier.include?("vault_ntfy_dozzle_token"),
      "the ntfy.curl config must not borrow dozzle's token")

# --- real role run -----------------------------------------------------------

Dir.mktmpdir("auto-deploy-role") do |root|
  home = File.join(root, "home")
  checkout = File.join(home, ".local/share/nas-platform/controller")
  config_root = File.join(home, ".config/nas-platform")
  FileUtils.mkdir_p([File.join(checkout, ".git"), File.join(checkout, "scripts"),
                     config_root])
  FileUtils.cp(POLLER_SOURCE, File.join(checkout, "scripts/production_auto_deploy.py"))
  # The poller runs Ansible from this virtualenv, so the role must find it.
  tooling_bin = File.join(checkout, ".venv/bin")
  FileUtils.mkdir_p(tooling_bin)
  %w[ansible-playbook pip].each do |name|
    path = File.join(tooling_bin, name)
    File.write(path, "#!/bin/sh\nexit 0\n")
    File.chmod(0o700, path)
  end
  # Only the password provider is planted. The role must converge without a
  # vault copy outside the checkout, because the committed vault travels with
  # the revision and a second copy would outrank it.
  path = File.join(config_root, "vault-password")
  File.write(path, "placeholder\n")
  File.chmod(0o600, path)

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
    "-e", "vault_ntfy_deploy_token=#{TOKEN}",
    "-e", "production_auto_deploy_public_host=#{PUBLIC_HOST}",
    # The cron tag is skipped so the suite never writes a developer's crontab;
    # declare external scheduling so the matching precondition is skipped too.
    "-e", "production_auto_deploy_external_scheduler=true",
    # --status now reports what the next poll would do, which reaches the
    # network. Point it at a closed port so the suite stays hermetic and is not
    # exposed to GitHub rate limits; both values must still be https.
    "-e", "production_auto_deploy_repository_url=https://127.0.0.1:1/nas-platform.git",
    "-e", "production_auto_deploy_github_api_base=https://127.0.0.1:1",
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
    check(failures, config["ansible_locale"].to_s.downcase.include?("utf"),
          "ansible_locale must be a UTF-8 locale, got #{config['ansible_locale'].inspect}")

    # The poller runs with a narrow PATH from cron, so the installer must record
    # where the tools really are rather than assuming /usr/bin.
    %w[git_path curl_path].each do |key|
      check(failures, config[key].to_s.start_with?("/") && File.executable?(config[key].to_s),
            "#{key} must be an absolute path to an executable, got #{config[key].inspect}")
    end
    # Discover independently of the role: asserting only git's directory would
    # pass on a host where git happens to live in /usr/bin, which is exactly the
    # assumption being removed.
    entries = config["tool_path"].to_s.split(":")
    %w[git curl docker].each do |tool|
      located = `command -v #{tool} 2>/dev/null`.strip
      next if located.empty?
      check(failures, entries.include?(File.dirname(located)),
            "tool_path must contain #{File.dirname(located)} where #{tool} lives, got " \
            "#{config['tool_path'].inspect}")
    end
    check(failures, config["tool_path"].to_s.split(":").all? { |entry| entry.start_with?("/") },
          "every tool_path entry must be absolute")

    check(failures, config["log_retention_days"].is_a?(Integer),
          "log_retention_days must be JSON integer, not a string")
    check(failures, !config["verify_tags"].include?("\n"),
          "verify_tags must be a single line")
    check(failures, config.values.none? { |value| value.to_s.include?(TOKEN) },
          "the non-secret configuration must never contain the ntfy token")
    # ntfy hashes the public host into the mobile push topic, so collapsing it
    # onto the LAN address silently publishes where nothing is subscribed.
    check(failures, config["platform_public_host"] == PUBLIC_HOST,
          "platform_public_host must come from its own variable, got " \
          "#{config['platform_public_host'].inspect}")
    check(failures, config["platform_nas_address"] != config["platform_public_host"],
          "platform_public_host must not be collapsed onto the LAN address")
    check(failures, config["platform_callback_host"] == config["platform_nas_address"],
          "platform_callback_host defaults to the NAS address")

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
    # The point of the addition: an idle poller must explain itself rather than
    # leaving silence to be interpreted.
    check(failures, status_output.include?("next poll:"),
          "--status must report what the next poll would do: #{status_output}")
    check(failures, status_output.include?("could not resolve"),
          "--status must degrade gracefully when the branch cannot be reached: " \
          "#{status_output}")
  end
end

# The role must refuse to install when the virtualenv the poller needs is absent,
# so the operator learns at install time instead of via a failed poll later. The
# path appears in the poller's own command line and in a fail_msg as well, so a
# whole-file substring said nothing about whether the role ever probed it: the
# probe has to register a result and an assertion has to consume that result
# before the cron entry goes in.
tooling_probe = tasks.find do |task|
  task.dig("ansible.builtin.stat", "path").to_s.end_with?("/.venv/bin/ansible-playbook")
end
tooling_register = tooling_probe.to_h["register"].to_s
tooling_refusal = tasks.index do |task|
  !tooling_register.empty? &&
    Array(task.dig("ansible.builtin.assert", "that")).any? do |clause|
      clause.to_s.include?("#{tooling_register}.stat.exists")
    end
end
cron_installation = tasks.index { |task| task.key?("ansible.builtin.cron") }
check(failures,
      !tooling_probe.nil? && !tooling_refusal.nil? && !cron_installation.nil? &&
        tooling_refusal < cron_installation,
      "the role must verify the controller virtualenv before installing")

if failures.empty?
  puts "production auto-deploy role: installed contract holds"
else
  failures.each { |failure| puts "FAIL #{failure}" }
  puts "#{failures.length} production auto-deploy role violation(s)"
  exit 1
end
