#!/usr/bin/env ruby
# frozen_string_literal: true

# Reconciliation behaviour for application, download-client and indexer.
# Shared fixtures live in media_acquisition_reconciliation_support.rb.

require_relative "media_acquisition_reconciliation_support"

failures = []
failures = []
CONFIGARR_QUALITY_DEFINITION_SOURCES.each do |service, path|
  failures << "Configarr #{service} pinned quality-definition source differs" unless
    Digest::SHA256.file(path).hexdigest == CONFIGARR_QUALITY_DEFINITION_SHA256.fetch(service)
end

Dir.mktmpdir("media-acquisition-ansible-resolution-") do |temporary|
  path_bin = File.join(temporary, "path-bin")
  FileUtils.mkdir_p(path_bin)
  path_ansible = File.join(path_bin, "ansible-playbook")
  File.write(path_ansible, "#!/bin/sh\nexit 0\n", mode: "w", perm: 0o700)
  failures << "PATH-first Ansible resolver ignored an executable ansible-playbook" unless
    resolve_ansible_playbook(path: path_bin) == path_ansible

  normal_root = File.join(temporary, "normal-repository")
  FileUtils.mkdir_p(normal_root)
  _output, git_status = Open3.capture2("git", "init", "-q", normal_root)
  if git_status.success?
    fallback = File.join(normal_root, ".venv", "bin", "ansible-playbook")
    FileUtils.mkdir_p(File.dirname(fallback))
    File.write(fallback, "#!/bin/sh\nexit 0\n", mode: "w", perm: 0o700)
    failures << "normal-layout Ansible fallback did not follow the Git common directory" unless
      resolve_ansible_playbook(root: normal_root, path: "") == fallback
  else
    failures << "HARNESS normal-layout Ansible resolver simulation could not initialize Git"
  end
end
failures << "current-worktree Ansible resolution is not executable" unless
  File.executable?(ANSIBLE_PLAYBOOK)

deadline_probe = capture_process(
  {}, RbConfig.ruby, "-e", "sleep 30", chdir: ROOT, timeout: 0.1
)
unless deadline_probe.fetch("timed_out") && deadline_probe.fetch("reaped") &&
       !deadline_probe.fetch("status").success? && deadline_probe.fetch("elapsed") < 4
  failures << "HARNESS wedged-command deadline did not terminate and reap its process group"
end

partial_api = AcquisitionApi.new({})
partial_client = TCPSocket.new("127.0.0.1", partial_api.port)
partial_client.write("POST /api/system/settings HTTP/1.1\r\nContent-Length: 100\r\n")
accept_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) +
                  SOCKET_DEADLINE_SECONDS
while partial_api.accepted_client_count.zero? &&
      Process.clock_gettime(Process::CLOCK_MONOTONIC) < accept_deadline
  Thread.pass
end
partial_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
partial_api.close
partial_elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - partial_started
failures << "HARNESS partial-client shutdown exceeded its deadline" if
  partial_elapsed >= SOCKET_DEADLINE_SECONDS + 1 || partial_api.error
partial_client.close unless partial_client.closed?

secret_sets = secret_task_sets
missing_secret_output_guards(secret_sets).each do |name|
  failures << "secret-bearing acquisition task can disclose private data: #{name}"
end
secret_sets.each do |path, tasks|
  tasks.each do |task|
    next unless secret_task_protected?(path, task)

    mutant_sets = deep_copy(secret_sets)
    mutant = mutant_sets.fetch(path).find { |candidate| candidate.fetch("name") == task.fetch("name") }
    mutant["no_log"] = false
    guard_name = File.join(File.basename(path), task.fetch("name"))
    failures << "acquisition output-guard mutation survived: #{File.basename(path)}/#{task.fetch('name')}" if
      !missing_secret_output_guards(mutant_sets).include?(guard_name)
  end
end

synthetic_recorder_tasks = [{
  "name" => FINGERPRINT_RECORD_TASK_NAME,
  "ansible.builtin.copy" => {
    "owner" => "{{ nas_uid }}", "group" => "{{ nas_gid }}", "mode" => "0600"
  }
}]
synthetic_loader_tasks = [{
  "name" => "Inspect private Arr desired-input fingerprint files",
  "ansible.builtin.stat" => {
    "get_checksum" => false, "get_mime" => false, "get_attributes" => false
  }
}, {
  "name" => "Validate private Arr desired-input fingerprints",
  "ansible.builtin.assert" => { "that" => FINGERPRINT_FILE_SAFETY_PREDICATES.values },
  "loop" => FINGERPRINT_STAT_RESULTS
}, {
  "name" => FINGERPRINT_READER_TASK_NAME,
  "ansible.builtin.command" => {
    "argv" => ["{{ ansible_facts.python.executable }}", "-c", <<~PYTHON]
      flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC
      before = os.fstat(fd)
      raise RuntimeError unless stat.S_ISREG(before.st_mode)
      raise RuntimeError if stat.S_IMODE(before.st_mode) != 0o600
      raise RuntimeError if before.st_uid != expected_uid
      raise RuntimeError if before.st_gid != expected_gid
      raise RuntimeError if before.st_size != 65
      content = os.read(fd, 65)
      raise RuntimeError if os.read(fd, 1)
      raise RuntimeError if content[64:] != b"\\n"
      raise RuntimeError if byte not in b"0123456789abcdef"
      after = os.fstat(fd)
      raise RuntimeError if before_identity != after_identity
      sys.stdout.write(content[:64].decode("ascii"))
    PYTHON
  }
}]
check_fingerprint_record_contract(
  failures, "synthetic mutation sanity", synthetic_recorder_tasks
)
check_fingerprint_loader_contract(
  failures, "synthetic mutation sanity", synthetic_loader_tasks
)

fingerprint_loader = File.join(ARR_TASKS, "reconciliation_fingerprints.yml")
fingerprint_recorder = File.join(ARR_TASKS, "record_reconciliation_fingerprints.yml")
failures << "private desired-input fingerprint loading is unavailable" unless File.file?(fingerprint_loader)
failures << "verified desired-input fingerprint recording is unavailable" unless File.file?(fingerprint_recorder)
if File.file?(fingerprint_loader)
  loader_tasks = YAML.safe_load_file(fingerprint_loader, aliases: true)
  check_fingerprint_loader_contract(
    failures, File.basename(fingerprint_loader),
    loader_tasks
  )
  computed = loader_tasks.first&.fetch("ansible.builtin.set_fact", {}) || {}
  filenames = computed.fetch("arr_reconciliation_fingerprint_filenames", {})
  failures << "Configarr verified owned-state hash path is unavailable" unless
    filenames["configarr_owned_state"] == CONFIGARR_STATE_FINGERPRINT_FILE
  failures << "Configarr opaque-context hash path is unavailable" unless
    filenames["configarr_opaque_context"] == CONFIGARR_OPAQUE_FINGERPRINT_FILE
  desired_inputs = computed.fetch("arr_desired_reconciliation_fingerprints", {})
  failures << "Configarr verified state was mislabeled as a desired-input digest" if
    desired_inputs.key?("configarr_owned_state")
  failures << "Configarr opaque context was mislabeled as a desired-input digest" if
    desired_inputs.key?("configarr_opaque_context")
