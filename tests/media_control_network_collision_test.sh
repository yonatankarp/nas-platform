#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
fixture=$(mktemp -d "${TMPDIR:-/tmp}/media-control-collision.XXXXXX")
suffix=$(basename "$fixture" | tr '[:upper:].' '[:lower:]-')
network=nas-platform-$suffix-media-control
container=nas-platform-$suffix-endpoint
ansible_python=$(ansible-playbook --version |
  sed -n 's/^  python version = .* (\(\/[^()]*\))$/\1/p')
[ -x "$ansible_python" ] || {
  printf '%s\n' 'Ansible managed Python interpreter is unavailable' >&2
  exit 1
}

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$fixture"
}
trap cleanup EXIT HUP INT TERM

ruby -ryaml -e '
  root, output = ARGV
  names = [
    "Inspect an existing exact-name media control network",
    "Refuse an existing media control network owned by another project",
    "Create the external media control network"
  ]
  tasks = YAML.safe_load_file(File.join(root, "roles/host_prep/tasks/main.yml"))
  selected = names.map { |name| tasks.find { |task| task["name"] == name } }
  abort "media control network task extraction is incomplete" if selected.any?(&:nil?)
  play = [{ "name" => "Exercise exact-name media control collision", "hosts" => "localhost",
            "connection" => "local", "gather_facts" => false, "tasks" => selected }]
  File.write(output, YAML.dump(play))
' "$repo_dir" "$fixture/play.yml"

for collision in unlabeled wrong_labels; do
  case $collision in
    unlabeled)
      docker network create --driver bridge "$network" >/dev/null
      ;;
    wrong_labels)
      docker network create --driver bridge \
        --label nas.platform.purpose=media-control \
        --label nas.platform.project=somebody-else "$network" >/dev/null
      ;;
  esac
  docker create --name "$container" --network "$network" ruby:3.2-alpine sleep 300 >/dev/null
  docker start "$container" >/dev/null
  before_id=$(docker network inspect "$network" --format '{{.Id}}')
  endpoint_id=$(docker inspect "$container" --format '{{.Id}}')

  status=0
  output=$(ANSIBLE_ROLES_PATH="$repo_dir/roles" ansible-playbook -i localhost, "$fixture/play.yml" \
    -e platform_media_control_network="$network" \
    -e platform_project_name=nas-platform-collision-owner \
    -e ansible_python_interpreter="$ansible_python" 2>&1) || status=$?
  [ "$status" -ne 0 ] && printf '%s\n' "$output" | grep -qF \
    "Refusing to modify the existing $network network" || {
      printf '%s collision was not refused safely:\n%s\n' "$collision" "$output" >&2
      exit 1
    }
  [ "$(docker network inspect "$network" --format '{{.Id}}')" = "$before_id" ] || {
    printf '%s\n' "$collision collision replaced the existing network" >&2
    exit 1
  }
  docker network inspect "$network" --format '{{range $id, $_ := .Containers}}{{$id}}{{end}}' |
    grep -qF "$endpoint_id" || {
      printf '%s\n' "$collision collision disconnected the unrelated endpoint" >&2
      exit 1
    }

  docker rm -f "$container" >/dev/null
  docker network rm "$network" >/dev/null
done

printf '%s\n' 'media control network collision: wrong ownership refuses without mutation'
