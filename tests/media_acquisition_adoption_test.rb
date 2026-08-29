#!/usr/bin/env ruby

require "fileutils"
require "open3"
require "tmpdir"
require "yaml"

ROOT = File.expand_path("..", __dir__)
TASK_PATH = File.join(ROOT, "roles", "arr", "tasks", "state_guard.yml")

failures = []
unless File.file?(TASK_PATH)
  warn "Arr adoption guard task must exist"
  exit 1
end

tasks = YAML.safe_load_file(TASK_PATH)
forbidden_modules = %w[
  ansible.builtin.copy ansible.builtin.file ansible.builtin.template
  ansible.builtin.command ansible.builtin.shell
]
tasks.each do |task|
  forbidden_modules.each do |module_name|
    failures << "adoption guard must be read-only (#{module_name})" if task.key?(module_name)
  end
end

cases = {
  [false, false, false] => true,
  [false, true, false] => true,
  [true, false, false] => false,
  [true, false, true] => true,
  [true, true, false] => true
}

cases.each do |(library_nonempty, state_present, adopt_input), expected_success|
  Dir.mktmpdir("media-acquisition-adoption-") do |root|
    paths = {
      "arr_movies_host_path" => File.join(root, "Media", "Movies"),
      "arr_series_host_path" => File.join(root, "Media", "Series"),
      "arr_radarr_config_host_path" => File.join(root, "Docker", "radarr", "config"),
      "arr_sonarr_config_host_path" => File.join(root, "Docker", "sonarr", "config"),
      "arr_prowlarr_config_host_path" => File.join(root, "Docker", "prowlarr", "config"),
      "arr_bazarr_config_host_path" => File.join(root, "Docker", "bazarr", "config")
    }
    paths.each_value { |path| FileUtils.mkdir_p(path) }

    if library_nonempty
      File.write(File.join(paths.fetch("arr_movies_host_path"), "existing.mkv"), "fixture")
      FileUtils.mkdir_p(File.join(paths.fetch("arr_series_host_path"), "Existing Series"))
      File.write(File.join(paths.fetch("arr_series_host_path"), "Existing Series", "episode.mkv"), "fixture")
    end
    if state_present
      File.write(File.join(paths.fetch("arr_radarr_config_host_path"), "radarr.db"), "fixture")
      File.write(File.join(paths.fetch("arr_sonarr_config_host_path"), "sonarr.db"), "fixture")
      File.write(File.join(paths.fetch("arr_prowlarr_config_host_path"), "prowlarr.db"), "fixture")
      FileUtils.mkdir_p(File.join(paths.fetch("arr_bazarr_config_host_path"), "db"))
      File.write(File.join(paths.fetch("arr_bazarr_config_host_path"), "db", "bazarr.db"), "fixture")
    end

    playbook = File.join(root, "playbook.yml")
    variables = paths.merge("media_acquisition_adopt_existing_libraries" => adopt_input)
    File.write(playbook, YAML.dump([{
      "name" => "Exercise Arr adoption guard",
      "hosts" => "localhost",
      "gather_facts" => false,
      "vars" => variables,
      "tasks" => [{
        "name" => "Run guard",
        "ansible.builtin.include_role" => {
          "name" => "arr",
          "tasks_from" => "state_guard"
        }
      }]
    }]))

    _stdout, stderr, status = Open3.capture3(
      { "ANSIBLE_ROLES_PATH" => File.join(ROOT, "roles") },
      "ansible-playbook", "-i", "localhost,", "-c", "local", playbook,
      chdir: ROOT
    )
    actual_success = status.success?
    failures << "guard matrix #{[library_nonempty, state_present, adopt_input].inspect} " \
                "expected success=#{expected_success}, got success=#{actual_success}: " \
                "#{stderr.lines.last&.strip}" unless actual_success == expected_success
  end
end

# Persistence is a property of one task: a writing module whose arguments name
# the one-run input. The pattern this replaced ran with /m over the whole file,
# so any writing module anywhere and any later mention of the variable matched,
# whether or not they were the same task — and a rename that split them across
# tasks would have hidden a real one.
PERSISTING_MODULES = /\.(copy|template|lineinfile|blockinfile)\z/
def guard_task_strings(node)
  case node
  when Hash then node.flat_map { |key, value| [key.to_s] + guard_task_strings(value) }
  when Array then node.flat_map { |value| guard_task_strings(value) }
  when String then [node]
  else []
  end
end
guard_tasks = Array(YAML.safe_load_file(TASK_PATH, aliases: true))
failures << "guard must never persist the one-run adoption input" if
  guard_tasks.any? do |task|
    task.is_a?(Hash) && task.keys.any? { |key| key.to_s.match?(PERSISTING_MODULES) } &&
      guard_task_strings(task).any? do |value|
        value.include?("media_acquisition_adopt_existing_libraries")
      end
  end

if failures.empty?
  puts "media acquisition adoption: refusal and one-run bypass matrix holds"
else
  warn failures.join("\n")
  exit 1
end