end
if File.file?(fingerprint_recorder)
  recorder_tasks = YAML.safe_load_file(fingerprint_recorder, aliases: true)
  check_fingerprint_record_contract(
    failures, File.basename(fingerprint_recorder),
    recorder_tasks
  )
  recorder_source = recorder_tasks.to_s
  failures << "Configarr verified state is not recorded from a distinct verified-state fact" unless
    recorder_source.include?("arr_verified_reconciliation_state_fingerprints")
end
check_verification_gate_contract(
  failures,
  YAML.safe_load_file(File.join(ARR_TASKS, "main.yml"), aliases: true),
  YAML.safe_load_file(File.join(ARR_TASKS, "verify.yml"), aliases: true)
)
production_order_contract_failures(
  YAML.safe_load_file(File.join(ROOT, "site.yml"), aliases: true),
  YAML.safe_load_file(File.join(ARR_TASKS, "main.yml"), aliases: true),
  YAML.safe_load_file(File.join(ARR_TASKS, "verify.yml"), aliases: true),
  YAML.safe_load_file(File.join(DOWNLOADER_TASKS, "main.yml"), aliases: true),
  YAML.safe_load_file(File.join(DOWNLOADER_TASKS, "verify.yml"), aliases: true),
  fingerprint_load_tasks,
  fingerprint_record_tasks
).each do |violation|
  failures << "production-order relationship contract violates #{violation}"
end

unless OPAQUE_TARGETED_ONLY
cross_resource_malformed_indexer = deep_copy(INDEXER_DECLARATION).merge(
  "name" => "Malformed Later Indexer"
)
cross_resource_malformed_indexer.fetch("fields").last.delete("value")
cross_resource_preflight_state = {
  "applications" => [
    deep_copy(APPLICATION).merge("enable" => false),
    deep_copy(SONARR_APPLICATION)
  ],
  "indexers" => [deep_copy(INDEXER)]
}
with_api(cross_resource_preflight_state) do |api|
  result = run_tasks(
    :prowlarr_preflight,
    api,
    {
      "media_arr_indexers" => [
        deep_copy(INDEXER_DECLARATION), cross_resource_malformed_indexer
      ]
    },
    prepare_fingerprints: false
  )
  sane = check_sanity(failures, "global Prowlarr preflight", result, api)
  if sane
    failures << "global Prowlarr preflight accepted a malformed later indexer" if
      result.fetch("status").success?
    failures << "global Prowlarr preflight reached a mutation" unless
      mutation_requests(api, ->(_request) { true }).empty?
  end
end

malformed_later_current_application_state = {
  "applications" => [
    deep_copy(APPLICATION).merge("enable" => false),
    deep_copy(SONARR_APPLICATION),
    {
      "id" => 12,
      "name" => "Malformed Later Current Application",
      "fields" => [{ "name" => "baseUrl" }]
    }
  ],
  "indexers" => [deep_copy(INDEXER)]
}
with_api(malformed_later_current_application_state) do |api|
  result = run_tasks(
    :prowlarr_preflight, api, {}, prepare_fingerprints: false
  )
  sane = check_sanity(failures, "malformed later current Prowlarr application", result, api)
  if sane
    failures << "malformed later current Prowlarr application was accepted" if
      result.fetch("status").success?
    failures << "malformed later current Prowlarr application reached a mutation" unless
      mutation_requests(api, ->(_request) { true }).empty?
  end
end

{
  "later application syncCategories" => lambda do
    state = {
      "applications" => [
        deep_copy(APPLICATION).merge("enable" => false), deep_copy(SONARR_APPLICATION)
      ],
      "indexers" => [deep_copy(INDEXER)]
    }
    set_field!(state.fetch("applications").last, "syncCategories", nil)
    state
  end,
  "later indexer minimumSeeders" => lambda do
    state = {
      "applications" => [
        deep_copy(APPLICATION).merge("enable" => false), deep_copy(SONARR_APPLICATION)
      ],
      "indexers" => [deep_copy(INDEXER)]
    }
    set_field!(state.fetch("indexers").first, "minimumSeeders", nil)
    state
  end
}.each do |label, build_state|
  with_api(build_state.call) do |api|
    result = run_tasks(:prowlarr_preflight, api, {}, prepare_fingerprints: false)
    sane = check_sanity(failures, "malformed typed Prowlarr #{label}", result, api)
    if sane
      failures << "malformed typed Prowlarr #{label} was accepted" if
        result.fetch("status").success?
      failures << "malformed typed Prowlarr #{label} reached a mutation" unless
        mutation_requests(api, ->(_request) { true }).empty?
    end
  end
end

application_state = {
  "applications" => [
    deep_copy(APPLICATION), deep_copy(SONARR_APPLICATION),
    {
      "id" => 12, "name" => "Unmanaged", "enable" => true,
      "syncLevel" => "fullSync", "implementation" => "Unmanaged",
      "implementationName" => "Unmanaged", "configContract" => "UnmanagedSettings",
      "fields" => [], "tags" => []
    }
  ]
}
if fingerprint_tasks_available?
  with_api(deep_copy(application_state)) do |api|
    result = run_tasks(:application, api)
    sane = check_sanity(
      failures, "dedicated fingerprint loader and recorder", result, api, kind: :application
    )
    if sane
      failures << "dedicated fingerprint loader and recorder failed: #{sanitized_tail(result)}" unless
        result.fetch("status").success?
      expected = result.fetch("expected_fingerprints")
      valid = FINGERPRINT_FILE_BY_KIND.reject do |kind, _filename|
        %i[download_client download_client_production].include?(kind)
      end.all? do |kind, filename|
        entry = result.fetch("fingerprints").fetch(filename)
        entry && entry.fetch("type") == "regular" && entry.fetch("mode") == 0o600 &&
          entry.fetch("uid") == Process.uid && entry.fetch("gid") == Process.gid &&
          entry.fetch("content") ==
            "#{expected.fetch(FINGERPRINT_INPUT_BY_KIND.fetch(kind))}\n"
      end
      valid &&= result.fetch("fingerprints").fetch(
        FINGERPRINT_FILE_BY_KIND.fetch(:download_client)
      ).nil?
      failures << "dedicated loader/recorder did not create exact private owned fingerprints" unless valid
    end
  end
  # The dedicated production probe above establishes the algorithm. The matrix
  # can seed equivalent private baselines without running another setup playbook
  # before every scenario.
  FINGERPRINT_BASELINE_CACHE["enabled"] = true
end

production_client_write = lambda do |request|
  request["target"].match?(%r{\A/(radarr|sonarr)/api/v3/downloadclient(?:/\d+)?\z})
