#!/usr/bin/env ruby
# Focused mutation checks for the migration manifest policy; the sandbox harness
# lives in policy_mutation_support.rb. Each row declares the policy scripts that
# detect it; run `--audit` after adding a check to a policy script (#435, #725).

require_relative "policy_mutation_support"

failures = []
retired_token = %w[tiny media manager].join

check_fixture_index_containment(failures)
check_fixture_index_hostile_environment(failures)
check_direct_policy_hostile_environment(failures, retired_token)

manifest = YAML.safe_load_file(File.join(ROOT, "services", "manifest.yml"))
valid_statuses = manifest.fetch("services").to_h do |entry|
  [entry.fetch("name"), entry.fetch("status")]
end
{
  "missing status-map entry" => [valid_statuses.reject { |name, _status| name == "arr" },
                                  "exactly the rostered service names"],
  "extra status-map entry" => [valid_statuses.merge("unknown" => "planned"),
                                "exactly the rostered service names"],
  "wrong status-map type" => [[], "service statuses must be a mapping"],
  "invalid status-map value" => [valid_statuses.merge("arr" => ["planned"]),
                                 "must be planned, implemented, or accepted"],
}.each do |label, (statuses, diagnostic)|
  _expectations, problems = pinned_service_expectations(ROOT, statuses)
  failures << "#{label}: missing #{diagnostic.inspect}" unless problems.any? { |problem| problem.include?(diagnostic) }
end

# The subject is built, not borrowed: real expectation files with one service's
# vault list emptied, so both branches of the rule are checked.
emptied_vault_root = lambda do |service_name, &block|
  Dir.mktmpdir("nas-platform-expectations-") do |root|
    expectations = File.join(root, "tests", "expected")
    FileUtils.mkdir_p(expectations)
    FileUtils.cp_r(File.join(ROOT, "tests", "expected", "."), expectations)
    path = File.join(expectations, "#{service_name}.yml")
    document = YAML.safe_load_file(path)
    document["vault_keys"] = []
    File.write(path, YAML.dump(document))
    block.call(root)
  end
end
emptied_vault_root.call("seerr") do |root|
  _expectations, problems = pinned_service_expectations(root, valid_statuses)
  diagnostic = "tests/expected/seerr.yml vault_keys must be a nonempty list"
  failures << "implemented service with an emptied vault contract: missing #{diagnostic.inspect}" unless
    problems.any? { |problem| problem.include?(diagnostic) }

  # A planned service may declare no credential at all.
  _expectations, planned_problems = pinned_service_expectations(
    root, valid_statuses.merge("seerr" => "planned")
  )
  failures << "planned service with an empty vault contract was rejected" if
    planned_problems.any? { |problem| problem.include?(diagnostic) }
end
begin
  pinned_service_expectations(ROOT)
  failures << "status-aware expectation helper accepts an omitted status mapping"
rescue ArgumentError
  nil
end

