#!/bin/sh
set -eu

mac_test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_dir=$(CDPATH= cd -- "$mac_test_dir/../.." && pwd -P)
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/nas-platform-config-isolation.XXXXXX")
trap 'rm -f -- "$temporary_dir"/*.json; rmdir -- "$temporary_dir"' EXIT HUP INT TERM

render() {
  label=$1
  base_name=$2
  beszel_port=$3
  ntfy_port=$4
  dozzle_port=$5
  audiobookshelf_port=$6

  env PLATFORM_PROJECT_NAME="$base_name" BESZEL_HOST_PORT="$beszel_port" \
    NAS_DOCKER_ROOT="$temporary_dir/$label" NAS_MEDIA_ROOT="$temporary_dir/$label-media" \
    NAS_RENDER_DEVICE=/dev/null BESZEL_APP_URL="http://127.0.0.1:$beszel_port" \
    BESZEL_SYSTEM_NAME=test BESZEL_AGENT_KEY=test BESZEL_AGENT_TOKEN=test TZ=UTC \
    docker compose --project-name "$base_name-beszel" \
      -f "$repo_dir/services/beszel/compose.yml" \
      -f "$repo_dir/services/beszel/compose.mac.yml" config --format json \
      > "$temporary_dir/$label-beszel.json"

  env PLATFORM_PROJECT_NAME="$base_name" NTFY_HOST_PORT="$ntfy_port" \
    NAS_DOCKER_ROOT="$temporary_dir/$label" NAS_UID=1000 NAS_GID=100 \
    NTFY_BASE_URL="http://127.0.0.1:$ntfy_port" NTFY_AUTH_USERS= \
    NTFY_AUTH_ACCESS= NTFY_AUTH_TOKENS= TZ=UTC \
    docker compose --project-name "$base_name-ntfy" \
      -f "$repo_dir/services/ntfy/compose.yml" \
      -f "$repo_dir/services/ntfy/compose.mac.yml" config --format json \
    > "$temporary_dir/$label-ntfy.json"

  env PLATFORM_PROJECT_NAME="$base_name" DOZZLE_HOST_PORT="$dozzle_port" \
    NAS_DOCKER_ROOT="$temporary_dir/$label" NAS_UID=1000 NAS_GID=100 TZ=UTC \
    docker compose --project-name "$base_name-dozzle" \
      -f "$repo_dir/services/dozzle/compose.yml" \
      -f "$repo_dir/services/dozzle/compose.mac.yml" config --format json \
      > "$temporary_dir/$label-dozzle.json"

  env PLATFORM_PROJECT_NAME="$base_name" AUDIOBOOKSHELF_HOST_PORT="$audiobookshelf_port" \
    AUDIOBOOKSHELF_CONFIG_PATH="$temporary_dir/$label-audiobookshelf-config" \
    AUDIOBOOKSHELF_METADATA_PATH="$temporary_dir/$label-audiobookshelf-metadata" \
    AUDIOBOOKSHELF_MEDIA_PATH="$temporary_dir/$label-audiobooks" TZ=UTC \
    docker compose --project-name "$base_name-audiobookshelf" \
      -f "$repo_dir/services/audiobookshelf/compose.yml" \
      -f "$repo_dir/services/audiobookshelf/compose.mac.yml" config --format json \
      > "$temporary_dir/$label-audiobookshelf.json"
}

render first nas-platform-mac-first 38090 32586 38080 33378
render second nas-platform-mac-second 38091 32587 38081 33379

ruby -rjson - "$temporary_dir" <<'RUBY'
directory = ARGV.fetch(0)
first_beszel = JSON.parse(File.read(File.join(directory, "first-beszel.json")))
second_beszel = JSON.parse(File.read(File.join(directory, "second-beszel.json")))
first_ntfy = JSON.parse(File.read(File.join(directory, "first-ntfy.json")))
second_ntfy = JSON.parse(File.read(File.join(directory, "second-ntfy.json")))
first_dozzle = JSON.parse(File.read(File.join(directory, "first-dozzle.json")))
second_dozzle = JSON.parse(File.read(File.join(directory, "second-dozzle.json")))
first_audiobookshelf = JSON.parse(File.read(File.join(directory, "first-audiobookshelf.json")))
second_audiobookshelf = JSON.parse(File.read(File.join(directory, "second-audiobookshelf.json")))

def published(config, service)
  config.dig("services", service, "ports", 0, "published").to_s
end

raise "Beszel project namespaces collide" if first_beszel["name"] == second_beszel["name"]
raise "ntfy project namespaces collide" if first_ntfy["name"] == second_ntfy["name"]
raise "Dozzle project namespaces collide" if first_dozzle["name"] == second_dozzle["name"]
raise "Audiobookshelf project namespaces collide" if first_audiobookshelf["name"] == second_audiobookshelf["name"]
first_beszel.fetch("services").each_key do |service|
  first_name = first_beszel.dig("services", service, "container_name")
  second_name = second_beszel.dig("services", service, "container_name")
  raise "Beszel #{service} container name is absent" unless first_name && second_name
  raise "Beszel #{service} container names collide" if first_name == second_name
end
raise "ntfy container names collide" if first_ntfy.dig("services", "ntfy", "container_name") ==
                                        second_ntfy.dig("services", "ntfy", "container_name")
first_dozzle.fetch("services").each_key do |service|
  first_name = first_dozzle.dig("services", service, "container_name")
  second_name = second_dozzle.dig("services", service, "container_name")
  raise "Dozzle #{service} container name is absent" unless first_name && second_name
  raise "Dozzle #{service} container names collide" if first_name == second_name
end
raise "Beszel published ports collide" if published(first_beszel, "hub") == published(second_beszel, "hub")
raise "ntfy published ports collide" if published(first_ntfy, "ntfy") == published(second_ntfy, "ntfy")
raise "Dozzle published ports collide" if published(first_dozzle, "dozzle") == published(second_dozzle, "dozzle")
raise "Audiobookshelf container names collide" if
  first_audiobookshelf.dig("services", "audiobookshelf", "container_name") ==
    second_audiobookshelf.dig("services", "audiobookshelf", "container_name")
raise "Audiobookshelf published ports collide" if
  published(first_audiobookshelf, "audiobookshelf") == published(second_audiobookshelf, "audiobookshelf")
raise "Mac socket proxy publishes a host port" if first_beszel.dig("services", "socket-proxy").key?("ports")
raise "Dozzle socket proxy publishes a host port" if first_dozzle.dig("services", "socket-proxy").key?("ports")

puts "Mac Compose isolation: distinct projects, names, and ports"
RUBY