end
clean_production_client_state = {
  "radarr_download_clients" => [], "sonarr_download_clients" => []
}
with_api(deep_copy(clean_production_client_state)) do |api|
  result = run_tasks(
    :download_client_production, api, {}, prepare_fingerprints: false
  )
  sane = check_sanity(
    failures, "clean production-order Servarr clients", result, api,
    kind: :download_client_production
  )
  if sane
    failures << "clean production-order Servarr clients failed" unless
      result.fetch("status").success?
    writes = mutation_requests(api, production_client_write)
    failures << "clean production-order Servarr clients did not create both clients" unless
      writes.length == 2 && writes.all? { |request| request["method"] == "POST" } &&
      canonical_production_client_writes?(writes)
    failures << "clean production-order Servarr clients reported an unexpected change count" unless
      result.fetch("reconciliation_changed") == 2
    failures << "clean production-order Servarr clients did not converge Radarr" unless
      download_client_projection(api.state.fetch("radarr_download_clients").first) ==
      download_client_projection(DOWNLOAD_CLIENT)
    failures << "clean production-order Servarr clients did not converge Sonarr" unless
      download_client_projection(api.state.fetch("sonarr_download_clients").first) ==
      download_client_projection(SONARR_DOWNLOAD_CLIENT)
    servarr_file = FINGERPRINT_FILE_BY_KIND.fetch(:download_client)
    entry = result.fetch("fingerprints").fetch(servarr_file)
    expected = result.fetch("expected_fingerprints").fetch("servarr_sabnzbd")
    failures << "clean production-order Servarr clients did not record only the Servarr digest" unless
      entry && entry.fetch("content") == "#{expected}\n" &&
      (FINGERPRINT_FILES - [servarr_file]).all? do |filename|
        result.fetch("fingerprints").fetch(filename).nil?
      end
    success_index = result.fetch("task_events").index do |event|
      event.fetch("task") == DOWNLOADER_GATE_SUCCESS_TASK_NAME
    end
    record_index = result.fetch("task_events").index do |event|
      event.fetch("task") == FINGERPRINT_RECORD_TASK_NAME
    end
    failures << "clean production-order Servarr digest was recorded before downloader verification" unless
      success_index && record_index && success_index < record_index
  end
end

malformed_later_production_client_state = {
  "radarr_download_clients" => [deep_copy(DOWNLOAD_CLIENT).merge("enable" => false)],
  "sonarr_download_clients" => [deep_copy(SONARR_DOWNLOAD_CLIENT).merge("priority" => nil)]
}
with_api(malformed_later_production_client_state) do |api|
  result = run_tasks(
    :download_client_production, api, {}, prepare_fingerprints: false
  )
  sane = check_sanity(
    failures, "malformed later production-order Servarr client", result, api,
    kind: :download_client_production
  )
  if sane
    failures << "malformed later production-order Servarr client was accepted" if
      result.fetch("status").success?
    failures << "malformed later production-order Servarr client reached mutation" unless
      mutation_requests(api, production_client_write).empty?
  end
end

servarr_global_ownership_cases = {}
servarr_url_duplicate_state = {
  "radarr_download_clients" => [deep_copy(DOWNLOAD_CLIENT).merge("enable" => false)],
  "sonarr_download_clients" => [
    deep_copy(SONARR_DOWNLOAD_CLIENT),
    deep_copy(SONARR_DOWNLOAD_CLIENT).merge("id" => 91, "name" => "URL Duplicate")
  ]
}
servarr_global_ownership_cases["later Sonarr URL duplicate"] = servarr_url_duplicate_state
servarr_conflicting_identity_state = {
  "radarr_download_clients" => [deep_copy(DOWNLOAD_CLIENT).merge("enable" => false)],
  "sonarr_download_clients" => [
    deep_copy(SONARR_DOWNLOAD_CLIENT).tap do |client|
      set_field!(client, "host", "legacy-sab")
    end,
    deep_copy(SONARR_DOWNLOAD_CLIENT).merge("id" => 92, "name" => "URL Owner")
  ]
}
servarr_global_ownership_cases["later Sonarr conflicting name and URL"] =
  servarr_conflicting_identity_state
servarr_incomplete_adoption = deep_copy(SONARR_DOWNLOAD_CLIENT).merge(
  "id" => 93, "name" => "URL Adoption"
)
remove_field!(servarr_incomplete_adoption, "useSsl")
servarr_global_ownership_cases["later Sonarr incomplete URL adoption"] = {
  "radarr_download_clients" => [deep_copy(DOWNLOAD_CLIENT).merge("enable" => false)],
  "sonarr_download_clients" => [servarr_incomplete_adoption]
}
servarr_global_ownership_cases.each do |label, state|
  with_api(state) do |api|
    result = run_tasks(
      :download_client_production, api, {}, prepare_fingerprints: false
    )
    sane = check_sanity(failures, label, result, api, kind: :download_client_production)
    if sane
      failures << "#{label} was accepted" if result.fetch("status").success?
      failures << "#{label} reached mutation" unless
        mutation_requests(api, production_client_write).empty?
    end
  end
end


with_api(
  deep_copy(clean_production_client_state), fail_client_service: "sonarr"
) do |api|
  result = run_tasks(
    :download_client_production, api, {}, prepare_fingerprints: false
  )
  sane = check_sanity(
    failures, "failed production-order Servarr client write", result, api,
    kind: :download_client_production
  )
  if sane
    failures << "failed production-order Servarr client write was accepted" if
      result.fetch("status").success?
    failures << "failed production-order Servarr client write reached downloader success" if
      result.fetch("task_events").any? do |event|
        event.fetch("task") == DOWNLOADER_GATE_SUCCESS_TASK_NAME
      end
    failures << "failed production-order Servarr client write reached fingerprint recording" if
      result.fetch("task_events").any? do |event|
        event.fetch("task") == FINGERPRINT_RECORD_TASK_NAME
      end
    failures << "failed production-order Servarr client write advanced a fingerprint" unless
      result.fetch("fingerprints").values.compact.empty?
  end
end

stable_production_client_state = {
  "radarr_download_clients" => [deep_copy(DOWNLOAD_CLIENT)],
  "sonarr_download_clients" => [deep_copy(SONARR_DOWNLOAD_CLIENT)]
}
with_api(
  deep_copy(stable_production_client_state), corrupt_client_verification: true
) do |api|
  result = run_tasks(
    :download_client_production, api, {}, prepare_fingerprints: false
  )
  sane = check_sanity(
    failures, "failed production-order downloader verification", result, api,
    kind: :download_client_production
  )
  if sane
    failures << "failed production-order downloader verification was accepted" if
      result.fetch("status").success?
    failures << "failed production-order downloader verification reached success" if
      result.fetch("task_events").any? do |event|
        event.fetch("task") == DOWNLOADER_GATE_SUCCESS_TASK_NAME
      end
    failures << "failed production-order downloader verification reached fingerprint recording" if
      result.fetch("task_events").any? do |event|
        event.fetch("task") == FINGERPRINT_RECORD_TASK_NAME
      end
    failures << "failed production-order downloader verification advanced a fingerprint" unless
      result.fetch("fingerprints").values.compact.empty?
  end
end

production_secret_state = deep_copy(stable_production_client_state)
%w[radarr_download_clients sonarr_download_clients].each do |collection|
  set_field!(
    production_secret_state.fetch(collection).first,
    "apiKey",
    "private-stale-apiKey"
  )
end
Dir.mktmpdir("media-acquisition-production-client-secret-") do |runtime|
  with_api(production_secret_state) do |api|
    baseline = run_tasks(
      :download_client_production,
      api,
      { "vault_downloaders_sabnzbd_api_key" => "private-stale-apiKey" },
      runtime: runtime,
      prepare_fingerprints: false
    )
    sane = check_sanity(
      failures, "old production-order Servarr secret", baseline, api,
      kind: :download_client_production
    )
    if sane && baseline.fetch("status").success?
      api.requests.clear
      result = run_tasks(
        :download_client_production, api, {}, runtime: runtime,
        prepare_fingerprints: false
      )
      sane = check_sanity(
        failures, "shared production-order Servarr secret transition", result, api,
        kind: :download_client_production
      )
      if sane
        writes = mutation_requests(api, production_client_write)
        failures << "shared production-order Servarr secret did not update both exact clients" unless
          result.fetch("status").success? && writes.length == 2 &&
          writes.all? { |request| request["method"] == "PUT" } &&
          canonical_production_client_writes?(writes)
        failures << "shared production-order Servarr secret reported an unexpected change count" unless
          result.fetch("reconciliation_changed") == 2
        failures << "shared production-order Servarr secret did not record one digest transition" unless
          result.fetch("fingerprint_changes") == 1
        success_index = result.fetch("task_events").index do |event|
          event.fetch("task") == DOWNLOADER_GATE_SUCCESS_TASK_NAME
        end
        record_index = result.fetch("task_events").index do |event|
          event.fetch("task") == FINGERPRINT_RECORD_TASK_NAME
        end
        failures << "shared production-order Servarr secret recorded before both clients verified" unless
          success_index && record_index && success_index < record_index
      end
    else
      failures << "could not establish old production-order Servarr secret fingerprint"
    end
  end
