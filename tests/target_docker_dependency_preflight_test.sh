#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
fixture=$(mktemp -d "${TMPDIR:-/tmp}/target-docker-preflight.XXXXXX")
trap 'rm -rf "$fixture"' EXIT HUP INT TERM

python3 -m venv --without-pip "$fixture/python"
marker=$fixture/mutated
play=$fixture/preflight.yml
cat > "$play" <<EOF
---
- name: Exercise target Docker dependency preflight
  hosts: localhost
  connection: local
  gather_facts: true
  tasks:
    - name: Validate target Docker module dependencies
      ansible.builtin.include_role:
        name: preflight
        tasks_from: target_docker_dependencies
    - name: Mutation sentinel after dependency preflight
      ansible.builtin.file:
        path: $marker
        state: touch
EOF

status=0
output=$(ANSIBLE_ROLES_PATH="$repo_dir/roles" ansible-playbook -i localhost, "$play" \
  -e ansible_python_interpreter="$fixture/python/bin/python" 2>&1) || status=$?
[ "$status" -ne 0 ] || {
  printf '%s\n' 'target dependency preflight accepted an interpreter without requests' >&2
  exit 1
}
printf '%s\n' "$output" | grep -qF \
  'The managed Python interpreter must be able to import requests before host preparation.' || {
    printf 'target dependency preflight failed for the wrong reason:\n%s\n' "$output" >&2
    exit 1
  }
[ ! -e "$marker" ] || {
  printf '%s\n' 'target dependency preflight mutated state before refusing missing requests' >&2
  exit 1
}

ruby -ryaml -e '
  root = ARGV.fetch(0)
  ["site.yml", "verify.yml"].each do |relative|
    play = YAML.safe_load_file(File.join(root, relative)).first
    dependency = Array(play["pre_tasks"]).index do |task|
      task.dig("ansible.builtin.include_role", "name") == "preflight" &&
        task.dig("ansible.builtin.include_role", "tasks_from") == "target_docker_dependencies"
    end
    abort "#{relative} must run target Docker dependency preflight first" unless dependency == 0
  end
' "$repo_dir"

printf '%s\n' 'target Docker dependency preflight: missing requests refuses before mutation'
