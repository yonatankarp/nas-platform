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
  root, output, race_output = ARGV
  names = [
    "Inspect an existing exact-name media control network",
    "Refuse an existing media control network owned by another project",
    "Create the external media control network",
    "Inspect the exact media control network after create-only handling",
    "Require the exact media control network after create-only handling"
  ]
  tasks = YAML.safe_load_file(File.join(root, "roles/host_prep/tasks/main.yml"))
  selected = names.map { |name| tasks.find { |task| task["name"] == name } }
  abort "media control network task extraction is incomplete" if selected.any?(&:nil?)
  play = [{ "name" => "Exercise exact-name media control collision", "hosts" => "localhost",
            "connection" => "local", "gather_facts" => false, "tasks" => selected }]
  File.write(output, YAML.dump(play))

  late_collision = [
    {
      "name" => "Inject a late unowned media control network",
      "ansible.builtin.command" => {
        "argv" => ["docker", "network", "create", "--driver", "bridge",
                   "{{ platform_media_control_network }}"]
      },
      "changed_when" => true
    },
    {
      "name" => "Attach an unrelated endpoint to the late collision",
      "ansible.builtin.command" => {
        "argv" => ["docker", "create", "--name", "{{ collision_container }}",
                   "--network", "{{ platform_media_control_network }}",
                   "ruby:3.2-alpine", "sleep", "300"]
      },
      "changed_when" => true
    },
    {
      "name" => "Start the unrelated late-collision endpoint",
      "ansible.builtin.command" => {
        "argv" => ["docker", "start", "{{ collision_container }}"]
      },
      "changed_when" => true
    },
    {
      "name" => "Capture the late collision before production creation",
      "ansible.builtin.command" => {
        "argv" => ["docker", "network", "inspect", "{{ platform_media_control_network }}"]
      },
      "register" => "late_collision_inspection",
      "changed_when" => false
    },
    {
      "name" => "Record the original late-collision network ID",
      "ansible.builtin.copy" => {
        "content" => "{{ (late_collision_inspection.stdout | from_json | first).Id }}\n",
        "dest" => "{{ race_network_id_file }}",
        "mode" => "0600"
      }
    }
  ]
  race_tasks = selected[0, 2] + late_collision + selected[2..]
  race_play = [{ "name" => "Exercise a late exact-name media control collision",
                 "hosts" => "localhost", "connection" => "local",
                 "gather_facts" => false, "tasks" => race_tasks }]
  File.write(race_output, YAML.dump(race_play))
' "$repo_dir" "$fixture/play.yml" "$fixture/race-play.yml"

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

docker network create --driver bridge \
  --label nas.platform.purpose=media-control \
  --label nas.platform.project=nas-platform-collision-owner "$network" >/dev/null
before_id=$(docker network inspect "$network" --format '{{.Id}}')
ANSIBLE_ROLES_PATH="$repo_dir/roles" ansible-playbook -i localhost, "$fixture/play.yml" \
  -e platform_media_control_network="$network" \
  -e platform_project_name=nas-platform-collision-owner \
  -e ansible_python_interpreter="$ansible_python" >/dev/null
[ "$(docker network inspect "$network" --format '{{.Id}}')" = "$before_id" ] || {
  printf '%s\n' 'an exact existing network was replaced instead of remaining idempotent' >&2
  exit 1
}
docker network rm "$network" >/dev/null

ANSIBLE_ROLES_PATH="$repo_dir/roles" ansible-playbook -i localhost, "$fixture/play.yml" \
  -e platform_media_control_network="$network" \
  -e platform_project_name=nas-platform-collision-owner \
  -e ansible_python_interpreter="$ansible_python" >/dev/null
[ "$(docker network inspect "$network" --format '{{.Driver}}')" = bridge ] || {
  printf '%s\n' 'an absent network was not created with the bridge driver' >&2
  exit 1
}
docker network inspect "$network" --format '{{json .Labels}}' |
  ruby -rjson -e '
    expected = {
      "nas.platform.purpose" => "media-control",
      "nas.platform.project" => "nas-platform-collision-owner"
    }
    abort "created network labels differ from the exact ownership set" unless
      JSON.parse(STDIN.read) == expected
  '
docker network rm "$network" >/dev/null

status=0
output=$(ANSIBLE_ROLES_PATH="$repo_dir/roles" ansible-playbook -i localhost, \
  "$fixture/race-play.yml" \
  -e platform_media_control_network="$network" \
  -e platform_project_name=nas-platform-collision-owner \
  -e collision_container="$container" \
  -e race_network_id_file="$fixture/race-network-id" \
  -e ansible_python_interpreter="$ansible_python" 2>&1) || status=$?
[ "$status" -ne 0 ] || {
  printf 'late collision was reconciled instead of refused atomically:\n%s\n' "$output" >&2
  exit 1
}
before_id=$(sed -n '1p' "$fixture/race-network-id")
[ "$(docker network inspect "$network" --format '{{.Id}}')" = "$before_id" ] || {
  printf '%s\n' 'late collision was replaced after initial absence inspection' >&2
  exit 1
}
endpoint_id=$(docker inspect "$container" --format '{{.Id}}')
docker network inspect "$network" --format '{{range $id, $_ := .Containers}}{{$id}}{{end}}' |
  grep -qF "$endpoint_id" || {
    printf '%s\n' 'late collision disconnected the unrelated endpoint' >&2
    exit 1
  }

printf '%s\n' 'media control network collision: pre-existing and late ownership conflicts refuse without mutation'