end

Dir.mktmpdir("media-acquisition-fingerprint-tags-") do |directory|
  runtime = File.join(directory, "runtime")
  FileUtils.mkdir_p(File.join(runtime, "services", "arr"))
  File.write(
    File.join(runtime, "services", "arr", FINGERPRINT_FILE_BY_KIND.fetch(:configarr)),
    "#{'0' * 64}\n", mode: "w", perm: 0o600
  )
  fingerprints_before = fingerprint_snapshot(runtime)
  variables = base_variables(1).merge(
    "media_usenet_enabled" => true,
    "platform_runtime_dir" => runtime
  )
  callback_directory = write_event_callback(directory)
  env = {
    "ANSIBLE_NOCOLOR" => "1",
    "ANSIBLE_CALLBACK_PLUGINS" => callback_directory,
    "ANSIBLE_CALLBACKS_ENABLED" => "acquisition_fixture_events",
    "ACQUISITION_FIXTURE_EVENT_LOG" => File.join(directory, "ansible-events.jsonl")
  }
  playbook = File.join(directory, "playbook.yml")
  write_playbook(playbook, variables, tag_filtered_fingerprint_tasks)
  result = run_playbook(
    playbook, env, "--tags", "arr", "--skip-tags", "platform_verify_arr"
  )
  failures << "HARNESS tag-filtered fingerprint gate produced no task events" if
    result.fetch("task_events").empty?
  failures << "tag-filtered verification skip failed: #{sanitized_tail(result)}" unless
    result.fetch("status")&.success?
  recorder_started = result.fetch("task_events").any? do |event|
    event.fetch("task") == FINGERPRINT_RECORD_TASK_NAME
  end
  failures << "tag-filtered verification skip reached fingerprint recording" if recorder_started
  failures << "tag-filtered verification skip changed fingerprint files" unless
    fingerprint_snapshot(runtime) == fingerprints_before
end


Dir.mktmpdir("media-acquisition-downloader-tags-") do |directory|
  runtime = File.join(directory, "runtime")
  FileUtils.mkdir_p(File.join(runtime, "services", "arr"))
  with_api(deep_copy(clean_production_client_state)) do |api|
    variables = base_variables(api.port).merge(
      "media_usenet_enabled" => true,
      "platform_runtime_dir" => runtime,
      "arr_servarr_instances" => [SERVARR_INSTANCE, SONARR_INSTANCE].map do |instance|
        deep_copy(instance).merge(
          "api" => "http://127.0.0.1:#{api.port}/#{instance.fetch('name')}/api/v3"
        )
      end
    )
    callback_directory = write_event_callback(directory)
    env = {
      "ANSIBLE_NOCOLOR" => "1",
      "ANSIBLE_CALLBACK_PLUGINS" => callback_directory,
      "ANSIBLE_CALLBACKS_ENABLED" => "acquisition_fixture_events",
      "ACQUISITION_FIXTURE_EVENT_LOG" => File.join(directory, "ansible-events.jsonl")
    }
    playbook = File.join(directory, "playbook.yml")
    write_playbook(playbook, variables, tag_filtered_downloader_relationship_tasks)
    result = run_playbook(
      playbook, env, "--tags", "downloaders", "--skip-tags", "platform_verify_downloaders"
    )
    failures << "HARNESS downloader tag-filtered gate produced no task events" if
      result.fetch("task_events").empty?
    failures << "downloader tag-filtered verification skip failed: #{sanitized_tail(result)}" unless
      result.fetch("status")&.success?
    failures << "downloader tag-filtered verification skip did not reconcile both clients" unless
      mutation_requests(api, production_client_write).length == 2
    failures << "downloader tag-filtered verification skip reached its success marker" if
      result.fetch("task_events").any? do |event|
        event.fetch("task") == DOWNLOADER_GATE_SUCCESS_TASK_NAME && event.fetch("event") == "ok"
      end
    failures << "downloader tag-filtered verification skip reached fingerprint recording" if
      result.fetch("task_events").any? do |event|
        event.fetch("task") == FINGERPRINT_RECORD_TASK_NAME
      end
    failures << "downloader tag-filtered verification skip changed fingerprint files" unless
      fingerprint_snapshot(runtime).values.compact.empty?
  end
end


[true, false].each do |stale|
  Dir.mktmpdir("media-acquisition-arr-verify-only-") do |directory|
    runtime = File.join(directory, "runtime")
    FileUtils.mkdir_p(File.join(runtime, "services", "arr"))
    state = { "applications" => [deep_copy(APPLICATION), deep_copy(SONARR_APPLICATION)],
              "indexers" => [deep_copy(INDEXER)] }
    with_api(state) do |api|
      variables = base_variables(api.port).merge("platform_runtime_dir" => runtime)
      fingerprint_variables = deep_copy(variables)
      if stale
        set_field!(
          fingerprint_variables.fetch("media_arr_indexers").first,
          "apiKey", "private-stale-indexer-secret"
        )
      end
      seed_fingerprint_baseline(
        runtime, fingerprint_variables, kind: :indexer, state: state
      )
      before = fingerprint_snapshot(runtime)
      callback_directory = write_event_callback(directory)
      env = {
        "ANSIBLE_NOCOLOR" => "1", "ANSIBLE_CALLBACK_PLUGINS" => callback_directory,
        "ANSIBLE_CALLBACKS_ENABLED" => "acquisition_fixture_events",
        "ACQUISITION_FIXTURE_EVENT_LOG" => File.join(directory, "ansible-events.jsonl")
      }
      playbook = File.join(directory, "playbook.yml")
      write_playbook(playbook, variables, arr_verify_only_tasks)
      result = run_playbook(playbook, env, "--tags", "platform_verify_arr")
      failures << "Arr verify-only stale digest was accepted" if stale && result.fetch("status").success?
      failures << "Arr verify-only matching digest failed: #{sanitized_tail(result)}" if
        !stale && !result.fetch("status").success?
      failures << "Arr verify-only execution reached an API mutation" unless
        mutation_requests(api, ->(_request) { true }).empty?
      failures << "Arr verify-only execution changed fingerprint state" unless
        fingerprint_snapshot(runtime) == before
    end
  end
end

