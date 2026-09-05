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

require_relative "policy_support"

include TestScaffold

ROLE_TASKS = File.join(ROOT, "roles/production_auto_deploy/tasks/main.yml")
POLLER_SOURCE = File.join(ROOT, "scripts/production_auto_deploy.py")
TOKEN = "tk_#{'r' * 29}"
PUBLIC_HOST = "100.64.0.1"
CALLBACK_HOST = "10.88.0.1"
# Deliberately not the deployed topics: rendering with names the repository
# never contains is what proves the configuration reads the declared variables
# rather than a literal that happens to agree with them today.
SENTINEL_CRITICAL = "sentinel-critical"
SENTINEL_DEPLOYMENT = "sentinel-deployment"
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
#
# A curl config has its own grammar, so it is read as the directives it declares
# rather than as substrings of the file. curl sends every header directive it is
# given, so "carries the deploy token" and "does not carry dozzle's" were both
# satisfied by a file that presented two Authorization headers; and both were
# satisfied by a token named only in the comment block above.
notifier_directives = notifier.lines.filter_map do |line|
  key, separator, value = line.strip.partition(" = ")
  [key, value] unless separator.empty?
end
check(failures,
      notifier_directives.select { |key, value| key == "header" && value.start_with?('"Authorization:') } ==
        [["header", '"Authorization: Bearer {{ vault_ntfy_deploy_token }}"']],
      "the ntfy.curl config must present exactly the deploy publisher's own bearer token")

# Because the poller publishes as `deploy` and nothing else, every topic its
# configuration names has to be one the deploy publisher is granted. The two
# sides used to be pinned to the same literal independently -- the template
# through `ntfy_topic | default('nas-critical')`, in a play that does not list
# the ntfy role and where the fallback was therefore the operative value -- so
# renaming a topic moved the grant and left the poller posting where the account
# could no longer write, silently (#345). This compares the declarations rather
# than the values: a value comparison passes on a template that stopped reading
# the variable at all, which is exactly the defect.
publishers = YAML.safe_load_file(File.join(ROOT, "roles/ntfy/defaults/main.yml"))
              .fetch("ntfy_publishers")
deploy_grant = publishers.find { |publisher| publisher["name"] == "deploy" }.to_h.fetch("topics", "")
granted_variables = deploy_grant.scan(/ntfy_[a-z_]*topic/).uniq
check(failures, granted_variables.length >= 2,
      "the deploy publisher's grant must name at least two topic variables, found " \
      "#{granted_variables.inspect} in #{deploy_grant.inspect}")

# Read off the rendered document's own keys rather than the file's bytes: the
# template is one Jinja mapping literal, so the expression a key is bound to is
# the thing that decides where the poller publishes.
POLLER_CONFIG_TEMPLATE = File.join(ROOT, "roles/production_auto_deploy/templates/config.json.j2")
PRUNE_CONFIG_TEMPLATE = File.join(ROOT, "roles/image_prune/templates/config.json.j2")

def topic_expressions(template_path)
  File.readlines(template_path).filter_map do |line|
    key, separator, expression = line.strip.partition(":")
    next if separator.empty?
    key = key.delete("'")
    [key, expression.strip.delete_suffix(",")] if key.start_with?("ntfy_topic_")
  end.to_h
end

[["the poller", POLLER_CONFIG_TEMPLATE], ["the prune", PRUNE_CONFIG_TEMPLATE]].each do |label, template|
  expressions = topic_expressions(template)
  check(failures, expressions.keys.sort == %w[ntfy_topic_critical ntfy_topic_deployment],
        "#{label} configuration must bind exactly the two topic keys, found #{expressions.keys.inspect}")
  expressions.each do |key, expression|
    check(failures, !expression.include?("default("),
          "#{label} must read #{key} from the declared variable, not from a fallback " \
          "this play cannot see: #{expression.inspect}")
    named = expression.scan(/ntfy_[a-z_]*topic/).uniq
    check(failures, named.length == 1 && granted_variables.include?(named.first),
          "#{label}'s #{key} must name a topic variable the deploy publisher is " \
          "granted, found #{expression.inspect} against #{granted_variables.inspect}")
  end
