#!/usr/bin/env ruby
# Focused mutation checks for the migration manifest policy.
#
# The sandbox harness and the fixture list live in policy_mutation_support.rb.

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
  "implemented service with empty vault list" => [valid_statuses.merge("bindery" => "implemented"),
                                                   "vault_keys must be a nonempty list"]
}.each do |label, (statuses, diagnostic)|
  _expectations, problems = pinned_service_expectations(ROOT, statuses)
  failures << "#{label}: missing #{diagnostic.inspect}" unless problems.any? { |problem| problem.include?(diagnostic) }
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
unless succeeded
  failures << "manifest reorder changed acquisition publication policy: #{output.lines.first&.strip}"
end

expect_acquisition_failure = lambda do |label, diagnostic, &mutation|
  output, succeeded = run_policy(["tests/media_acquisition_foundation_test.rb"], &mutation)
  failures << "#{label}: acquisition policy unexpectedly passed" if succeeded
  failures << "#{label}: missing failure message #{diagnostic.inspect}" unless output.include?(diagnostic)
  failures << "#{label}: emitted a Ruby stack trace" if output.match?(/\.rb:\d+:in [`']/)
end

storage_path = lambda do |inventory, path|
  inventory.fetch("nas_storage").find { |entry| entry.fetch("path") == path }
end
mutate_compose = lambda do |root, relative_path, &mutation|
  path = File.join(root, relative_path)
  document = YAML.safe_load_file(path, aliases: true)
  mutation.call(document)
  File.write(path, YAML.dump(document))
end

expect_acquisition_failure.call(
  "media acquisition recovery changed",
  "media acquisition storage differs from the exact classified foundation"
) do |root|
  mutate_yaml_file(root, "inventory/group_vars/all/main.yml") do |inventory|
    storage_path.call(inventory, "{{ nas_docker_root }}/radarr/config")["recovery"] = "cache"
  end
end
expect_acquisition_failure.call(
  "media acquisition ownership claimed",
  "media acquisition user/cache paths must not claim ownership"
) do |root|
  mutate_yaml_file(root, "inventory/group_vars/all/main.yml") do |inventory|
    storage_path.call(inventory, "{{ nas_media_root }}/Media/Movies")["owner"] = "{{ nas_uid }}"
  end
end
expect_acquisition_failure.call(
  "media acquisition leaf removed",
  "media acquisition storage differs from the exact classified foundation"
) do |root|
  mutate_yaml_file(root, "inventory/group_vars/all/main.yml") do |inventory|
    inventory.fetch("nas_storage").reject! do |entry|
      entry.fetch("path") == "{{ nas_media_root }}/Media/YouTube"
    end
  end
end
expect_acquisition_failure.call(
  "media acquisition marker removed",
  "media acquisition storage differs from the exact classified foundation"
) do |root|
  mutate_yaml_file(root, "inventory/group_vars/all/main.yml") do |inventory|
    storage_path.call(inventory, "{{ nas_docker_root }}/seerr/config")
                .delete("media_acquisition_foundation")
  end
end

%w[nas_hosts mac_hosts].product(%w[media_usenet_enabled media_torrent_enabled]).each do |host_group, flag|
  expect_acquisition_failure.call("#{host_group} #{flag} enabled", "#{flag} must be literal false") do |root|
    mutate_yaml_file(root, "inventory/group_vars/#{host_group}/main.yml") do |vars|
      vars[flag] = true
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
  "host preparation must create the derived bridge media control network"
) do |root|
  mutate_yaml_file(root, "roles/host_prep/tasks/main.yml") do |tasks|
    task = tasks.find { |entry| entry["name"] == "Create the media control network" }
    task.fetch("community.docker.docker_network")["driver"] = "overlay"
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
  "recursive media state ownership",
  "host preparation must never recursively change storage ownership"
) do |root|
  mutate_yaml_file(root, "roles/host_prep/tasks/main.yml") do |tasks|
    task = tasks.find { |entry| entry["name"] == "Create service state directories" }
    task.fetch("ansible.builtin.file")["recurse"] = true
  end
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

expect_failure(failures, "recreated retired role",
               "retired role directory must be absent") do |root|
  path = File.join(root, "roles", retired_token, "tasks", "main.yml")
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, "---\n[]\n")
end

expect_failure(failures, "current README mention",
               "retired declaration remains: README.md") do |root|
  File.open(File.join(root, "README.md"), "a") { |file| file.puts(retired_token) }
end

expect_failure(failures, "current operator documentation mention",
               "retired declaration remains: docs/adding-a-service.md") do |root|
  File.open(File.join(root, "docs", "adding-a-service.md"), "a") do |file|
    file.puts(retired_token.upcase)
  end
end

expect_failure(failures, "nested current operator documentation mention",
               "retired declaration remains: docs/operator/guide.md") do |root|
  path = File.join(root, "docs", "operator", "guide.md")
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, retired_token)
end

expect_failure(failures, "deceptive migration neighbor",
               "retired declaration remains: scripts/migrate-media-acquisition-vault.py.bak") do |root|
  path = File.join(root, "scripts", "migrate-media-acquisition-vault.py.bak")
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, retired_token)
end

expect_failure(failures, "lone migration file",
               "the temporary encrypted-vault migration audit is incomplete") do |root|
  path = File.join(root, "scripts", "migrate-media-acquisition-vault.py")
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, "#!/usr/bin/env python3\n")
end

expect_failure(failures, "missing validation registration",
               "the temporary encrypted-vault migration audit is incomplete") do |root|
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
               "retired declaration remains: README.md") do |root|
  path = File.join(root, "README.md")
  File.open(path, "a") { |file| file.puts(retired_token) }
  _stdout, stderr, status = capture3_without_git_routing("git", "add", "README.md", chdir: root)
  raise "could not stage tracked README mutation: #{stderr.lines.first&.strip}" unless status.success?
end

expect_failure(failures, "new untracked forbidden source",
               "retired declaration remains: tests/retired-policy.rb") do |root|
  File.write(File.join(root, "tests", "retired-policy.rb"), retired_token)
end

expect_failure(failures, "selected current-source leaf symlink",
               "tests/retired-policy.rb: active source must be a regular file") do |root|
  target = File.join(root, "retired-policy-target")
  File.write(target, retired_token)
  File.symlink(target, File.join(root, "tests", "retired-policy.rb"))
end

expect_failure(failures, "selected current-source symlinked ancestor",
               "tests/operator/guide.rb: active source path must not contain symlinks") do |root|
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

# The harness's own guards come first: if the fixture builder can be talked into
# reading or writing outside the sandbox, nothing below proves anything.
expect_fixture_identity_rejection(
  failures, "traversal service name",
  { "name" => "../../source-sentinel", "role" => "ntfy", "status" => "implemented" }
)
expect_fixture_identity_rejection(
  failures, "traversal role",
  { "name" => "ntfy", "role" => "../../sandbox-sentinel", "status" => "implemented" }
)

expect_failure(failures, "reintroduced legacy source",
               "must not reintroduce a legacy migration source") do |root|
  mutate_manifest(root) do |manifest|
    manifest["legacy_source"] = { "repository" => "example/legacy" }
  end
end

{
  "role" => "wrong_role"
}.each do |field, value|
  expect_failure(failures, "wrong #{field}", "beszel: #{field} must equal") do |root|
    mutate_manifest(root) { |manifest| service(manifest, "beszel")[field] = value }
  end
end

expect_failure(failures, "ntfy downgrade", "ntfy: status must be implemented or accepted") do |root|
  mutate_manifest(root) { |manifest| service(manifest, "ntfy")["status"] = "planned" }
end

expect_failure(failures, "non-string name", "service name must be a string") do |root|
  mutate_manifest(root) { |manifest| manifest.fetch("services").first["name"] = 7 }
end

expect_failure(failures, "heterogeneous services", "each service manifest entry must be a mapping") do |root|
  mutate_manifest(root) { |manifest| manifest.fetch("services")[0] = "audiobookshelf" }
end

expect_failure(failures, "duplicate manifest service", "service manifest name values must be unique") do |root|
  mutate_manifest(root) do |document|
    document.fetch("services") << service(document, "arr").dup
  end
end

expect_failure(failures, "planned service promoted without vault contract",
               "tests/expected/bindery.yml vault_keys must be a nonempty list") do |root|
  mutate_manifest(root) { |document| service(document, "bindery")["status"] = "implemented" }
end

%w[policy_test.rb policy_vault_test.rb].each do |caller|
  expect_failure(failures, "#{caller} substitutes the manifest status mapping",
                 "service statuses must have exactly the rostered service names") do |root|
    path = File.join(root, "tests", caller)
    source = File.read(path)
    expected = "pinned_service_expectations(ROOT, service_statuses)"
    raise "status-aware caller source is absent" unless source.include?(expected)

    File.write(path, source.sub(expected, "pinned_service_expectations(ROOT, {})"))
  end
end

expect_failure(failures, "malformed YAML", "service manifest is malformed") do |root|
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
               "inventory/local.yml must expose nas_hosts as a child of platform_hosts") do |root|
  mutate_yaml_file(root, "inventory/local.yml") { |inventory| inventory.delete("platform_hosts") }
end

expect_failure(failures, "wrong platform child",
               "inventory/local.yml must expose nas_hosts as a child of platform_hosts") do |root|
  mutate_yaml_file(root, "inventory/local.yml") do |inventory|
    inventory.fetch("platform_hosts").fetch("children")["wrong_hosts"] =
      inventory.fetch("platform_hosts").fetch("children").delete("nas_hosts")
  end
end

expect_failure(failures, "missing Mac inventory", "inventory/mac.yml is missing") do |root|
  FileUtils.rm(File.join(root, "inventory", "mac.yml"))
end

expect_failure(failures, "machine fact leaked into shared vars",
               "machine facts must not be all-group variables") do |root|
  mutate_yaml_file(root, "inventory/group_vars/all/main.yml") do |vars|
    vars["nas_docker_root"] = "/leaked"
  end
end

expect_failure(failures, "raw Mac storage root",
               "Mac nas_docker_root must canonicalize PLATFORM_DOCKER_ROOT before export") do |root|
  mutate_yaml_file(root, "inventory/group_vars/mac_hosts/main.yml") do |vars|
    vars["nas_docker_root"] = "{{ lookup('env', 'PLATFORM_DOCKER_ROOT') }}"
  end
end

expect_failure(failures, "missing filter registration",
               "Mac path canonicalization must use the configured physical-path filter") do |root|
  path = File.join(root, "ansible.cfg")
  File.write(path, File.read(path).sub(/^filter_plugins\s*=.*\n/, ""))
end

expect_failure(failures, "nonfunctional physical-path filter",
               "Mac physical-path filter must reject ambiguous or relative paths") do |root|
  path = File.join(root, "filter_plugins", "platform_paths.py")
  source = File.read(path).sub("return os.path.realpath(value)",
                               "return value  # os.path.realpath(value)")
  File.write(path, source)
end

expect_failure(failures, "leading double separator accepted",
               "Mac physical-path filter must reject ambiguous or relative paths") do |root|
  path = File.join(root, "filter_plugins", "platform_paths.py")
  source = File.read(path).sub(" or value.startswith(os.sep * 2)", "")
  File.write(path, source)
end

expect_failure(failures, "missing Mac path fixture wiring",
               "integration must prove canonical Mac paths pass target validation") do |root|
  path = File.join(root, "tests", "integration.sh")
  source = File.read(path)
    .gsub(/^.*mac_inventory_path_test\.yml.*\n/, "")
    .gsub(/^.*MAC_PATH_(?:CANONICAL|LEXICAL_REFUSED).*\n/, "")
  File.write(path, source)
end

expect_failure(failures, "missing host capability", "must define platform_beszel_agent_available") do |root|
  mutate_yaml_file(root, "inventory/group_vars/mac_hosts/main.yml") do |vars|
    vars.delete("platform_beszel_agent_available")
  end
end

expect_failure(failures, "wrong capability type",
               "platform_render_device_available must be boolean") do |root|
  mutate_yaml_file(root, "inventory/group_vars/mac_hosts/main.yml") do |vars|
    vars["platform_render_device_available"] = "false"
  end
end

expect_failure(failures, "invalid production platform kind", "platform_kind must be mac") do |root|
  mutate_yaml_file(root, "inventory/group_vars/mac_hosts/main.yml") do |vars|
    vars["platform_kind"] = "integration"
  end
end

expect_failure(failures, "removed NAS mount guard",
               "preflight must check mounts by command exit status, including in check mode") do |root|
  mutate_yaml_file(root, "roles/preflight/tasks/main.yml") do |tasks|
    tasks.find { |task| task["name"] == "Require the NAS volumes to be mounted" }.delete("when")
  end
end

expect_failure(failures, "weakened GPU device proof",
               "GPU availability must require declared capability and an existing character device") do |root|
  mutate_yaml_file(root, "roles/preflight/tasks/gpu.yml") do |tasks|
    task = tasks.find { |entry| entry["name"] == "Record whether hardware acceleration is available" }
    task.fetch("ansible.builtin.set_fact")["preflight_gpu_available"] =
      "{{ platform_render_device_available and preflight_render_device.stat.exists }}"
  end
end

expect_failure(failures, "weakened platform kind choices",
               "deployment bundle platform_kind must allow only nas or mac") do |root|
  mutate_yaml_file(root, "roles/deployment_bundle/meta/argument_specs.yml") do |spec|
    spec.dig("argument_specs", "main", "options", "platform_kind").delete("choices")
  end
end

expect_failure(failures, "test mode defaults enabled",
               "deployment bundle test mode must be an explicit false boolean option") do |root|
  mutate_yaml_file(root, "roles/deployment_bundle/meta/argument_specs.yml") do |spec|
    spec.dig("argument_specs", "main", "options", "deployment_bundle_test_mode")["default"] = true
  end
end

expect_failure(failures, "weakened dirty bypass guard",
               "dirty controller bypass must require explicit integration Compose test mode") do |root|
  mutate_yaml_file(root, "roles/deployment_bundle/tasks/controller.yml") do |tasks|
    task = tasks.find { |entry| entry["name"] == "Restrict dirty controller bypass to integration" }
    task.fetch("ansible.builtin.assert")["that"] = [
      "not deployment_bundle_allow_dirty_controller or platform_compose_kind == 'integration'"
    ]
  end
end

expect_failure(failures, "weakened Compose override guard",
               "Compose override selection must require explicit test mode") do |root|
  mutate_yaml_file(root, "roles/deployment_bundle/tasks/controller.yml") do |tasks|
    task = tasks.find do |entry|
      entry["name"] == "Restrict Compose override selection to explicit test mode"
    end
    task.fetch("ansible.builtin.assert")["that"] = ["platform_kind in ['nas', 'mac']"]
  end
end

expect_failure(failures, "missing ntfy Compose interface",
               "ntfy argument specs must require platform_compose_kind") do |root|
  mutate_yaml_file(root, "roles/ntfy/meta/argument_specs.yml") do |spec|
    spec.dig("argument_specs", "main", "options").delete("platform_compose_kind")
  end
end

expect_failure(failures, "missing Beszel render interface",
               "Beszel argument specs must require platform_render_device_path") do |root|
  mutate_yaml_file(root, "roles/beszel/meta/argument_specs.yml") do |spec|
    spec.dig("argument_specs", "main", "options").delete("platform_render_device_path")
  end
end


expect_failure(failures, "missing Beszel Compose interface",
               "beszel argument specs must require platform_compose_kind") do |root|
  mutate_yaml_file(root, "roles/beszel/meta/argument_specs.yml") do |spec|
    spec.dig("argument_specs", "main", "options").delete("platform_compose_kind")
  end
end

expect_failure(failures, "Mac storage claims Linux ownership",
               "host preparation must restrict Linux ownership to the explicit integration capability") do |root|
  mutate_yaml_file(root, "roles/host_prep/tasks/main.yml") do |tasks|
    task = tasks.find { |entry| entry["name"] == "Create service state directories" }
    task.fetch("ansible.builtin.file")["owner"] = "{{ item.owner | default(omit) }}"
  end
end

expect_failure(failures, "preservation-only storage inspected after creation",
               "host preparation must validate preservation-only storage before ordinary creation") do |root|
  mutate_yaml_file(root, "roles/host_prep/tasks/main.yml") do |tasks|
    inspect = tasks.delete_at(tasks.index do |task|
      task["name"] == "Inspect preservation-only service state directories"
    end)
    create_index = tasks.index { |task| task["name"] == "Create service state directories" }
    tasks.insert(create_index + 1, inspect)
  end
end

expect_failure(failures, "preservation-only storage follows symlinks",
               "host preparation must inspect preservation-only storage without following symlinks") do |root|
  mutate_yaml_file(root, "roles/host_prep/tasks/main.yml") do |tasks|
    task = tasks.find do |entry|
      entry["name"] == "Inspect preservation-only service state directories"
    end
    task.fetch("ansible.builtin.stat")["follow"] = true
  end
end

expect_failure(failures, "preservation-only directory refusal removed",
               "host preparation must refuse missing, non-directory, or symlink preservation-only storage") do |root|
  mutate_yaml_file(root, "roles/host_prep/tasks/main.yml") do |tasks|
    task = tasks.find do |entry|
      entry["name"] == "Require safe preservation-only service state directories"
    end
    task.fetch("ansible.builtin.assert").fetch("that").delete("not item.stat.islnk")
  end
end

expect_failure(failures, "preservation-only storage recreated",
               "ordinary storage creation must include unmarked entries and exclude preservation-only storage") do |root|
  mutate_yaml_file(root, "roles/host_prep/tasks/main.yml") do |tasks|
    task = tasks.find { |entry| entry["name"] == "Create service state directories" }
    task["loop"] = "{{ nas_storage }}"
  end
end

expect_failure(failures, "unfiltered Beszel settings readback",
               "collection readback must use a URL-encoded identity filter with totals") do |root|
  mutate_yaml_file(root, "roles/beszel/tasks/main.yml") do |tasks|
    task = flatten_fixture_tasks(tasks).find do |entry|
      entry["name"] == "Refresh notification settings after reconciliation"
    end
    uri = task.fetch("ansible.builtin.uri")
    uri["url"] = uri.fetch("url").sub(" | urlencode", "")
  end
end

expect_failure(failures, "silent Beszel user creation",
               "Beszel user creation must report real and check-mode predicted changes") do |root|
  mutate_yaml_file(root, "roles/beszel/tasks/main.yml") do |tasks|
    task = flatten_fixture_tasks(tasks).find do |entry|
      entry["name"] == "Create the application user"
    end
    task["changed_when"] = false
  end
end

expect_failure(failures, "unredacted Beszel webhook summary",
               "Beszel webhook mismatch diagnostics must never include URL bodies") do |root|
  mutate_yaml_file(root, "roles/beszel/tasks/main.yml") do |tasks|
    task = flatten_fixture_tasks(tasks).find do |entry|
      entry["name"] == "Summarize the managed ntfy webhook without URL bodies"
    end
    task["no_log"] = false
  end
end

expect_failure(failures, "missing Beszel system ownership guard",
               "Beszel must reject same-name systems outside the managed user relation") do |root|
  path = File.join(root, "roles", "beszel", "tasks", "main.yml")
  body = File.read(path).sub(
    "Refuse same-name systems outside the managed user relation",
    "Bypass same-name systems outside the managed user relation"
  )
  File.write(path, body)
end

expect_failure(failures, "unencoded Beszel contract filters",
               "Beszel contract must use complete encoded identity filters and enforce system ownership") do |root|
  path = File.join(root, "tests", "contracts", "beszel.sh")
  File.write(path, File.read(path).gsub("URI.encode_www_form", "removed_form_encoding"))
end

{
  "duplicate top-level key" => ["\nservices: []\n", "services"],
  "duplicate service name key" => ["    name: duplicate\n", "name"],
  "duplicate service key" => ["    role: duplicate\n", "role"]
}.each do |label, (insertion, key)|
  expect_failure(failures, label, "service manifest contains duplicate mapping key #{key}") do |root|
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

expect_failure(failures, "CI bypasses policy entrypoint", "CI must run tests/validate-policy.sh") do |root|
  path = File.join(root, ".github", "workflows", "ci.yml")
  File.write(path, File.read(path).sub("tests/validate-policy.sh", "ruby tests/policy_test.rb"))
end

expect_failure(failures, "integration omits contract execution", "integration must execute registered contracts") do |root|
  path = File.join(root, "tests", "integration.sh")
  File.write(path, File.read(path).sub(/^\s*ruby \/repo\/tests\/run_contracts\.rb --execute\n/, ""))
end

expect_failure(failures, "integration omits contract ABI", "integration must set the contract environment ABI") do |root|
  path = File.join(root, "tests", "integration.sh")
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

expect_failure(failures, "arbitrary provisioning uri", "ntfy: implemented service has no automated verification") do |root|
  File.write(File.join(root, "roles", "ntfy", "tasks", "main.yml"), provisioning_task)
end

{
  "tagged unrelated uri" => <<~YAML,
    ---
    - name: Verify an unrelated endpoint
      tags: [platform_verify_ntfy]
      ansible.builtin.uri:
        url: http://127.0.0.1/unrelated/
  YAML
  "tagged uri body mention" => <<~YAML,
    ---
    - name: Verify an unrelated endpoint with service text
      tags: [platform_verify_ntfy]
      ansible.builtin.uri:
        url: http://127.0.0.1/unrelated/
        body: ntfy
        status_code: [200]
  YAML
  "tagged literal assertion" => <<~YAML,
    ---
    - name: Verify a literal
      tags: [platform_verify_ntfy]
      ansible.builtin.assert:
        that: [true]
  YAML
  "tagged constant service assertion" => <<~YAML,
    ---
    - name: Verify a constant expression
      tags: [platform_verify_ntfy]
      ansible.builtin.assert:
        that: ["'ntfy' == 'ntfy'"]
  YAML
  "tagged undefined service assertion" => <<~YAML,
    ---
    - name: Verify an undefined result
      tags: [platform_verify_ntfy]
      ansible.builtin.assert:
        that: ["ntfy_missing_result.status == 200"]
  YAML
  "tagged true command" => <<~YAML,
    ---
    - name: Verify a no-op command
      tags: [platform_verify_ntfy]
      ansible.builtin.command: /bin/true
  YAML
  "tagged service command" => <<~YAML,
    ---
    - name: Verify command output
      tags: [platform_verify_ntfy]
      ansible.builtin.command: echo ntfy
  YAML
  "assert from command register" => <<~YAML,
    ---
    - name: Produce a fake result
      ansible.builtin.command: echo ntfy
      register: ntfy_result
    - name: Verify fake result
      tags: [platform_verify_ntfy]
      ansible.builtin.assert:
        that: ["ntfy_result.stdout == 'ntfy'"]
  YAML
  "assert self comparison" => <<~YAML
    ---
    - name: Probe ntfy
      ansible.builtin.uri:
        url: http://127.0.0.1/{{ ntfy_port }}/health
        status_code: [200]
      register: ntfy_result
    - name: Verify a tautology
      tags: [platform_verify_ntfy]
      ansible.builtin.assert:
        that: ["ntfy_result.status == ntfy_result.status"]
  YAML
}.each do |label, tasks|
  expect_failure(failures, label, "ntfy: implemented service has no automated verification") do |root|
    File.write(File.join(root, "roles", "ntfy", "tasks", "main.yml"), tasks)
  end
end

expect_success(failures, "assert from registered URI result") do |root|
  File.write(File.join(root, "roles", "ntfy", "tasks", "main.yml"), <<~YAML)
    ---
    - name: Probe ntfy
      ansible.builtin.uri:
        url: http://127.0.0.1/{{ ntfy_port }}/health
        status_code: [200]
      register: ntfy_result
    - name: Verify the observed status
      tags: [platform_verify_ntfy]
      ansible.builtin.assert:
        that: ["ntfy_result.status == 200"]
  YAML
end

expect_failure(failures, "wrong contract path", "ntfy: implemented service has no automated verification") do |root|
  File.write(File.join(root, "roles", "ntfy", "tasks", "main.yml"), provisioning_task)
  contract = File.join(root, "services", "ntfy", "contract.yml")
  File.write(contract, "#!/bin/sh\nexit 1\n")
  File.chmod(0o755, contract)
end

expect_failure(failures, "empty contract", "ntfy: implemented service has no automated verification") do |root|
  File.write(File.join(root, "roles", "ntfy", "tasks", "main.yml"), provisioning_task)
  contract = File.join(root, "tests", "contracts", "ntfy.sh")
  FileUtils.mkdir_p(File.dirname(contract))
  File.write(contract, "")
  File.chmod(0o755, contract)
end

{
  "echo test" => "#!/bin/sh\necho test\n",
  "exit one" => "#!/bin/sh\nexit 1\n",
  "standalone false" => "#!/bin/sh\nfalse\n"
}.each do |label, body|
  expect_failure(failures, label, "ntfy: implemented service has no automated verification") do |root|
    File.write(File.join(root, "roles", "ntfy", "tasks", "main.yml"), provisioning_task)
    write_contract(root, "ntfy", body)
  end
end

expect_success(failures, "nested verification task") do |root|
  File.write(File.join(root, "roles", "ntfy", "tasks", "main.yml"), <<~YAML)
    ---
    - name: Group verification tasks
      block:
        - name: Verify the application endpoint
          tags: [platform_verify_ntfy]
          ansible.builtin.uri:
            url: http://127.0.0.1/{{ ntfy_port }}/v1/health
            status_code: [200]
  YAML
end

expect_success(failures, "registered variable contract") do |root|
  File.write(File.join(root, "roles", "ntfy", "tasks", "main.yml"), provisioning_task)
  write_contract(root, "ntfy", <<~'SH')
    #!/bin/sh
    endpoint=http://127.0.0.1/ntfy/health
    probe() {
      curl --fail "$endpoint"
    }
    probe
  SH
  register_contract(root, "ntfy")
end

expect_failure(failures, "unregistered contract", "ntfy: implemented service has no automated verification") do |root|
  File.write(File.join(root, "roles", "ntfy", "tasks", "main.yml"), provisioning_task)
  write_contract(root, "ntfy", "#!/bin/sh\nendpoint=/ntfy/health\ncurl --fail \"$endpoint\"\n")
end

{
  "assignment registration spoof" => ["tests/integration.sh", "contract=tests/contracts/ntfy.sh\n"],
  "echo registration spoof" => ["tests/integration.sh", "echo tests/contracts/ntfy.sh\n"],
  "YAML name registration spoof" => [".github/workflows/ci.yml", "\nname: tests/contracts/ntfy.sh\n"]
}.each do |label, (relative_harness, registration)|
  expect_failure(failures, label, "ntfy: implemented service has no automated verification") do |root|
    File.write(File.join(root, "roles", "ntfy", "tasks", "main.yml"), provisioning_task)
    write_contract(root, "ntfy", "#!/bin/sh\ntrue\n")
    harness = File.join(root, relative_harness)
    File.open(harness, "a") { |file| file.write(registration) }
  end
end

expect_failure(failures, "contract syntax error", "ntfy: implemented service has no automated verification") do |root|
  File.write(File.join(root, "roles", "ntfy", "tasks", "main.yml"), provisioning_task)
  write_contract(root, "ntfy", "#!/bin/sh\nif then\ncurl --fail http://127.0.0.1/ntfy\n")
  register_contract(root, "ntfy")
end

expect_failure(failures, "symlink contract", "ntfy: implemented service has no automated verification") do |root|
  File.write(File.join(root, "roles", "ntfy", "tasks", "main.yml"), provisioning_task)
  contracts = File.join(root, "tests", "contracts")
  FileUtils.mkdir_p(contracts)
  target = File.join(contracts, "shared.sh")
  File.write(target, "#!/bin/sh\ntrue\n")
  File.chmod(0o755, target)
  File.symlink("shared.sh", File.join(contracts, "ntfy.sh"))
  register_contract(root, "ntfy")
end

expect_success(failures, "paperless contract alias") do |root|
  implement_paperless(root)
  register_contract(root, "paperless")
end

expect_failure(failures, "paperless service-name contract", "paperless-ngx: implemented service has no automated verification") do |root|
  implement_paperless(root)
  write_contract(root, "paperless-ngx", <<~'SH')
    #!/bin/sh
    response=$(curl --silent http://127.0.0.1/paperless/api/)
    test -n "$response"
  SH
  register_contract(root, "paperless-ngx")
end

expect_failure(failures, "symlink compose", "ntfy: compose.yml must be a regular file within its service root") do |root|
  path = File.join(root, "services", "ntfy", "compose.yml")
  File.unlink(path)
  File.symlink("../beszel/compose.yml", path)
end

expect_failure(failures, "symlink role directory", "ntfy: role must be a real directory within roles") do |root|
  path = File.join(root, "roles", "ntfy")
  FileUtils.rm_r(path)
  File.symlink("beszel", path)
end

expect_failure(failures, "symlink role meta", "ntfy: argument_specs.yml must be a regular file within its role root") do |root|
  path = File.join(root, "roles", "ntfy", "meta", "argument_specs.yml")
  File.unlink(path)
  File.symlink("../../beszel/meta/argument_specs.yml", path)
end

expect_failure(failures, "symlink role tasks", "ntfy: tasks/main.yml must be a regular file within its role root") do |root|
  path = File.join(root, "roles", "ntfy", "tasks", "main.yml")
  File.unlink(path)
  File.symlink("../../beszel/tasks/main.yml", path)
end

expect_failure(failures, "dirty controller enabled by default",
               "deployment bundle must refuse dirty controller sources by default") do |root|
  path = File.join(root, "roles", "deployment_bundle", "defaults", "main.yml")
  defaults = YAML.safe_load_file(path)
  defaults["deployment_bundle_allow_dirty_controller"] = true
  File.write(path, YAML.dump(defaults))
end

expect_failure(failures, "untracked controller inspection removed",
               "deployment bundle must inspect the whole tracked and untracked controller checkout") do |root|
  path = File.join(root, "roles", "deployment_bundle", "tasks", "controller.yml")
  tasks = File.read(path).sub("      - --untracked-files=all\n", "")
  File.write(path, tasks)
end

expect_failure(failures, "controller inspection narrowed by pathspec",
               "deployment bundle must inspect the whole tracked and untracked controller checkout") do |root|
  path = File.join(root, "roles", "deployment_bundle", "tasks", "controller.yml")
  tasks = File.read(path).sub(
    "      - --untracked-files=all\n",
    "      - --untracked-files=all\n      - --\n      - services\n"
  )
  File.write(path, tasks)
end

expect_failure(failures, "dirty refusal made run once",
               "dirty controller refusal must be evaluated independently for every target host") do |root|
  path = File.join(root, "roles", "deployment_bundle", "tasks", "controller.yml")
  tasks = File.read(path).sub(
    "- name: Require committed controller bundle sources\n",
    "- name: Require committed controller bundle sources\n  run_once: true\n"
  )
  File.write(path, tasks)
end

expect_failure(failures, "fresh-root probe regressed to deployment root",
               "fresh-install preflight must probe the existing validated nas_docker_root") do |root|
  path = File.join(root, "roles", "preflight", "tasks", "main.yml")
  tasks = File.read(path).gsub(
    "{{ nas_docker_root }}/.nas-platform-preflight-probe",
    "{{ platform_deploy_root }}/.preflight-probe"
  )
  File.write(path, tasks)
end

expect_failure(failures, "release mode comparison removed",
               "immutable release comparison must include stat.S_IMODE") do |root|
  path = File.join(root, "roles", "deployment_bundle", "files", "compare_release_trees.py")
  File.write(path, File.read(path).gsub("stat.S_IMODE", "stat.filemode"))
end

expect_failure(failures, "controller input canonical containment removed",
               "controller input validator must use os.path.realpath") do |root|
  path = File.join(root, "roles", "deployment_bundle", "files", "validate_controller_input.py")
  File.write(path, File.read(path).gsub("os.path.realpath", "os.path.normpath"))
end

expect_failure(failures, "controller input validator unreferenced",
               "controller input task must execute the exact extracted validator source") do |root|
  path = File.join(root, "roles", "deployment_bundle", "tasks", "controller_input.yml")
  File.write(path, File.read(path).gsub("files/validate_controller_input.py",
                                        "files/validate_target.py"))
end

expect_failure(failures, "release comparison script unreferenced",
               "deployment bundle must compare releases with the tracked comparison script") do |root|
  path = File.join(root, "roles", "deployment_bundle", "tasks", "main.yml")
  File.write(path, File.read(path).gsub("files/compare_release_trees.py",
                                        "files/validate_target.py"))
end

expect_failure(failures, "Immich classifier controller validation removed",
               "controller inputs must validate every tracked runtime helper") do |root|
  path = File.join(root, "roles", "deployment_bundle", "tasks", "inputs.yml")
  File.write(path, File.read(path).gsub(
    "services/immich/classify_restore.py", "services/immich/missing.py"
  ))
end

expect_failure(failures, "Immich classifier release copy removed",
               "deployment bundle must package the exact Immich classifier with mode 0644") do |root|
  path = File.join(root, "roles", "deployment_bundle", "tasks", "main.yml")
  tasks = YAML.safe_load_file(path)
  tasks.reject! do |task|
    task["name"] == "Copy the tracked Immich restore classifier from the controller"
  end
  File.write(path, YAML.dump(tasks))
end

expect_failure(failures, "Immich classifier manifest integrity removed",
               "deployment manifest must bind runtime helper paths, modes, and checksums") do |root|
  path = File.join(root, "roles", "deployment_bundle", "templates", "manifest.yml.j2")
  File.write(path, File.read(path).gsub(
    "'immich': ['classify_restore.py']", "'immich': []"
  ))
end

expect_failure(failures, "Immich classifier manifest verifier removed",
               "deployment manifest verifier must reproduce runtime helper integrity") do |root|
  path = File.join(root, "tests", "verify_deployment_manifest.rb")
  File.write(path, File.read(path).gsub(
    '"immich" => ["classify_restore.py"]', '"immich" => []'
  ))
end

expect_failure(failures, "deployment sha unquoted",
               "deployment manifest must quote git_sha as a YAML string") do |root|
  path = File.join(root, "roles", "deployment_bundle", "templates", "manifest.yml.j2")
  File.write(path, File.read(path).gsub("platform_release_id | to_json", "platform_release_id"))
end

expect_failure(failures, "target lstat replaced by following stat",
               "target validator must use os.lstat for symlink-safe canonical containment") do |root|
  path = File.join(root, "roles", "deployment_bundle", "files", "validate_target.py")
  File.write(path, File.read(path).gsub("os.lstat", "os.stat"))
end

expect_failure(failures, "root ancestor walk removed",
               "target validator must lstat every existing ancestor from filesystem root to nas_docker_root") do |root|
  path = File.join(root, "roles", "deployment_bundle", "files", "validate_target.py")
  File.write(path, File.read(path).gsub("root_relative_parts", "unchecked_root_parts"))
end

expect_failure(failures, "target validator lookup replaced",
               "target containment task must execute the exact extracted validator source") do |root|
  path = File.join(root, "roles", "deployment_bundle", "tasks", "target.yml")
  lookup = "{{ lookup('ansible.builtin.file', role_path ~ '/files/validate_target.py') }}"
  File.write(path, File.read(path).gsub(lookup, "{{ 'pass' }}"))
end

expect_failure(failures, "preflight probe leaf unguarded",
               "target validator must guard the exact preflight probe leaf") do |root|
  path = File.join(root, "roles", "deployment_bundle", "tasks", "target.yml")
  body = File.read(path)
                  .gsub("      - \"{{ nas_docker_root }}/.nas-platform-preflight-probe\"\n", "")
                  .gsub("          nas_docker_root ~ '/.nas-platform-preflight-probe',\n", "")
  File.write(path, body)
end

expect_failure(failures, "preflight target validation removed",
               "target containment must be validated before preflight can mutate the target") do |root|
  path = File.join(root, "site.yml")
  site = YAML.safe_load_file(path)
  site.first["pre_tasks"].reject! do |task|
    task.dig("ansible.builtin.include_role", "tasks_from") == "target"
  end
  File.write(path, YAML.dump(site))
end

expect_failure(failures, "manifest component validation removed",
               "deployment bundle must validate manifest service path components") do |root|
  path = File.join(root, "roles", "deployment_bundle", "tasks", "inputs.yml")
  tasks = YAML.safe_load_file(path)
  tasks.reject! do |task|
    task["name"] == "Validate manifest service path components before interpolation"
  end
  File.write(path, YAML.dump(tasks))
end

expect_failure(failures, "platform image merge removed",
               "deployment manifest images must merge canonical and platform Compose services") do |root|
  path = File.join(root, "roles", "deployment_bundle", "templates", "manifest.yml.j2")
  File.write(path, File.read(path).gsub("platform_compose", "override_compose"))
end

expect_failure(failures, "Compose override tag normalization removed",
               "deployment manifest must parse Compose tags without rewriting source text") do |root|
  path = File.join(root, "roles", "deployment_bundle", "templates", "manifest.yml.j2")
  File.write(path, File.read(path).gsub("platform_compose_metadata", "from_yaml"))
end

expect_failure(failures, "Compose metadata unknown-tag rejection removed",
               "Compose metadata loader must allow only exact known tags and fail closed") do |root|
  path = File.join(root, "filter_plugins", "compose_metadata.py")
  File.write(path, File.read(path).gsub("except yaml.YAMLError", "except TypeError"))
end

expect_failure(failures, "Compose metadata behavior tests bypassed",
               "policy validation must execute Compose metadata parser behavior tests") do |root|
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
               "platform image overrides differ from the canonical compose.yml image") do |root|
  path = File.join(root, "services", "beszel", "compose.integration.yml")
  File.write(path, <<~YAML)
    ---
    services:
      agent:
        image: example.invalid/beszel-agent:1@sha256:#{'0' * 64}
  YAML
end

expect_failure(failures, "controller input lstat removed",
               "controller input validator must use os.lstat") do |root|
  path = File.join(root, "roles", "deployment_bundle", "files", "validate_controller_input.py")
  File.write(path, File.read(path).gsub("os.lstat", "os.stat"))
end

expect_failure(failures, "runtime service leaves omitted",
               "target validator must guard every implemented runtime service leaf") do |root|
  path = File.join(root, "roles", "deployment_bundle", "tasks", "target.yml")
  File.write(path, File.read(path).gsub("deployment_bundle_services", "unchecked_services"))
end

expect_failure(failures, "portable vault key omitted",
               "vault-plain.yml.j2 is missing required portable credential vault_immich_db_password") do |root|
  path = File.join(root, "templates", "vault-plain.yml.j2")
  File.write(path, File.read(path).gsub(/^vault_immich_db_password:.*\n/, ""))
end

expect_failure(failures, "NAS coordinate leaked into vault",
               "vault.yml.example has unexpected or non-portable vault key vault_nas_address") do |root|
  path = File.join(root, "inventory", "group_vars", "all", "vault.yml.example")
  File.write(path, File.read(path) + "vault_nas_address: 192.0.2.1\n")
end

expect_failure(failures, "vault validation disclosure",
               "every vault contract task must use no_log") do |root|
  path = File.join(root, "roles", "vault_contract", "tasks", "main.yml")
  tasks = YAML.safe_load_file(path)
  tasks.first.delete("no_log")
  File.write(path, YAML.dump(tasks))
end

# The shape rules moved into filter_plugins/vault_credential_schema.py, so what a
# credential can now lose is its entry in the mapping the role passes to the
# filter rather than a Jinja condition. Dropping the entry is the mutation that
# corresponds to dropping the old condition: the key stops being inspected, and
# nothing else in the role names it.
expect_failure(failures, "vault shape validation omitted",
               "vault contract shape validation must inspect vault_immich_db_password") do |root|
  path = File.join(root, "roles", "vault_contract", "tasks", "main.yml")
  body = File.read(path)
  File.write(path, replace_last(
                     body,
                     "\n          'vault_immich_db_password': vault_immich_db_password,",
                     ""
                   ))
end

expect_failure(failures, "vault checksum moved before encryption guard",
               "vault contract must verify encryption header before computing SHA-256") do |root|
  path = File.join(root, "roles", "vault_contract", "tasks", "main.yml")
  tasks = YAML.safe_load_file(path)
  checksum_index = tasks.index do |task|
    task["name"] == "Compute the encrypted vault artifact SHA-256"
  end
  guard_index = tasks.index do |task|
    task["name"] == "Require the reported vault artifact to be encrypted"
  end
  checksum_task = tasks.delete_at(checksum_index)
  tasks.insert(guard_index, checksum_task)
  File.write(path, YAML.dump(tasks))
end

[
  "Generate passwords",
  "Read the Beszel hub keypair",
  "Hash the ntfy passwords with ntfy's own hasher",
  "Generate the ntfy access tokens with ntfy's own generator",
  "Collect the generated material",
  "Fail loudly if any value did not parse",
  "Write the plaintext vars file for encryption"
].each do |task_name|
  expect_failure(failures, "generator redaction removed from #{task_name}",
                 "generate-secrets.yml must redact secret-bearing task #{task_name}") do |root|
    path = File.join(root, "generate-secrets.yml")
    play = YAML.safe_load_file(path).first
    task = play.fetch("tasks").find { |entry| entry["name"] == task_name }
    task.delete("no_log")
    File.write(path, YAML.dump([play]))
  end
end

expect_failure(failures, "ephemeral self-test silence check removed from CI",
               "CI must run the silent ephemeral vault self-test with explicit dependencies") do |root|
  path = File.join(root, ".github", "workflows", "ci.yml")
  File.write(path, File.read(path).gsub("test ! -s", "true"))
end

expect_failure(failures, "ephemeral dependency removed from CI",
               "CI must run the silent ephemeral vault self-test with explicit dependencies") do |root|
  path = File.join(root, ".github", "workflows", "ci.yml")
  File.write(path, File.read(path).gsub("apache2-utils", "removed-dependency"))
end

expect_failure(failures, "ephemeral self-test removed from CI",
               "CI must run the silent ephemeral vault self-test with explicit dependencies") do |root|
  path = File.join(root, ".github", "workflows", "ci.yml")
  File.write(path, File.read(path).gsub("tests/generate-ephemeral-vault.sh --self-test", "true"))
end

expect_failure(failures, "generator redaction test removed from CI",
               "CI must execute the generated-secret redaction test") do |root|
  path = File.join(root, ".github", "workflows", "ci.yml")
  File.write(path, File.read(path).gsub("tests/generate-secrets-redaction-test.sh", "true"))
end

expect_failure(failures, "integration ephemeral helper bypassed",
               "integration must consume the ephemeral encrypted vault without duplicate secret authoring") do |root|
  path = File.join(root, "tests", "integration.sh")
  File.write(path, File.read(path).sub('--output \"\$vault_file\"', "--output-bypassed"))
end

expect_failure(failures, "integration ephemeral cleanup context removed",
               "integration must consume the ephemeral encrypted vault without duplicate secret authoring") do |root|
  path = File.join(root, "tests", "integration.sh")
  File.write(path, File.read(path).sub("TMPDIR='$sandbox' /repo/tests/generate-ephemeral-vault.sh --cleanup",
                                      "/repo/tests/generate-ephemeral-vault.sh --cleanup"))
end

expect_failure(failures, "integration lock acquisition removed",
               "integration must serialize fixed-name containers with an atomic empty-directory lock") do |root|
  path = File.join(root, "tests", "integration.sh")
  File.write(path, File.read(path).sub("acquire_integration_lock", "bypass_integration_lock"))
end

expect_failure(failures, "integration lock made non-atomic",
               "integration must serialize fixed-name containers with an atomic empty-directory lock") do |root|
  path = File.join(root, "tests", "integration_lock.sh")
  File.write(path, File.read(path).sub('mkdir "$lock_candidate"', "true"))
end

{
  "vault password file" => '--vault-password-file \"\$vault_password_file\"',
  "encrypted vars input" => '-e @\"\$vault_file\"',
  "encrypted artifact path" => '-e platform_vault_file=\"\$vault_file\"',
  "contract vault ABI" => 'PLATFORM_CONTRACT_VAULT_FILE=\"\$vault_file\"'
}.each do |property, source|
  expect_failure(failures, "integration #{property} removed",
                 "integration must consume the ephemeral encrypted vault without duplicate secret authoring") do |root|
    path = File.join(root, "tests", "integration.sh")
    body = File.read(path)
    mutated = if property == "contract vault ABI"
                replace_last(body, source, "removed-integration-vault-binding")
              else
                body.sub(source, "removed-integration-vault-binding")
              end
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
                 "ephemeral vault self-test must cover #{property}") do |root|
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
  "failure cleanup trap" => 'trap \'rm -f -- "$plain" "$private_key" "$private_key.pub" "$password_file" "$output"\' EXIT',
  "self-test cleanup trap" => "trap self_test_cleanup_on_exit EXIT"
}.each do |property, source|
  expect_failure(failures, "ephemeral #{property} removed",
                 "ephemeral vault helper must preserve #{property}") do |root|
    path = File.join(root, "tests", "generate-ephemeral-vault.sh")
    File.write(path, File.read(path).sub(source, "removed-helper-guard"))
  end
end

expect_failure(failures, "Mac lifecycle keep-on-failure option removed",
               "Mac proof harness must accept --keep-on-failure") do |root|
  path = File.join(root, "tests", "mac", "run.sh")
  File.write(path, File.read(path).gsub("--keep-on-failure", "removed-keep-on-failure"))
end

expect_failure(failures, "Mac log sanitizer self-test removed",
               "validate-policy.sh must run ruby tests/mac/sanitize-logs.rb --self-test") do |root|
  path = File.join(root, "tests", "validate-policy.sh")
  File.write(path, File.read(path).gsub("ruby tests/mac/sanitize-logs.rb --self-test", "true"))
end

expect_failure(failures, "Mac report self-test removed",
               "validate-policy.sh must run ruby tests/mac/report.rb --self-test") do |root|
  path = File.join(root, "tests", "validate-policy.sh")
  File.write(path, File.read(path).gsub("ruby tests/mac/report.rb --self-test", "true"))
end

expect_failure(failures, "Mac cleanup self-test removed",
               "validate-policy.sh must run tests/mac/cleanup.sh --self-test") do |root|
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
  "Paperless mail reconciliation regression" => "ruby tests/paperless_mail_reconciliation_test.rb",
  "Immich selective helper integrity regression" =>
    "ruby tests/immich_selective_helper_integrity_test.rb",
  "Mac manual-validation runner regression" => "tests/mac/manual-validation-runner-test.sh",
  "Mac hook coverage regression" => "tests/mac/hook-coverage-test.sh",
  "Paperless snapshot recovery regression" => "tests/mac/snapshot-paperless-recovery-test.sh",
  "Paperless drill login budget regression" =>
    "tests/mac/snapshot-paperless-drill-throttle-test.sh"
}.each do |name, command|
  expect_failure(failures, "#{name} removed from policy validation",
                 "validate-policy.sh must run #{command}") do |root|
    path = File.join(root, "tests", "validate-policy.sh")
    File.write(path, File.read(path).lines.reject { |line| line.strip == command }.join)
  end
end

{
  "production auto-deploy poller suite" =>
    'PYTHONDONTWRITEBYTECODE=1 "$ansible_python" -m unittest -v tests.production_auto_deploy_test',
  "production auto-deploy installer suite" =>
    "ruby tests/production_auto_deploy_role_test.rb"
}.each do |name, command|
  expect_failure(failures, "#{name} removed from policy validation",
                 "validate-policy.sh must run the #{name} exactly once") do |root|
    path = File.join(root, "tests", "validate-policy.sh")
    File.write(path, File.read(path).lines.reject { |line| line.strip == command }.join)
  end
end

expect_failure(failures, "production auto-deploy installer syntax check removed",
               "CI must syntax-check install-production-auto-deploy.yml") do |root|
  path = File.join(root, ".github", "workflows", "ci.yml")
  File.write(path, File.read(path).lines.reject do |line|
    line.strip == "ansible-playbook -i inventory/local.yml install-production-auto-deploy.yml --syntax-check"
  end.join)
end

expect_failure(failures, "Mac raw log body retained",
               "Mac log sanitizer self-test must pass without raw values") do |root|
  path = File.join(root, "tests", "mac", "sanitize-logs.rb")
  leaked_body = 'line.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "")'
  File.write(path, File.read(path).sub('"message" => REDACTION', "\"message\" => #{leaked_body}"))
end

# The per-service expectations moved out of policy_test.rb into one file each, so the
# properties that used to be protected by Ruby's own load-time errors now need stating:
# a deleted file must not read as a service with nothing to check, and a value that
# drifts from the Compose file must still be caught from its new home.
expect_failure(failures, "pinned service expectations deleted",
               "pinned service expectations are missing: tests/expected/komga.yml") do |root|
  FileUtils.rm(File.join(root, "tests", "expected", "komga.yml"))
end

expect_failure(failures, "pinned expectations for an unrostered service",
               "tests/expected must hold exactly one file per rostered service") do |root|
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
               "jellyfin/jellyfin: CPU ceiling must match the pinned service policy") do |root|
  mutate_yaml_file(root, "tests/expected/jellyfin.yml") do |expectation|
    expectation["container_cpus"]["jellyfin"] = 9.9
  end
end

expect_failure(failures, "pinned CPU ceiling is not a number",
               "tests/expected/jellyfin.yml container_cpus.jellyfin must be numeric") do |root|
  mutate_yaml_file(root, "tests/expected/jellyfin.yml") do |expectation|
    expectation["container_cpus"]["jellyfin"] = "3.O"
  end
end

expect_failure(failures, "pinned vault key dropped",
               "vault key vault_jellyfin_opensubtitles_password") do |root|
  mutate_yaml_file(root, "tests/expected/jellyfin.yml") do |expectation|
    expectation["vault_keys"].delete("vault_jellyfin_opensubtitles_password")
  end
end

expect_failure(failures, "pinned role drifts from the manifest",
               "jellyfin: role must equal") do |root|
  mutate_yaml_file(root, "tests/expected/jellyfin.yml") do |expectation|
    expectation["role"] = "jellyfin_wrong"
  end
end

expect_failure(failures, "pinned expectations gain an unknown field",
               "tests/expected/komga.yml must define exactly") do |root|
  mutate_yaml_file(root, "tests/expected/komga.yml") { |e| e["unexpected"] = true }
end

# The media library path is written once in a service template and once in
# nas_storage, and Compose passes the template's copy through as a bind source.
# Nothing used to compare the two, so these mutations are what keep the new
# comparison honest: a rename on either side has to be reported, and the one
# relaxation the comparison makes has to be earned rather than blanket.
expect_failure(failures, "service template mounts an undeclared library",
               "roles/komga/templates/env.j2: {{ nas_media_root }}/Comics is not declared in nas_storage") do |root|
  path = File.join(root, "roles", "komga", "templates", "env.j2")
  File.write(path, File.read(path).sub(
    "KOMGA_LIBRARY_PATH={{ nas_media_root }}/Books",
    "KOMGA_LIBRARY_PATH={{ nas_media_root }}/Comics"
  ))
end

# Jellyfin mounts the media tree itself, which nas_storage never declares as an
# entry of its own: it is accepted only because the libraries beneath it are
# declared and host_prep creates it as their parent. Removing those leaves must
# therefore stop the parent mount being accepted, or the relaxation would be a
# blanket pass for any path with a declared entry somewhere below it.
expect_failure(failures, "media library leaves removed from storage",
               "roles/jellyfin/templates/env.j2: {{ nas_media_root }}/Media is not declared in nas_storage") do |root|
  mutate_yaml_file(root, "inventory/group_vars/all/main.yml") do |inventory|
    inventory.fetch("nas_storage").reject! do |entry|
      entry.fetch("path").start_with?("{{ nas_media_root }}/Media/")
    end
  end
end

expect_failure(failures, "media Compose bind source undeclared",
               "immich/immich-server: ${NAS_MEDIA_ROOT:?}/Immich is not declared in nas_storage") do |root|
  mutate_yaml_file(root, "inventory/group_vars/all/main.yml") do |inventory|
    entry = inventory.fetch("nas_storage").find { |item| item.fetch("path") == "{{ nas_media_root }}/Immich" }
    entry["path"] = "{{ nas_media_root }}/Immich-renamed"
  end
end

if failures.empty?
  puts "policy manifest: all mutation checks hold"
else
  failures.each { |failure| warn "FAIL #{failure}" }
  abort "#{failures.length} policy manifest regression(s)"
end