[true, false].each do |stale|
  Dir.mktmpdir("media-acquisition-downloader-verify-only-") do |directory|
    runtime = File.join(directory, "runtime")
    FileUtils.mkdir_p(File.join(runtime, "services", "arr"))
    with_api(deep_copy(stable_production_client_state)) do |api|
      variables = base_variables(api.port).merge(
        "platform_runtime_dir" => runtime,
        "arr_servarr_instances" => [SERVARR_INSTANCE, SONARR_INSTANCE].map do |instance|
          deep_copy(instance).merge(
            "api" => "http://127.0.0.1:#{api.port}/#{instance.fetch('name')}/api/v3"
          )
        end
      )
      fingerprint_variables = deep_copy(variables)
      if stale
        fingerprint_variables["vault_downloaders_sabnzbd_admin_username"] =
          "private-stale-username"
        fingerprint_variables["vault_downloaders_sabnzbd_admin_password"] =
          "private-stale-password"
      end
      seed_fingerprint_baseline(
        runtime, fingerprint_variables, kind: :download_client_production,
        state: api.state
      )
      before = fingerprint_snapshot(runtime)
      callback_directory = write_event_callback(directory)
      env = {
        "ANSIBLE_NOCOLOR" => "1", "ANSIBLE_CALLBACK_PLUGINS" => callback_directory,
        "ANSIBLE_CALLBACKS_ENABLED" => "acquisition_fixture_events",
        "ACQUISITION_FIXTURE_EVENT_LOG" => File.join(directory, "ansible-events.jsonl")
      }
      playbook = File.join(directory, "playbook.yml")
      write_playbook(playbook, variables, downloader_verify_only_tasks)
      result = run_playbook(playbook, env, "--tags", "platform_verify_downloaders")
      failures << "downloader verify-only stale digest was accepted" if
        stale && result.fetch("status").success?
      failures << "downloader verify-only matching digest failed: #{sanitized_tail(result)}" if
        !stale && !result.fetch("status").success?
      failures << "downloader verify-only execution reached an API mutation" unless
        mutation_requests(api, ->(_request) { true }).empty?
      failures << "downloader verify-only execution changed fingerprint state" unless
        fingerprint_snapshot(runtime) == before
    end
  end
end

Dir.mktmpdir("media-acquisition-fingerprint-oversized-") do |runtime|
  FileUtils.mkdir_p(File.join(runtime, "services", "arr"))
  with_api(deep_copy(application_state)) do |api|
    variables = base_variables(api.port)
    seed_fingerprint_baseline(
      runtime, variables, kind: :application, state: api.state
    )
    path = File.join(
      runtime, "services", "arr", FINGERPRINT_FILE_BY_KIND.fetch(:application)
    )
    File.write(path, "a" * (1024 * 1024), mode: "w", perm: 0o600)
    before = fingerprint_snapshot(runtime)
    result = run_tasks(
      :application, api, {}, runtime: runtime, prepare_fingerprints: false
    )
    failures << "oversized fingerprint was accepted" if result.fetch("status").success?
    failures << "oversized fingerprint reached an API request" unless api.requests.empty?
    failures << "oversized fingerprint reached fingerprint recording" if
      result.fetch("recorder_started")
    failures << "oversized fingerprint changed filesystem state" unless
      result.fetch("fingerprints") == before

    File.write(path, "#{'A' * 64}\n", mode: "w", perm: 0o600)
    before = fingerprint_snapshot(runtime)
    api.requests.clear
    result = run_tasks(
      :application, api, {}, runtime: runtime, prepare_fingerprints: false
    )
    failures << "uppercase fingerprint was accepted" if result.fetch("status").success?
    failures << "uppercase fingerprint reached an API request" unless api.requests.empty?
    failures << "uppercase fingerprint reached fingerprint recording" if
      result.fetch("recorder_started")
    failures << "uppercase fingerprint changed filesystem state" unless
      result.fetch("fingerprints") == before
  end
end

Dir.mktmpdir("media-acquisition-fingerprint-race-") do |runtime|
  fingerprint_directory = File.join(runtime, "services", "arr")
  FileUtils.mkdir_p(fingerprint_directory)
  with_api(deep_copy(application_state)) do |api|
    variables = base_variables(api.port)
    seed_fingerprint_baseline(
      runtime, variables, kind: :application, state: api.state
    )
    path = File.join(fingerprint_directory, FINGERPRINT_FILE_BY_KIND.fetch(:application))
    target = File.join(runtime, "replacement-target")
    File.write(target, "#{'f' * 64}\n", mode: "w", perm: 0o600)
    target_before = File.binread(target)
    inject_replacement = lambda do |tasks|
      assertion_index = tasks.index do |task|
        task["name"] == "Validate private Arr desired-input fingerprints"
      end
      raise "fingerprint race injection boundary is unavailable" unless assertion_index

      tasks.insert(
        assertion_index + 1,
        {
          "name" => "Remove the inspected fingerprint for race injection",
          "ansible.builtin.file" => { "path" => path, "state" => "absent" },
          "no_log" => true
        },
        {
          "name" => "Replace the inspected fingerprint with a symlink",
          "ansible.builtin.file" => {
            "src" => target, "dest" => path, "state" => "link"
          },
          "no_log" => true
        }
      )
    end
    result = run_tasks(
      :application, api, {}, runtime: runtime, prepare_fingerprints: false,
      task_mutator: inject_replacement
    )
    failures << "replacement-symlink fingerprint race was accepted" if
      result.fetch("status").success?
    failures << "replacement-symlink fingerprint race reached an API request" unless
      api.requests.empty?
    failures << "replacement-symlink fingerprint race reached fingerprint recording" if
      result.fetch("recorder_started")
    failures << "replacement-symlink fingerprint race did not execute" unless
      result.dig("fingerprints", FINGERPRINT_FILE_BY_KIND.fetch(:application), "type") == "symlink"
    failures << "replacement-symlink fingerprint race changed its target" unless
      File.binread(target) == target_before
  end
end

Dir.mktmpdir("media-acquisition-fingerprint-fifo-race-") do |runtime|
  fingerprint_directory = File.join(runtime, "services", "arr")
  FileUtils.mkdir_p(fingerprint_directory)
  with_api(deep_copy(application_state)) do |api|
    variables = base_variables(api.port)
    seed_fingerprint_baseline(
      runtime, variables, kind: :application, state: api.state
    )
    path = File.join(fingerprint_directory, FINGERPRINT_FILE_BY_KIND.fetch(:application))
    inject_fifo = lambda do |tasks|
      assertion_index = tasks.index do |task|
        task["name"] == "Validate private Arr desired-input fingerprints"
      end
      raise "fingerprint FIFO race injection boundary is unavailable" unless assertion_index

      tasks.insert(
        assertion_index + 1,
        {
          "name" => "Remove the inspected fingerprint for FIFO race injection",
          "ansible.builtin.file" => { "path" => path, "state" => "absent" },
          "no_log" => true
        },
        {
          "name" => "Replace the inspected fingerprint with a FIFO",
          "ansible.builtin.command" => { "argv" => ["/usr/bin/mkfifo", path] },
          "changed_when" => false,
          "no_log" => true
        }
      )
    end
    result = run_tasks(
      :application, api, {}, runtime: runtime, prepare_fingerprints: false,
      task_mutator: inject_fifo
    )
    failures << "replacement-FIFO fingerprint race was accepted" if
      result.fetch("status").success?
    failures << "replacement-FIFO fingerprint race reached an API request" unless
      api.requests.empty?
    failures << "replacement-FIFO fingerprint race reached fingerprint recording" if
      result.fetch("recorder_started")
    failures << "replacement-FIFO fingerprint race did not execute" unless
      result.dig("fingerprints", FINGERPRINT_FILE_BY_KIND.fetch(:application), "type") == "other"
  end
end

if ENV["ACQUISITION_FINGERPRINT_TARGETED_ONLY"] == "1"
  abort failures.join("\n") unless failures.empty?
  puts "media acquisition fingerprint safety behavior holds"
  exit
