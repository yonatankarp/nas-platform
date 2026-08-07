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
  komga_port=$7
  tinymediamanager_web_port=$8
  tinymediamanager_api_port=$9
  jellyfin_port=${10}

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

  env PLATFORM_PROJECT_NAME="$base_name" KOMGA_HOST_PORT="$komga_port" \
    KOMGA_CONFIG_PATH="$temporary_dir/$label-komga-config" \
    KOMGA_LIBRARY_PATH="$temporary_dir/$label-books" TZ=UTC \
    docker compose --project-name "$base_name-komga" \
      -f "$repo_dir/services/komga/compose.yml" \
      -f "$repo_dir/services/komga/compose.mac.yml" config --format json \
      > "$temporary_dir/$label-komga.json"

  env PLATFORM_PROJECT_NAME="$base_name" \
    TINYMEDIAMANAGER_WEB_HOST_PORT="$tinymediamanager_web_port" \
    TINYMEDIAMANAGER_API_HOST_PORT="$tinymediamanager_api_port" \
    TINYMEDIAMANAGER_DATA_PATH="$temporary_dir/$label-tinymediamanager-data" \
    TINYMEDIAMANAGER_MOVIES_PATH="$temporary_dir/$label-movies" \
    TINYMEDIAMANAGER_SERIES_PATH="$temporary_dir/$label-series" \
    TINYMEDIAMANAGER_PASSWORD=test USER_ID=1000 GROUP_ID=100 TZ=UTC \
    docker compose --project-name "$base_name-tinymediamanager" \
      -f "$repo_dir/services/tinymediamanager/compose.yml" \
      -f "$repo_dir/services/tinymediamanager/compose.mac.yml" config --format json \
      > "$temporary_dir/$label-tinymediamanager.json"

  env PLATFORM_PROJECT_NAME="$base_name" JELLYFIN_HOST_PORT="$jellyfin_port" \
    JELLYFIN_CONFIG_PATH="$temporary_dir/$label-jellyfin-config" \
    JELLYFIN_CACHE_PATH="$temporary_dir/$label-jellyfin-cache" \
    JELLYFIN_MEDIA_PATH="$temporary_dir/$label-media" TZ=UTC \
    docker compose --project-name "$base_name-jellyfin" \
      -f "$repo_dir/services/jellyfin/compose.yml" \
      -f "$repo_dir/services/jellyfin/compose.mac.yml" config --format json \
      > "$temporary_dir/$label-jellyfin.json"
}

render first nas-platform-mac-first 38090 32586 38080 33378 35600 34000 37878 38096
render second nas-platform-mac-second 38091 32587 38081 33379 35601 34001 37879 38097

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
first_komga = JSON.parse(File.read(File.join(directory, "first-komga.json")))
second_komga = JSON.parse(File.read(File.join(directory, "second-komga.json")))
first_tinymediamanager = JSON.parse(File.read(File.join(directory, "first-tinymediamanager.json")))
second_tinymediamanager = JSON.parse(File.read(File.join(directory, "second-tinymediamanager.json")))
first_jellyfin = JSON.parse(File.read(File.join(directory, "first-jellyfin.json")))
second_jellyfin = JSON.parse(File.read(File.join(directory, "second-jellyfin.json")))

def published(config, service)
  config.dig("services", service, "ports", 0, "published").to_s
end

raise "Beszel project namespaces collide" if first_beszel["name"] == second_beszel["name"]
raise "ntfy project namespaces collide" if first_ntfy["name"] == second_ntfy["name"]
raise "Dozzle project namespaces collide" if first_dozzle["name"] == second_dozzle["name"]
raise "Audiobookshelf project namespaces collide" if first_audiobookshelf["name"] == second_audiobookshelf["name"]
raise "Komga project namespaces collide" if first_komga["name"] == second_komga["name"]
raise "tinyMediaManager project namespaces collide" if
  first_tinymediamanager["name"] == second_tinymediamanager["name"]
raise "Jellyfin project namespaces collide" if first_jellyfin["name"] == second_jellyfin["name"]
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
raise "Komga container names collide" if first_komga.dig("services", "komga", "container_name") ==
                                         second_komga.dig("services", "komga", "container_name")
raise "Komga published ports collide" if published(first_komga, "komga") == published(second_komga, "komga")
raise "tinyMediaManager container names collide" if
  first_tinymediamanager.dig("services", "tinymediamanager", "container_name") ==
    second_tinymediamanager.dig("services", "tinymediamanager", "container_name")
tmm_first_ports = first_tinymediamanager.dig("services", "tinymediamanager", "ports").map { |port| port["published"].to_s }.sort
tmm_second_ports = second_tinymediamanager.dig("services", "tinymediamanager", "ports").map { |port| port["published"].to_s }.sort
raise "tinyMediaManager published ports collide" unless (tmm_first_ports & tmm_second_ports).empty?
raise "tinyMediaManager Mac runtime did not replace host networking" unless
  first_tinymediamanager.dig("services", "tinymediamanager", "network_mode") == "bridge"
raise "Jellyfin container names collide" if
  first_jellyfin.dig("services", "jellyfin", "container_name") ==
    second_jellyfin.dig("services", "jellyfin", "container_name")
raise "Jellyfin published ports collide" if
  published(first_jellyfin, "jellyfin") == published(second_jellyfin, "jellyfin")
# The Mac override must drop the NAS render node and the root group that opens
# it, or a Docker Desktop run would fail on a device that does not exist.
raise "Jellyfin Mac runtime kept the NAS render device" unless
  first_jellyfin.dig("services", "jellyfin", "devices").to_a.empty?
raise "Jellyfin Mac runtime kept the NAS root group" unless
  first_jellyfin.dig("services", "jellyfin", "group_add").to_a.empty?
raise "Mac socket proxy publishes a host port" if first_beszel.dig("services", "socket-proxy").key?("ports")
raise "Dozzle socket proxy publishes a host port" if first_dozzle.dig("services", "socket-proxy").key?("ports")

puts "Mac Compose isolation: distinct projects, names, and ports"
RUBY