{
  "sequence" => "---\n[]\n",
  "null" => "---\nnull\n",
  "false" => "---\nfalse\n"
}.each do |label, document|
  output, succeeded = run_policy(["tests/media_acquisition_foundation_test.rb"]) do |root|
    File.write(File.join(root, "config", "media-acquisition.yml"), document)
  end
  failures << "#{label} acquisition catalog unexpectedly passed" if succeeded
  unless output.include?("config/media-acquisition.yml must be a mapping")
    failures << "#{label} acquisition catalog omitted controlled shape diagnostic"
  end
  failures << "#{label} acquisition catalog emitted a Ruby stack trace" if
    output.match?(/\.rb:\d+:in [`']/)
end

output, succeeded = run_policy(["tests/media_acquisition_foundation_test.rb"]) do |root|
  mutate_manifest(root) { |document| document.fetch("services").reverse! }
end
# Reported through the helper, not `output.lines.first` (#438).
unless succeeded
  failures << "manifest reorder changed acquisition publication policy: #{policy_failure_diagnostic(output)}"
end

expect_acquisition_failure = lambda do |label, diagnostic, &mutation|
  output, succeeded = run_policy(["tests/media_acquisition_foundation_test.rb"], &mutation)
  failures << "#{label}: acquisition policy unexpectedly passed" if succeeded
  failures << "#{label}: missing failure message #{diagnostic.inspect}" unless output.include?(diagnostic)
  failures << "#{label}: emitted a Ruby stack trace" if output.match?(/\.rb:\d+:in [`']/)
end

# nas_storage is composed per file, so route a planted path to the file that owns it.
storage_file_for = lambda do |root, path|
  Dir.glob(File.join(root, "inventory", "group_vars", "all", "*.yml")).sort.each do |file|
    next if File.basename(file) == "vault.yml"

    document = YAML.safe_load_file(file)
    next unless document.is_a?(Hash)

    document.each do |key, value|
      next unless key.start_with?("nas_storage_") && value.is_a?(Array)
      next unless value.any? { |entry| entry.is_a?(Hash) && entry["path"] == path }

      return [File.join("inventory", "group_vars", "all", File.basename(file)), key]
    end
  end
  raise "no storage contributor declares #{path}"
end
mutate_storage_entry = lambda do |root, path, &mutation|
  relative, key = storage_file_for.call(root, path)
  mutate_yaml_file(root, relative) do |document|
    mutation.call(document.fetch(key).find { |entry| entry.fetch("path") == path })
  end
end
remove_storage_entry = lambda do |root, path|
  relative, key = storage_file_for.call(root, path)
  mutate_yaml_file(root, relative) do |document|
    document.fetch(key).reject! { |entry| entry.fetch("path") == path }
  end
end
mutate_compose = lambda do |root, relative_path, &mutation|
  path = File.join(root, relative_path)
  document = YAML.safe_load_file(path, aliases: true)
  mutation.call(document)
  File.write(path, YAML.dump(document))
end
require_valid_site_syntax = lambda do |root, label|
  syntax_path = File.join(root, ".host-prep-mutation-syntax.yml")
  File.write(syntax_path, <<~YAML)
    ---
    - name: Validate mutated host preparation syntax
      hosts: localhost
      gather_facts: false
      roles:
        - role: host_prep
  YAML
  begin
    _stdout, stderr, status = capture3_without_git_routing(
      "ansible-playbook", "-i", "localhost,", syntax_path, "--syntax-check", chdir: root
    )
  ensure
    FileUtils.rm_f(syntax_path)
  end
  next if status.success?

  raise "#{label} produced invalid Ansible syntax: #{stderr.lines.first&.strip}"
end

expect_acquisition_failure.call(
  "media acquisition recovery changed",
  "media acquisition storage differs from the exact classified foundation"
) do |root|
  mutate_storage_entry.call(root, "{{ nas_docker_root }}/radarr/config") do |entry|
    entry["recovery"] = "cache"
  end
end
expect_acquisition_failure.call(
  "media acquisition ownership claimed",
  "media root path {{ nas_media_root }}/Media/Movies must not claim ownership"
) do |root|
  mutate_storage_entry.call(root, "{{ nas_media_root }}/Media/Movies") do |entry|
    entry["owner"] = "{{ nas_uid }}"
  end
end
expect_acquisition_failure.call(
  "media acquisition leaf removed",
  "media acquisition storage differs from the exact classified foundation"
) do |root|
  remove_storage_entry.call(root, "{{ nas_media_root }}/Media/YouTube")
end
expect_acquisition_failure.call(
  "Komga Books parent removed",
  "media acquisition storage differs from the exact classified foundation"
) do |root|
  remove_storage_entry.call(root, "{{ nas_media_root }}/Books")
end
expect_acquisition_failure.call(
  "media acquisition marker removed",
  "media acquisition storage differs from the exact classified foundation"
) do |root|
  mutate_storage_entry.call(root, "{{ nas_docker_root }}/seerr/config") do |entry|
    entry.delete("media_acquisition_foundation")
  end
end

# Each flipped away from its expected value.
{ "nas_hosts" => { "media_usenet_enabled" => true, "media_torrent_enabled" => false },
  "mac_hosts" => { "media_usenet_enabled" => false, "media_torrent_enabled" => false } }
  .each do |host_group, flags|
  flags.each do |flag, expected|
    expect_acquisition_failure.call(
      "#{host_group} #{flag} #{expected ? 'disabled' : 'enabled'}",
      "#{flag} must be literal #{expected}"
    ) do |root|
      mutate_yaml_file(root, "inventory/group_vars/#{host_group}/main.yml") do |vars|
        vars[flag] = !expected
      end
    end
  end
end
expect_acquisition_failure.call(
  "constant Mac media network name",
  "media control network identity must be derived from the project namespace"
) do |root|
  mutate_yaml_file(root, "inventory/group_vars/all/main.yml") do |vars|
    vars["platform_media_control_network"] = "media-control"
  end
end
expect_acquisition_failure.call(
  "media control network driver changed",
  "host preparation must create the derived bridge media control network atomically"
) do |root|
  mutate_yaml_file(root, "roles/host_prep/tasks/main.yml") do |tasks|
    task = tasks.find do |entry|
      entry["name"] == "Create the external media control network"
    end
    argv = task.fetch("ansible.builtin.command").fetch("argv")
    argv[argv.index("bridge")] = "overlay"
  end
end
{
  "nas.platform.purpose" => "media-control",
  "nas.platform.project" => "{{ platform_project_name | default('nas-platform', true) }}"
}.each do |label_name, label_value|
  short_name = label_name.delete_prefix("nas.platform.")
  {
    "deleted" => proc { |argv| argv.delete("#{label_name}=#{label_value}") },
    "renamed" => proc do |argv|
      index = argv.index("#{label_name}=#{label_value}")
      argv[index] = "renamed.#{label_name}=#{label_value}"
    end,
    "wrong value" => proc do |argv|
      index = argv.index("#{label_name}=#{label_value}")
      argv[index] = "#{label_name}=wrong-#{label_value}"
    end
  }.each do |mutation_name, mutation|
    expect_acquisition_failure.call(
      "media control #{short_name} label #{mutation_name}",
      "host preparation must create the derived bridge media control network atomically"
    ) do |root|
      mutate_yaml_file(root, "roles/host_prep/tasks/main.yml") do |tasks|
        task = tasks.find do |entry|
          entry["name"] == "Create the external media control network"
        end
        mutation.call(task.fetch("ansible.builtin.command").fetch("argv"))
      end
    end
  end
end
expect_acquisition_failure.call(
  "broad media control network deletion",
  "host preparation must never delete Docker networks"
) do |root|
  mutate_yaml_file(root, "roles/host_prep/tasks/main.yml") do |tasks|
    tasks << {
      "name" => "Delete all media networks",
      "community.docker.docker_network" => { "name" => "media-control", "state" => "absent" }
    }
  end
end
expect_acquisition_failure.call(
  "nested media control network deletion",
  "host preparation must never delete Docker networks"
) do |root|
  mutate_yaml_file(root, "roles/host_prep/tasks/main.yml") do |tasks|
    tasks << {
      "name" => "Nested media network deletion",
      "block" => [{
        "name" => "Delete a nested media network",
        "community.docker.docker_network" => {
          "name" => "media-control", "state" => "absent"
        }
      }]
    }
  end
end
expect_acquisition_failure.call(
  "recursive media state ownership",
  "host preparation must never recursively change storage ownership"
) do |root|
  mutate_yaml_file(root, "roles/host_prep/tasks/main.yml") do |tasks|
    task = tasks.find { |entry| entry["name"] == "Create service state directories" }
    task.fetch("ansible.builtin.file")["recurse"] = true
  end
end
expect_acquisition_failure.call(
  "nested recursive media state ownership",
  "host preparation must never recursively change storage ownership"
) do |root|
  mutate_yaml_file(root, "roles/host_prep/tasks/main.yml") do |tasks|
    tasks << {
      "name" => "Nested recursive ownership",
      "block" => [{
        "name" => "Exercise the guarded ownership block",
        "ansible.builtin.debug" => { "msg" => "valid mutation fixture" }
      }],
      "rescue" => [{
        "name" => "Recursively claim nested media state",
        "ansible.builtin.file" => {
          "path" => "{{ nas_media_root }}/Media", "recurse" => true
        }
      }]
    }
  end
  require_valid_site_syntax.call(root, "nested recursive ownership")
end
expect_acquisition_failure.call(
  "always-branch media control network deletion",
  "host preparation must never delete Docker networks"
) do |root|
  mutate_yaml_file(root, "roles/host_prep/tasks/main.yml") do |tasks|
    tasks << {
      "name" => "Always delete a media network",
      "block" => [{
        "name" => "Exercise the guarded network block",
        "ansible.builtin.debug" => { "msg" => "valid mutation fixture" }
      }],
      "always" => [{
        "name" => "Delete a media network from always",
        "community.docker.docker_network" => {
          "name" => "media-control", "state" => "absent"
        }
      }]
    }
  end
  require_valid_site_syntax.call(root, "always-branch network deletion")
end

expect_acquisition_failure.call(
  "conflicting Jellyfin media network environment",
  "jellyfin must export the derived media control network exactly once"
) do |root|
  path = File.join(root, "roles", "jellyfin", "templates", "env.j2")
  File.open(path, "a") { |file| file.puts("PLATFORM_MEDIA_NETWORK=wrong-network") }
end

%w[audiobookshelf jellyfin].each do |reader|
  %w[default media-control].each do |membership|
    expect_acquisition_failure.call(
      "#{reader} missing #{membership} membership",
      "#{reader} must join default and media-control explicitly"
    ) do |root|
      mutate_compose.call(root, "services/#{reader}/compose.yml") do |compose|
        compose.fetch("services").fetch(reader).fetch("networks").delete(membership)
      end
    end
  end
  expect_acquisition_failure.call(
    "#{reader} internal media control network",
    "#{reader} must declare only canonical default and external media-control networks"
  ) do |root|
    mutate_compose.call(root, "services/#{reader}/compose.yml") do |compose|
      compose.fetch("networks").fetch("media-control")["external"] = false
    end
  end
  expect_acquisition_failure.call(
    "#{reader} writable media mount",
    "#{reader} media mount must remain read-only"
  ) do |root|
    mutate_compose.call(root, "services/#{reader}/compose.yml") do |compose|
      volumes = compose.fetch("services").fetch(reader).fetch("volumes")
      index = volumes.index { |volume| volume.end_with?(reader == "jellyfin" ? "/media:ro" : "/audiobooks:ro") }
      volumes[index] = volumes.fetch(index).delete_suffix(":ro")
    end
  end
end

# The pre-upgrade copy rule is the only guard on the shared rescue (#836).
expect_failure(failures, "shared pre-upgrade rescue that leaves the service stopped",
               "role pre_upgrade_backup: a failed pre-upgrade copy must start the stopped container again, " \
               "on its old image",
               detected_by: %i[policy]) do |root|
  mutate_yaml_file(root, "roles/pre_upgrade_backup/tasks/main.yml") do |tasks|
    tasks.find { |task| task.key?("rescue") }["rescue"]
         .reject! { |task| task.key?("community.docker.docker_compose_v2") }
  end
end

expect_failure(failures, "shared pre-upgrade rescue that starts over a missing store",
               "role pre_upgrade_backup: a failed pre-upgrade copy must not start the old container over a missing store",
               detected_by: %i[policy]) do |root|
  mutate_yaml_file(root, "roles/pre_upgrade_backup/tasks/main.yml") do |tasks|
    tasks.find { |task| task.key?("rescue") }["rescue"]
         .find { |task| task.key?("community.docker.docker_compose_v2") }.delete("when")
  end
end

expect_failure(failures, "shared pre-upgrade rescue start gated on the read taken before the stop",
               "role pre_upgrade_backup: a failed pre-upgrade copy must not start the old container over a missing store",
               detected_by: %i[policy]) do |root|
  mutate_yaml_file(root, "roles/pre_upgrade_backup/tasks/main.yml") do |tasks|
    tasks.find { |task| task.key?("rescue") }["rescue"]
         .find { |task| task.key?("community.docker.docker_compose_v2") }["when"] =
      "pre_upgrade_backup_store_stat.stat.isreg | default(false)"
  end
end

expect_failure(failures, "shared pre-upgrade rescue start that accepts a directory or a dangling symlink",
               "role pre_upgrade_backup: a failed pre-upgrade copy must not start the old container over a missing store",
               detected_by: %i[policy]) do |root|
  mutate_yaml_file(root, "roles/pre_upgrade_backup/tasks/main.yml") do |tasks|
    tasks.find { |task| task.key?("rescue") }["rescue"]
         .find { |task| task.key?("community.docker.docker_compose_v2") }["when"] =
      "pre_upgrade_backup_store_after.stat.exists | default(false)"
  end
end

expect_failure(failures, "shared pre-upgrade rescue store read of the write-ahead log",
               "role pre_upgrade_backup: a failed pre-upgrade copy must not start the old container over a missing store",
               detected_by: %i[policy]) do |root|
  mutate_yaml_file(root, "roles/pre_upgrade_backup/tasks/main.yml") do |tasks|
    tasks.find { |task| task.key?("rescue") }["rescue"]
         .find { |task| task.key?("ansible.builtin.stat") }["ansible.builtin.stat"]["path"] =
      "{{ pre_upgrade_backup_store_dir }}/{{ pre_upgrade_backup_store_file }}-wal"
  end
end

expect_failure(failures, "shared pre-upgrade rescue store read that aborts on a permission error",
               "role pre_upgrade_backup: a failed pre-upgrade copy must not start the old container over a missing store",
               detected_by: %i[policy]) do |root|
  mutate_yaml_file(root, "roles/pre_upgrade_backup/tasks/main.yml") do |tasks|
    tasks.find { |task| task.key?("rescue") }["rescue"]
         .find { |task| task.key?("ansible.builtin.stat") }.delete("failed_when")
  end
end

expect_failure(failures, "shared second pre-upgrade start under always",
               "role pre_upgrade_backup: a failed pre-upgrade copy must start the stopped container again, " \
               "on its old image",
               detected_by: %i[policy]) do |root|
  mutate_yaml_file(root, "roles/pre_upgrade_backup/tasks/main.yml") do |tasks|
    unit = tasks.find { |task| task.key?("rescue") }
    start = unit["rescue"].find { |task| task.key?("community.docker.docker_compose_v2") }
    unit["always"] = [Marshal.load(Marshal.dump(start)).tap { |task| task.delete("when") }]
  end
end

expect_failure(failures, "shared pre-upgrade rescue that lets the upgrade proceed",
               "role pre_upgrade_backup: a failed pre-upgrade copy must still fail the run",
               detected_by: %i[policy]) do |root|
  mutate_yaml_file(root, "roles/pre_upgrade_backup/tasks/main.yml") do |tasks|
    tasks.find { |task| task.key?("rescue") }["rescue"].reject! { |task| task.key?("ansible.builtin.fail") }
  end
end

expect_failure(failures, "Vaultwarden deployment report that ignores the shared pre-upgrade restart",
               "role vaultwarden: includes roles/pre_upgrade_backup but its deployment report ignores " \
               "pre_upgrade_backup_restart",
               detected_by: %i[policy]) do |root|
  path = File.join(root, "roles/vaultwarden/tasks/report.yml")
  body = File.read(path)
  planted = body.sub("((pre_upgrade_backup_restart | default({})) is changed) or", "")
  raise "report gate plant matched nothing" if planted == body

  File.write(path, planted)
end

# A caller naming a service it never declared is an uncontained start (#836).
expect_failure(failures, "shared pre-upgrade copy naming a service its caller never contained",
               "role vaultwarden starts komga out of the installed release",
               detected_by: %i[deployment policy]) do |root|
  path = File.join(root, "roles/vaultwarden/tasks/deploy.yml")
  body = File.read(path)
  planted = body.sub("    pre_upgrade_backup_service_name: vaultwarden\n",
                     "    pre_upgrade_backup_service_name: komga\n")
  raise "caller service plant matched nothing" if planted == body

  File.write(path, planted)
end

# Vaultwarden's call site: each argument policy_test.rb holds is planted once.
[
  ["    pre_upgrade_backup_extra_patterns: [rsa_key*]\n", "    pre_upgrade_backup_extra_patterns: []\n",
   "role vaultwarden: the pre-upgrade copy must carry rsa_key*"],
  ["    pre_upgrade_backup_project_name: \"{{ vaultwarden_compose_project_name }}\"\n",
   "    pre_upgrade_backup_project_name: \"{{ kapowarr_compose_project_name }}\"\n",
   "role vaultwarden: the pre-upgrade copy must be given pre_upgrade_backup_project_name"],
  ["    pre_upgrade_backup_store_file: db.sqlite3\n", "    pre_upgrade_backup_store_file: Kapowarr.db\n",
   "role vaultwarden: the pre-upgrade copy must be given pre_upgrade_backup_store_file"],
  ["    pre_upgrade_backup_path: \"{{ vaultwarden_pre_upgrade_backup_path }}\"\n",
   "    pre_upgrade_backup_path: \"{{ vaultwarden_data_host_path }}/backup\"\n",
   "role vaultwarden: the pre-upgrade copy must be given pre_upgrade_backup_path"],
  ["    pre_upgrade_backup_manage_ownership: true\n", "    pre_upgrade_backup_manage_ownership: false\n",
   "role vaultwarden: the pre-upgrade copy must be given pre_upgrade_backup_manage_ownership"]
].each do |from, to, message|
  expect_failure(failures, "Vaultwarden pre-upgrade call site with #{to.strip}", message,
                 detected_by: %i[policy]) do |root|
    path = File.join(root, "roles/vaultwarden/tasks/deploy.yml")
    body = File.read(path)
    raise "Vaultwarden call-site plant matched #{body.scan(from).length} times" unless body.scan(from).length == 1

    File.write(path, body.sub(from, to))
  end
end

expect_failure(failures, "Karakeep deployment report that ignores the shared pre-upgrade restart",
               "role karakeep: includes roles/pre_upgrade_backup but its deployment report ignores " \
               "pre_upgrade_backup_restart",
               detected_by: %i[policy]) do |root|
  path = File.join(root, "roles/karakeep/tasks/report.yml")
  body = File.read(path)
  planted = body.sub("((pre_upgrade_backup_restart | default({})) is changed) or", "")
  raise "report gate plant matched nothing" if planted == body

  File.write(path, planted)
end

# Karakeep's call site (#826), and its position after the application's guard.
[
  ["    pre_upgrade_backup_compose_service: karakeep\n", "    pre_upgrade_backup_compose_service: web\n",
   "role karakeep: the pre-upgrade copy must be given pre_upgrade_backup_compose_service"],
  ["    pre_upgrade_backup_project_name: \"{{ karakeep_compose_project_name }}\"\n",
   "    pre_upgrade_backup_project_name: \"{{ kapowarr_compose_project_name }}\"\n",
   "role karakeep: the pre-upgrade copy must be given pre_upgrade_backup_project_name"],
  ["    pre_upgrade_backup_store_file: db.db\n", "    pre_upgrade_backup_store_file: queue.db\n",
   "role karakeep: the pre-upgrade copy must be given pre_upgrade_backup_store_file"],
  ["    pre_upgrade_backup_extra_patterns: [queue.db]\n", "    pre_upgrade_backup_extra_patterns: [\"*\"]\n",
   "role karakeep: the pre-upgrade copy must be given pre_upgrade_backup_extra_patterns"],
  ["    pre_upgrade_backup_path: \"{{ karakeep_pre_upgrade_backup_path }}\"\n",
   "    pre_upgrade_backup_path: \"{{ karakeep_meilisearch_host_path }}/backup\"\n",
   "role karakeep: the pre-upgrade copy must be given pre_upgrade_backup_path"],
  ["    pre_upgrade_backup_manage_ownership: \"{{ platform_kind == 'nas' or (platform_manage_linux_ownership | bool) }}\"\n",
   "    pre_upgrade_backup_manage_ownership: false\n",
   "role karakeep: the pre-upgrade copy must be given pre_upgrade_backup_manage_ownership"]
].each do |from, to, message|
  expect_failure(failures, "Karakeep pre-upgrade call site with #{to.strip}", message,
                 detected_by: %i[policy]) do |root|
    path = File.join(root, "roles/karakeep/tasks/deploy.yml")
    body = File.read(path)
    raise "Karakeep call-site plant matched #{body.scan(from).length} times" unless body.scan(from).length == 1

    File.write(path, body.sub(from, to))
  end
end

# The copy must not run ahead of the application's guard (#858).
expect_failure(failures, "Karakeep pre-upgrade copy ahead of the application guard",
               "role karakeep: the pre-upgrade copy must follow the application's image_downgrade_guard",
               detected_by: %i[policy]) do |root|
  mutate_yaml_file(root, "roles/karakeep/tasks/deploy.yml") do |tasks|
    copy = tasks.index { |task| task.dig("ansible.builtin.include_role", "name") == "pre_upgrade_backup" }
    app = tasks.index { |task| task.dig("vars", "image_downgrade_guard_compose_service") == "karakeep" }
    raise "guard order plant found no guard or copy" unless copy && app && app < copy

    tasks.insert(app, tasks.delete_at(copy))
  end
end

expect_failure(failures, "Karakeep application guard tagged apart from the pre-upgrade copy",
               "role karakeep: the pre-upgrade copy must follow the application's image_downgrade_guard",
               detected_by: %i[policy]) do |root|
  mutate_yaml_file(root, "roles/karakeep/tasks/deploy.yml") do |tasks|
    app = tasks.find { |task| task.dig("vars", "image_downgrade_guard_compose_service") == "karakeep" }
    raise "guard tag plant found no application guard" unless app

    app["tags"] = ["karakeep_guard"]
  end
end

# The include parameter would outrank the pin the role reads itself (#858).
expect_failure(failures, "shared pre-upgrade copy handed a pin by its caller",
               "hands roles/pre_upgrade_backup a pre_upgrade_backup_pinned_image",
               detected_by: %i[policy]) do |root|
  path = File.join(root, "roles/vaultwarden/tasks/deploy.yml")
  body = File.read(path)
  from = "    pre_upgrade_backup_project_name: \"{{ vaultwarden_compose_project_name }}\"\n"
  raise "pin plant matched #{body.scan(from).length} times" unless body.scan(from).length == 1

  File.write(path, body.sub(from, from + "    pre_upgrade_backup_pinned_image: \"{{ image_downgrade_guard_pinned_image }}\"\n"))
end

expect_failure(failures, "Karakeep pre-upgrade copy after its deployment",
               "role karakeep: the pre-upgrade copy must run before the Compose deployment",
               detected_by: %i[policy]) do |root|
  mutate_yaml_file(root, "roles/karakeep/tasks/deploy.yml") do |tasks|
    copy = tasks.index { |task| task.dig("ansible.builtin.include_role", "name") == "pre_upgrade_backup" }
    deploy = tasks.index { |task| Array(task["block"]).any? { |inner| inner["register"] == "karakeep_deploy" } }
    raise "deployment order plant found no copy or deployment" unless copy && deploy && copy < deploy

    tasks.insert(deploy, tasks.delete_at(copy))
  end
end

# The pg_dump entry Nextcloud and Paperless-ngx take (#826).
PG_DUMP_SHAPE = "role pre_upgrade_backup: tasks/pg_dump.yml must dump the database after stopping the application"
expect_failure(failures, "pre-upgrade dump taken before the application stops", PG_DUMP_SHAPE,
               detected_by: %i[policy]) do |root|
  mutate_yaml_file(root, "roles/pre_upgrade_backup/tasks/pg_dump.yml") do |tasks|
    tasks.find { |task| task.key?("rescue") }["block"].reverse!
  end
end

expect_failure(failures, "pre-upgrade dump that succeeds on any exit code", PG_DUMP_SHAPE,
               detected_by: %i[policy]) do |root|
  mutate_yaml_file(root, "roles/pre_upgrade_backup/tasks/pg_dump.yml") do |tasks|
    tasks.find { |task| task.key?("rescue") }["block"]
         .find { |task| task.key?("community.docker.docker_compose_v2_exec") }["failed_when"] = false
  end
end

expect_failure(failures, "pre-upgrade dump rescue that starts only the application", PG_DUMP_SHAPE,
               detected_by: %i[policy]) do |root|
  mutate_yaml_file(root, "roles/pre_upgrade_backup/tasks/pg_dump.yml") do |tasks|
    tasks.find { |task| task.key?("rescue") }["rescue"]
         .find { |task| task.key?("community.docker.docker_compose_v2") }["community.docker.docker_compose_v2"]["services"] =
      ["{{ pre_upgrade_backup_compose_service }}"]
  end
end

expect_failure(failures, "pre-upgrade dump rescue that lets the upgrade proceed",
               "role pre_upgrade_backup: a failed pre-upgrade copy must still fail the run",
               detected_by: %i[policy]) do |root|
  mutate_yaml_file(root, "roles/pre_upgrade_backup/tasks/pg_dump.yml") do |tasks|
    tasks.find { |task| task.key?("rescue") }["rescue"].reject! { |task| task.key?("ansible.builtin.fail") }
  end
end

PG_CODE_ARCHIVE = "role pre_upgrade_backup: tasks/pg_dump.yml must archive the code tree after the dump"
code_archive = ->(task) { Array(task.dig("ansible.builtin.command", "argv"))[0, 2] == %w[docker run] }
expect_failure(failures, "pre-upgrade code archive outside the block its rescue covers", PG_CODE_ARCHIVE,
               detected_by: %i[policy]) do |root|
  mutate_yaml_file(root, "roles/pre_upgrade_backup/tasks/pg_dump.yml") do |tasks|
    unit = tasks.find { |task| task.key?("rescue") }
    tasks.insert(tasks.index(unit) + 1, unit["block"].delete(unit["block"].find(&code_archive)))
  end
end

expect_failure(failures, "pre-upgrade code archive taken before the dump", PG_CODE_ARCHIVE,
               detected_by: %i[policy]) do |root|
  mutate_yaml_file(root, "roles/pre_upgrade_backup/tasks/pg_dump.yml") do |tasks|
    block = tasks.find { |task| task.key?("rescue") }["block"]
    block.insert(0, block.delete(block.find(&code_archive)))
  end
end

expect_failure(failures, "pre-upgrade code archive run from the pinned image", PG_CODE_ARCHIVE,
               detected_by: %i[policy]) do |root|
  mutate_yaml_file(root, "roles/pre_upgrade_backup/tasks/pg_dump.yml") do |tasks|
    argv = tasks.find { |task| task.key?("rescue") }["block"].find(&code_archive)["ansible.builtin.command"]["argv"]
    argv[argv.index("{{ pre_upgrade_backup_deployed_image_id }}")] = "{{ pre_upgrade_backup_pinned_image }}"
  end
end

expect_failure(failures, "pre-upgrade code archive whose failure is ignored", PG_CODE_ARCHIVE,
               detected_by: %i[policy]) do |root|
  mutate_yaml_file(root, "roles/pre_upgrade_backup/tasks/pg_dump.yml") do |tasks|
    tasks.find { |task| task.key?("rescue") }["block"].find(&code_archive)["ignore_errors"] = true
  end
end

expect_failure(failures, "pre-upgrade dump entry removed",
               "pre-upgrade copies that stop a container: 1 found, expected at least 2",
               detected_by: %i[policy]) do |root|
  FileUtils.rm_f(File.join(root, "roles/pre_upgrade_backup/tasks/pg_dump.yml"))
end

[
  ["nextcloud", "    pre_upgrade_backup_stop_services: [nextcloud, cron]\n",
   "    pre_upgrade_backup_stop_services: [nextcloud]\n", "pre_upgrade_backup_stop_services"],
  ["nextcloud", "    tasks_from: pg_dump\n", "", "tasks_from"],
  ["nextcloud", "    pre_upgrade_backup_database_service: db\n",
   "    pre_upgrade_backup_database_service: cache\n", "pre_upgrade_backup_database_service"],
  ["paperless_ngx", "    pre_upgrade_backup_compose_service: webserver\n",
   "    pre_upgrade_backup_compose_service: db\n", "pre_upgrade_backup_compose_service"],
  ["paperless_ngx", "    pre_upgrade_backup_project_name: \"{{ paperless_compose_project_name }}\"\n",
   "    pre_upgrade_backup_project_name: \"{{ nextcloud_compose_project_name }}\"\n", "pre_upgrade_backup_project_name"],
  # #884: a dropped code root, or one inside the data root that rsync --delete removes.
  ["nextcloud", "    pre_upgrade_backup_code_root: \"{{ nextcloud_data_host_path }}\"\n", "",
   "pre_upgrade_backup_code_root"],
  ["nextcloud", "    pre_upgrade_backup_code_archive_dir: \"{{ nextcloud_postgres_host_path }}/pre-upgrade-backup\"\n",
   "    pre_upgrade_backup_code_archive_dir: \"{{ nextcloud_data_host_path }}/pre-upgrade-backup\"\n",
   "pre_upgrade_backup_code_archive_dir"]
].each do |role, from, to, argument|
  expect_failure(failures, "#{role} pre-upgrade dump call site without #{from.strip}",
                 "role #{role}: the pre-upgrade dump must be given #{argument}",
                 detected_by: %i[policy]) do |root|
    path = File.join(root, "roles/#{role}/tasks/deploy.yml")
    body = File.read(path)
    raise "#{role} call-site plant matched #{body.scan(from).length} times" unless body.scan(from).length == 1

    File.write(path, body.sub(from, to))
  end
end

{ "nextcloud" => "nextcloud_data_deploy", "paperless_ngx" => "paperless_deploy" }.each do |role, register|
  expect_failure(failures, "#{role} pre-upgrade dump moved past #{register}",
                 "role #{role}: the pre-upgrade dump must run after the deployment registering",
                 detected_by: %i[policy]) do |root|
    mutate_yaml_file(root, "roles/#{role}/tasks/deploy.yml") do |tasks|
      dump = tasks.index { |task| task.dig("ansible.builtin.include_role", "name") == "pre_upgrade_backup" }
      anchor = tasks.index { |task| task["register"] == register }
      raise "#{role} order plant found no dump or #{register}" unless dump && anchor

      tasks.insert(anchor, tasks.delete_at(dump))
    end
  end
end

expect_failure(failures, "Nextcloud guard gated apart from the pre-upgrade dump",
               "role nextcloud: the pre-upgrade dump must follow the nextcloud image_downgrade_guard",
               detected_by: %i[policy]) do |root|
  mutate_yaml_file(root, "roles/nextcloud/tasks/deploy.yml") do |tasks|
    guard = tasks.find { |task| task.dig("ansible.builtin.include_role", "name") == "image_downgrade_guard" }
    raise "guard plant found no guard" unless guard

    guard["tags"] = ["nextcloud_guard"]
  end
end

{ "nextcloud" => "roles/nextcloud/tasks/report.yml", "paperless_ngx" => "roles/paperless_ngx/tasks/deploy.yml" }
  .each do |role, path|
  expect_failure(failures, "#{role} deployment report that ignores the pre-upgrade dump's restart",
                 "role #{role}: includes roles/pre_upgrade_backup but its deployment report ignores " \
                 "pre_upgrade_backup_restart",
                 detected_by: %i[policy]) do |root|
    file = File.join(root, path)
    body = File.read(file)
    planted = body.sub(/ or\s*\(\(pre_upgrade_backup_restart \| default\(\{\}\)\) is changed\)/, "")
                  .sub("((pre_upgrade_backup_restart | default({})) is changed) or", "")
    raise "#{role} report gate plant matched nothing" if planted == body

    File.write(file, planted)
  end
end

# Compose resolves anchors per file, so the copied fragments must agree.
expect_failure(failures, "divergent logging fragment",
               "komga: x-logging must hold the values every stack's copy of it shares",
               detected_by: %i[policy]) do |root|
  mutate_compose.call(root, "services/komga/compose.yml") do |compose|
    compose["x-logging"] = { "driver" => "json-file", "options" => { "max-size" => "50m", "max-file" => "3" } }
  end
end

expect_failure(failures, "divergent health-check timing fragment",
               "komga: x-healthcheck-defaults must hold the values every stack's copy of it shares",
               detected_by: %i[policy]) do |root|
  mutate_compose.call(root, "services/komga/compose.yml") do |compose|
    compose["x-healthcheck-defaults"] = { "interval" => "45s", "timeout" => "10s",
                                          "retries" => 5, "start_period" => "60s" }
  end
end

# Each row types a number into a task that the timing policy owns (#844).
[
  ['retries: "{{ komga_claim_retries }}"', "retries: 20", "retries: 20 as a literal"],
  ['retries: "{{ komga_claim_retries }}"', 'retries: "20"', 'retries: "20" as a literal'],
  ['retries: "{{ komga_claim_retries }}"', 'retries: "{{ 20 }}"', 'retries: "{{ 20 }}" as a literal'],
  ['retries: "{{ komga_claim_retries }}"', 'retries: "{{ komga_undeclared_retries }}"',
   'retries: "{{ komga_undeclared_retries }}", reading undeclared komga_undeclared_retries'],
  ['until: komga_claim_status.status | default(0) == 200
  retries: "{{ komga_claim_retries }}"
  delay: "{{ platform_readiness_delay }}"',
   'until: komga_claim_status.status | default(0) == 200
  retries: "{{ komga_claim_retries }}"
  delay: 3', "delay: 3 as a literal"]
].each do |from, to, message|
  expect_failure(failures, "Komga claim wait with #{to.lines.last.strip}",
                 "roles/komga/tasks/main.yml: \"Read Komga claim status\" writes #{message}",
                 detected_by: %i[policy]) do |root|
    mutate_text(root, "roles/komga/tasks/main.yml", from, to)
  end
end

expect_failure(failures, "literal Compose wait_timeout",
               "writes wait_timeout as a literal",
               detected_by: %i[policy]) do |root|
  mutate_text(root, "roles/komga/tasks/main.yml",
              'wait_timeout: "{{ platform_compose_wait_timeout }}"', "wait_timeout: 180")
end

expect_failure(failures, "service defaults fragment disagreeing with platform policy",
               "komga: x-service-defaults must carry the platform cpuset, " \
               "security_opt, restart and logging",
               detected_by: %i[policy]) do |root|
  mutate_compose.call(root, "services/komga/compose.yml") do |compose|
    compose.fetch("x-service-defaults")["security_opt"] = []
  end
end

expect_failure(failures, "container-local logging variant",
               "komga/komga: logging must be the platform fragment, not a variant of it",
               detected_by: %i[policy]) do |root|
  mutate_compose.call(root, "services/komga/compose.yml") do |compose|
    compose.fetch("services").fetch("komga")["logging"] =
      { "driver" => "json-file", "options" => { "max-size" => "1g", "max-file" => "99" } }
  end
end

# The only proof the memory-limit checks work; the two heap rows catch a check that
# skips its relation when mem_limit is absent, and one that never fires without a heap.
expect_failure(failures, "self-sizing image without a memory limit",
               "paperless-ngx/tika: an image that sizes its own memory from what it can see " \
               "must declare mem_limit",
               detected_by: %i[policy]) do |root|
  mutate_compose.call(root, "services/paperless-ngx/compose.yml") do |compose|
    compose.fetch("services").fetch("tika").delete("mem_limit")
  end
end

expect_failure(failures, "self-sizing image bumped off the pinned expectation",
               "update both together",
               detected_by: %i[policy]) do |root|
  mutate_compose.call(root, "services/paperless-ngx/compose.yml") do |compose|
    tika = compose.fetch("services").fetch("tika")
    tika["image"] = tika.fetch("image").sub("apache/tika", "apache/tika-renamed")
  end
end

expect_failure(failures, "declared heap with no memory limit",
               "paperless-ngx/tika: a container declaring a JVM heap must declare mem_limit",
               detected_by: %i[policy]) do |root|
  mutate_compose.call(root, "services/paperless-ngx/compose.yml") do |compose|
    tika = compose.fetch("services").fetch("tika")
    tika.delete("mem_limit")
    tika["environment"] = tika.fetch("environment").merge("JAVA_TOOL_OPTIONS" => "-Xmx512m")
  end
end

expect_failure(failures, "declared heap above half its memory limit",
               "paperless-ngx/tika: declared heap must be at most half of mem_limit",
               detected_by: %i[policy]) do |root|
  mutate_compose.call(root, "services/paperless-ngx/compose.yml") do |compose|
    tika = compose.fetch("services").fetch("tika")
    tika["environment"] = tika.fetch("environment").merge("JAVA_TOOL_OPTIONS" => "-Xmx1500m")
  end
end

# Release-mount label rule (#810): a missing label, and a removed mount that would
# empty the derived subject set.
expect_failure(failures, "release-mounted file with no content label",
               "downloaders/sabnzbd: a file bind-mounted out of the release pointer must be " \
               "labelled with its own sha256",
               detected_by: %i[policy]) do |root|
  mutate_compose.call(root, "services/downloaders/compose.yml") do |compose|
    compose.fetch("services").fetch("sabnzbd").fetch("labels")
           .delete("dev.nas-platform.downloaders.clamav-gate-sha256")
  end
end

expect_failure(failures, "release mount dropped off the pinned expectation",
               "containers bind-mounting a file out of the release pointer are",
               detected_by: %i[policy]) do |root|
  mutate_compose.call(root, "services/dozzle/compose.yml") do |compose|
    relay = compose.fetch("services").fetch("alert-relay")
    relay["volumes"] = relay.fetch("volumes").grep_v(%r{\A\$\{PLATFORM_CURRENT_DIR:\?\}/})
  end
end

expect_failure(failures, "release mount hidden in a platform override",
               "a file mounted out of the release pointer belongs in the canonical compose.yml",
               detected_by: %i[policy]) do |root|
  mutate_compose.call(root, "services/downloaders/compose.mac.yml") do |compose|
    compose.fetch("services").fetch("sabnzbd")["volumes"] =
      ["${PLATFORM_CURRENT_DIR:?}/services/downloaders/clamav_gate.py:/scripts/extra.py:ro"]
  end
end

# Who can reach a Docker socket proxy (#829).
{
  "hub joined to the Beszel socket proxy network" =>
    ["services/beszel/compose.yml", "beszel/socket-proxy: shares a network with",
     ->(compose) { compose.fetch("services").fetch("hub")["networks"] << "docker-api" }],
  "alert relay joined to the Dozzle socket proxy network" =>
    ["services/dozzle/compose.yml", "dozzle/socket-proxy: shares a network with",
     ->(compose) { compose.fetch("services").fetch("alert-relay")["networks"] << "docker-api" }],
  "Dozzle socket proxy fallen back onto default" =>
    ["services/dozzle/compose.yml", "dozzle/socket-proxy: shares a network with",
     ->(compose) { compose.fetch("services").fetch("socket-proxy").delete("networks") }],
  "stated Beszel consumer dropped off the proxy network" =>
    ["services/beszel/compose.yml", "beszel/socket-proxy: shares a network with []",
     ->(compose) { compose.fetch("services").fetch("agent-portable")["networks"] = ["default"] }],
  "Beszel socket proxy network no longer internal" =>
    ["services/beszel/compose.yml", "beszel/socket-proxy: network docker-api must be internal",
     ->(compose) { compose.fetch("networks").fetch("docker-api").delete("internal") }],
  "Dozzle socket proxy published on loopback" =>
    ["services/dozzle/compose.yml", "dozzle/socket-proxy: publishes",
     ->(compose) { compose.fetch("services").fetch("socket-proxy")["ports"] = ["127.0.0.1:2376:2375"] }],
  "Beszel socket proxy published on the wildcard" =>
    ["services/beszel/compose.yml", "beszel/socket-proxy: publishes",
     ->(compose) { compose.fetch("services").fetch("socket-proxy")["ports"] = ["2375:2375"] }],
  "socket proxy membership rewired in a platform override" =>
    ["services/dozzle/compose.integration.yml",
     "services/dozzle/compose.integration.yml/alert-relay: an override may not change who reaches",
     ->(compose) { compose.fetch("services").fetch("alert-relay")["networks"] = ["docker-api"] }],
  "Beszel proxy network redefined in the Mac override" =>
    ["services/beszel/compose.mac.yml",
     "services/beszel/compose.mac.yml: an override may not declare networks",
     ->(compose) { compose["networks"] = { "docker-api" => { "internal" => false } } }],
  "Dozzle proxy network redefined in the integration override" =>
    ["services/dozzle/compose.integration.yml",
     "services/dozzle/compose.integration.yml: an override may not declare networks",
     ->(compose) { compose["networks"] = { "docker-api" => { "internal" => false } } }],
  "socket proxy the consumer map no longer finds" =>
    ["services/dozzle/compose.yml", "services mounting the Docker socket are",
     ->(compose) { compose.fetch("services").fetch("socket-proxy")["volumes"] = [] }]
}.each do |label, (relative_path, message, mutation)|
  expect_failure(failures, label, message, detected_by: %i[policy]) do |root|
    mutate_compose.call(root, relative_path, &mutation)
  end
end

expect_failure(failures, "recreated retired role",
               "retired role directory must be absent",
               detected_by: %i[policy]) do |root|
  path = File.join(root, "roles", retired_token, "tasks", "main.yml")
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, "---\n[]\n")
end

expect_failure(failures, "current README mention",
               "retired declaration remains: README.md",
               detected_by: %i[policy]) do |root|
  File.open(File.join(root, "README.md"), "a") { |file| file.puts(retired_token) }
end

expect_failure(failures, "current operator documentation mention",
               "retired declaration remains: docs/adding-a-service.md",
               detected_by: %i[policy]) do |root|
  File.open(File.join(root, "docs", "adding-a-service.md"), "a") do |file|
    file.puts(retired_token.upcase)
  end
end

expect_failure(failures, "nested current operator documentation mention",
               "retired declaration remains: docs/operator/guide.md",
               detected_by: %i[policy]) do |root|
  path = File.join(root, "docs", "operator", "guide.md")
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, retired_token)
end

expect_failure(failures, "deceptive migration neighbor",
               "retired declaration remains: scripts/migrate-media-acquisition-vault.py.bak",
               detected_by: %i[policy]) do |root|
  path = File.join(root, "scripts", "migrate-media-acquisition-vault.py.bak")
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, retired_token)
end