end

if ENV["ACQUISITION_PRODUCTION_ORDER_TARGETED_ONLY"] == "1"
  abort failures.join("\n") unless failures.empty?
  puts "media acquisition production-order relationship behavior holds"
  exit
end

application_mutations = {
  "name" => ->(state) { state.fetch("applications").first["name"] = "Legacy Radarr" },
  "enable" => ->(state) { state.fetch("applications").first["enable"] = false },
  "syncLevel" => ->(state) { state.fetch("applications").first["syncLevel"] = "addOnly" },
  "implementation" => ->(state) { state.fetch("applications").first["implementation"] = "Legacy" },
  "implementationName" => ->(state) { state.fetch("applications").first["implementationName"] = "Legacy" },
  "configContract" => ->(state) { state.fetch("applications").first["configContract"] = "LegacySettings" },
  "sorted tags" => ->(state) { state.fetch("applications").first["tags"] = [44] },
  "fields.prowlarrUrl" => lambda do |state|
    set_field!(state.fetch("applications").first, "prowlarrUrl", "http://legacy:9696")
  end,
  "fields.baseUrl" => ->(state) { set_field!(state.fetch("applications").first, "baseUrl", "http://legacy:7878") },
  "fields.username" => ->(state) { set_field!(state.fetch("applications").first, "username", "legacy-user") },
  "fields.password" => ->(state) { set_field!(state.fetch("applications").first, "password", "legacy-readable-value") },
  "fields.syncCategories" => ->(state) { set_field!(state.fetch("applications").first, "syncCategories", [9999]) },
  "fields.apiKey missing readable value" => lambda do |state|
    remove_field!(state.fetch("applications").first, "apiKey")
  end
}
application_write = ->(request) { request["target"].match?(%r{\A/api/v1/applications(?:/\d+)?\z}) }
application_current = lambda do |state|
  state.fetch("applications").find { |item| item["name"] == APPLICATION.fetch("name") }
end
exercise_mutations(
  failures, relationship: "Prowlarr application", kind: :application,
  baseline: application_state, mutations: application_mutations,
  write_matcher: application_write, projection: method(:application_projection),
  desired: APPLICATION, current: application_current
)
exercise_stable(
  failures, relationship: "Prowlarr application", kind: :application,
  state: application_state, write_matcher: application_write,
  projection: method(:application_projection), desired: APPLICATION,
  current: application_current
)
application_secret_state = deep_copy(application_state)
set_field!(application_secret_state.fetch("applications").first, "apiKey", "private-stale-application-secret")
old_application_declaration = deep_copy(APPLICATION_DECLARATION)
old_application_declaration["api_key"] = "private-stale-application-secret"
exercise_secret_change(
  failures, relationship: "Prowlarr application", kind: :application,
  state: application_secret_state, field: "fields.apiKey",
  variables: {},
  old_variables: {
    "arr_prowlarr_applications" => [old_application_declaration, SONARR_APPLICATION_DECLARATION]
  }, write_matcher: application_write, projection: method(:application_projection),
  desired: APPLICATION, current: application_current,
  expected_writes: 2, expected_changed: 2,
  write_set_validator: method(:canonical_application_secret_writes?)
)
duplicate_applications = deep_copy(application_state)
duplicate_applications.fetch("applications") << deep_copy(APPLICATION).merge("id" => 14)
exercise_duplicate(
  failures, relationship: "Prowlarr application", kind: :application,
  state: duplicate_applications, variables: {}, write_matcher: application_write
)
duplicate_application_declarations = [
  deep_copy(APPLICATION_DECLARATION), deep_copy(APPLICATION_DECLARATION)
]
application_declaration_preflight_state = deep_copy(application_state)
application_declaration_preflight_state.fetch("applications").first["enable"] = false
exercise_duplicate(
  failures, relationship: "Prowlarr application declaration", kind: :application,
  state: application_declaration_preflight_state,
  variables: { "arr_prowlarr_applications" => duplicate_application_declarations },
  write_matcher: application_write
)
malformed_application_declaration = deep_copy(SONARR_APPLICATION_DECLARATION)
malformed_application_declaration.delete("base_url")
exercise_duplicate(
  failures, relationship: "Prowlarr malformed later application declaration",
  kind: :application, state: application_declaration_preflight_state,
  variables: {
    "arr_prowlarr_applications" => [
      deep_copy(APPLICATION_DECLARATION), malformed_application_declaration
    ]
  },
  write_matcher: application_write
)

client_state = { "download_clients" => [deep_copy(DOWNLOAD_CLIENT)] }
client_mutations = {
  "name" => ->(state) { state.fetch("download_clients").first["name"] = "Legacy SAB" },
  "enable" => ->(state) { state.fetch("download_clients").first["enable"] = false },
  "protocol" => ->(state) { state.fetch("download_clients").first["protocol"] = "torrent" },
  "priority" => ->(state) { state.fetch("download_clients").first["priority"] = 50 },
  "removeCompletedDownloads" => ->(state) { state.fetch("download_clients").first["removeCompletedDownloads"] = false },
  "removeFailedDownloads" => ->(state) { state.fetch("download_clients").first["removeFailedDownloads"] = false },
  "implementation" => ->(state) { state.fetch("download_clients").first["implementation"] = "Legacy" },
  "implementationName" => ->(state) { state.fetch("download_clients").first["implementationName"] = "Legacy" },
  "configContract" => ->(state) { state.fetch("download_clients").first["configContract"] = "LegacySettings" },
  "sorted tags" => ->(state) { state.fetch("download_clients").first["tags"] = [44] },
  "fields.host" => ->(state) { set_field!(state.fetch("download_clients").first, "host", "legacy-sab") },
  "fields.port" => ->(state) { set_field!(state.fetch("download_clients").first, "port", "9999") },
  "fields.useSsl" => ->(state) { set_field!(state.fetch("download_clients").first, "useSsl", true) },
  "fields.urlBase" => ->(state) { set_field!(state.fetch("download_clients").first, "urlBase", "/legacy") },
  "fields.apiKey missing readable value" => lambda do |state|
    remove_field!(state.fetch("download_clients").first, "apiKey")
  end,
  "fields.username missing readable value" => lambda do |state|
    remove_field!(state.fetch("download_clients").first, "username")
  end,
  "fields.password missing readable value" => lambda do |state|
    remove_field!(state.fetch("download_clients").first, "password")
  end,
  "fields.movieCategory" => ->(state) { set_field!(state.fetch("download_clients").first, "movieCategory", "legacy") },
  "fields.movieCategory wrong key" => lambda do |state|
    client = state.fetch("download_clients").first
    remove_field!(client, "movieCategory")
    client.fetch("fields") << { "name" => "tvCategory", "value" => "movies" }
  end,
  "fields.movieCategory missing key" => lambda do |state|
    remove_field!(state.fetch("download_clients").first, "movieCategory")
  end
}
client_write = ->(request) { request["target"].match?(%r{\A/api/v3/downloadclient(?:/\d+)?\z}) }
client_current = lambda do |state|
  state.fetch("download_clients").find { |item| item["name"] == DOWNLOAD_CLIENT.fetch("name") }