end

# The same fallback anywhere else is the same defect waiting for a second
# publisher outside the ntfy role's play. Screened over the declarations that
# render, with a floor, so an expression list that goes empty cannot pass.
topic_readers = Dir.glob(File.join(ROOT, "roles/*/{defaults,vars,templates,tasks}/*")).select do |path|
  File.file?(path) && File.read(path).match?(/ntfy_[a-z_]*topic/)
end
fallback_readers = topic_readers.select do |path|
  File.read(path).match?(/ntfy_[a-z_]*topic[[:space:]]*\|[[:space:]]*default\(/)
end
check(failures, topic_readers.length >= 2,
      "at least two role declarations must read an ntfy topic variable, found " \
      "#{topic_readers.length}")
check(failures, fallback_readers.empty?,
      "an ntfy topic must never be read through a fallback; the name is also the " \
      "ACL grant, so a stale default publishes where the account may not write: " \
      "#{fallback_readers.map { |path| path.delete_prefix("#{ROOT}/") }.inspect}")

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

  # The two addresses are declared exactly where every inventory declares them,
  # and nowhere else: the role used to demand a second `-e` for the same public
  # host, which is what made reinstalling the poller irreproducible from the
  # repository. Passing them here as host variables is what proves it no longer
  # does -- the command line below names neither.
  inventory = File.join(root, "inventory.yml")
  File.write(inventory, <<~YAML)
    platform_hosts:
      hosts:
        localhost:
          ansible_connection: local
          platform_kind: nas
          platform_public_host: #{PUBLIC_HOST}
          platform_callback_host: #{CALLBACK_HOST}
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
    # The topics are supplied the way the platform supplies them -- as inventory
    # variables the role declares required -- rather than defaulted inside the
    # role. This synthetic inventory is not inventory/local.yml, so nothing here
    # would define them otherwise, which is the point.
    "-e", "ntfy_topic=#{SENTINEL_CRITICAL}",
    "-e", "ntfy_deployment_topic=#{SENTINEL_DEPLOYMENT}",
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

    # The rendered half of the coupling checked above: the declared topics reach
    # the file the poller reads. A template that stopped consulting them renders
    # the deployed names here and the sentinels catch it.
    check(failures, config["ntfy_topic_critical"] == SENTINEL_CRITICAL &&
                    config["ntfy_topic_deployment"] == SENTINEL_DEPLOYMENT,
          "the configuration must render the declared topics, got " \
          "#{config['ntfy_topic_critical'].inspect} and " \
          "#{config['ntfy_topic_deployment'].inspect}")

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
          "platform_public_host must be inherited from the inventory variable " \
          "every other role reads, with no second -e, got " \
          "#{config['platform_public_host'].inspect}")
    check(failures, config["platform_nas_address"] != config["platform_public_host"],
          "platform_public_host must not be collapsed onto the LAN address")
    check(failures, config["platform_callback_host"] == CALLBACK_HOST,
          "platform_callback_host must be inherited from the inventory too, got " \
          "#{config['platform_callback_host'].inspect}")

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

  # And the refusal, which is what a fallback removed: with no topic declared the
  # role must stop and name the variable rather than install a poller pointed at
  # a topic the deploy account may not hold. Check mode is enough because the
  # argument spec is validated before the role's first task.
  undeclared = []
  index = 0
  while index < arguments.length
    if arguments[index] == "-e" &&
       arguments[index + 1].to_s.start_with?("ntfy_topic=", "ntfy_deployment_topic=")
      index += 2
      next
    end
    undeclared << arguments[index]
    index += 1
  end
  refusal_output, refusal_status = Open3.capture2e(environment, *undeclared, "--check")
  check(failures, !refusal_status.success? &&
        refusal_output.include?("missing required arguments") &&
        refusal_output.include?("ntfy_topic") &&
        refusal_output.include?("ntfy_deployment_topic"),
        "the role must refuse to install when no topic is declared, naming the " \
        "variable: #{refusal_output.lines.last(8).join}")
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