expect_failure(failures, "lone migration file",
               "the temporary encrypted-vault migration audit is incomplete",
               detected_by: %i[policy]) do |root|
  path = File.join(root, "scripts", "migrate-media-acquisition-vault.py")
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, "#!/usr/bin/env python3\n")
end

expect_failure(failures, "missing validation registration",
               "the temporary encrypted-vault migration audit is incomplete",
               detected_by: %i[policy]) do |root|
  migration_paths = %w[
    scripts/migrate-media-acquisition-vault.py
    tests/media_acquisition_vault_migration_test.py
  ]
  migration_paths.each do |relative_path|
    path = File.join(root, relative_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "# temporary migration audit\n")
  end
end

expect_failure(failures, "changed tracked README detection",
               "retired declaration remains: README.md",
               detected_by: %i[policy]) do |root|
  path = File.join(root, "README.md")
  File.open(path, "a") { |file| file.puts(retired_token) }
  _stdout, stderr, status = capture3_without_git_routing("git", "add", "README.md", chdir: root)
  raise "could not stage tracked README mutation: #{stderr.lines.first&.strip}" unless status.success?
end

expect_failure(failures, "new untracked forbidden source",
               "retired declaration remains: tests/retired-policy.rb",
               detected_by: %i[policy]) do |root|
  File.write(File.join(root, "tests", "retired-policy.rb"), retired_token)
end

expect_failure(failures, "selected current-source leaf symlink",
               "tests/retired-policy.rb: active source must be a regular file",
               detected_by: %i[policy]) do |root|
  target = File.join(root, "retired-policy-target")
  File.write(target, retired_token)
  File.symlink(target, File.join(root, "tests", "retired-policy.rb"))
end

expect_failure(failures, "selected current-source symlinked ancestor",
               "tests/operator/guide.rb: active source path must not contain symlinks",
               detected_by: %i[policy]) do |root|
  tracked_directory = File.join(root, "tests", "operator")
  tracked_source = File.join(tracked_directory, "guide.rb")
  FileUtils.mkdir_p(tracked_directory)
  File.write(tracked_source, "current source\n")
  _stdout, stderr, status = capture3_without_git_routing(
    "git", "add", "tests/operator/guide.rb", chdir: root
  )
  raise "could not stage symlink-ancestor fixture: #{stderr.lines.first&.strip}" unless status.success?

  outside = File.join(File.dirname(root), "outside-active-sources")
  FileUtils.mkdir_p(outside)
  File.write(File.join(outside, "guide.rb"), retired_token)
  FileUtils.rm_rf(tracked_directory)
  File.symlink(outside, tracked_directory)
end

expect_success(failures, "ignored bytecode containing retired token") do |root|
  cache = File.join(root, "tests", "__pycache__")
  FileUtils.mkdir_p(cache)
  File.binwrite(File.join(cache, "retired-policy.pyc"), retired_token)
end

# The harness's own guards first: a fixture builder escaping the sandbox proves nothing.
expect_fixture_identity_rejection(
  failures, "traversal service name",
  { "name" => "../../source-sentinel", "role" => "beszel", "status" => "implemented" }
)
expect_fixture_identity_rejection(
  failures, "traversal role",
  { "name" => "beszel", "role" => "../../sandbox-sentinel", "status" => "implemented" }
)

expect_failure(failures, "reintroduced legacy source",
               "must not reintroduce a legacy migration source",
               detected_by: %i[policy]) do |root|
  mutate_manifest(root) do |manifest|
    manifest["legacy_source"] = { "repository" => "example/legacy" }
  end
end

# vault detects this too: the manifest `role` names both vault_<role>.yml and
# service_<role>.yml, which policy_vault_test.rb derives from.
{
  "role" => "wrong_role"
}.each do |field, value|
  expect_failure(failures, "wrong #{field}", "beszel: #{field} must equal",
                 detected_by: %i[policy deployment vault]) do |root|
    mutate_manifest(root) { |manifest| service(manifest, "beszel")[field] = value }
  end
end

expect_failure(failures, "beszel downgrade", "beszel: status must be implemented or accepted",
               detected_by: %i[policy ci]) do |root|
  mutate_manifest(root) { |manifest| service(manifest, "beszel")["status"] = "planned" }
end

expect_failure(failures, "non-string name", "service name must be a string",
               detected_by: %i[policy ci deployment vault]) do |root|
  mutate_manifest(root) { |manifest| manifest.fetch("services").first["name"] = 7 }
end

expect_failure(failures, "heterogeneous services", "each service manifest entry must be a mapping",
               detected_by: %i[policy ci deployment vault]) do |root|
  mutate_manifest(root) { |manifest| manifest.fetch("services")[0] = "audiobookshelf" }
end

expect_failure(failures, "duplicate manifest service", "service manifest name values must be unique",
               detected_by: %i[policy vault]) do |root|
  mutate_manifest(root) do |document|
    document.fetch("services") << service(document, "arr").dup
  end
end

expect_failure(failures, "implemented service stripped of its vault contract",
               "tests/expected/seerr.yml vault_keys must be a nonempty list",
               detected_by: %i[policy vault]) do |root|
  mutate_yaml_file(root, "tests/expected/seerr.yml") { |document| document["vault_keys"] = [] }
end

expect_failure(failures, "second acquisition job",
               "Configarr must be the sole one-shot acquisition service",
               detected_by: %i[policy]) do |root|
  mutate_yaml_file(root, "config/media-acquisition.yml") do |catalog|
    catalog.dig("projects", "arr", "services", "radarr")["class"] = "one_shot"
  end
end

promote_arr_with_compose = lambda do |root|
  logging = {
    "driver" => "json-file",
    "options" => { "max-size" => "10m", "max-file" => "3" }
  }
  daemon = lambda do |cpus|
    {
      "image" => "example.invalid/service:1.0@sha256:#{'a' * 64}",
      "cpuset" => "${PLATFORM_CONTAINER_CPUSET:?}",
      "cpus" => cpus,
      "labels" => { "dev.dozzle.name" => "service" },
      "healthcheck" => { "test" => ["CMD", "curl", "--fail", "http://127.0.0.1:8080/health"] },
      "security_opt" => ["no-new-privileges:true"],
      "restart" => "unless-stopped",
      "logging" => logging,
      "volumes" => []
    }
  end
  configarr = {
    "image" => "example.invalid/configarr:1.0@sha256:#{'b' * 64}",
    "cpuset" => "${PLATFORM_CONTAINER_CPUSET:?}",
    "cpus" => 0.5,
    "profiles" => ["jobs"],
    "security_opt" => ["no-new-privileges:true"],
    "logging" => logging,
    "volumes" => []
  }
  compose = {
    "services" => {
      "radarr" => daemon.call(1.0),
      "sonarr" => daemon.call(1.0),
      "prowlarr" => daemon.call(0.5),
      "bazarr" => daemon.call(1.0),
      "configarr" => configarr
    }
  }
  service_root = File.join(root, "services", "arr")
  FileUtils.mkdir_p(service_root)
  File.write(File.join(service_root, "compose.yml"), YAML.dump(compose))
  mutate_manifest(root) { |document| service(document, "arr")["status"] = "implemented" }
  compose
end

expect_failure(failures, "acquisition job missing jobs profile",
               "arr/configarr: one-shot acquisition service must use only the jobs profile",
               detected_by: %i[policy]) do |root|
  compose = promote_arr_with_compose.call(root)
  compose.dig("services", "configarr").delete("profiles")
  File.write(File.join(root, "services", "arr", "compose.yml"), YAML.dump(compose))
end

expect_failure(failures, "acquisition job publishes a port",
               "arr/configarr: one-shot acquisition service must not publish ports",
               detected_by: %i[policy]) do |root|
  compose = promote_arr_with_compose.call(root)
  compose.dig("services", "configarr")["ports"] = ["9999:9999"]
  File.write(File.join(root, "services", "arr", "compose.yml"), YAML.dump(compose))
end

expect_failure(failures, "acquisition daemon claims restart exemption",
               "arr/radarr: long-running services must restart unless-stopped",
               detected_by: %i[policy]) do |root|
  compose = promote_arr_with_compose.call(root)
  compose.dig("services", "radarr").delete("restart")
  File.write(File.join(root, "services", "arr", "compose.yml"), YAML.dump(compose))
end

expect_failure(failures, "acquisition daemon claims healthcheck exemption",
               "arr/radarr: long-running services must define a health check",
               detected_by: %i[policy]) do |root|
  compose = promote_arr_with_compose.call(root)
  compose.dig("services", "radarr").delete("healthcheck")
  File.write(File.join(root, "services", "arr", "compose.yml"), YAML.dump(compose))
end

expect_failure(failures, "acquisition daemon keeps a probe that cannot fail",
               "arr/radarr: health check must reach the service -- an HTTP or TCP endpoint, " \
               "a readiness client, or the image's own health command -- not merely " \
               "observe that a process exists",
               detected_by: %i[policy]) do |root|
  compose = promote_arr_with_compose.call(root)
  compose.dig("services", "radarr")["healthcheck"] = { "test" => ["CMD-SHELL", "kill -0 1"] }
  File.write(File.join(root, "services", "arr", "compose.yml"), YAML.dump(compose))
end

expect_failure(failures, "acquisition daemon claims privilege-escalation exemption",
               "arr/radarr: must refuse privilege escalation with security_opt " \
               "no-new-privileges:true",
               detected_by: %i[policy]) do |root|
  compose = promote_arr_with_compose.call(root)
  compose.dig("services", "radarr").delete("security_opt")
  File.write(File.join(root, "services", "arr", "compose.yml"), YAML.dump(compose))
end

expect_failure(failures, "acquisition job claims privilege-escalation exemption",
               "arr/configarr: must refuse privilege escalation with security_opt " \
               "no-new-privileges:true",
               detected_by: %i[policy]) do |root|
  compose = promote_arr_with_compose.call(root)
  compose.dig("services", "configarr").delete("security_opt")
  File.write(File.join(root, "services", "arr", "compose.yml"), YAML.dump(compose))
end

expect_failure(failures, "acquisition daemon disarms no-new-privileges",
               "arr/radarr: must refuse privilege escalation with security_opt " \
               "no-new-privileges:true",
               detected_by: %i[policy]) do |root|
  compose = promote_arr_with_compose.call(root)
  compose.dig("services", "radarr")["security_opt"] = ["no-new-privileges:false"]
  File.write(File.join(root, "services", "arr", "compose.yml"), YAML.dump(compose))
end

expect_failure(failures, "acquisition daemon claims Dozzle exemption",
               "arr/radarr: long-running services must declare a Dozzle event identity",
               detected_by: %i[policy]) do |root|
  compose = promote_arr_with_compose.call(root)
  compose.dig("services", "radarr", "labels").delete("dev.dozzle.name")
  File.write(File.join(root, "services", "arr", "compose.yml"), YAML.dump(compose))