end
exercise_mutations(
  failures, relationship: "Servarr SABnzbd client", kind: :download_client,
  baseline: client_state, mutations: client_mutations,
  write_matcher: client_write, projection: method(:download_client_projection),
  desired: DOWNLOAD_CLIENT, current: client_current
)
exercise_stable(
  failures, relationship: "Servarr SABnzbd client", kind: :download_client,
  state: client_state, write_matcher: client_write,
  projection: method(:download_client_projection), desired: DOWNLOAD_CLIENT,
  current: client_current
)
radarr_blank_category_state = deep_copy(client_state)
radarr_blank_category_state.fetch("download_clients").first.fetch("fields") <<
  { "name" => "tvCategory", "value" => "" }
exercise_stable(
  failures, relationship: "Radarr SABnzbd client blank non-applicable category",
  kind: :download_client, state: radarr_blank_category_state,
  write_matcher: client_write, projection: method(:download_client_projection),
  desired: DOWNLOAD_CLIENT, current: client_current
)
%w[apiKey username password].each do |secret_field|
  secret_state = deep_copy(client_state)
  old_secret = "private-stale-#{secret_field}"
  set_field!(secret_state.fetch("download_clients").first, secret_field, old_secret)
  variable = {
    "apiKey" => "vault_downloaders_sabnzbd_api_key",
    "username" => "vault_downloaders_sabnzbd_admin_username",
    "password" => "vault_downloaders_sabnzbd_admin_password"
  }.fetch(secret_field)
  exercise_secret_change(
    failures, relationship: "Servarr SABnzbd client", kind: :download_client,
    state: secret_state, field: "fields.#{secret_field}",
    variables: {}, old_variables: { variable => old_secret },
    write_matcher: client_write, projection: method(:download_client_projection),
    desired: DOWNLOAD_CLIENT, current: client_current
  )
end
duplicate_clients = deep_copy(client_state)
duplicate_clients.fetch("download_clients") << deep_copy(DOWNLOAD_CLIENT).merge("id" => 23)
exercise_duplicate(
  failures, relationship: "Servarr SABnzbd client", kind: :download_client,
  state: duplicate_clients, variables: {}, write_matcher: client_write
)
{
  "missing port" => ->(client) { remove_field!(client, "port") },
  "null port" => ->(client) { set_field!(client, "port", nil) },
  "invalid useSsl" => ->(client) { set_field!(client, "useSsl", "sometimes") },
  "null priority" => ->(client) { client["priority"] = nil }
}.each do |label, mutate|
  malformed = deep_copy(client_state)
  mutate.call(malformed.fetch("download_clients").first)
  exercise_duplicate(
    failures, relationship: "Servarr SABnzbd client #{label}", kind: :download_client,
    state: malformed, variables: {}, write_matcher: client_write
  )
end

sonarr_client_state = { "download_clients" => [deep_copy(SONARR_DOWNLOAD_CLIENT)] }
sonarr_client_mutations = client_mutations.reject do |field, _mutate|
  field.start_with?("fields.movieCategory")
end
sonarr_client_mutations["fields.tvCategory"] = lambda do |state|
  set_field!(state.fetch("download_clients").first, "tvCategory", "legacy")
end
sonarr_client_mutations["fields.tvCategory wrong key"] = lambda do |state|
  client = state.fetch("download_clients").first
  remove_field!(client, "tvCategory")
  client.fetch("fields") << { "name" => "movieCategory", "value" => "series" }
end
sonarr_client_mutations["fields.tvCategory missing key"] = lambda do |state|
  remove_field!(state.fetch("download_clients").first, "tvCategory")
end
sonarr_variables = { "fixture_servarr_instance" => deep_copy(SONARR_INSTANCE) }
sonarr_client_current = lambda do |state|
  state.fetch("download_clients").find do |item|
    item["name"] == SONARR_DOWNLOAD_CLIENT.fetch("name")
  end
end
exercise_mutations(
  failures, relationship: "Sonarr SABnzbd client", kind: :download_client,
  baseline: sonarr_client_state, mutations: sonarr_client_mutations,
  variables: sonarr_variables, write_matcher: client_write,
  projection: method(:download_client_projection), desired: SONARR_DOWNLOAD_CLIENT,
  current: sonarr_client_current
)
exercise_stable(
  failures, relationship: "Sonarr SABnzbd client", kind: :download_client,
  state: sonarr_client_state, variables: sonarr_variables, write_matcher: client_write,
  projection: method(:download_client_projection), desired: SONARR_DOWNLOAD_CLIENT,
  current: sonarr_client_current
)
sonarr_blank_category_state = deep_copy(sonarr_client_state)
sonarr_blank_category_state.fetch("download_clients").first.fetch("fields") <<
  { "name" => "movieCategory", "value" => "" }
exercise_stable(
  failures, relationship: "Sonarr SABnzbd client blank non-applicable category",
  kind: :download_client, state: sonarr_blank_category_state,
  variables: sonarr_variables, write_matcher: client_write,
  projection: method(:download_client_projection), desired: SONARR_DOWNLOAD_CLIENT,
  current: sonarr_client_current
)
%w[apiKey username password].each do |secret_field|
  secret_state = deep_copy(sonarr_client_state)
  old_secret = "private-stale-sonarr-#{secret_field}"
  set_field!(secret_state.fetch("download_clients").first, secret_field, old_secret)
  variable = {
    "apiKey" => "vault_downloaders_sabnzbd_api_key",
    "username" => "vault_downloaders_sabnzbd_admin_username",
    "password" => "vault_downloaders_sabnzbd_admin_password"
  }.fetch(secret_field)
  exercise_secret_change(
    failures, relationship: "Sonarr SABnzbd client", kind: :download_client,
    state: secret_state, field: "fields.#{secret_field}",
    variables: sonarr_variables,
    old_variables: sonarr_variables.merge(variable => old_secret),
    write_matcher: client_write, projection: method(:download_client_projection),
    desired: SONARR_DOWNLOAD_CLIENT, current: sonarr_client_current
  )
end
duplicate_sonarr_clients = deep_copy(sonarr_client_state)
duplicate_sonarr_clients.fetch("download_clients") << deep_copy(SONARR_DOWNLOAD_CLIENT).merge("id" => 24)
exercise_duplicate(
  failures, relationship: "Sonarr SABnzbd client", kind: :download_client,
  state: duplicate_sonarr_clients, variables: sonarr_variables, write_matcher: client_write
)

indexer_state = { "indexers" => [deep_copy(INDEXER)] }
indexer_mutations = {
  "name" => ->(state) { state.fetch("indexers").first["name"] = "Legacy Indexer" },
  "enable" => ->(state) { state.fetch("indexers").first["enable"] = false },
  "priority" => ->(state) { state.fetch("indexers").first["priority"] = 50 },
  "implementation" => ->(state) { state.fetch("indexers").first["implementation"] = "Legacy" },
  "implementationName" => ->(state) { state.fetch("indexers").first["implementationName"] = "Legacy" },
  "configContract" => ->(state) { state.fetch("indexers").first["configContract"] = "LegacySettings" },
  "sorted tags" => ->(state) { state.fetch("indexers").first["tags"] = [44] },
  "fields.baseUrl" => ->(state) { set_field!(state.fetch("indexers").first, "baseUrl", "https://legacy.invalid") },
  "fields.apiPath" => ->(state) { set_field!(state.fetch("indexers").first, "apiPath", "/legacy") },
  "fields.orderedValues" => lambda do |state|
    set_field!(state.fetch("indexers").first, "orderedValues", [2, { "nested" => 1 }, "first"])
  end,
  "fields.categories" => ->(state) { set_field!(state.fetch("indexers").first, "categories", [9999]) },
  "fields.minimumSeeders" => ->(state) { set_field!(state.fetch("indexers").first, "minimumSeeders", 99) }
}
indexer_write = ->(request) { request["target"].match?(%r{\A/api/v1/indexer(?:/\d+)?\z}) }
indexer_current = lambda do |state|
  state.fetch("indexers").find { |item| item["name"] == INDEXER.fetch("name") }
