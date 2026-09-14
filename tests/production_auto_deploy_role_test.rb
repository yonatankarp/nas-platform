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
# One sentinel per Pushover credential, each distinct, and each carrying the two
# characters a curl config quotes -- a double quote and a backslash -- so a
# rendered config is proved to escape them and to hold only its own application's
# token. The schema gives neither value a pattern, so neither is assumed absent.
PUSHOVER_ALERTS_TOKEN = 'sentinel-alerts-"token\\one'
PUSHOVER_DEPLOYMENTS_TOKEN = 'sentinel-deployments-"token\\two'
PUSHOVER_USER_KEY = 'sentinel-user-"key\\three'
PUSHOVER_CREDENTIALS = {
  "vault_pushover_alerts_token" => PUSHOVER_ALERTS_TOKEN,
  "vault_pushover_deployments_token" => PUSHOVER_DEPLOYMENTS_TOKEN,
  "vault_pushover_user_key" => PUSHOVER_USER_KEY
}.freeze
PUBLIC_HOST = "100.64.0.1"
CALLBACK_HOST = "10.88.0.1"
TIMEOUT_SECONDS = 300
# Sentinels again, on a domain that never resolves: rendering them proves the
# configuration reads the vault variables, and the installed poller the suite
# runs below could not reach a real check even if it pinged.
POLLER_PING_URL = "https://hc-ping.invalid/role-sentinel-poller"
VERIFY_PING_URL = "https://hc-ping.invalid/role-sentinel-verify"