end

# Manifest and catalog contract must agree on status; demotion is the direction
# left to exercise.
expect_acquisition_failure.call(
  "implemented acquisition project demoted in the manifest",
  "seerr must be implemented in the service manifest"
) do |root|
  mutate_manifest(root) { |document| service(document, "seerr")["status"] = "planned" }
end

# The strict-CLI check: the foundation test takes no arguments (#639).
stdout, stderr, status = capture3_without_git_routing(
  RbConfig.ruby, "tests/media_acquisition_foundation_test.rb", "--project", "arr",
  chdir: ROOT
)
failures << "foundation strict CLI: an argument unexpectedly passed" if status.success?
failures << "foundation strict CLI: missing usage diagnostic" unless
  (stdout + stderr).include?(
    "usage: ruby tests/media_acquisition_foundation_test.rb (this program takes no arguments)"
  )

%w[policy_test.rb policy_vault_test.rb].each do |caller|
  expect_failure(failures, "#{caller} substitutes the manifest status mapping",
                 "service statuses must have exactly the rostered service names",
                 detected_by: %i[policy vault]) do |root|
    path = File.join(root, "tests", caller)
    source = File.read(path)
    expected = "pinned_service_expectations(ROOT, service_statuses)"
    raise "status-aware caller source is absent" unless source.include?(expected)

    File.write(path, source.sub(expected, "pinned_service_expectations(ROOT, {})"))
  end
end

expect_failure(failures, "malformed YAML", "service manifest is malformed",
               detected_by: %i[policy vault]) do |root|
  File.write(File.join(root, "services", "manifest.yml"), "services: [unterminated")
end

output, succeeded = run_policy(["tests/policy_test.rb"]) do |root|
  File.open(File.join(root, "services", "manifest.yml"), "a") do |file|
    file.write("---\nservices: []\n")
  end
end
failures << "multiple manifest documents: policy_test.rb unexpectedly passed" if succeeded
unless output.include?("service manifest must contain exactly one YAML document")
  failures << "multiple manifest documents: policy_test.rb missing strict document-count diagnostic"