end
exercise_mutations(
  failures, relationship: "Prowlarr indexer", kind: :indexer,
  baseline: indexer_state, mutations: indexer_mutations,
  write_matcher: indexer_write, projection: method(:indexer_projection),
  desired: INDEXER, current: indexer_current
)
exercise_stable(
  failures, relationship: "Prowlarr indexer", kind: :indexer,
  state: indexer_state, write_matcher: indexer_write,
  projection: method(:indexer_projection), desired: INDEXER,
  current: indexer_current
)
category_order_state = deep_copy(indexer_state)
set_field!(category_order_state.fetch("indexers").first, "categories", [2000, 5000])
exercise_stable(
  failures, relationship: "Prowlarr unordered indexer categories", kind: :indexer,
  state: category_order_state, write_matcher: indexer_write,
  projection: method(:indexer_projection), desired: INDEXER,
  current: indexer_current
)
malformed_category_state = deep_copy(indexer_state)
set_field!(malformed_category_state.fetch("indexers").first, "categories", [5000, [2000]])
exercise_duplicate(
  failures, relationship: "Prowlarr malformed indexer categories", kind: :indexer,
  state: malformed_category_state, variables: {}, write_matcher: indexer_write
)
missing_indexer_api_key_state = deep_copy(indexer_state)
remove_field!(missing_indexer_api_key_state.fetch("indexers").first, "apiKey")
exercise_duplicate(
  failures, relationship: "Prowlarr missing readable indexer API key", kind: :indexer,
  state: missing_indexer_api_key_state, variables: {}, write_matcher: indexer_write
)
indexer_secret_state = deep_copy(indexer_state)
set_field!(indexer_secret_state.fetch("indexers").first, "apiKey", "private-stale-indexer-secret")
exercise_secret_change(
  failures, relationship: "Prowlarr indexer", kind: :indexer,
  state: indexer_secret_state, field: "fields.apiKey",
  variables: {},
  old_variables: {
    "media_arr_indexers" => [deep_copy(INDEXER_DECLARATION).tap do |declaration|
      set_field!(declaration, "apiKey", "private-stale-indexer-secret")
    end]
  }, write_matcher: indexer_write, projection: method(:indexer_projection),
  desired: INDEXER, current: indexer_current
)
duplicate_indexers = deep_copy(indexer_state)
duplicate_indexers.fetch("indexers") << deep_copy(INDEXER).merge("id" => 32)
exercise_duplicate(
  failures, relationship: "Prowlarr indexer", kind: :indexer,
  state: duplicate_indexers, variables: {}, write_matcher: indexer_write
)
malformed_indexer_declaration = deep_copy(INDEXER_DECLARATION)
malformed_indexer_declaration.fetch("fields").last.delete("value")
indexer_declaration_preflight_state = deep_copy(indexer_state)
indexer_declaration_preflight_state.fetch("indexers").first["priority"] = 50
exercise_duplicate(
  failures, relationship: "Prowlarr malformed later indexer declaration", kind: :indexer,
  state: indexer_declaration_preflight_state,
  variables: {
    "media_arr_indexers" => [
      deep_copy(INDEXER_DECLARATION), malformed_indexer_declaration.merge(
        "name" => "Malformed Later Indexer"
      )
    ]
  },
  write_matcher: indexer_write
)
malformed_later_current_indexer_state = deep_copy(indexer_declaration_preflight_state)
malformed_later_current_indexer_state.fetch("indexers") << {
  "id" => 33,
  "name" => "Malformed Later Current Indexer",
  "fields" => [{ "name" => "baseUrl" }]
}
exercise_duplicate(
  failures, relationship: "Prowlarr malformed later current indexer", kind: :indexer,
  state: malformed_later_current_indexer_state,
  variables: {}, write_matcher: indexer_write
)

if ENV["ACQUISITION_RELATIONSHIPS_TARGETED_ONLY"] == "1"
  abort failures.join("\n") unless failures.empty?
  puts "media acquisition relationship reconciliation behavior holds"
  exit
end
end

FINGERPRINT_BASELINE_CACHE["enabled"] = true if OPAQUE_TARGETED_ONLY

%w[matching stale_input stale_state stale_opaque].each_case(failures) do |scenario, failures; before, callback_directory, env, fingerprint_variables, playbook, result, runtime, state, variables|
  Dir.mktmpdir("media-acquisition-configarr-verify-only-") do |directory|
    runtime = File.join(directory, "runtime")
    FileUtils.mkdir_p(File.join(runtime, "services", "arr"))
    state = {
      "configarr" => deep_copy(CONFIGARR),
      "configarr_desired" => deep_copy(CONFIGARR)
    }
    if scenario == "stale_state"
      state.dig("configarr", "radarr", "qualityprofile").first["minFormatScore"] = 999
    elsif scenario == "stale_opaque"
      definition = state.dig("configarr", "sonarr", "qualitydefinition").find do |item|
        item.dig("quality", "name") == "Raw-HD"
      end
      definition["id"] += 100
    end
    with_api(state) do |api|
      instances = [SERVARR_INSTANCE, SONARR_INSTANCE].map do |instance|
        deep_copy(instance).merge(
          "api" => "http://127.0.0.1:#{api.port}/#{instance.fetch('name')}/api/v3"
        )
      end
      variables = base_variables(api.port).merge(
        "platform_runtime_dir" => runtime,
        "arr_servarr_instances" => instances
      )
      fingerprint_variables = deep_copy(variables)
      if scenario == "stale_input"
        fingerprint_variables["vault_arr_radarr_api_key"] = "private-stale-radarr-apikey"
      end
      seed_fingerprint_baseline(
        runtime, fingerprint_variables, kind: :configarr, state: state
      )
      before = fingerprint_snapshot(runtime)
      callback_directory = write_event_callback(directory)
      env = {
        "ANSIBLE_NOCOLOR" => "1", "ANSIBLE_CALLBACK_PLUGINS" => callback_directory,
        "ANSIBLE_CALLBACKS_ENABLED" => "acquisition_fixture_events",
        "ACQUISITION_FIXTURE_EVENT_LOG" => File.join(directory, "ansible-events.jsonl")
      }
      playbook = File.join(directory, "playbook.yml")
      write_playbook(playbook, variables, configarr_verify_only_tasks)
      result = run_playbook(playbook, env, "--tags", "platform_verify_arr")
      if scenario == "matching"
        failures << "Configarr verify-only matching state failed: #{sanitized_tail(result)}" unless
          result.fetch("status").success?
      elsif result.fetch("status").success?
        failures << "Configarr verify-only #{scenario.tr('_', ' ')} was accepted"
      end
      failures << "Configarr verify-only #{scenario} reached a mutation" unless
        mutation_requests(api, ->(_request) { true }).empty?
      failures << "Configarr verify-only #{scenario} changed reconciliation hashes" unless
        fingerprint_snapshot(runtime) == before
    end
  end
end

abort failures.join("\n") unless failures.empty?
puts "media acquisition reconciliation (core) behavior holds"