CONFIG_KEYS = %w[
  ansible_locale branch checkout curl_path external_scheduler git_path
  github_api_base
  healthchecks_poller_ping_url healthchecks_verify_ping_url hourly_only_verify_tags
  log_retention_days log_root
  platform_callback_host platform_nas_address
  platform_public_host pushover_alerts_curl_config pushover_deployments_curl_config
  repository repository_url state_root tool_path
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

# #558 removed ntfy, so the role renders no ntfy.curl any more. The file a
# previous installation left in the config root is the operator's to delete.
check(failures, tasks.none? { |task| task.dig("ansible.builtin.template", "src").to_s.include?("ntfy") } &&
                !File.exist?(File.join(ROOT, "roles/production_auto_deploy/templates/ntfy.curl.j2")),
      "the role must render no ntfy.curl: #558 removed the service it published to")

# One protected curl config per Pushover application, rendered by one looped
# task under no_log, each naming only its own application's token.
pushover_tasks = tasks.select do |task|
  task.dig("ansible.builtin.template", "src") == "pushover.curl.j2"
end
check(failures, pushover_tasks.length == 1 &&
        pushover_tasks.all? { |task| task["no_log"] == true && task.dig("ansible.builtin.template", "mode") == "0600" },
      "the role must render pushover.curl.j2 exactly once, at mode 0600, with no_log")
# deployer.json carries the healthchecks.io ping URLs since #606, and a template
# task without no_log prints its diff under --check --diff.
config_tasks = tasks.select do |task|
  task.dig("ansible.builtin.template", "src") == "config.json.j2"
end
check(failures, config_tasks.length == 1 && config_tasks.all? { |task| task["no_log"] == true },
      "the role must render deployer.json exactly once, with no_log, because it carries the ping URLs")

cron_tasks = tasks.select { |task| task.key?("ansible.builtin.cron") }
check(failures, cron_tasks.length == 2,
      "the role must install exactly two cron entries, a poll and a verify")
cron_for = lambda do |mode|
  cron_tasks.map { |task| task["ansible.builtin.cron"] }
            .find { |entry| entry.fetch("job", "").end_with?(" #{mode}") } || {}
end
cron = cron_for.call("--poll")
check(failures, cron["minute"] == "*/5", "the cron entry must poll every five minutes")
check(failures, cron["state"] == "present", "the cron entry must be declared present")
verify_cron = cron_for.call("--verify")
defaults = YAML.safe_load_file(File.join(ROOT, "roles/production_auto_deploy/defaults/main.yml"))
check(failures, verify_cron["minute"] == "{{ production_auto_deploy_verify_cron_minute }}" &&
        defaults["production_auto_deploy_verify_cron_minute"].to_s.match?(/\A[0-5]?\d\z/) &&
        !verify_cron.key?("hour"),
      "the verify cron entry must run once an hour, at a minute the defaults pin")
check(failures, verify_cron["state"] == "present" &&
        verify_cron["name"] != cron["name"],
      "the verify cron entry must be present under a name of its own")
# The poller runs this role from the revision it just deployed, so the copy of
# the new script lands first; a cron entry installed ahead of it would call an
# older poller that rejects --verify, every hour, if the copy failed.
poller_copy = tasks.index { |task| task.dig("ansible.builtin.copy", "dest").to_s.include?("poller_path") }
verify_cron_index = tasks.index { |task| task.dig("ansible.builtin.cron", "job").to_s.end_with?(" --verify") }
check(failures, !poller_copy.nil? && !verify_cron_index.nil? && poller_copy < verify_cron_index,
      "the verify cron entry must be installed after the poller it calls")
external_notice = tasks.find { |task| task["name"].to_s.include?("external polling schedule") }
check(failures, external_notice.to_h.dig("ansible.builtin.debug", "msg").to_s.include?("--verify"),
      "an external scheduler must be told about the hourly --verify entry too")

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

# A tag the hourly --verify run selects and a deployment's verify play must not.
# A deployment whose verify fails is quarantined and never retried, and a
# degraded RAID array still serves, so platform_verify_mdraid in the deploy list
# would record every revision converged during a rebuild as failed (#609). Stated
# rather than derived, and held both ways below, so a service tag cannot quietly
# become hourly-only either.
HOURLY_ONLY_VERIFY_TAGS = %w[platform_verify_mdraid].freeze
hourly_default = defaults.fetch("production_auto_deploy_hourly_only_verify_tags", "").to_s.strip
hourly_tags = hourly_default.split(",")

def verify_tag_problems(deploy, hourly, existing)
  problems = []
  covered = deploy + hourly
  unless (existing - covered).empty? && (covered - existing).empty?
    problems << "the poller's verify tags must match the service roles exactly; " \
                "missing=#{(existing - covered).inspect} stale=#{(covered - existing).inspect}"
  end
  leaked = deploy & (HOURLY_ONLY_VERIFY_TAGS | hourly)
  unless leaked.empty?
    problems << "#{leaked.inspect} must stay out of production_auto_deploy_verify_tags: " \
                "a deployment failing it is quarantined while the array still serves"
  end
  unless hourly.sort == HOURLY_ONLY_VERIFY_TAGS.sort
    problems << "production_auto_deploy_hourly_only_verify_tags must be exactly " \
                "#{HOURLY_ONLY_VERIFY_TAGS.join(',')}, got #{hourly.inspect}"
  end
  problems
end
verify_tag_problems(declared_tags, hourly_tags, existing_tags).each { |problem| check(failures, false, problem) }
# The rule has to bite on the three failures it exists for, proved on planted
# lists rather than trusted: the hourly-only tag moved into the deploy list, a
# tag in neither list, and a service tag made hourly-only. Built from the deploy
# list without the hourly-only tags, so a broken real list cannot also make a
# plant misreport.
deploy_without_hourly = declared_tags - HOURLY_ONLY_VERIFY_TAGS
check(failures,
      verify_tag_problems(deploy_without_hourly + HOURLY_ONLY_VERIFY_TAGS, [], existing_tags)
        .any? { |problem| problem.include?("must stay out of production_auto_deploy_verify_tags") },
      "planted: platform_verify_mdraid in the deploy list must be refused")
check(failures,
      verify_tag_problems(deploy_without_hourly, [], existing_tags)
        .any? { |problem| problem.include?("missing=") },
      "planted: a verify tag in neither list must be refused")
check(failures,
      verify_tag_problems(deploy_without_hourly.drop(1), HOURLY_ONLY_VERIFY_TAGS + deploy_without_hourly.take(1),
                          existing_tags).any? { |problem| problem.include?("must be exactly") },
      "planted: a service tag moved to the hourly-only list must be refused")

doc_tags = File.read(File.join(ROOT, "docs/getting-started-nas.md"))
              .scan(/platform_verify_[a-z_]+/).uniq
all_verify_tags = (declared_tags + hourly_tags).uniq
check(failures, doc_tags.sort == all_verify_tags.sort,
      "the operator guide's verify tags must match the poller's deploy and hourly-only lists; " \
      "difference=#{((doc_tags | all_verify_tags) - (doc_tags & all_verify_tags)).inspect}")

# No task site.yml can reach may carry an hourly-only tag. There a degraded
# array would fail every converge and quarantine each revision (#609), and
# nothing else refuses, say, host_prep's main.yml including verify_mdraid.yml.
# Two checks, because neither sees every route:
# - ansible-playbook --list-tasks --list-tags resolves everything Ansible expands
#   when it loads site.yml: roles and their meta dependencies, import_playbook,
#   import_tasks and import_role, templated paths included. It does not list what
#   a dynamic include_tasks or include_role would add at run time.
# - The walker below reads the files: site.yml's task sections and roles, then
#   every include_tasks/import_tasks/include_role/import_role -- spelled bare,
#   ansible.builtin. or ansible.legacy. -- whose target is a literal, through
#   block/rescue/always. It covers the dynamic includes, and it cannot follow a
#   templated path, a meta dependency or an import_playbook.
# Neither covers: a dynamic include_tasks or include_role whose file, role name
# or tasks_from is templated; a role's handlers files, which neither reads; and
# the removed bare `include`. Without ansible-playbook this file aborts at its
# top rather than passing.
SITE_PLAYBOOK = File.join(ROOT, "site.yml")
# Every spelling Ansible and ansible-lint --strict accept for the same action.
include_spellings = ->(*actions) { actions.flat_map { |a| [a, "ansible.builtin.#{a}", "ansible.legacy.#{a}"] } }
TASK_INCLUDES = include_spellings.call("include_tasks", "import_tasks").freeze
ROLE_INCLUDES = include_spellings.call("include_role", "import_role").freeze

def site_reachable_tasks(overrides = {})
  load = ->(path) { overrides.fetch(path) { YAML.safe_load_file(path, aliases: true) } }
  files = []
  tasks = []
  role_file = lambda do |name, tasks_from|
    File.join(ROOT, "roles", name, "tasks", "#{tasks_from.to_s.delete_suffix('.yml')}.yml")
  end
  walk = nil
  visit = lambda do |path|
    next if files.include?(path) || !(overrides.key?(path) || File.file?(path))

    files << path
    walk.call(load.call(path), File.dirname(path))
  end
  walk = lambda do |list, directory|
    PolicySupport.flatten_tasks(list).each do |task|
      tasks << task
      TASK_INCLUDES.each do |key|
        file = task[key].is_a?(Hash) ? task[key]["file"] : task[key]
        next unless file.is_a?(String) && !file.include?("{{")

        # Ansible looks in the role's tasks directory as well as beside the
        # including file, which differ for a file in a subdirectory.
        visit.call(File.expand_path(file, directory))
        tasks_root = directory[%r{\A.*/roles/[^/]+/tasks(?=/|\z)}]
        visit.call(File.expand_path(file, tasks_root)) if tasks_root
      end
      ROLE_INCLUDES.each do |key|
        name = task[key].is_a?(Hash) ? task[key]["name"] : nil
        next unless name.is_a?(String) && !name.include?("{{")

        visit.call(role_file.call(name, task[key].fetch("tasks_from", "main")))
      end
    end
  end
  Array(load.call(SITE_PLAYBOOK)).each do |play|
    tasks << { "tags" => play["tags"] }
    %w[pre_tasks tasks post_tasks handlers].each { |section| walk.call(play[section], ROOT) }
    Array(play["roles"]).each do |entry|
      name = entry.is_a?(Hash) ? entry["role"] || entry["name"] : entry
      tasks << { "tags" => entry["tags"] } if entry.is_a?(Hash)
      visit.call(role_file.call(name, "main")) if name.is_a?(String)
    end
  end
  [tasks, files]
end

def hourly_only_tags_in(tasks)
  tasks.flat_map do |task|
    applied = (TASK_INCLUDES + ROLE_INCLUDES).filter_map { |key| task[key]["apply"] if task[key].is_a?(Hash) }
    (Array(task["tags"]) + applied.flat_map { |apply| Array(apply.is_a?(Hash) ? apply["tags"] : nil) }) &
      HOURLY_ONLY_VERIFY_TAGS
  end.uniq
end

site_tasks, site_files = site_reachable_tasks
host_prep_main = File.join(ROOT, "roles/host_prep/tasks/main.yml")
check(failures, site_files.include?(host_prep_main) && site_files.length >= 20,
      "the site.yml walk must reach host_prep's main.yml and every role; reached #{site_files.length} files")
leaked_into_site = hourly_only_tags_in(site_tasks)
check(failures, leaked_into_site.empty?,
      "#{leaked_into_site.inspect} is reachable from site.yml: a failing hourly-only check there fails " \
      "every converge and quarantines the revision, so it belongs to verify.yml alone")
# Planted in memory: the shapes a hand edit would take, including the
# ansible.legacy spellings that --list-tasks also passes, since both are dynamic.
beszel_main = File.join(ROOT, "roles/beszel/tasks/main.yml")
{
  "host_prep's main.yml, include_tasks" =>
    [host_prep_main, { "name" => "Planted", "ansible.builtin.include_tasks" => "verify_mdraid.yml" }],
  "host_prep's main.yml, import_tasks in a block" =>
    [host_prep_main, { "name" => "Planted", "block" => [
      { "name" => "Planted", "ansible.builtin.import_tasks" => { "file" => "verify_mdraid.yml" } }
    ] }],
  "host_prep's main.yml, ansible.legacy.include_tasks" =>
    [host_prep_main, { "name" => "Planted", "ansible.legacy.include_tasks" => "verify_mdraid.yml" }],
  "beszel's main.yml, ansible.legacy.include_role in a block" =>
    [beszel_main, { "name" => "Planted", "block" => [
      { "name" => "Planted",
        "ansible.legacy.include_role" => { "name" => "host_prep", "tasks_from" => "verify_mdraid" } }
    ] }]
}.each do |shape, (path, planted)|
  tasks_with_plant, = site_reachable_tasks(path => YAML.safe_load_file(path, aliases: true) + [planted])
  check(failures, hourly_only_tags_in(tasks_with_plant) == HOURLY_ONLY_VERIFY_TAGS,
        "planted: #{shape} reaching verify_mdraid.yml must be refused")
end

def listed_hourly_only_tags(ansible, playbook)
  environment = {
    "ANSIBLE_CONFIG" => File.join(ROOT, "ansible.cfg"),
    "ANSIBLE_ROLES_PATH" => File.join(ROOT, "roles")
  }
  output, status = Open3.capture2e(environment, ansible, "-i", File.join(ROOT, "inventory/local.yml"),
                                   playbook, "--list-tasks", "--list-tags", chdir: ROOT)
  return [nil, output] unless status.success?

  [output.scan(/platform_verify_[a-z_]+/).uniq & HOURLY_ONLY_VERIFY_TAGS, output]
end

listed, listing = listed_hourly_only_tags(ansible, SITE_PLAYBOOK)
check(failures, listed == [] && listing.include?("host_prep :"),
      "ansible-playbook site.yml --list-tasks must list host_prep and no hourly-only tag; got " \
      "#{listed.inspect}#{listed.nil? ? ": #{listing.lines.last(5).join}" : ''}")
# Planted on disk in a copy beside the real roles, since these routes live in
# files the walker does not read: a meta dependency of host_prep, an
# import_playbook appended to site.yml, and a templated import_tasks path.
Dir.mktmpdir("hourly-only-site-plant") do |sandbox|
  site_source = File.read(SITE_PLAYBOOK)
  mdraid_tasks = File.join(ROOT, "roles/host_prep/tasks/verify_mdraid.yml")
  plant_host_prep = lambda do |directory|
    FileUtils.mkdir_p(File.join(directory, "roles"))
    FileUtils.cp_r(File.join(ROOT, "roles/host_prep"), File.join(directory, "roles/host_prep"))
    File.join(directory, "roles/host_prep")
  end
  {
    "a meta dependency of host_prep" => lambda do |directory|
      role = plant_host_prep.call(directory)
      File.write(File.join(role, "meta/main.yml"), "---\ndependencies:\n  - role: mdraid_probe\n")
      FileUtils.mkdir_p(File.join(directory, "roles/mdraid_probe/tasks"))
      FileUtils.cp(mdraid_tasks, File.join(directory, "roles/mdraid_probe/tasks/main.yml"))
      File.write(File.join(directory, "site.yml"), site_source)
    end,
    "an import_playbook appended to site.yml" => lambda do |directory|
      File.write(File.join(directory, "planted.yml"), <<~YAML)
        ---
        - name: Planted
          hosts: platform_hosts
          gather_facts: false
          tasks:
            - name: Planted
              ansible.builtin.import_role:
                name: host_prep
                tasks_from: verify_mdraid
      YAML
      File.write(File.join(directory, "site.yml"), "#{site_source}\n- ansible.builtin.import_playbook: planted.yml\n")
    end,
    "a templated import_tasks path" => lambda do |directory|
      role = plant_host_prep.call(directory)
      File.write(File.join(role, "tasks/main.yml"),
                 "#{File.read(File.join(role, 'tasks/main.yml'))}\n- name: Planted\n" \
                 "  ansible.builtin.import_tasks: \"{{ role_path }}/tasks/verify_mdraid.yml\"\n")
      File.write(File.join(directory, "site.yml"), site_source)
    end
  }.each do |route, plant|
    directory = File.join(sandbox, route.tr(" ", "-"))
    FileUtils.mkdir_p(directory)
    plant.call(directory)
    planted, planted_listing = listed_hourly_only_tags(ansible, File.join(directory, "site.yml"))
    check(failures, planted == HOURLY_ONLY_VERIFY_TAGS,
          "planted: #{route} reaching verify_mdraid.yml must be refused; listed #{planted.inspect}" \
          "#{planted.nil? ? ": #{planted_listing.lines.last(5).join}" : ''}")
  end
end

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

# The Pushover curl config's own grammar, read as the directives it declares
# rather than as substrings: curl sends every form-string it is given, so a
# config naming the token twice presents two tokens, and a token named only in
# the comment block would satisfy a substring check while the directive read a
# literal.
pushover_template = File.read(File.join(ROOT, "roles/production_auto_deploy/templates/pushover.curl.j2"))
pushover_directives = pushover_template.lines.filter_map do |line|
  key, separator, value = line.strip.partition(" = ")
  [key, value] unless separator.empty?
end
check(failures,
      pushover_directives.select { |key, value| key == "form-string" && value.start_with?('"token=') }
        .map(&:last) == ['"token={{ lookup(\'ansible.builtin.vars\', item.token_variable) | ' \
                         'replace(\'\\\\\', \'\\\\\\\\\') | replace(\'"\', \'\\\\"\') }}"'],
      "the pushover.curl config must present exactly one token, its own application's, read " \
      "by name and escaped")
check(failures,
      pushover_directives.select { |key, value| key == "form-string" && value.start_with?('"user=') }.length == 1 &&
        pushover_directives.map(&:first).sort == %w[form-string form-string url],
      "the pushover.curl config must declare exactly a url, the user key and one token")
check(failures,
      pushover_directives.find { |key, _| key == "url" }.to_a.last.to_s ==
        '"{{ production_auto_deploy_pushover_api_url }}"',
      "the pushover.curl url must read production_auto_deploy_pushover_api_url")

# Which token each config carries is the defaults' list, and the poller routes
# by position in it: Alerts first, Deployments second. Stated rather than
# derived, and each named variable must be one the role declares required, so a
# config cannot read a credential from a variable this play never validates --
# the #345 shape, a coupling to a declaration the play cannot see, on the
# Pushover subject that replaced the topics.
notifiers = defaults.fetch("production_auto_deploy_pushover_notifiers", [])
check(failures,
      notifiers.map { |notifier| [File.basename(notifier["path"].to_s), notifier["token_variable"]] } ==
        [["pushover-alerts.curl", "vault_pushover_alerts_token"],
         ["pushover-deployments.curl", "vault_pushover_deployments_token"]],
      "production_auto_deploy_pushover_notifiers must be the Alerts then the Deployments config, " \
      "each with its own token variable, found #{notifiers.inspect}")
spec_options = YAML.safe_load_file(File.join(ROOT, "roles/production_auto_deploy/meta/argument_specs.yml"))
                   .dig("argument_specs", "main", "options")
PUSHOVER_CREDENTIALS.each_key do |variable|
  check(failures, spec_options.dig(variable, "required") == true,
        "#{variable} must be declared required in the role's argument spec")
end

# Read off the rendered document's own keys rather than the file's bytes: the
# template is one Jinja mapping literal. The Pushover keys must name the notifier
# list rather than restate a path.
POLLER_CONFIG_TEMPLATE = File.join(ROOT, "roles/production_auto_deploy/templates/config.json.j2")
PRUNE_CONFIG_TEMPLATE = File.join(ROOT, "roles/image_prune/templates/config.json.j2")

def template_bindings(template_path)
  File.readlines(template_path).filter_map do |line|
    key, separator, expression = line.strip.partition(":")
    next if separator.empty?

    [key.delete("'"), expression.strip.delete_suffix(",")]
  end.to_h
end

# The prune's second application is Containers: Deployments is the release
# message's alone.
[["the poller", POLLER_CONFIG_TEMPLATE, "production_auto_deploy", %w[alerts deployments]],
 ["the prune", PRUNE_CONFIG_TEMPLATE, "image_prune", %w[alerts containers]]].each do |label, template, prefix, apps|
  bindings = template_bindings(template)
  check(failures, bindings.keys.count { |key| key.include?("pushover_") } == apps.length,
        "#{label} configuration must bind exactly #{apps.inspect}'s curl configs, found " \
        "#{bindings.keys.grep(/pushover_/).inspect}")
  apps.each_with_index do |app, index|
    check(failures, bindings["'pushover_#{app}_curl_config'"] == "#{prefix}_pushover_notifiers[#{index}].path" ||
                    bindings["pushover_#{app}_curl_config"] == "#{prefix}_pushover_notifiers[#{index}].path",
          "#{label} configuration must bind pushover_#{app}_curl_config to #{prefix}_pushover_notifiers[#{index}].path, " \
          "found #{bindings.select { |key, _| key.include?('pushover') }.inspect}")
  end
end

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
    "-e", "vault_healthchecks_poller_ping_url=#{POLLER_PING_URL}",
    "-e", "vault_healthchecks_verify_ping_url=#{VERIFY_PING_URL}",
    # JSON, because the sentinels carry a quote and a backslash that key=value
    # parsing would take apart.
    "-e", JSON.generate(PUSHOVER_CREDENTIALS),
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

    # The rendered half of the coupling checked above: each Pushover config is
    # 0600, is the one the configuration names, and carries its own application's
    # token -- escaped -- and no other, beside the user key.
    escape = ->(value) { value.gsub("\\") { "\\\\" }.gsub('"') { '\\"' } }
    { "alerts" => PUSHOVER_ALERTS_TOKEN, "deployments" => PUSHOVER_DEPLOYMENTS_TOKEN }.each do |app, token|
      path = File.join(config_root, "pushover-#{app}.curl")
      check(failures, config["pushover_#{app}_curl_config"] == path,
            "pushover_#{app}_curl_config must name #{path}, got #{config["pushover_#{app}_curl_config"].inspect}")
      next check(failures, false, "#{path} was not rendered") unless File.file?(path)

      rendered = File.read(path)
      check(failures, (File.stat(path).mode & 0o777) == 0o600, "pushover-#{app}.curl must be mode 0600")
      others = PUSHOVER_CREDENTIALS.values - [token, PUSHOVER_USER_KEY]
      check(failures,
            rendered.lines.grep(/\Aform-string = "token=/) == ["form-string = \"token=#{escape.call(token)}\"\n"] &&
              rendered.lines.grep(/\Aform-string = "user=/) == ["form-string = \"user=#{escape.call(PUSHOVER_USER_KEY)}\"\n"] &&
              others.none? { |other| rendered.include?(escape.call(other)) },
            "pushover-#{app}.curl must carry its own token and the user key, escaped, and no other " \
            "application's token")
    end

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
    # Rendered, not just declared, and under the new key only: an older poller
    # reads periodic_verify_tags as its whole hourly list, so rendering that key
    # with the hourly-only meaning would verify the services not at all (#609).
    check(failures,
          config["hourly_only_verify_tags"] == HOURLY_ONLY_VERIFY_TAGS.join(",") &&
            !config.key?("periodic_verify_tags"),
          "hourly_only_verify_tags must render as #{HOURLY_ONLY_VERIFY_TAGS.join(',')} with no " \
          "periodic_verify_tags beside it, got #{config.slice('hourly_only_verify_tags', 'periodic_verify_tags').inspect}")
    check(failures, config.values.none? { |value| PUSHOVER_CREDENTIALS.values.any? { |secret| value.to_s.include?(secret) } },
          "the poller configuration must never contain a Pushover credential")
    check(failures, PUSHOVER_CREDENTIALS.values.none? { |secret| output.include?(secret) },
          "the role's own output must never print a Pushover credential")
    check(failures, config["healthchecks_poller_ping_url"] == POLLER_PING_URL &&
                    config["healthchecks_verify_ping_url"] == VERIFY_PING_URL,
          "the configuration must render the vault's ping URLs, got " \
          "#{config['healthchecks_poller_ping_url'].inspect} and " \
          "#{config['healthchecks_verify_ping_url'].inspect}")
    check(failures, !output.include?(POLLER_PING_URL) && !output.include?(VERIFY_PING_URL),
          "the role's own output must never print a ping URL")
    # The address clients use and the LAN address are different facts, so
    # collapsing one onto the other hands the plays an address devices do not use.
    check(failures, config["platform_public_host"] == PUBLIC_HOST,
          "platform_public_host must be inherited from the inventory variable " \
          "every other role reads, with no second -e, got " \
          "#{config['platform_public_host'].inspect}")
    check(failures, config["platform_nas_address"] != config["platform_public_host"],
          "platform_public_host must not be collapsed onto the LAN address")
    check(failures, config["platform_callback_host"] == CALLBACK_HOST,
          "platform_callback_host must be inherited from the inventory too, got " \
          "#{config['platform_callback_host'].inspect}")

    check(failures, !File.exist?(File.join(config_root, "ntfy.curl")),
          "the role must not render ntfy.curl since #558 removed ntfy")

    poller = File.join(home, ".local/share/nas-platform/poller/production_auto_deploy.py")
    check(failures, (File.stat(poller).mode & 0o777) == 0o700, "the poller must be mode 0700")

    launcher = File.join(home, ".local/bin/nas-platform-deploy")
    check(failures, (File.stat(launcher).mode & 0o777) == 0o700, "the launcher must be mode 0700")
    launcher_body = File.read(launcher)
    check(failures, launcher_body.include?(poller), "the launcher must exec the installed poller")
    check(failures, launcher_body.include?(config_path), "the launcher must pass the config path")
    check(failures, PUSHOVER_CREDENTIALS.values.none? { |secret| launcher_body.include?(secret) },
          "the launcher must not contain a Pushover credential")

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
    check(failures, !status_output.include?("nothing can be published"),
          "the installed poller must find both Pushover configs its configuration names: #{status_output}")

    # The hourly entry calls the installed poller, so the installed poller has
    # to accept the mode -- and verify nothing before anything has deployed.
    verify_output, verify_result = Open3.capture2e(
      { "PATH" => ENV.fetch("PATH", "") }, launcher, "--verify"
    )
    check(failures, verify_result.success? && verify_output.include?("nothing has deployed"),
          "a fresh installation's --verify must skip and exit 0: #{verify_output}")
  end

  # And the refusal, which is what a fallback removed: with no Pushover
  # credential declared the role must stop and name each variable rather than
  # install a poller that cannot publish. Check mode is enough because the
  # argument spec is validated before the role's first task.
  undeclared = []
  index = 0
  while index < arguments.length
    if arguments[index] == "-e" &&
       arguments[index + 1] == JSON.generate(PUSHOVER_CREDENTIALS)
      index += 2
      next
    end
    undeclared << arguments[index]
    index += 1
  end
  # "missing required arguments" is ansible-core's own diagnostic (2.21.3, pinned
  # in controller-requirements.txt). Matching its wording is what makes this sharp
  # rather than satisfiable by any incidental check-mode failure; a core bump that
  # rephrases it breaks this assertion, and that is the reason why.
  #
  # Read the names out of that clause rather than out of the whole output: the
  # refusal also dumps argument_spec_data, which names every option the role
  # declares, so a whole-output substring is satisfied by an option that is
  # present and optional -- which is the defect (#402).
  refusal_output, refusal_status = Open3.capture2e(environment, *undeclared, "--check")
  missing_arguments =
    refusal_output[/missing required arguments: ([a-z_, ]+)/, 1].to_s.split(",").map(&:strip)
  check(failures, !refusal_status.success? &&
        (%w[vault_pushover_alerts_token vault_pushover_deployments_token
            vault_pushover_user_key] - missing_arguments).empty?,
        "the role must refuse to install when no Pushover credential is declared, naming " \
        "each missing variable, found #{missing_arguments.inspect} in: " \
        "#{refusal_output.lines.last(8).join}")
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