end
failures << "multiple manifest documents: policy_test.rb emitted a Ruby stack trace" if
  output.match?(/\.rb:\d+:in [`']/)

expect_failure(failures, "missing platform hierarchy",
               "inventory/local.yml must expose nas_hosts as a child of platform_hosts",
               detected_by: %i[policy]) do |root|
  mutate_yaml_file(root, "inventory/local.yml") { |inventory| inventory.delete("platform_hosts") }
end

expect_failure(failures, "wrong platform child",
               "inventory/local.yml must expose nas_hosts as a child of platform_hosts",
               detected_by: %i[policy]) do |root|
  mutate_yaml_file(root, "inventory/local.yml") do |inventory|
    inventory.fetch("platform_hosts").fetch("children")["wrong_hosts"] =
      inventory.fetch("platform_hosts").fetch("children").delete("nas_hosts")
  end
end

expect_failure(failures, "missing Mac inventory", "inventory/mac.yml is missing",
               detected_by: %i[policy]) do |root|
  FileUtils.rm(File.join(root, "inventory", "mac.yml"))
end

# #388. A bare lookup falls back to the inventory hostname, not an empty value.
expect_failure(failures, "unguarded remote transport address",
               "inventory/remote.yml must define ansible_host and fail on an " \
               "unset environment value with undef()",
               detected_by: %i[policy]) do |root|
  mutate_yaml_file(root, "inventory/remote.yml") do |inventory|
    inventory.dig("platform_hosts", "children", "nas_hosts", "hosts", "nas")["ansible_host"] =
      "{{ lookup('env', 'PLATFORM_NAS_ADDRESS') }}"
  end
end

expect_failure(failures, "dropped remote transport account",
               "inventory/remote.yml must define ansible_user and fail on an " \
               "unset environment value with undef()",
               detected_by: %i[policy]) do |root|
  mutate_yaml_file(root, "inventory/remote.yml") do |inventory|
    inventory.dig("platform_hosts", "children", "nas_hosts", "hosts", "nas").delete("ansible_user")
  end
end

# #410. The local-connection branch, planted in both inventories so a roster that
# stopped visiting mac.yml is caught too.
guarded_coordinate = lambda do |variable, hint|
  "{{ lookup('env', '#{variable}') | default(undef(hint='#{variable} is unset: #{hint}'), true) }}"
end

expect_failure(failures, "transport address on the local inventory",
               "inventory/local.yml uses a local connection and must not declare ansible_host",
               detected_by: %i[policy]) do |root|
  mutate_yaml_file(root, "inventory/local.yml") do |inventory|
    inventory.dig("platform_hosts", "children", "nas_hosts", "hosts", "nas")["ansible_host"] =
      guarded_coordinate.call("PLATFORM_NAS_ADDRESS", "export the address this run reaches the NAS at")
  end
end

expect_failure(failures, "transport account on the Mac inventory",
               "inventory/mac.yml uses a local connection and must not declare ansible_user",
               detected_by: %i[policy]) do |root|
  mutate_yaml_file(root, "inventory/mac.yml") do |inventory|
    inventory.dig("platform_hosts", "children", "mac_hosts", "hosts", "mac")["ansible_user"] =
      guarded_coordinate.call("PLATFORM_NAS_USER", "export the account this run logs into the NAS as")
  end
end

# The three shapes an undef() can take while pointing at the wrong variable.
expect_failure(failures, "remote transport address hinting the wrong variable",
               "inventory/remote.yml ansible_host must read PLATFORM_NAS_ADDRESS and name " \
               "that same variable in its undef() hint",
               detected_by: %i[policy]) do |root|
  mutate_yaml_file(root, "inventory/remote.yml") do |inventory|
    inventory.dig("platform_hosts", "children", "nas_hosts", "hosts", "nas")["ansible_host"] =
      "{{ lookup('env', 'PLATFORM_NAS_ADDRESS') | " \
      "default(undef(hint='PLATFORM_NAS_USER is unset: export the account this run logs into the NAS as'), true) }}"
  end
end

expect_failure(failures, "remote transport account reading the wrong variable",
               "inventory/remote.yml ansible_user must read PLATFORM_NAS_USER and name " \
               "that same variable in its undef() hint",
               detected_by: %i[policy]) do |root|
  mutate_yaml_file(root, "inventory/remote.yml") do |inventory|
    inventory.dig("platform_hosts", "children", "nas_hosts", "hosts", "nas")["ansible_user"] =
      guarded_coordinate.call("PLATFORM_NAS_ADDRESS", "export the address this run reaches the NAS at")
  end
end

expect_failure(failures, "remote transport address refusing without a hint",
               "inventory/remote.yml ansible_host must read PLATFORM_NAS_ADDRESS and name " \
               "that same variable in its undef() hint",
               detected_by: %i[policy]) do |root|
  mutate_yaml_file(root, "inventory/remote.yml") do |inventory|
    inventory.dig("platform_hosts", "children", "nas_hosts", "hosts", "nas")["ansible_host"] =
      "{{ lookup('env', 'PLATFORM_NAS_ADDRESS') | default(undef(), true) }}"
  end
end

expect_failure(failures, "machine fact leaked into shared vars",
               "machine facts must not be all-group variables",
               detected_by: %i[platform]) do |root|
  mutate_yaml_file(root, "inventory/group_vars/all/main.yml") do |vars|
    vars["nas_docker_root"] = "/leaked"
  end
end

expect_failure(failures, "raw Mac storage root",
               "Mac nas_docker_root must canonicalize PLATFORM_DOCKER_ROOT before export",
               detected_by: %i[platform]) do |root|
  mutate_yaml_file(root, "inventory/group_vars/mac_hosts/main.yml") do |vars|
    vars["nas_docker_root"] = "{{ lookup('env', 'PLATFORM_DOCKER_ROOT') }}"
  end
end

expect_failure(failures, "missing filter registration",
               "Mac path canonicalization must use the configured physical-path filter",
               detected_by: %i[policy]) do |root|
  path = File.join(root, "ansible.cfg")
  File.write(path, File.read(path).sub(/^filter_plugins\s*=.*\n/, ""))
end

expect_failure(failures, "restored default inventory",
               "ansible.cfg must name no default inventory, so a forgotten -i " \
               "cannot silently target a host",
               detected_by: %i[ci]) do |root|
  mutate_text(root, "ansible.cfg", /^\[defaults\]\n/,
              "[defaults]\ninventory = inventory/remote.yml\n")
end

# Keys outside any section also break the two scripts that boot Ansible.
expect_failure(failures, "unreadable ansible.cfg section",
               "ansible.cfg must carry a [defaults] section for its keys to be read",
               detected_by: %i[ci deployment integration]) do |root|
  mutate_text(root, "ansible.cfg", /^\[defaults\]\n/, "")
end

expect_failure(failures, "untracked ANSIBLE_HOME",
               "gitignore must exclude the local ANSIBLE_HOME that " \
               "ansible-galaxy fills in the repository root",
               detected_by: %i[ci]) do |root|
  mutate_text(root, ".gitignore", /^\.ansible\/\n/, "")
end

# The historical defect (#641): a literal ignore lets a renamed plaintext output
# be committed.
expect_failure(failures, "literal ignore for the generator's plaintext output",
               "a literal line covers only the one name the generator writes today",
               detected_by: %i[vault]) do |root|
  mutate_text(root, ".gitignore", /^\*-plain\.yml\n/,
              "inventory/group_vars/all/vault-plain.yml\n")
end

expect_failure(failures, "nonfunctional physical-path filter",
               "Mac physical-path filter must reject ambiguous or relative paths",
               detected_by: %i[policy]) do |root|
  path = File.join(root, "filter_plugins", "platform_paths.py")
  source = File.read(path).sub("return os.path.realpath(value)",
                               "return value  # os.path.realpath(value)")
  File.write(path, source)
end

expect_failure(failures, "leading double separator accepted",
               "Mac physical-path filter must reject ambiguous or relative paths",
               detected_by: %i[policy]) do |root|
  path = File.join(root, "filter_plugins", "platform_paths.py")
  source = File.read(path).sub(" or value.startswith(os.sep * 2)", "")
  File.write(path, source)
end

expect_failure(failures, "missing Mac path fixture wiring",
               "integration must prove canonical Mac paths pass target validation",
               detected_by: %i[integration]) do |root|
  mutate_text(root, "tests/integration_controller.sh",
              /^.*mac_inventory_path_test\.yml.*\n/, "", occurrences: 2)
  mutate_text(root, "tests/integration_controller.sh",
              /^.*MAC_PATH_(?:CANONICAL|LEXICAL_REFUSED).*\n/, "", occurrences: 2)
end

expect_failure(failures, "missing host capability", "must define platform_beszel_agent_available",
               detected_by: %i[platform]) do |root|
  mutate_yaml_file(root, "inventory/group_vars/mac_hosts/main.yml") do |vars|
    vars.delete("platform_beszel_agent_available")
  end
end

expect_failure(failures, "wrong capability type",
               "platform_render_device_available must be boolean",
               detected_by: %i[platform]) do |root|
  mutate_yaml_file(root, "inventory/group_vars/mac_hosts/main.yml") do |vars|
    vars["platform_render_device_available"] = "false"
  end
end

expect_failure(failures, "invalid production platform kind", "platform_kind must be mac",
               detected_by: %i[platform]) do |root|
  mutate_yaml_file(root, "inventory/group_vars/mac_hosts/main.yml") do |vars|
    vars["platform_kind"] = "integration"
  end
end

expect_failure(failures, "removed NAS mount guard",
               "preflight must check mounts by command exit status, including in check mode",
               detected_by: %i[platform]) do |root|
  mutate_yaml_file(root, "roles/preflight/tasks/main.yml") do |tasks|
    tasks.find { |task| task["name"] == "Require the NAS volumes to be mounted" }.delete("when")
  end
end

# Role and playbook halves of #530's scanner. The planted value is TWO characters:
# single quotes are load-bearing, a Ruby "\n" would make both rows vacuous.
expect_failure(failures, "a whitespace escape inside a role's Jinja expression",
               "contains a whitespace backslash escape, which Ansible will not process",
               detected_by: %i[policy]) do |root|
  mutate_yaml_file(root, "roles/host_prep/tasks/main.yml") do |tasks|
    tasks.first["name"] = '{{ "Create service state\ndirectories" }}'
  end
end

expect_failure(failures, "a whitespace escape inside a root playbook's Jinja expression",
               "contains a whitespace backslash escape, which Ansible will not process",
               detected_by: %i[policy]) do |root|
  mutate_yaml_file(root, "site.yml") do |plays|
    plays.first["name"] = '{{ "Converge\tthe platform" }}'
  end
end

expect_failure(failures, "weakened GPU device proof",
               "GPU availability must require declared capability and an existing character device",
               detected_by: %i[platform]) do |root|
  mutate_yaml_file(root, "roles/preflight/tasks/gpu.yml") do |tasks|
    task = tasks.find { |entry| entry["name"] == "Record whether hardware acceleration is available" }
    task.fetch("ansible.builtin.set_fact")["preflight_gpu_available"] =
      "{{ platform_render_device_available and preflight_render_device.stat.exists }}"
  end
end

expect_failure(failures, "weakened platform kind choices",
               "deployment bundle platform_kind must allow only nas or mac",
               detected_by: %i[deployment]) do |root|
  mutate_yaml_file(root, "roles/deployment_bundle/meta/argument_specs.yml") do |spec|
    spec.dig("argument_specs", "main", "options", "platform_kind").delete("choices")
  end
end

expect_failure(failures, "test mode defaults enabled",
               "deployment bundle test mode must be an explicit false boolean option",
               detected_by: %i[deployment]) do |root|
  mutate_yaml_file(root, "roles/deployment_bundle/meta/argument_specs.yml") do |spec|
    spec.dig("argument_specs", "main", "options", "deployment_bundle_test_mode")["default"] = true
  end
end

expect_failure(failures, "weakened dirty bypass guard",
               "dirty controller bypass must require explicit integration Compose test mode",
               detected_by: %i[deployment]) do |root|
  mutate_yaml_file(root, "roles/deployment_bundle/tasks/controller.yml") do |tasks|
    task = tasks.find { |entry| entry["name"] == "Restrict dirty controller bypass to integration" }
    task.fetch("ansible.builtin.assert")["that"] = [
      "not deployment_bundle_allow_dirty_controller or platform_compose_kind == 'integration'"
    ]
  end
end

expect_failure(failures, "weakened Compose override guard",
               "Compose override selection must require explicit test mode",
               detected_by: %i[deployment]) do |root|
  mutate_yaml_file(root, "roles/deployment_bundle/tasks/controller.yml") do |tasks|
    task = tasks.find do |entry|
      entry["name"] == "Restrict Compose override selection to explicit test mode"
    end
    task.fetch("ansible.builtin.assert")["that"] = ["platform_kind in ['nas', 'mac']"]
  end
end

expect_failure(failures, "missing Beszel Compose interface",
               "beszel argument specs must require platform_compose_kind",
               detected_by: %i[policy]) do |root|
  mutate_yaml_file(root, "roles/beszel/meta/argument_specs.yml") do |spec|
    spec.dig("argument_specs", "main", "options").delete("platform_compose_kind")
  end
end

expect_failure(failures, "missing Beszel render interface",
               "Beszel argument specs must require platform_render_device_path",
               detected_by: %i[policy]) do |root|
  mutate_yaml_file(root, "roles/beszel/meta/argument_specs.yml") do |spec|
    spec.dig("argument_specs", "main", "options").delete("platform_render_device_path")
  end
end


expect_failure(failures, "missing Beszel Compose interface",
               "beszel argument specs must require platform_compose_kind",
               detected_by: %i[policy]) do |root|
  mutate_yaml_file(root, "roles/beszel/meta/argument_specs.yml") do |spec|
    spec.dig("argument_specs", "main", "options").delete("platform_compose_kind")
  end
end

expect_failure(failures, "Mac storage claims Linux ownership",
               "host preparation must restrict Linux ownership to the explicit integration capability",
               detected_by: %i[beszel]) do |root|
  mutate_yaml_file(root, "roles/host_prep/tasks/main.yml") do |tasks|
    task = tasks.find { |entry| entry["name"] == "Create service state directories" }
    task.fetch("ansible.builtin.file")["owner"] = "{{ item.owner | default(omit) }}"
  end
end

expect_failure(failures, "preservation-only storage inspected after creation",
               "host preparation must validate preservation-only storage before ordinary creation",
               detected_by: %i[beszel]) do |root|
  mutate_yaml_file(root, "roles/host_prep/tasks/main.yml") do |tasks|
    inspect = tasks.delete_at(tasks.index do |task|
      task["name"] == "Inspect preservation-only service state directories"
    end)
    create_index = tasks.index { |task| task["name"] == "Create service state directories" }
    tasks.insert(create_index + 1, inspect)
  end
end

expect_failure(failures, "preservation-only storage follows symlinks",
               "host preparation must inspect preservation-only storage without following symlinks",
               detected_by: %i[beszel]) do |root|
  mutate_yaml_file(root, "roles/host_prep/tasks/main.yml") do |tasks|
    task = tasks.find do |entry|
      entry["name"] == "Inspect preservation-only service state directories"
    end
    task.fetch("ansible.builtin.stat")["follow"] = true
  end
end

expect_failure(failures, "preservation-only directory refusal removed",
               "host preparation must refuse missing, non-directory, or symlink preservation-only storage",
               detected_by: %i[beszel]) do |root|
  mutate_yaml_file(root, "roles/host_prep/tasks/main.yml") do |tasks|
    task = tasks.find do |entry|
      entry["name"] == "Require safe preservation-only service state directories"
    end
    task.fetch("ansible.builtin.assert").fetch("that").delete("not item.stat.islnk")
  end
end

expect_failure(failures, "preservation-only storage recreated",
               "ordinary storage creation must include unmarked entries and exclude preservation-only storage",
               detected_by: %i[beszel]) do |root|
  mutate_yaml_file(root, "roles/host_prep/tasks/main.yml") do |tasks|
    task = tasks.find { |entry| entry["name"] == "Create service state directories" }
    task["loop"] = "{{ nas_storage }}"
  end
end

expect_failure(failures, "unfiltered Beszel settings readback",
               "collection readback must use a URL-encoded identity filter with totals",
               detected_by: %i[beszel]) do |root|
  mutate_yaml_file(root, "roles/beszel/tasks/configure.yml") do |tasks|
    task = flatten_tasks(tasks).find do |entry|
      entry["name"] == "Refresh notification settings after reconciliation"
    end
    uri = task.fetch("ansible.builtin.uri")
    uri["url"] = uri.fetch("url").sub(" | urlencode", "")
  end
end

expect_failure(failures, "silent Beszel user creation",
               "Beszel user creation must report real and check-mode predicted changes",
               detected_by: %i[beszel]) do |root|
  mutate_yaml_file(root, "roles/beszel/tasks/application_user.yml") do |tasks|
    task = flatten_tasks(tasks).find do |entry|
      entry["name"] == "Create the application user"
    end
    task["changed_when"] = false
  end
end

expect_failure(failures, "unredacted Beszel webhook summary",
               "Beszel webhook mismatch diagnostics must never include URL bodies",
               detected_by: %i[beszel]) do |root|
  mutate_yaml_file(root, "roles/beszel/tasks/configure.yml") do |tasks|
    task = flatten_tasks(tasks).find do |entry|
      entry["name"] == "Summarize the managed relay webhook without URL bodies"
    end
    task["no_log"] = false
  end
end

expect_failure(failures, "missing Beszel system ownership guard",
               "Beszel must reject same-name systems outside the managed user relation",
               detected_by: %i[beszel]) do |root|
  path = File.join(root, "roles", "beszel", "tasks", "configure.yml")
  body = File.read(path).sub(
    "Refuse same-name systems outside the managed user relation",
    "Bypass same-name systems outside the managed user relation"
  )
  File.write(path, body)
end

# The runtime body lives in tests/contracts/beszel-runtime.rb, not the wrapper (#147).
expect_failure(failures, "unencoded Beszel contract filters",
               "Beszel contract must use complete encoded identity filters and enforce system ownership",
               detected_by: %i[beszel]) do |root|
  path = File.join(root, "tests", "contracts", "beszel-runtime.rb")
  body = File.read(path)
  raise "Beszel contract mutation subject moved" unless body.include?("URI.encode_www_form")

  File.write(path, body.gsub("URI.encode_www_form", "removed_form_encoding"))
end

{
  "duplicate top-level key" => ["\nservices: []\n", "services"],
  "duplicate service name key" => ["    name: duplicate\n", "name"],
  "duplicate service key" => ["    role: duplicate\n", "role"]
}.each do |label, (insertion, key)|
  expect_failure(failures, label, "service manifest contains duplicate mapping key #{key}",
                 detected_by: %i[policy ci deployment mac vault]) do |root|
    path = File.join(root, "services", "manifest.yml")
    body = File.read(path)
    body = case label
           when "duplicate top-level key"
             body + insertion
           when "duplicate service name key"
             body.sub(/(  - name: audiobookshelf\n)/, "\\1#{insertion}")
           else
             body.sub(/(    role: audiobookshelf\n)/, "\\1#{insertion}")
           end
    File.write(path, body)
  end
end

expect_failure(failures, "CI bypasses policy entrypoint", "CI must run tests/validate-policy.sh",
               detected_by: %i[ci]) do |root|
  path = File.join(root, ".github", "workflows", "ci.yml")
  File.write(path, File.read(path).sub("tests/validate-policy.sh", "ruby tests/policy_test.rb"))
end

# The harness runs only from ci.yml, so dropping its job is planted here.
expect_failure(failures, "CI drops the policy mutation job",
               "CI must run ruby tests/policy_manifest_test.rb",
               detected_by: %i[ci]) do |root|
  path = File.join(root, ".github", "workflows", "ci.yml")
  File.write(path, File.read(path).sub("ruby tests/policy_manifest_test.rb", "true"))
end

# The nightly narrowed back re-derives nothing (#727).
expect_failure(failures, "CI drops the nightly mutation audit",
               "CI must run ruby tests/policy_manifest_test.rb --audit on the nightly",
               detected_by: %i[ci]) do |root|
  path = File.join(root, ".github", "workflows", "ci.yml")
  File.write(path, File.read(path).sub("ruby tests/policy_manifest_test.rb --audit",
                                       "ruby tests/policy_manifest_test.rb"))
end

expect_failure(failures, "integration omits contract execution", "integration must execute registered contracts",
               detected_by: %i[integration]) do |root|
  path = File.join(root, "tests", "integration_controller.sh")
  File.write(path, File.read(path).sub(/^\s*ruby \/repo\/tests\/run_contracts\.rb --execute\n/, ""))
end

expect_failure(failures, "controller pasted back into an argument",
               "must not paste the controller back into an sh -c argument",
               detected_by: %i[policy integration]) do |root|
  # Plant the escaped-argument shape; the quoting bug it caused has nowhere to live now.
  path = File.join(root, "tests", "integration.sh")
  body = File.read(path)
  broken = body.sub(
    %(  sh /repo/tests/integration_controller.sh "$playbook" "$@"),
    %(  sh -eu -c "\n    exec /repo/tests/integration_controller.sh\n  " ) +
    %(integration-run "$playbook" "$@")
  )
  raise "controller argument mutation did not apply" if broken == body

  File.write(path, broken)
end

expect_failure(failures, "integration omits contract ABI", "integration must set the contract environment ABI",
               detected_by: %i[integration]) do |root|
  path = File.join(root, "tests", "integration_controller.sh")
  body = File.read(path)
  source = body.scan(/^\s*PLATFORM_REPORT_ROOT=.*\n/).last
  File.write(path, replace_last(body, source, ""))
end

provisioning_task = <<~YAML
  ---
  - name: Provision an endpoint
    ansible.builtin.uri:
      url: http://127.0.0.1/
YAML

expect_failure(failures, "arbitrary provisioning uri", "vaultwarden: implemented service has no automated verification",
               detected_by: %i[policy]) do |root|
  File.write(File.join(root, "roles", "vaultwarden", "tasks", "main.yml"), provisioning_task)
end

{
  "tagged unrelated uri" => <<~YAML,
    ---
    - name: Verify an unrelated endpoint
      tags: [platform_verify_vaultwarden]
      ansible.builtin.uri:
        url: http://127.0.0.1/unrelated/
  YAML
  "tagged uri body mention" => <<~YAML,
    ---
    - name: Verify an unrelated endpoint with service text
      tags: [platform_verify_vaultwarden]
      ansible.builtin.uri:
        url: http://127.0.0.1/unrelated/
        body: vaultwarden
        status_code: [200]
  YAML
  "tagged literal assertion" => <<~YAML,
    ---
    - name: Verify a literal
      tags: [platform_verify_vaultwarden]
      ansible.builtin.assert:
        that: [true]
  YAML
  "tagged constant service assertion" => <<~YAML,
    ---
    - name: Verify a constant expression
      tags: [platform_verify_vaultwarden]
      ansible.builtin.assert:
        that: ["'vaultwarden' == 'vaultwarden'"]
  YAML
  "tagged undefined service assertion" => <<~YAML,
    ---
    - name: Verify an undefined result
      tags: [platform_verify_vaultwarden]
      ansible.builtin.assert:
        that: ["vaultwarden_missing_result.status == 200"]
  YAML
  "tagged true command" => <<~YAML,
    ---
    - name: Verify a no-op command
      tags: [platform_verify_vaultwarden]
      ansible.builtin.command: /bin/true
  YAML
  "tagged service command" => <<~YAML,
    ---
    - name: Verify command output
      tags: [platform_verify_vaultwarden]
      ansible.builtin.command: echo vaultwarden
  YAML
  "assert from command register" => <<~YAML,
    ---
    - name: Produce a fake result
      ansible.builtin.command: echo vaultwarden
      register: vaultwarden_result
    - name: Verify fake result
      tags: [platform_verify_vaultwarden]
      ansible.builtin.assert:
        that: ["vaultwarden_result.stdout == 'vaultwarden'"]
  YAML
  "assert self comparison" => <<~YAML
    ---
    - name: Probe vaultwarden
      ansible.builtin.uri:
        url: http://127.0.0.1/{{ vaultwarden_port }}/health
        status_code: [200]
      register: vaultwarden_result
    - name: Verify a tautology
      tags: [platform_verify_vaultwarden]
      ansible.builtin.assert:
        that: ["vaultwarden_result.status == vaultwarden_result.status"]
  YAML
}.each do |label, tasks|
  expect_failure(failures, label, "vaultwarden: implemented service has no automated verification",
                 detected_by: %i[policy]) do |root|
    File.write(File.join(root, "roles", "vaultwarden", "tasks", "main.yml"), tasks)
  end
end

expect_success(failures, "assert from registered URI result") do |root|
  File.write(File.join(root, "roles", "vaultwarden", "tasks", "main.yml"), <<~YAML)
    ---
    - name: Probe vaultwarden
      ansible.builtin.uri:
        url: http://127.0.0.1/{{ vaultwarden_port }}/health
        status_code: [200]
      register: vaultwarden_result
    - name: Verify the observed status
      tags: [platform_verify_vaultwarden]
      ansible.builtin.assert:
        that: ["vaultwarden_result.status == 200"]
  YAML
end

expect_failure(failures, "wrong contract path", "vaultwarden: implemented service has no automated verification",
               detected_by: %i[policy]) do |root|
  File.write(File.join(root, "roles", "vaultwarden", "tasks", "main.yml"), provisioning_task)
  contract = File.join(root, "services", "vaultwarden", "contract.yml")
  File.write(contract, "#!/bin/sh\nexit 1\n")
  File.chmod(0o755, contract)
end

expect_failure(failures, "empty contract", "vaultwarden: implemented service has no automated verification",
               detected_by: %i[policy]) do |root|
  File.write(File.join(root, "roles", "vaultwarden", "tasks", "main.yml"), provisioning_task)
  contract = File.join(root, "tests", "contracts", "vaultwarden.sh")
  FileUtils.mkdir_p(File.dirname(contract))
  File.write(contract, "")
  File.chmod(0o755, contract)
end

{
  "echo test" => "#!/bin/sh\necho test\n",
  "exit one" => "#!/bin/sh\nexit 1\n",
  "standalone false" => "#!/bin/sh\nfalse\n"
}.each do |label, body|
  expect_failure(failures, label, "vaultwarden: implemented service has no automated verification",
                 detected_by: %i[policy]) do |root|
    File.write(File.join(root, "roles", "vaultwarden", "tasks", "main.yml"), provisioning_task)
    write_contract(root, "vaultwarden", body)
  end
end

expect_success(failures, "nested verification task") do |root|
  File.write(File.join(root, "roles", "vaultwarden", "tasks", "main.yml"), <<~YAML)
    ---
    - name: Group verification tasks
      block:
        - name: Verify the application endpoint
          tags: [platform_verify_vaultwarden]
          ansible.builtin.uri:
            url: http://127.0.0.1/{{ vaultwarden_port }}/v1/health
            status_code: [200]
  YAML
end

expect_success(failures, "registered variable contract") do |root|
  File.write(File.join(root, "roles", "vaultwarden", "tasks", "main.yml"), provisioning_task)
  write_contract(root, "vaultwarden", <<~'SH')
    #!/bin/sh
    endpoint=http://127.0.0.1/vaultwarden/health
    probe() {
      curl --fail "$endpoint"
    }
    probe
  SH
  register_contract(root, "vaultwarden")
  # A registered contract owes tests/mac/run-contract.sh an arm, so plant it beside
  # the registration rather than exempting it.
  mutate_text(root, "tests/mac/run-contract.sh", "case $mac_service in\n",
              "case $mac_service in\n  vaultwarden)\n    ;;\n")
end

expect_failure(failures, "unregistered contract", "vaultwarden: implemented service has no automated verification",
               detected_by: %i[policy]) do |root|
  File.write(File.join(root, "roles", "vaultwarden", "tasks", "main.yml"), provisioning_task)
  write_contract(root, "vaultwarden", "#!/bin/sh\nendpoint=/vaultwarden/health\ncurl --fail \"$endpoint\"\n")
end

# Registration is a registry entry: a mention of the contract path anywhere the
# harness reads (shell, echo, YAML, the controller) must not count (#314).
{
  "assignment registration spoof" => ["tests/integration.sh", "contract=tests/contracts/vaultwarden.sh\n"],
  "echo registration spoof" => ["tests/integration.sh", "echo tests/contracts/vaultwarden.sh\n"],
  "controller registration spoof" => ["tests/integration_controller.sh",
                                      "contract=tests/contracts/vaultwarden.sh\n"],
  "YAML name registration spoof" => [".github/workflows/ci.yml", "\nname: tests/contracts/vaultwarden.sh\n"]
}.each do |label, (relative_harness, registration)|
  expect_failure(failures, label, "vaultwarden: implemented service has no automated verification",
                 detected_by: %i[policy]) do |root|
    File.write(File.join(root, "roles", "vaultwarden", "tasks", "main.yml"), provisioning_task)
    write_contract(root, "vaultwarden", "#!/bin/sh\ntrue\n")
    harness = File.join(root, relative_harness)
    # Appending to a moved path would create it silently; require it to exist.
    raise "#{label}: #{relative_harness} is not a file to append to" unless File.file?(harness)

    File.open(harness, "a") { |file| file.write(registration) }
  end
end

expect_failure(failures, "contract syntax error", "vaultwarden: implemented service has no automated verification",
               detected_by: %i[policy mac]) do |root|
  File.write(File.join(root, "roles", "vaultwarden", "tasks", "main.yml"), provisioning_task)
  write_contract(root, "vaultwarden", "#!/bin/sh\nif then\ncurl --fail http://127.0.0.1/vaultwarden\n")
  register_contract(root, "vaultwarden")
end

expect_failure(failures, "symlink contract", "vaultwarden: implemented service has no automated verification",
               detected_by: %i[policy mac]) do |root|
  File.write(File.join(root, "roles", "vaultwarden", "tasks", "main.yml"), provisioning_task)
  contracts = File.join(root, "tests", "contracts")
  FileUtils.mkdir_p(contracts)
  target = File.join(contracts, "shared.sh")
  File.write(target, "#!/bin/sh\ntrue\n")
  File.chmod(0o755, target)
  File.symlink("shared.sh", File.join(contracts, "vaultwarden.sh"))
  register_contract(root, "vaultwarden")
end

expect_success(failures, "paperless contract alias") do |root|
  implement_paperless(root)
  mutate_yaml_file(root, "services/paperless-ngx/compose.yml") do |compose|
    compose.fetch("services").each do |container, spec|
      spec["healthcheck"] = { "test" => ["CMD", "curl", "--fail", "http://127.0.0.1:8080/health"] }
      spec["labels"] = { "dev.dozzle.name" => container }
    end
  end
  register_contract(root, "paperless")
end

# integration detects this too: registering paperless-ngx.sh displaces paperless
# from the registry, breaking the static-half partition (#667).
expect_failure(failures, "paperless service-name contract", "paperless-ngx: implemented service has no automated verification",
               detected_by: %i[policy integration]) do |root|
  implement_paperless(root)
  write_contract(root, "paperless-ngx", <<~'SH')
    #!/bin/sh
    response=$(curl --silent http://127.0.0.1/paperless/api/)
    test -n "$response"
  SH
  register_contract(root, "paperless-ngx")
end

expect_failure(failures, "symlink compose", "trailarr: compose.yml must be a regular file within its service root",
               detected_by: %i[policy integration]) do |root|
  path = File.join(root, "services", "trailarr", "compose.yml")
  File.unlink(path)
  File.symlink("../beszel/compose.yml", path)
end

# vault detects this too: the symlink keeps the env.j2 glob count while trailarr
# drops out of the Compose-escaping sweep.
expect_failure(failures, "symlink role directory", "trailarr: role must be a real directory within roles",
               detected_by: %i[policy deployment vault]) do |root|
  path = File.join(root, "roles", "trailarr")
  FileUtils.rm_r(path)
  File.symlink("beszel", path)
end

expect_failure(failures, "symlink role meta", "trailarr: argument_specs.yml must be a regular file within its role root",
               detected_by: %i[policy]) do |root|
  path = File.join(root, "roles", "trailarr", "meta", "argument_specs.yml")
  File.unlink(path)
  File.symlink("../../beszel/meta/argument_specs.yml", path)
end

expect_failure(failures, "symlink role tasks", "trailarr: tasks/main.yml must be a regular file within its role root",
               detected_by: %i[policy]) do |root|
  path = File.join(root, "roles", "trailarr", "tasks", "main.yml")
  File.unlink(path)
  File.symlink("../../beszel/tasks/main.yml", path)
end

# Per-role properties over the roles/* globs (#556): a loop over nothing passes,
# so each property is planted directly. kapowarr hosts all six rows because every
# sandbox carries it complete and no other row mutates it.

expect_failure(failures, "role interface absent", "role kapowarr: missing meta/argument_specs.yml",
               detected_by: %i[policy]) do |root|
  File.delete(File.join(root, "roles", "kapowarr", "meta", "argument_specs.yml"))
end

# Two rows: a removed options key and an empty `{}` map, which passed until the
# non-empty term landed.
expect_failure(failures, "role interface options key removed",
               "role kapowarr: argument_specs declares no options",
               detected_by: %i[policy]) do |root|
  mutate_yaml_file(root, "roles/kapowarr/meta/argument_specs.yml") do |spec|
    spec.fetch("argument_specs").fetch("main").delete("options")
  end
end

expect_failure(failures, "role interface options emptied",
               "role kapowarr: argument_specs declares no options",
               detected_by: %i[policy]) do |root|
  mutate_yaml_file(root, "roles/kapowarr/meta/argument_specs.yml") do |spec|
    spec.fetch("argument_specs").fetch("main")["options"] = {}
  end
end

# Appended, not rewritten from a deployment, so only one defect is planted.
expect_failure(failures, "role shells out to Compose",
               "roles/kapowarr/tasks/main.yml: shells out to Compose; " \
               "use community.docker.docker_compose_v2",
               detected_by: %i[policy]) do |root|
  path = File.join(root, "roles", "kapowarr", "tasks", "main.yml")
  File.write(path, "#{File.read(path)}\n- name: Restart the stack the quick way\n" \
                   "  ansible.builtin.command: docker compose restart\n" \
                   "  changed_when: false\n")
end

# No sandbox holds a phase-gated file (all are include_tasks), so this row writes
# one. Omitting the assert yields two diagnostics; the row asserts the first.
expect_failure(failures, "role phase gate opens without an assert",
               "roles/kapowarr/tasks/reconcile_stage.yml: gates tasks on " \
               "kapowarr_reconcile_phase but does not open with an unconditional assert",
               detected_by: %i[policy]) do |root|
  File.write(File.join(root, "roles", "kapowarr", "tasks", "reconcile_stage.yml"),
             "---\n- name: Reconcile one stage\n  ansible.builtin.debug:\n" \
             "    msg: reconciling\n  when: kapowarr_reconcile_phase == 'provision'\n")
end

# The caller half of the gate (#647): a file reached by neither include_role nor
# include_tasks.
expect_failure(failures, "role phase gate has no caller",
               "roles/kapowarr/tasks/reconcile_stage.yml: declares kapowarr_reconcile_phase " \
               "phases provision but its callers pass none",
               detected_by: %i[policy]) do |root|
  File.write(File.join(root, "roles", "kapowarr", "tasks", "reconcile_stage.yml"),
             "---\n- name: Validate the stage phase\n  ansible.builtin.assert:\n" \
             "    that:\n      - kapowarr_reconcile_phase in ['provision']\n" \
             "    fail_msg: An unrecognised phase would skip this file silently.\n\n" \
             "- name: Reconcile one stage\n  ansible.builtin.debug:\n" \
             "    msg: reconciling\n  when: kapowarr_reconcile_phase == 'provision'\n")
end

expect_failure(failures, "role deploys without reporting it",
               "role kapowarr: deploys Compose services but declares 0 deployment reports, not one",
               detected_by: %i[policy]) do |root|
  mutate_yaml_file(root, "roles/kapowarr/tasks/main.yml") do |tasks|
    tasks.reject! do |task|
      task.is_a?(Hash) &&
        task.dig("ansible.builtin.include_role", "tasks_from") == "report"
    end
  end
end

# docker_compose_v2_exec sets check_rc only when detached (#521).
expect_failure(failures, "Compose exec exit code left unchecked",
               "runs docker_compose_v2_exec without failed_when",
               detected_by: %i[policy]) do |root|
  path = File.join(root, "roles", "nextcloud", "tasks", "reconcile_admin.yml")
  tasks = YAML.safe_load_file(path)
  reset = tasks.find { |task| task["register"] == "nextcloud_admin_repair" }
  raise "the Nextcloud administrator reset is absent" unless reset
  raise "the Nextcloud administrator reset states no failed_when" unless reset.key?("failed_when")

  reset.delete("failed_when")
  File.write(path, YAML.dump(tasks))
end

# A renamed module key empties the discovered subject list; the floor catches it.
expect_failure(failures, "Compose exec subjects renamed out of the sweep",
               "docker_compose_v2_exec tasks the exit-code policy inspected",
               detected_by: %i[policy]) do |root|
  Dir[File.join(root, "roles", "*", "tasks", "**", "*.yml")].each do |path|
    body = File.read(path)
    next unless body.include?("community.docker.docker_compose_v2_exec")

    File.write(path, body.gsub("community.docker.docker_compose_v2_exec",
                               "community.docker.docker_compose_v2_renamed_exec"))
  end
end

expect_failure(failures, "dirty controller enabled by default",
               "deployment bundle must refuse dirty controller sources by default",
               detected_by: %i[deployment]) do |root|
  path = File.join(root, "roles", "deployment_bundle", "defaults", "main.yml")
  defaults = YAML.safe_load_file(path)
  defaults["deployment_bundle_allow_dirty_controller"] = true
  File.write(path, YAML.dump(defaults))
end

expect_failure(failures, "untracked controller inspection removed",
               "deployment bundle must inspect the whole tracked and untracked controller checkout",
               detected_by: %i[deployment]) do |root|
  path = File.join(root, "roles", "deployment_bundle", "tasks", "controller.yml")
  tasks = File.read(path).sub("      - --untracked-files=all\n", "")
  File.write(path, tasks)
end

expect_failure(failures, "controller inspection narrowed by pathspec",
               "deployment bundle must inspect the whole tracked and untracked controller checkout",
               detected_by: %i[deployment]) do |root|
  path = File.join(root, "roles", "deployment_bundle", "tasks", "controller.yml")
  tasks = File.read(path).sub(
    "      - --untracked-files=all\n",
    "      - --untracked-files=all\n      - --\n      - services\n"
  )
  File.write(path, tasks)
end

expect_failure(failures, "dirty refusal made run once",
               "dirty controller refusal must be evaluated independently for every target host",
               detected_by: %i[deployment]) do |root|
  path = File.join(root, "roles", "deployment_bundle", "tasks", "controller.yml")
  tasks = File.read(path).sub(
    "- name: Require committed controller bundle sources\n",
    "- name: Require committed controller bundle sources\n  run_once: true\n"
  )
  File.write(path, tasks)
end

# Poller sweep subject going quiet (#596). The failure MESSAGE is the binding
# assertion: this plant also breaks a neighbouring check, so exit status alone
# would pass vacuously.
expect_failure(failures, "poller role defaults emptied",
               "is missing, empty or not a mapping, so the poller paths that role installs " \
               "were derived from nothing",
               detected_by: %i[deployment]) do |root|
  File.write(File.join(root, "roles", "production_auto_deploy", "defaults", "main.yml"), "")
end

# A valid defaults file with one renamed key (#597); floors a count, so it also
# covers `--- {}`. Pinned on the prose: Hash#inspect changed in Ruby 3.4.
expect_failure(failures, "poller role defaults renamed a contributing key",
               "derived fewer than 3 distinctive path fragments from defaults that parsed",
               detected_by: %i[deployment]) do |root|
  path = File.join(root, "roles", "production_auto_deploy", "defaults", "main.yml")
  File.write(path, File.read(path).sub("production_auto_deploy_launcher_path:",
                                       "production_auto_deploy_launcher_file:"))
end

expect_failure(failures, "fresh-root probe regressed to deployment root",
               "fresh-install preflight must probe the existing validated nas_docker_root",
               detected_by: %i[platform]) do |root|
  path = File.join(root, "roles", "preflight", "tasks", "main.yml")
  tasks = File.read(path).gsub(
    "{{ nas_docker_root }}/.nas-platform-preflight-probe",
    "{{ platform_deploy_root }}/.preflight-probe"
  )
  File.write(path, tasks)
end

expect_failure(failures, "release mode comparison removed",
               "immutable release comparison must include stat.S_IMODE",
               detected_by: %i[deployment]) do |root|
  path = File.join(root, "roles", "deployment_bundle", "files", "compare_release_trees.py")
  File.write(path, File.read(path).gsub("stat.S_IMODE", "stat.filemode"))
end

expect_failure(failures, "controller input canonical containment removed",
               "controller input validator must use os.path.realpath",
               detected_by: %i[deployment]) do |root|
  path = File.join(root, "roles", "deployment_bundle", "files", "validate_controller_input.py")
  File.write(path, File.read(path).gsub("os.path.realpath", "os.path.normpath"))
end

expect_failure(failures, "controller input validator unreferenced",
               "controller input task must execute the exact extracted validator source",
               detected_by: %i[deployment]) do |root|
  path = File.join(root, "roles", "deployment_bundle", "tasks", "controller_input.yml")
  File.write(path, File.read(path).gsub("files/validate_controller_input.py",
                                        "files/validate_target.py"))
end

expect_failure(failures, "release comparison script unreferenced",
               "deployment bundle must compare releases with the tracked comparison script",
               detected_by: %i[deployment]) do |root|
  path = File.join(root, "roles", "deployment_bundle", "tasks", "main.yml")
  File.write(path, File.read(path).gsub("files/compare_release_trees.py",
                                        "files/validate_target.py"))
end

expect_failure(failures, "Immich classifier controller validation removed",
               "controller inputs must validate every tracked runtime helper",
               detected_by: %i[deployment]) do |root|
  path = File.join(root, "roles", "deployment_bundle", "tasks", "inputs.yml")
  File.write(path, File.read(path).gsub(
    "services/immich/classify_restore.py", "services/immich/missing.py"
  ))
end

expect_failure(failures, "acquisition catalog controller validation moved after parsing",
               "controller inputs must validate the required acquisition catalog before parsing inputs",
               detected_by: %i[deployment]) do |root|
  path = File.join(root, "roles", "deployment_bundle", "tasks", "inputs.yml")
  tasks = YAML.safe_load_file(path)
  # The catalog is found by the expression it hands the validator (#333).
  validation_index = tasks.index do |task|
    task["ansible.builtin.include_tasks"] == "controller_input.yml" &&
      task.dig("vars", "deployment_controller_inputs").to_s
          .include?("config/media-acquisition.yml")
  end
  validation = tasks.delete_at(validation_index)
  parse_index = tasks.index do |task|
    task["name"] == "Resolve implemented services from the validated controller manifest"
  end
  tasks.insert(parse_index + 1, validation)
  File.write(path, YAML.dump(tasks))
end

expect_failure(failures, "managed-user capability register controller validation removed",
               "controller inputs must validate the required managed-user capability register",
               detected_by: %i[deployment]) do |root|
  path = File.join(root, "roles", "deployment_bundle", "tasks", "inputs.yml")
  File.write(path, File.read(path).gsub(
    "[playbook_dir ~ '/config/managed-user-capabilities.yml', '0']", "[]"
  ))
end

expect_failure(failures, "Immich classifier release copy removed",
               "deployment bundle must package the exact Immich classifier with mode 0644",
               detected_by: %i[deployment]) do |root|
  path = File.join(root, "roles", "deployment_bundle", "tasks", "main.yml")
  tasks = YAML.safe_load_file(path)
  tasks.reject! do |task|
    task["name"] == "Copy the tracked Immich restore classifier from the controller"
  end
  File.write(path, YAML.dump(tasks))
end

expect_failure(failures, "acquisition catalog release destination changed",
               "deployment bundle must stage the exact acquisition catalog bytes with mode 0644",
               detected_by: %i[deployment]) do |root|
  path = File.join(root, "roles", "deployment_bundle", "tasks", "main.yml")
  File.write(path, File.read(path).gsub(
    "{{ deployment_bundle_staging_dir }}/config/media-acquisition.yml",
    "{{ deployment_bundle_staging_dir }}/media-acquisition.yml"
  ))
end

expect_failure(failures, "acquisition catalog release mode changed",
               "deployment bundle must stage the exact acquisition catalog bytes with mode 0644",
               detected_by: %i[deployment]) do |root|
  path = File.join(root, "roles", "deployment_bundle", "tasks", "main.yml")
  tasks = YAML.safe_load_file(path)
  copy = tasks.find do |task|
    task["name"] == "Copy the media acquisition catalog from the controller"
  end
  copy.fetch("ansible.builtin.copy")["mode"] = "0600"
  File.write(path, YAML.dump(tasks))
end

expect_failure(failures, "managed-user capability register release copy removed",
               "deployment bundle must stage the exact managed-user capability register with mode 0644",
               detected_by: %i[deployment]) do |root|
  path = File.join(root, "roles", "deployment_bundle", "tasks", "main.yml")
  tasks = YAML.safe_load_file(path)
  tasks.reject! do |task|
    task["name"] == "Copy the managed-user capability register from the controller"
  end
  File.write(path, YAML.dump(tasks))
end

expect_failure(failures, "Immich classifier manifest integrity removed",
               "deployment manifest must bind runtime helper paths, modes, and checksums",
               detected_by: %i[deployment]) do |root|
  path = File.join(root, "roles", "deployment_bundle", "templates", "manifest.yml.j2")
  File.write(path, File.read(path).gsub(
    "'immich': ['classify_restore.py']", "'immich': []"
  ))
end

expect_failure(failures, "acquisition catalog manifest checksum removed",
               "deployment manifest must bind the exact acquisition catalog path, mode, and checksum",
               detected_by: %i[deployment]) do |root|
  path = File.join(root, "roles", "deployment_bundle", "templates", "manifest.yml.j2")
  File.write(path, File.read(path).gsub(
    "lookup('file', playbook_dir ~ '/config/media-acquisition.yml', rstrip=false)",
    "'unbound-catalog'"
  ))
end

expect_failure(failures, "managed-user capability register manifest checksum removed",
               "deployment manifest must bind the exact managed-user capability register path and checksum",
               detected_by: %i[deployment]) do |root|
  path = File.join(root, "roles", "deployment_bundle", "templates", "manifest.yml.j2")
  File.write(path, File.read(path).gsub(
    "lookup('file', playbook_dir ~ '/config/managed-user-capabilities.yml', rstrip=false)",
    "'unbound-register'"
  ))
end

expect_failure(failures, "managed-user capability register manifest verifier removed",
               "deployment manifest verifier must require the exact platform input digests and " \
               "detect staged-byte mutation",
               detected_by: %i[deployment]) do |root|
  path = File.join(root, "tests", "verify_deployment_manifest.rb")
  File.write(path, File.read(path).gsub(
    '["config/managed-user-capabilities.yml", "managed-user capability register"]', "[]"
  ))
end

expect_failure(failures, "Immich classifier manifest verifier removed",
               "deployment manifest verifier must reproduce runtime helper integrity",
               detected_by: %i[deployment]) do |root|
  path = File.join(root, "tests", "verify_deployment_manifest.rb")
  File.write(path, File.read(path).gsub(
    '"immich" => ["classify_restore.py"]', '"immich" => []'
  ))
end

expect_failure(failures, "acquisition staged-byte verification removed",
               "deployment manifest verifier must require the exact platform input digests and " \
               "detect staged-byte mutation",
               detected_by: %i[deployment]) do |root|
  path = File.join(root, "tests", "verify_deployment_manifest.rb")
  File.write(path, File.read(path).gsub("File.dirname(manifest_path)", "repository_root"))
end

expect_failure(failures, "deployment sha unquoted",
               "deployment manifest must quote git_sha as a YAML string",
               detected_by: %i[deployment]) do |root|
  path = File.join(root, "roles", "deployment_bundle", "templates", "manifest.yml.j2")
  File.write(path, File.read(path).gsub("platform_release_id | to_json", "platform_release_id"))
end

expect_failure(failures, "target lstat replaced by following stat",
               "target validator must use os.lstat for symlink-safe canonical containment",
               detected_by: %i[deployment]) do |root|
  path = File.join(root, "roles", "deployment_bundle", "files", "validate_target.py")
  File.write(path, File.read(path).gsub("os.lstat", "os.stat"))
end

expect_failure(failures, "root ancestor walk removed",
               "target validator must lstat every existing ancestor from filesystem root to nas_docker_root",
               detected_by: %i[deployment]) do |root|
  path = File.join(root, "roles", "deployment_bundle", "files", "validate_target.py")
  File.write(path, File.read(path).gsub("root_relative_parts", "unchecked_root_parts"))
end

expect_failure(failures, "target validator lookup replaced",
               "target containment task must execute the exact extracted validator source",
               detected_by: %i[deployment]) do |root|
  path = File.join(root, "roles", "deployment_bundle", "tasks", "target.yml")
  lookup = "{{ lookup('ansible.builtin.file', role_path ~ '/files/validate_target.py') }}"
  File.write(path, File.read(path).gsub(lookup, "{{ 'pass' }}"))
end

expect_failure(failures, "target validation record removed",
               "target validation must record that the play has already validated containment",
               detected_by: %i[deployment]) do |root|
  path = File.join(root, "roles", "deployment_bundle", "tasks", "target.yml")
  tasks = YAML.safe_load_file(path)
  tasks.reject! do |task|
    task.dig("ansible.builtin.set_fact", "deployment_bundle_target_validated") == true
  end
  File.write(path, YAML.dump(tasks))
end

expect_failure(failures, "containment revalidated beside each mutation",
               "deployment bundle must validate target containment exactly once, " \
               "not beside each mutation",
               detected_by: %i[deployment]) do |root|
  path = File.join(root, "roles", "deployment_bundle", "tasks", "main.yml")
  tasks = YAML.safe_load_file(path)
  index = tasks.index { |task| task["ansible.builtin.include_tasks"] == "target.yml" }
  tasks.insert(index + 1, Marshal.load(Marshal.dump(tasks.fetch(index))))
  File.write(path, YAML.dump(tasks))
end

expect_failure(failures, "play-level containment validation repeated",
               "deployment bundle target validation must be skipped when the play already validated",
               detected_by: %i[deployment]) do |root|
  path = File.join(root, "roles", "deployment_bundle", "tasks", "main.yml")
  tasks = YAML.safe_load_file(path)
  tasks.each do |task|
    task.delete("when") if task["ansible.builtin.include_tasks"] == "target.yml"
  end
  File.write(path, YAML.dump(tasks))
end

# Hoisting the check out of the roles would leave this policy passing over nothing.
expect_failure(failures, "service Compose override left unguarded",
               "komga must name the manifest service whose Compose files a selective run deploys",
               detected_by: %i[deployment]) do |root|
  path = File.join(root, "roles", "komga", "tasks", "main.yml")
  tasks = YAML.safe_load_file(path)
  tasks.each do |task|
    next unless task.dig("ansible.builtin.include_role", "tasks_from") == "target"

    task.fetch("vars")["deployment_target_service"] = "komga-typo"
  end
  File.write(path, YAML.dump(tasks))
end

# The containment validator would silently accept the widened paths.
expect_failure(failures, "derived deployment paths widened past the role",
               "names service \"jellyfin\", which is not the manifest service directory " \
               "deployed by role \"komga\"",
               detected_by: %i[deployment]) do |root|
  path = File.join(root, "roles", "komga", "tasks", "main.yml")
  tasks = YAML.safe_load_file(path)
  tasks.each do |task|
    next unless task.dig("ansible.builtin.include_role", "tasks_from") == "target"

    task.fetch("vars")["deployment_target_service"] = "jellyfin"
  end
  File.write(path, YAML.dump(tasks))
end

expect_failure(failures, "preflight probe leaf unguarded",
               "target validator must guard the exact preflight probe leaf",
               detected_by: %i[deployment]) do |root|
  path = File.join(root, "roles", "deployment_bundle", "tasks", "target.yml")
  body = File.read(path)
                  .gsub("      - \"{{ nas_docker_root }}/.nas-platform-preflight-probe\"\n", "")
                  .gsub("          nas_docker_root ~ '/.nas-platform-preflight-probe',\n", "")
  File.write(path, body)
end

expect_failure(failures, "preflight target validation removed",
               "target containment must be validated before preflight can mutate the target",
               detected_by: %i[deployment]) do |root|
  path = File.join(root, "site.yml")
  site = YAML.safe_load_file(path)
  site.first["pre_tasks"].reject! do |task|
    task.dig("ansible.builtin.include_role", "tasks_from") == "target"
  end
  File.write(path, YAML.dump(site))
end

expect_failure(failures, "manifest component validation removed",
               "deployment bundle must validate manifest service path components",
               detected_by: %i[deployment]) do |root|
  path = File.join(root, "roles", "deployment_bundle", "tasks", "inputs.yml")
  tasks = YAML.safe_load_file(path)
  tasks.reject! do |task|
    task["name"] == "Validate manifest service path components before interpolation"
  end
  File.write(path, YAML.dump(tasks))
end

expect_failure(failures, "platform image merge removed",
               "deployment manifest images must merge canonical and platform Compose services",
               detected_by: %i[deployment]) do |root|
  path = File.join(root, "roles", "deployment_bundle", "templates", "manifest.yml.j2")
  File.write(path, File.read(path).gsub("platform_compose", "override_compose"))
end

expect_failure(failures, "Compose override tag normalization removed",
               "deployment manifest must parse Compose tags without rewriting source text",
               detected_by: %i[deployment]) do |root|
  path = File.join(root, "roles", "deployment_bundle", "templates", "manifest.yml.j2")
  File.write(path, File.read(path).gsub("platform_compose_metadata", "from_yaml"))
end

expect_failure(failures, "Compose metadata unknown-tag rejection removed",
               "Compose metadata loader must allow only exact known tags and fail closed",
               detected_by: %i[deployment]) do |root|
  path = File.join(root, "filter_plugins", "compose_metadata.py")
  File.write(path, File.read(path).gsub("except yaml.YAMLError", "except TypeError"))
end

expect_failure(failures, "Compose metadata behavior tests bypassed",
               "policy validation must execute Compose metadata parser behavior tests",
               detected_by: %i[deployment]) do |root|
  path = File.join(root, "tests", "validate-policy.sh")
  File.write(path, File.read(path).gsub(
    "ansible-playbook -i localhost, -c local tests/compose_metadata_filter_test.yml",
    "true"
  ))
end

permissive_output, permissive_status = run_compose_metadata_behavior do |root|
  path = File.join(root, "filter_plugins", "compose_metadata.py")
  source = File.read(path)
  constructor_loop = <<~PYTHON.chomp
    for _compose_tag in ("!override", "!reset"):
        _ComposeMetadataLoader.add_constructor(_compose_tag, _construct_compose_value)
  PYTHON
  permissive_constructor = <<~PYTHON.chomp
    _ComposeMetadataLoader.add_multi_constructor(
        "!", lambda loader, _suffix, node: _construct_compose_value(loader, node)
    )
  PYTHON
  raise "mutation source is absent" unless source.include?(constructor_loop)

  File.write(path, source.sub(constructor_loop, "#{constructor_loop}\n#{permissive_constructor}"))
end
if permissive_status.success?
  failures << "permissive Compose unknown-tag constructor: behavioral suite unexpectedly passed"
end
unless permissive_output.include?("Verify only parser rejection satisfied the unknown-tag proof") &&
       permissive_output.include?("unknown_tag_rejected | default(false) | bool")
  failures << "permissive Compose unknown-tag constructor: missing strict behavioral failure"
end
if permissive_output.include?("compose-filter-secret-sentinel")
  failures << "permissive Compose unknown-tag constructor: secret sentinel reached diagnostics"
end

expect_failure(failures, "platform override redefines image",
               "platform image overrides differ from the canonical compose.yml image",
               detected_by: %i[policy integration]) do |root|
  path = File.join(root, "services", "beszel", "compose.integration.yml")
  File.write(path, <<~YAML)
    ---
    services:
      agent:
        image: example.invalid/beszel-agent:1@sha256:#{'0' * 64}
  YAML
end

expect_failure(failures, "controller input lstat removed",
               "controller input validator must use os.lstat",
               detected_by: %i[deployment]) do |root|
  path = File.join(root, "roles", "deployment_bundle", "files", "validate_controller_input.py")
  File.write(path, File.read(path).gsub("os.lstat", "os.stat"))
end

expect_failure(failures, "runtime service leaves omitted",
               "target validator must guard every implemented runtime service leaf",
               detected_by: %i[deployment]) do |root|
  path = File.join(root, "roles", "deployment_bundle", "tasks", "target.yml")
  File.write(path, File.read(path).gsub("deployment_bundle_services", "unchecked_services"))
end

expect_failure(failures, "portable vault key omitted",
               "vault-plain.yml.j2 is missing required portable credential vault_immich_db_password",
               detected_by: %i[vault]) do |root|
  path = File.join(root, "templates", "vault-plain.yml.j2")
  File.write(path, File.read(path).gsub(/^vault_immich_db_password:.*\n/, ""))
end

expect_failure(failures, "NAS coordinate leaked into vault",
               "vault.yml.example has unexpected or non-portable vault key vault_nas_address",
               detected_by: %i[vault]) do |root|
  path = File.join(root, "inventory", "group_vars", "all", "vault.yml.example")
  File.write(path, File.read(path) + "vault_nas_address: 192.0.2.1\n")
end

# Encrypted on purpose so only tracking is wrong; unstaged, the same file is allowed.
expect_failure(failures, "retired single-file vault committed",
               "inventory/group_vars/all/vault.yml is committed",
               detected_by: %i[vault]) do |root|
  File.write(File.join(root, "inventory", "group_vars", "all", "vault.yml"),
             "$ANSIBLE_VAULT;1.1;AES256\n0000\n")
  _stdout, stderr, status = capture3_without_git_routing(
    "git", "add", "inventory/group_vars/all/vault.yml", chdir: root
  )
  raise "could not stage the committed vault fixture: #{stderr.lines.first&.strip}" unless status.success?
end

expect_failure(failures, "credential-bearing read left unredacted",
               "tasks that render a credential must set no_log",
               detected_by: %i[vault]) do |root|
  path = File.join(root, "roles", "komga", "tasks", "main.yml")
  body = File.read(path)
  File.write(path, replace_last(
                     body,
                     "  register: komga_libraries_before\n" \
                     "  when: not ansible_check_mode or komga_claim_status.json.isClaimed | bool\n" \
                     "  changed_when: false\n  check_mode: false\n  no_log: true\n",
                     "  register: komga_libraries_before\n" \
                     "  when: not ansible_check_mode or komga_claim_status.json.isClaimed | bool\n" \
                     "  changed_when: false\n  check_mode: false\n"
                   ))
end

# The target's shape is read off the parsed role, so a drifted target is reported
# rather than planting on a task the rule would excuse anyway.
REDACTED_ASSERTION_TARGET = "Require a complete Komga library listing"
expect_failure(failures, "credential-free assertion redacted",
               "assertions that can render no credential must not set no_log",
               detected_by: %i[vault]) do |root|
  path = File.join(root, "roles", "komga", "tasks", "main.yml")
  target = YAML.safe_load_file(path, aliases: true).find do |task|
    task.is_a?(Hash) && task["name"] == REDACTED_ASSERTION_TARGET
  end
  raise "#{REDACTED_ASSERTION_TARGET} is absent" unless target
  raise "#{REDACTED_ASSERTION_TARGET} is no longer an unredacted unlooped assertion" unless
    target.key?("ansible.builtin.assert") && !target.key?("loop") && !target.key?("no_log")
  raise "#{REDACTED_ASSERTION_TARGET} now names a credential" if
    YAML.dump(target).match?(/\bvault_[a-z0-9_]+\b/)

  anchor = "- name: #{REDACTED_ASSERTION_TARGET}\n  ansible.builtin.assert:\n"
  File.write(path, replace_last(File.read(path), anchor,
                                "- name: #{REDACTED_ASSERTION_TARGET}\n  no_log: true\n" \
                                "  ansible.builtin.assert:\n"))
end

# The companion name check is skipped on a partial tree, so this asserts the rule's
# message.
expect_failure(failures, "pinned redaction exception no longer covers a renamed task",
               "tasks that render a credential must set no_log",
               detected_by: %i[vault]) do |root|
  path = File.join(root, "roles", "beszel", "tasks", "application_user.yml")
  File.write(path, File.read(path).sub(
                     "- name: Refuse duplicate managed application users after reconciliation\n",
                     "- name: Refuse duplicate managed application users\n"
                   ))
end

expect_failure(failures, "vault validation disclosure",
               "every vault contract task must use no_log",
               detected_by: %i[vault]) do |root|
  path = File.join(root, "roles", "vault_contract", "tasks", "main.yml")
  tasks = YAML.safe_load_file(path)
  tasks.first.delete("no_log")
  File.write(path, YAML.dump(tasks))
end

# Dropping a key from the filter's mapping means it is no longer inspected.
expect_failure(failures, "vault shape validation omitted",
               "vault contract shape validation must inspect vault_immich_db_password",
               detected_by: %i[vault]) do |root|
  path = File.join(root, "roles", "vault_contract", "tasks", "main.yml")
  body = File.read(path)
  File.write(path, replace_last(
                     body,
                     "\n          'vault_immich_db_password': vault_immich_db_password,",
                     ""
                   ))
end

# Order must be select -> floor -> hash; the two rows plant the two ways to lose it.
VAULT_CONTRACT_SELECTION_MESSAGE =
  "vault contract must select on the encryption header, floor the selection, then compute SHA-256"
expect_failure(failures, "vault checksum moved before the selection floor",
               VAULT_CONTRACT_SELECTION_MESSAGE,
               detected_by: %i[vault]) do |root|
  path = File.join(root, "roles", "vault_contract", "tasks", "main.yml")
  tasks = YAML.safe_load_file(path)
  checksum_index = tasks.index do |task|
    task["name"] == "Compute the encrypted vault artifact SHA-256"
  end
  floor_index = tasks.index do |task|
    task["name"] == "Require at least one encrypted vault artifact"
  end
  raise "vault contract tasks not found for the plant" if checksum_index.nil? || floor_index.nil?

  checksum_task = tasks.delete_at(checksum_index)
  tasks.insert(floor_index, checksum_task)
  File.write(path, YAML.dump(tasks))
end
expect_failure(failures, "vault header matched at any line, not at file start",
               VAULT_CONTRACT_SELECTION_MESSAGE,
               detected_by: %i[vault]) do |root|
  path = File.join(root, "roles", "vault_contract", "tasks", "main.yml")
  tasks = YAML.safe_load_file(path)
  selection = tasks.find { |task| task["name"] == "Select the encrypted vault artifacts" }
  raise "vault contract selection task not found for the plant" if selection.nil?

  find = selection.fetch("ansible.builtin.find")
  find["read_whole_file"] = false
  find["contains"] = find.fetch("contains").sub(/\A\\A/, "^")
  File.write(path, YAML.dump(tasks))
end
expect_failure(failures, "vault selection narrowed to one extension",
               VAULT_CONTRACT_SELECTION_MESSAGE,
               detected_by: %i[vault]) do |root|
  path = File.join(root, "roles", "vault_contract", "tasks", "main.yml")
  tasks = YAML.safe_load_file(path)
  selection = tasks.find { |task| task["name"] == "Select the encrypted vault artifacts" }
  raise "vault contract selection task not found for the plant" if selection.nil?

  selection.fetch("ansible.builtin.find")["patterns"] = "*.yml"
  File.write(path, YAML.dump(tasks))
end
expect_failure(failures, "vault location default regressed to one file",
               "site.yml must default platform_vault_file to the inventory/group_vars/all directory",
               detected_by: %i[platform]) do |root|
  path = File.join(root, "site.yml")
  source = File.read(path)
  mutated = source.sub("'/inventory/group_vars/all', true)", "'/inventory/group_vars/all/vault.yml', true)")
  raise "site.yml default not found for the plant" if mutated == source

  File.write(path, mutated)
end
expect_failure(failures, "vault selection no longer tests the encryption header",
               VAULT_CONTRACT_SELECTION_MESSAGE,
               detected_by: %i[vault]) do |root|
  path = File.join(root, "roles", "vault_contract", "tasks", "main.yml")
  tasks = YAML.safe_load_file(path)
  selection = tasks.find { |task| task["name"] == "Select the encrypted vault artifacts" }
  raise "vault contract selection task not found for the plant" if selection.nil?

  selection.fetch("ansible.builtin.find").delete("contains")
  File.write(path, YAML.dump(tasks))
end

[
  "Generate passwords",
  "Read the Beszel hub keypair",
  "Hash the administrator passwords with the pinned bcrypt hasher",
  "Collect the generated material",
  "Fail loudly if any value did not parse",
  "Write the plaintext vars file for encryption"
].each do |task_name|
  expect_failure(failures, "generator redaction removed from #{task_name}",
                 "generate-secrets.yml must redact secret-bearing task #{task_name}",
                 detected_by: %i[vault]) do |root|
    path = File.join(root, "generate-secrets.yml")
    play = YAML.safe_load_file(path).first
    task = play.fetch("tasks").find { |entry| entry["name"] == task_name }
    task.delete("no_log")
    File.write(path, YAML.dump([play]))
  end
end

expect_failure(failures, "ephemeral self-test silence check removed from CI",
               "CI must run the silent ephemeral vault self-test with explicit dependencies",
               detected_by: %i[vault]) do |root|
  path = File.join(root, ".github", "workflows", "ci.yml")
  File.write(path, File.read(path).gsub("test ! -s", "true"))
end

expect_failure(failures, "ephemeral dependency removed from CI",
               "CI must run the silent ephemeral vault self-test with explicit dependencies",
               detected_by: %i[vault]) do |root|
  path = File.join(root, ".github", "workflows", "ci.yml")
  File.write(path, File.read(path).gsub("apache2-utils", "removed-dependency"))
end

expect_failure(failures, "ephemeral self-test removed from CI",
               "CI must run the silent ephemeral vault self-test with explicit dependencies",
               detected_by: %i[vault]) do |root|
  path = File.join(root, ".github", "workflows", "ci.yml")
  File.write(path, File.read(path).gsub("tests/generate-ephemeral-vault.sh --self-test", "true"))
end

# Planted in the manifest since #653; removed, not rewritten, so the policy script
# objects rather than the gate crashing.
expect_failure(failures, "generator redaction test removed from the policy gate",
               "CI must execute the generated-secret redaction test",
               detected_by: %i[ci vault]) do |root|
  path = File.join(root, "tests", "validate-policy.sh")
  command = "tests/generate-secrets-redaction-test.sh"
  File.write(path, File.read(path).lines.reject { |line| line.strip == command }.join)
end

# The other two checks #653 moved into the manifest; only the CI policy requires them.
{
  "integration sandbox cleanup test" => "tests/integration_cleanup_test.sh",
  "Immich probe status rendering test" =>
    'PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/immich_probe_status_test.py'
}.each do |name, command|
  expect_failure(failures, "#{name} removed from the policy gate",
                 "validate-policy.sh must run the #{name} exactly once",
                 detected_by: %i[ci]) do |root|
    path = File.join(root, "tests", "validate-policy.sh")
    File.write(path, File.read(path).lines.reject { |line| line.strip == command }.join)
  end
end

expect_failure(failures, "integration ephemeral helper bypassed",
               "integration must consume the ephemeral encrypted vault without duplicate secret authoring",
               detected_by: %i[integration]) do |root|
  mutate_text(root, "tests/integration_controller.sh",
              '--output "$vault_file"', "--output-bypassed")
end

expect_failure(failures, "integration ephemeral cleanup context removed",
               "integration must consume the ephemeral encrypted vault without duplicate secret authoring",
               detected_by: %i[integration]) do |root|
  mutate_text(root, "tests/integration_controller.sh",
              'TMPDIR="$sandbox" /repo/tests/generate-ephemeral-vault.sh --cleanup',
              "/repo/tests/generate-ephemeral-vault.sh --cleanup")
end

expect_failure(failures, "integration lock acquisition removed",
               "integration must serialize fixed-name containers with an atomic empty-directory lock",
               detected_by: %i[integration]) do |root|
  path = File.join(root, "tests", "integration.sh")
  File.write(path, File.read(path).sub("acquire_integration_lock", "bypass_integration_lock"))
end

expect_failure(failures, "integration lock made non-atomic",
               "integration must serialize fixed-name containers with an atomic empty-directory lock",
               detected_by: %i[integration]) do |root|
  path = File.join(root, "tests", "integration_lock.sh")
  File.write(path, File.read(path).sub('mkdir "$lock_candidate"', "true"))
end

# Each mutation deletes a play binding or contract ABI line where it lives.
{
  "vault password file" => ["tests/integration_controller_lib.sh",
                            '--vault-password-file "$vault_password_file"'],
  "encrypted vars input" => ["tests/integration_controller_lib.sh",
                             '-e @"$vault_file"'],
  "encrypted artifact path" => ["tests/integration_controller_lib.sh",
                                '-e platform_vault_file="$vault_file"'],
  "contract vault ABI" => ["tests/integration_controller.sh",
                           'PLATFORM_CONTRACT_VAULT_FILE="$vault_file"']
}.each do |property, (relative_path, source)|
  expect_failure(failures, "integration #{property} removed",
                 "integration must consume the ephemeral encrypted vault without duplicate secret authoring",
                 detected_by: %i[integration]) do |root|
    path = File.join(root, relative_path)
    body = File.read(path)
    mutated = if property == "contract vault ABI"
                replace_last(body, source, "removed-integration-vault-binding")
              else
                body.sub(source, "removed-integration-vault-binding")
              end
    raise "integration vault mutation did not apply" if mutated == body

    File.write(path, mutated)
  end
end

{
  "pre-existing output refusal" => "self-test generation accepted a pre-existing output",
  "vault leaf symlink refusal" => "self-test generation accepted a vault output symlink",
  "password leaf symlink refusal" => "self-test generation accepted a password output symlink",
  "unexpected entry refusal" => "self-test generation accepted an unexpected entry",
  "in-repository refusal" => "self-test generation accepted an in-repository directory",
  "TMPDIR symlink refusal" => "self-test accepted a symlink temporary parent",
  "trailing-slash symlink refusal" => "self-test cleanup accepted a trailing-slash symlink alias",
  "lexical alias refusal" => "self-test cleanup accepted a non-normalized lexical alias",
  "trailing-slash TMPDIR refusal" => "self-test accepted a trailing-slash symlink temporary parent",
  "unsafe mode refusal" => "self-test generation accepted a world-writable directory",
  "ownership refusal" => "self-test generation accepted a foreign-owned directory",
  "failure cleanup" => "self-test failed generation left credential material",
  "mid-validation cleanup" => "self-test mid-validation failure left credential material"
}.each do |property, evidence|
  expect_failure(failures, "ephemeral #{property} removed",
                 "ephemeral vault self-test must cover #{property}",
                 detected_by: %i[vault]) do |root|
    path = File.join(root, "tests", "generate-ephemeral-vault.sh")
    File.write(path, File.read(path).gsub(evidence, "removed self-test evidence"))
  end
end


{
  "requested-path lexical guard" => 'validate_lexical_path "$requested"',
  "temporary-parent lexical guard" => 'validate_lexical_path "$temporary_parent_input"',
  "temporary-parent symlink guard" => '[ ! -L "$temporary_parent_input" ]',
  "directory symlink guard" => '[ ! -L "$requested" ]',
  "directory ownership guard" => '[ "$(owner_id "$physical")" = "$(id -u)" ]',
  "directory mode guard" => '[ "$(file_mode "$physical")" = 700 ]',
  "repository containment guard" => '"$repo_dir/"*) die',
  "output overwrite and symlink guard" => '[ ! -e "$candidate" ] && [ ! -L "$candidate" ]',
  "empty-directory guard" => '[ -z "$(find "$directory" -mindepth 1 -maxdepth 1 -print -quit)" ]',
  "cleanup unexpected-entry guard" => '! -name vault.yml ! -name password -print -quit',
  "cleanup leaf-symlink guard" => '[ ! -L "$directory/vault.yml" ] && [ ! -L "$directory/password" ]',
  "failure trap isolation" => "generate_vault() (",
  "failure cleanup trap" => 'trap \'rm -f -- "$plain" "$private_key" "$private_key.pub" "$agent_cert" "$agent_key" "$password_file" "$output"\' EXIT',
  "self-test cleanup trap" => "trap self_test_cleanup_on_exit EXIT"
}.each do |property, source|
  expect_failure(failures, "ephemeral #{property} removed",
                 "ephemeral vault helper must preserve #{property}",
                 detected_by: %i[vault]) do |root|
    path = File.join(root, "tests", "generate-ephemeral-vault.sh")
    File.write(path, File.read(path).sub(source, "removed-helper-guard"))
  end
end

expect_failure(failures, "Mac lifecycle keep-on-failure option removed",
               "Mac proof harness must accept --keep-on-failure",
               detected_by: %i[mac]) do |root|
  path = File.join(root, "tests", "mac", "run.sh")
  File.write(path, File.read(path).gsub("--keep-on-failure", "removed-keep-on-failure"))
end

expect_failure(failures, "Mac log sanitizer self-test removed",
               "validate-policy.sh must run ruby tests/mac/sanitize-logs.rb --self-test",
               detected_by: %i[ci]) do |root|
  path = File.join(root, "tests", "validate-policy.sh")
  File.write(path, File.read(path).gsub("ruby tests/mac/sanitize-logs.rb --self-test", "true"))
end

expect_failure(failures, "Mac report self-test removed",
               "validate-policy.sh must run ruby tests/mac/report.rb --self-test",
               detected_by: %i[ci]) do |root|
  path = File.join(root, "tests", "validate-policy.sh")
  File.write(path, File.read(path).gsub("ruby tests/mac/report.rb --self-test", "true"))
end

expect_failure(failures, "Mac cleanup self-test removed",
               "validate-policy.sh must run tests/mac/cleanup.sh --self-test",
               detected_by: %i[ci]) do |root|
  path = File.join(root, "tests", "validate-policy.sh")
  File.write(path, File.read(path).gsub("tests/mac/cleanup.sh --self-test", "true"))
end

{
  "Beszel telemetry semantic probe" => "ruby tests/beszel_telemetry_probe_test.rb",
  "Beszel telemetry deadline regression" => "ruby tests/beszel_telemetry_timeout_test.rb",
  "Beszel telemetry Ansible regression" => "ruby tests/beszel_telemetry_ansible_test.rb",
  "Beszel telemetry production probe regression" => "python3 tests/beszel_telemetry_module_test.py",
  "Beszel telemetry Mac hook regression" => "tests/mac/beszel-telemetry-hook-test.sh",
  "Komga library reconciliation regression" => "ruby tests/komga_library_reconciliation_test.rb",
  "Komga library reconciliation self-test" =>
    "ruby tests/komga_library_reconciliation_test.rb --self-test",
  "Paperless mail reconciliation regression" => "ruby tests/paperless_mail_reconciliation_test.rb",
  "media acquisition reconciliation regression" =>
    "ruby tests/media_acquisition_foundation_verifier_test.rb",
  "acquisition filter argument conversion regression" =>
    'PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/acquisition_filter_native_arguments_test.py',
  "Bazarr provider schema regression" =>
    "ruby tests/bazarr_provider_schema_test.rb",
  "Bazarr provider schema self-test" =>
    "ruby tests/bazarr_provider_schema_test.rb --self-test",
  "Configarr owned-field coverage regression" =>
    "ruby tests/acquisition_configarr_field_coverage_test.rb",
  "Configarr owned-field coverage self-test" =>
    "ruby tests/acquisition_configarr_field_coverage_test.rb --self-test",
  "relationship owned-field coverage regression" =>
    'PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/acquisition_owned_field_coverage_test.py',
  "acquisition filter argument conversion self-test" =>
    'PYTHONDONTWRITEBYTECODE=1 "$ansible_python" ' \
    'tests/acquisition_filter_native_arguments_test.py --self-test',
  "Immich selective helper integrity regression" =>
    "ruby tests/immich_selective_helper_integrity_test.rb",
  "Mac manual-validation runner regression" => "tests/mac/manual-validation-runner-test.sh",
  "Mac hook coverage regression" => "tests/mac/hook-coverage-test.sh",
  "media acquisition verifier regression" =>
    "ruby tests/media_acquisition_foundation_verifier_test.rb",
  "host preparation integration writer regression" =>
    "ruby tests/host_prep_integration_writer_test.rb",
  "media acquisition hook regression" =>
    "tests/mac/media-acquisition-foundation-hook-test.sh",
  "media acquisition report regression" =>
    "ruby tests/mac/media-acquisition-foundation-report-test.rb",
  "media acquisition cleanup regression" =>
    "tests/mac/media-acquisition-foundation-cleanup-test.sh",
  "documentation link and prose gate" => "ruby tests/docs_links_test.rb",
  "documentation gate self-test" => "ruby tests/docs_links_test.rb --self-test",
  "Paperless snapshot recovery regression" => "tests/mac/snapshot-paperless-recovery-test.sh",
  "Paperless drill login budget regression" =>
    "tests/mac/snapshot-paperless-drill-throttle-test.sh"
}.each do |name, command|
  expect_failure(failures, "#{name} removed from policy validation",
                 "validate-policy.sh must run #{command}",
                 detected_by: %i[policy ci mac]) do |root|
    path = File.join(root, "tests", "validate-policy.sh")
    File.write(path, File.read(path).lines.reject { |line| line.strip == command }.join)
  end
end

# The six Mac gate checks (#315), detected by policy_mac_test.rb alone, so they
# need a call site of their own for the audit.
{
  "Mac configuration isolation regression" => "tests/mac/config-isolation.sh",
  "Mac phase status regression" => "tests/mac/run-phase-status-test.sh",
  "Mac Dozzle drift hook regression" => "tests/mac/dozzle-drift-hook-test.sh",
  "Mac Immich drift hook regression" => "tests/mac/immich-drift-hook-test.sh",
  "Mac integration context regression" => "tests/mac/integration-context-test.sh",
  "Paperless snapshot context regression" => "tests/mac/snapshot-paperless-context-test.sh",
  "Paperless snapshot self-test" => "tests/mac/snapshot-paperless.sh --self-test"
}.each do |name, command|
  expect_failure(failures, "#{name} removed from policy validation",
                 "validate-policy.sh must run #{command}",
                 detected_by: %i[mac]) do |root|
    path = File.join(root, "tests", "validate-policy.sh")
    File.write(path, File.read(path).lines.reject { |line| line.strip == command }.join)
  end
end

expect_failure(failures, "filter input argument spec check removed from policy validation",
               "validate-policy.sh must run PYTHONDONTWRITEBYTECODE=1 \"$ansible_python\" " \
               "tests/filter_input_argument_spec_test.py exactly once",
               detected_by: %i[ci]) do |root|
  path = File.join(root, "tests", "validate-policy.sh")
  File.write(path, File.read(path).lines.reject do |line|
    line.strip == 'PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/filter_input_argument_spec_test.py'
  end.join)
end

{
  "production auto-deploy poller suite" =>
    'PYTHONDONTWRITEBYTECODE=1 "$ansible_python" -m unittest -v tests.production_auto_deploy_test',
  "production auto-deploy installer suite" =>
    "ruby tests/production_auto_deploy_role_test.rb",
  "scheduled image prune suite" =>
    'PYTHONDONTWRITEBYTECODE=1 "$ansible_python" -m unittest -v tests.image_prune_test',
  "image prune installer suite" =>
    "ruby tests/image_prune_role_test.rb"
}.each do |name, command|
  expect_failure(failures, "#{name} removed from policy validation",
                 "validate-policy.sh must run the #{name} exactly once",
                 detected_by: %i[ci]) do |root|
    path = File.join(root, "tests", "validate-policy.sh")
    File.write(path, File.read(path).lines.reject { |line| line.strip == command }.join)
  end
end

expect_failure(failures, "production auto-deploy installer syntax check removed",
               "CI must syntax-check install-production-auto-deploy.yml",
               detected_by: %i[ci]) do |root|
  path = File.join(root, ".github", "workflows", "ci.yml")
  File.write(path, File.read(path).lines.reject do |line|
    line.strip == "ansible-playbook -i inventory/local.yml install-production-auto-deploy.yml --syntax-check"
  end.join)
end

expect_failure(failures, "Mac raw log body retained",
               "Mac log sanitizer self-test must pass without raw values",
               detected_by: %i[mac]) do |root|
  path = File.join(root, "tests", "mac", "sanitize-logs.rb")
  leaked_body = 'line.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "")'
  File.write(path, File.read(path).sub('"message" => REDACTION', "\"message\" => #{leaked_body}"))
end

# A deleted expectations file must not read as nothing to check.
expect_failure(failures, "pinned service expectations deleted",
               "pinned service expectations are missing: tests/expected/komga.yml",
               detected_by: %i[policy vault]) do |root|
  FileUtils.rm(File.join(root, "tests", "expected", "komga.yml"))
end

expect_failure(failures, "pinned expectations for an unrostered service",
               "tests/expected must hold exactly one file per rostered service",
               detected_by: %i[policy vault]) do |root|
  File.write(File.join(root, "tests", "expected", "plex.yml"), <<~YAML)
    ---
    role: plex
    container_cpus:
      plex: 1.0
    vault_keys:
    - vault_plex_token
  YAML
end

expect_failure(failures, "pinned CPU ceiling drifts from Compose",
               "jellyfin/jellyfin: CPU ceiling must match the pinned service policy",
               detected_by: %i[policy]) do |root|
  mutate_yaml_file(root, "tests/expected/jellyfin.yml") do |expectation|
    expectation["container_cpus"]["jellyfin"] = 9.9
  end
end

# A single ceiling wider than the cpuset must fail by name, not only as Compose drift.
expect_failure(failures, "pinned CPU ceiling exceeds the container CPU budget",
               "jellyfin/jellyfin: CPU ceiling 4.0 exceeds the 3-CPU cpuset it shares",
               detected_by: %i[policy]) do |root|
  mutate_yaml_file(root, "tests/expected/jellyfin.yml") do |expectation|
    expectation["container_cpus"]["jellyfin"] = 4.0
  end
end

expect_failure(failures, "pinned CPU ceiling is not a number",
               "tests/expected/jellyfin.yml container_cpus.jellyfin must be numeric",
               detected_by: %i[policy vault]) do |root|
  mutate_yaml_file(root, "tests/expected/jellyfin.yml") do |expectation|
    expectation["container_cpus"]["jellyfin"] = "3.O"
  end
end

# In range and well shaped, so only the catalog-to-expected equality catches it.
expect_failure(failures, "deployed acquisition catalog ceiling drifts from the pinned home",
               "arr/radarr: config/media-acquisition.yml cpus 2.0 must equal the 1.0 pinned in " \
               "tests/expected/arr.yml",
               detected_by: %i[policy]) do |root|
  mutate_yaml_file(root, "config/media-acquisition.yml") do |catalog|
    catalog.dig("projects", "arr", "services", "radarr")["cpus"] = 2.0
  end
end

# Container sets are compared both ways; this proves that comparison is live.
expect_failure(failures, "deployed acquisition catalog drops a pinned container",
               "downloaders: config/media-acquisition.yml must declare a cpus ceiling for exactly " \
               "the containers pinned in tests/expected/downloaders.yml",
               detected_by: %i[policy]) do |root|
  mutate_yaml_file(root, "config/media-acquisition.yml") do |catalog|
    catalog.dig("projects", "downloaders", "services").delete("unpackerr")
  end
end

expect_failure(failures, "pinned vault key dropped",
               "vault key vault_jellyfin_opensubtitles_password",
               detected_by: %i[vault]) do |root|
  mutate_yaml_file(root, "tests/expected/jellyfin.yml") do |expectation|
    expectation["vault_keys"].delete("vault_jellyfin_opensubtitles_password")
  end
end

expect_failure(failures, "pinned role drifts from the manifest",
               "jellyfin: role must equal",
               detected_by: %i[policy]) do |root|
  mutate_yaml_file(root, "tests/expected/jellyfin.yml") do |expectation|
    expectation["role"] = "jellyfin_wrong"
  end
end

expect_failure(failures, "pinned expectations gain an unknown field",
               "tests/expected/komga.yml must define exactly",
               detected_by: %i[policy vault]) do |root|
  mutate_yaml_file(root, "tests/expected/komga.yml") { |e| e["unexpected"] = true }
end

# A nas_storage_* definition outside group_vars/all is refused; inside a nested
# checkout it is not.
expect_failure(failures, "storage contributor outside group_vars/all",
               "roles/dozzle/defaults/planted.yml: nas_storage_planted",
               detected_by: %i[policy]) do |root|
  File.write(File.join(root, "roles", "dozzle", "defaults", "planted.yml"),
             YAML.dump("nas_storage_planted" => [{ "path" => "/tmp/planted" }]))
end

# A directory holding a `.git` file is a worktree on disk, which the sweep prunes
# on (#665). Planting the shape, not the path name, is the point.
expect_success(failures, "storage contributor inside a nested checkout") do |root|
  checkout = File.join(root, ".claude", "worktrees", "agent-0000")
  contributors = File.join(checkout, "inventory", "group_vars", "all")
  FileUtils.mkdir_p(contributors)
  File.write(File.join(checkout, ".git"), "gitdir: /nonexistent/worktrees/agent-0000\n")
  File.write(File.join(contributors, "service_planted.yml"),
             YAML.dump("nas_storage_planted" => [{ "path" => "/tmp/planted" }]))
end

# Library mounts are compared against nas_storage; a rename on either side must be
# reported and the parent-mount relaxation earned.
expect_failure(failures, "service template mounts an undeclared library",
               "roles/komga/templates/env.j2: {{ nas_media_root }}/Comics is not declared in nas_storage",
               detected_by: %i[policy]) do |root|
  path = File.join(root, "roles", "komga", "templates", "env.j2")
  File.write(path, File.read(path).sub(
    "KOMGA_LIBRARY_PATH={{ nas_media_root }}/Books",
    "KOMGA_LIBRARY_PATH={{ nas_media_root }}/Comics"
  ))
end

# Jellyfin's parent mount is accepted only because its leaves are declared.
expect_failure(failures, "media library leaves removed from storage",
               "roles/jellyfin/templates/env.j2: {{ nas_media_root }}/Media is not declared in nas_storage",
               detected_by: %i[policy]) do |root|
  # Every contributor: staging paths under Media/ would otherwise still cover the mount.
  Dir.glob(File.join(root, "inventory", "group_vars", "all", "*.yml")).sort.each do |file|
    # Encrypted vault files parse to a String, not a mapping.
    next if File.basename(file).match?(/\Avault(?:_[a-z0-9_]+)?\.yml\z/)

    relative = File.join("inventory", "group_vars", "all", File.basename(file))
    mutate_yaml_file(root, relative) do |inventory|
      inventory.each do |key, value|
        next unless key.start_with?("nas_storage_") && value.is_a?(Array)

        value.reject! { |entry| entry.fetch("path").start_with?("{{ nas_media_root }}/Media/") }
      end
    end
  end
end

expect_failure(failures, "media Compose bind source undeclared",
               "immich/immich-server: ${NAS_MEDIA_ROOT:?}/Immich is not declared in nas_storage",
               detected_by: %i[policy]) do |root|
  mutate_storage_entry.call(root, "{{ nas_media_root }}/Immich") do |entry|
    entry["path"] = "{{ nas_media_root }}/Immich-renamed"
  end
end


# _write_private is duplicated on purpose: the copies drifting, and a copy
# truncating in place.
expect_failure(failures, "private write copies diverged",
               "every script must define _write_private identically",
               detected_by: %i[policy]) do |root|
  path = File.join(root, "scripts", "image_prune.py")
  File.write(path, File.read(path).sub(
    "Replace path's contents atomically, at mode 0600.",
    "Replace the contents of path atomically, at mode 0600."
  ))
end

expect_failure(failures, "private write truncates in place again",
               "_write_private must replace the target rather than truncate it in place",
               detected_by: %i[policy]) do |root|
  path = File.join(root, "scripts", "image_prune.py")
  source = File.read(path)
  opening = source.index("def _write_private(path: Path, payload: bytes) -> None:")
  closing = source.index("def _record_lock_holder(descriptor: int, holder: str) -> None:")
  legacy = <<~PYTHON
    def _write_private(path: Path, payload: bytes) -> None:
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(descriptor, "wb") as sink:
            sink.write(payload)
        os.chmod(path, 0o600)


  PYTHON
  File.write(path, source[0...opening] + legacy + source[closing..])
end


# Held identical as raw text, so a one-word docstring drift must fail (#423).
expect_failure(failures, "duplicated helper docstring diverged",
               "every script must define html_escape identically",
               detected_by: %i[policy]) do |root|
  path = File.join(root, "scripts", "image_prune.py")
  File.write(path, File.read(path).sub(
    "Bound one value, then make it inert markup for Pushover's html=1.",
    "Bound one value, then make it inert markup for Pushover's html=1 field."
  ))
end

# A retired helper kept by one script is refused by name.
expect_failure(failures, "retired markdown_escape left behind in one script",
               "scripts/image_prune.py still defines [\"markdown_escape\"]",
               detected_by: %i[policy]) do |root|
  path = File.join(root, "scripts", "image_prune.py")
  File.write(path, "#{File.read(path)}\n\ndef markdown_escape(value: str, maximum: int = 256) -> str:\n" \
                   "    return value[:maximum]\n")
end

# A byte-identical fresh copy must be listed before anyone edits one side.
expect_failure(failures, "fresh duplicate helper left unlisted",
               "are defined identically in every scripts/*.py program but are not listed",
               detected_by: %i[policy]) do |root|
  source = File.read(File.join(root, "scripts", "image_prune.py"))
  opening = source.index("def format_bytes(count: int) -> str:")
  closing = source.index("def format_duration(seconds: int) -> str:")
  path = File.join(root, "scripts", "production_auto_deploy.py")
  File.write(path, "#{File.read(path)}\n\n#{source[opening...closing].rstrip}\n")
end

# The pinned function's input bound drifting while both bodies stay identical (#515).
expect_failure(failures, "escaped field bound diverged",
               "every copy site must spell MAX_ESCAPED_FIELD_CHARACTERS identically",
               detected_by: %i[policy]) do |root|
  mutate_text(root, "scripts/image_prune.py",
              /^MAX_ESCAPED_FIELD_CHARACTERS = .*$/, "MAX_ESCAPED_FIELD_CHARACTERS = 768")
end

# The site list is exact, so a copy dropping the constant fails.
expect_failure(failures, "Pushover title cap dropped by a copy site",
               "A copy that disappeared is as much a change to this contract as one that diverged",
               detected_by: %i[policy]) do |root|
  mutate_text(root, "scripts/image_prune.py", /^MAX_TITLE_CHARACTERS = .*\n/, "")
end

# A verbatim copy shared by the relay and one script (#515).
expect_failure(failures, "fresh duplicate shared with the relay left unlisted",
               "are spelled byte-identically in two or more of",
               detected_by: %i[policy]) do |root|
  helper = <<~PYTHON

    def _shared_bound(value: int) -> int:
        """The bound both copies must agree on."""
        return min(value, 128)
  PYTHON
  %w[scripts/image_prune.py services/dozzle/alert_relay.py].each do |relative|
    path = File.join(root, relative)
    File.write(path, "#{File.read(path).rstrip}\n\n#{helper}")
  end
end

# The relay's verbatim copies of the message helpers (#558).
expect_failure(failures, "relay message helper diverged from the scripts",
               "must define fit_message identically to scripts/production_auto_deploy.py",
               detected_by: %i[policy]) do |root|
  mutate_text(root, "services/dozzle/alert_relay.py",
              "Join message lines, dropping whole lines from the end until Pushover takes it.",
              "Join message lines, dropping whole lines from the end until Pushover accepts it.")
end

audit_policy_detection(failures)
report_mutation_census(failures)
report(failures, "policy manifest: all mutation checks hold", "policy manifest regression(s)")
