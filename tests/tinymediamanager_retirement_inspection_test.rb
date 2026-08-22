#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"
require "yaml"

ROOT = File.expand_path("..", __dir__)
ROLE_PATH = File.join(ROOT, "roles/tinymediamanager/tasks/main.yml")
TASKS = YAML.safe_load_file(ROLE_PATH, aliases: true)
INSPECTION = TASKS.find do |task|
  task["name"] == "Inspect the retired tinyMediaManager container"
end
ABSENCE_ASSERTION = TASKS.find do |task|
  task["name"] == "Require tinyMediaManager to remain retired"
end
abort "retirement inspection tasks are absent" unless INSPECTION && ABSENCE_ASSERTION

def run_scenario(container_names, docker_status: 0)
  Dir.mktmpdir("tinymediamanager-retirement-inspection") do |directory|
    bin = File.join(directory, "bin")
    FileUtils.mkdir(bin)
    docker = File.join(bin, "docker")
    File.write(docker, <<~SH, mode: "w", perm: 0o700)
      #!/bin/sh
      [ "$#" -eq 5 ] &&
        [ "$1" = container ] && [ "$2" = ls ] && [ "$3" = --all ] &&
        [ "$4" = --format ] && [ "$5" = '{{.Names}}' ] || exit 64
      #{container_names.map { |name| "printf '%s\\n' #{name.dump}" }.join("\n")}
      exit #{docker_status}
    SH

    playbook = File.join(directory, "inspection.yml")
    File.write(playbook, [{
      "name" => "Exercise exact tinyMediaManager retirement inspection",
      "hosts" => "localhost",
      "connection" => "local",
      "gather_facts" => false,
      "vars" => {
        "tinymediamanager_container_name" => "nas.prod-tinymediamanager",
        "tinymediamanager_post_retirement_state" => {
          "stat" => { "exists" => true, "isdir" => true, "islnk" => false }
        }
      },
      "tasks" => [INSPECTION, ABSENCE_ASSERTION]
    }].to_yaml)

    env = {
      "ANSIBLE_CONFIG" => File.join(ROOT, "ansible.cfg"),
      "PATH" => "#{bin}:#{ENV.fetch('PATH')}"
    }
    Open3.capture3(env, "ansible-playbook", "-i", "localhost,", playbook)
  end
end

_stdout, stderr, status = run_scenario(["nasXprod-tinymediamanager"])
abort "confusable container name was treated as the configured name: #{stderr}" unless status.success?

_stdout, _stderr, status = run_scenario(
  ["nasXprod-tinymediamanager", "nas.prod-tinymediamanager"]
)
abort "configured container name was not detected" if status.success?

_stdout, _stderr, status = run_scenario([], docker_status: 70)
abort "Docker inspection failure was accepted as container absence" if status.success?

puts "tinyMediaManager retirement inspection behavior passed"
