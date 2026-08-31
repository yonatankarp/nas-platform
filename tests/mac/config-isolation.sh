#!/bin/sh
set -eu

mac_test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_dir=$(CDPATH= cd -- "$mac_test_dir/../.." && pwd -P)
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/nas-platform-config-isolation.XXXXXX")
trap 'rm -f -- "$temporary_dir"/*.json; rmdir -- "$temporary_dir"' EXIT HUP INT TERM
export PLATFORM_CONTAINER_CPUSET=0-2

render() {
  label=$1
  base_name=$2
  beszel_port=$3
  ntfy_port=$4
  dozzle_port=$5
  audiobookshelf_port=$6
  komga_port=$7
  jellyfin_port=$8
  immich_port=$9
  paperless_port=${10}
  radarr_port=${11}
  sonarr_port=${12}
  prowlarr_port=${13}
  bazarr_port=${14}
  sabnzbd_port=${15}
  pinchflat_port=${16}
  kapowarr_port=${17}
  bindery_port=${18}

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
    PLATFORM_CURRENT_DIR="$repo_dir" DOZZLE_STATE_ROOT="$temporary_dir/$label/dozzle/data" \
    ALERT_RELAY_SCRIPT_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    ALERT_RELAY_TOKEN=test-relay-token ALERT_RELAY_PORT=8081 \
    NTFY_PUBLISH_URL="http://127.0.0.1:$ntfy_port/" \
    NTFY_TOPIC=nas-critical NTFY_CONTAINERS_TOPIC=nas-containers NTFY_TOKEN=test-ntfy-token \
    docker compose --project-name "$base_name-dozzle" \
      -f "$repo_dir/services/dozzle/compose.yml" \
      -f "$repo_dir/services/dozzle/compose.mac.yml" config --format json \
      > "$temporary_dir/$label-dozzle.json"

  env PLATFORM_PROJECT_NAME="$base_name" AUDIOBOOKSHELF_HOST_PORT="$audiobookshelf_port" \
    PLATFORM_MEDIA_NETWORK="$base_name-media-control" NAS_UID=1000 NAS_GID=100 \
    PLATFORM_DOCKER_ROOT="$temporary_dir/$label" \
    AUDIOBOOKSHELF_CONFIG_PATH="$temporary_dir/$label-audiobookshelf-config" \
    AUDIOBOOKSHELF_METADATA_PATH="$temporary_dir/$label-audiobookshelf-metadata" \
    AUDIOBOOKSHELF_MEDIA_PATH="$temporary_dir/$label-audiobooks" \
    AUDIOBOOKSHELF_BACKUP_PATH="$temporary_dir/$label/audiobookshelf/backups" TZ=UTC \
    docker compose --project-name "$base_name-audiobookshelf" \
      -f "$repo_dir/services/audiobookshelf/compose.yml" \
      -f "$repo_dir/services/audiobookshelf/compose.mac.yml" config --format json \
      > "$temporary_dir/$label-audiobookshelf.json"

  env PLATFORM_PROJECT_NAME="$base_name" KOMGA_HOST_PORT="$komga_port" \
    NAS_UID=1000 NAS_GID=100 \
    KOMGA_CONFIG_PATH="$temporary_dir/$label-komga-config" \
    KOMGA_LIBRARY_PATH="$temporary_dir/$label-books" TZ=UTC \
    docker compose --project-name "$base_name-komga" \
      -f "$repo_dir/services/komga/compose.yml" \
      -f "$repo_dir/services/komga/compose.mac.yml" config --format json \
      > "$temporary_dir/$label-komga.json"

  env PLATFORM_PROJECT_NAME="$base_name" JELLYFIN_HOST_PORT="$jellyfin_port" \
    PLATFORM_MEDIA_NETWORK="$base_name-media-control" NAS_UID=1000 NAS_GID=100 \
    JELLYFIN_CONFIG_PATH="$temporary_dir/$label-jellyfin-config" \
    JELLYFIN_CACHE_PATH="$temporary_dir/$label-jellyfin-cache" \
    JELLYFIN_MEDIA_PATH="$temporary_dir/$label-media" TZ=UTC \
    docker compose --project-name "$base_name-jellyfin" \
      -f "$repo_dir/services/jellyfin/compose.yml" \
      -f "$repo_dir/services/jellyfin/compose.mac.yml" config --format json \
      > "$temporary_dir/$label-jellyfin.json"

  env PLATFORM_PROJECT_NAME="$base_name" IMMICH_HOST_PORT="$immich_port" \
    NAS_DOCKER_ROOT="$temporary_dir/$label" NAS_MEDIA_ROOT="$temporary_dir/$label-media" \
    IMMICH_DB_NAME=test IMMICH_DB_USERNAME=test IMMICH_DB_PASSWORD=test TZ=UTC \
    docker compose --project-name "$base_name-immich" \
      -f "$repo_dir/services/immich/compose.yml" \
      -f "$repo_dir/services/immich/compose.mac.yml" config --format json \
      > "$temporary_dir/$label-immich.json"

  env PLATFORM_PROJECT_NAME="$base_name" PAPERLESS_HOST_PORT="$paperless_port" \
    PAPERLESS_POSTGRES_PATH="$temporary_dir/$label-paperless-postgres" \
    PAPERLESS_REDIS_PATH="$temporary_dir/$label-paperless-redis" \
    PAPERLESS_DATA_PATH="$temporary_dir/$label-paperless-data" \
    PAPERLESS_CACHE_PATH="$temporary_dir/$label-paperless-cache" \
    PAPERLESS_TESSDATA_PATH="$temporary_dir/$label-paperless-tessdata" \
    PAPERLESS_MEDIA_PATH="$temporary_dir/$label-paperless-media" \
    PAPERLESS_CONSUME_PATH="$temporary_dir/$label-paperless-consume" \
    PAPERLESS_EXPORT_PATH="$temporary_dir/$label-paperless-export" \
    PAPERLESS_ADMIN_USER=test PAPERLESS_ADMIN_PASSWORD=test PAPERLESS_ADMIN_MAIL=test@example.invalid \
    PAPERLESS_DBHOST=db PAPERLESS_REDIS=redis://broker:6379 \
    PAPERLESS_TIKA_ENDPOINT=http://tika:9998 PAPERLESS_GOTENBERG_ENDPOINT=http://gotenberg:3000 \
    PAPERLESS_AI_ENABLED=false PAPERLESS_AI_LLM_ENDPOINT=http://example.invalid:11434 \
    PAPERLESS_AI_LLM_MODEL=test-model \
    PAPERLESS_SECRET_KEY=test DB_NAME=test DB_USER=test DB_PASSWORD=test \
    USER_ID=1000 GROUP_ID=100 TZ=UTC \
    docker compose --project-name "$base_name-paperless" \
      -f "$repo_dir/services/paperless-ngx/compose.yml" \
      -f "$repo_dir/services/paperless-ngx/compose.mac.yml" config --format json \
      > "$temporary_dir/$label-paperless.json"

  env PLATFORM_PROJECT_NAME="$base_name" PLATFORM_MEDIA_NETWORK="$base_name-media-control" \
    PLATFORM_CONTAINER_CPUSET=0-2 NAS_UID=1000 NAS_GID=100 TZ=UTC \
    MEDIA_ROOT="$temporary_dir/$label-media" \
    RADARR_CONFIG_PATH="$temporary_dir/$label-radarr-config" RADARR_HOST_PORT="$radarr_port" \
    SONARR_CONFIG_PATH="$temporary_dir/$label-sonarr-config" SONARR_HOST_PORT="$sonarr_port" \
    PROWLARR_CONFIG_PATH="$temporary_dir/$label-prowlarr-config" PROWLARR_HOST_PORT="$prowlarr_port" \
    BAZARR_CONFIG_PATH="$temporary_dir/$label-bazarr-config" BAZARR_HOST_PORT="$bazarr_port" \
    CONFIGARR_CONFIG_PATH="$temporary_dir/$label-configarr.yml" \
    CONFIGARR_SECRETS_PATH="$temporary_dir/$label-configarr-secrets.yml" \
    CONFIGARR_REPOS_PATH="$temporary_dir/$label-configarr-repos" \
    docker compose --project-name "$base_name-arr" \
      -f "$repo_dir/services/arr/compose.yml" \
      -f "$repo_dir/services/arr/compose.mac.yml" config --format json \
      > "$temporary_dir/$label-arr.json"

  env PLATFORM_PROJECT_NAME="$base_name" PLATFORM_MEDIA_NETWORK="$base_name-media-control" \
    PLATFORM_CONTAINER_CPUSET=0-2 NAS_UID=1000 NAS_GID=100 TZ=UTC \
    SABNZBD_CONFIG_PATH="$temporary_dir/$label-sabnzbd-config" \
    MEDIA_ACQUISITION_PATH="$temporary_dir/$label-media/Media/.acquisition" \
    BOOKS_ACQUISITION_PATH="$temporary_dir/$label-media/Books/.acquisition" \
    SABNZBD_HOST_PORT="$sabnzbd_port" SABNZBD_API_KEY=test \
    RADARR_API_KEY=test SONARR_API_KEY=test \
    docker compose --project-name "$base_name-downloaders" \
      -f "$repo_dir/services/downloaders/compose.yml" \
      -f "$repo_dir/services/downloaders/compose.mac.yml" config --format json \
      > "$temporary_dir/$label-downloaders.json"

  env PLATFORM_PROJECT_NAME="$base_name" PLATFORM_CONTAINER_CPUSET=0-2 \
    NAS_UID=1000 NAS_GID=100 TZ=UTC \
    PINCHFLAT_CONFIG_PATH="$temporary_dir/$label-pinchflat-config" \
    PINCHFLAT_DOWNLOADS_PATH="$temporary_dir/$label-media/Media/YouTube" \
    PINCHFLAT_HOST_PORT="$pinchflat_port" \
    PINCHFLAT_BASIC_AUTH_USERNAME=test PINCHFLAT_BASIC_AUTH_PASSWORD=test \
    docker compose --project-name "$base_name-pinchflat" \
      -f "$repo_dir/services/pinchflat/compose.yml" \
      -f "$repo_dir/services/pinchflat/compose.mac.yml" config --format json \
      > "$temporary_dir/$label-pinchflat.json"

  env PLATFORM_PROJECT_NAME="$base_name" PLATFORM_CONTAINER_CPUSET=0-2 \
    NAS_UID=1000 NAS_GID=100 TZ=UTC \
    KAPOWARR_CONFIG_PATH="$temporary_dir/$label-kapowarr-config" \
    KAPOWARR_DOWNLOADS_PATH="$temporary_dir/$label-media/Books/.acquisition/usenet/comics" \
    KAPOWARR_COMICS_PATH="$temporary_dir/$label-media/Books/Comics" \
    KAPOWARR_HOST_PORT="$kapowarr_port" \
    docker compose --project-name "$base_name-kapowarr" \
      -f "$repo_dir/services/kapowarr/compose.yml" \
      -f "$repo_dir/services/kapowarr/compose.mac.yml" config --format json \
      > "$temporary_dir/$label-kapowarr.json"

  env PLATFORM_PROJECT_NAME="$base_name" PLATFORM_CONTAINER_CPUSET=0-2 \
    PLATFORM_MEDIA_NETWORK="$base_name-media-control" \
    NAS_UID=1000 NAS_GID=100 TZ=UTC \
    BINDERY_API_KEY=00000000000000000000000000000000 \
    BINDERY_CONFIG_PATH="$temporary_dir/$label-bindery-config" \
    BINDERY_EBOOKS_PATH="$temporary_dir/$label-media/Books/Ebooks" \
    BINDERY_AUDIOBOOKS_PATH="$temporary_dir/$label-media/Media/Audiobooks" \
    BINDERY_EBOOK_DOWNLOADS_PATH="$temporary_dir/$label-media/Books/.acquisition/usenet/ebooks" \
    BINDERY_AUDIOBOOK_DOWNLOADS_PATH="$temporary_dir/$label-media/Media/.acquisition/usenet/audiobooks" \
    BINDERY_HOST_PORT="$bindery_port" \
    docker compose --project-name "$base_name-bindery" \
      -f "$repo_dir/services/bindery/compose.yml" \
      -f "$repo_dir/services/bindery/compose.mac.yml" config --format json \
      > "$temporary_dir/$label-bindery.json"
}

render first nas-platform-mac-first 38090 32586 38080 33378 35600 38096 32283 38000 \
  37878 38989 36969 36767 38082 38945 35656 38787
render second nas-platform-mac-second 38091 32587 38081 33379 35601 38097 32284 38001 \
  37879 38990 36970 36768 38083 38946 35657 38788

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
first_pinchflat = JSON.parse(File.read(File.join(directory, "first-pinchflat.json")))
second_pinchflat = JSON.parse(File.read(File.join(directory, "second-pinchflat.json")))
first_kapowarr = JSON.parse(File.read(File.join(directory, "first-kapowarr.json")))
second_kapowarr = JSON.parse(File.read(File.join(directory, "second-kapowarr.json")))
first_bindery = JSON.parse(File.read(File.join(directory, "first-bindery.json")))
second_bindery = JSON.parse(File.read(File.join(directory, "second-bindery.json")))
first_komga = JSON.parse(File.read(File.join(directory, "first-komga.json")))
second_komga = JSON.parse(File.read(File.join(directory, "second-komga.json")))
first_jellyfin = JSON.parse(File.read(File.join(directory, "first-jellyfin.json")))
second_jellyfin = JSON.parse(File.read(File.join(directory, "second-jellyfin.json")))
first_immich = JSON.parse(File.read(File.join(directory, "first-immich.json")))
second_immich = JSON.parse(File.read(File.join(directory, "second-immich.json")))
first_paperless = JSON.parse(File.read(File.join(directory, "first-paperless.json")))
second_paperless = JSON.parse(File.read(File.join(directory, "second-paperless.json")))
first_arr = JSON.parse(File.read(File.join(directory, "first-arr.json")))
second_arr = JSON.parse(File.read(File.join(directory, "second-arr.json")))
first_downloaders = JSON.parse(File.read(File.join(directory, "first-downloaders.json")))
second_downloaders = JSON.parse(File.read(File.join(directory, "second-downloaders.json")))

def published(config, service)
  config.dig("services", service, "ports", 0, "published").to_s
end

def bind_source(config, service, target)
  mounts = config.dig("services", service, "volumes") || []
  matches = mounts.select { |mount| mount["type"] == "bind" && mount["target"] == target }
  raise "#{service} has an ambiguous #{target} bind" unless matches.length == 1

  matches.fetch(0).fetch("source")
end

def assert_dozzle_aliases_and_distinct_names(first, second, stack)
  first.fetch("services").each_key do |service|
    first_alias = first.dig("services", service, "labels", "dev.dozzle.name")
    second_alias = second.dig("services", service, "labels", "dev.dozzle.name")
    raise "#{stack} first #{service} Dozzle name is not the service key" unless first_alias == service
    raise "#{stack} second #{service} Dozzle name is not the service key" unless second_alias == service

    first_name = first.dig("services", service, "container_name")
    second_name = second.dig("services", service, "container_name")
    raise "#{stack} #{service} container name is absent" unless first_name && second_name
    raise "#{stack} #{service} container names collide" if first_name == second_name
  end
end

[
  [first_beszel, second_beszel, "Beszel"],
  [first_ntfy, second_ntfy, "ntfy"],
  [first_dozzle, second_dozzle, "Dozzle"],
  [first_audiobookshelf, second_audiobookshelf, "Audiobookshelf"],
  [first_komga, second_komga, "Komga"],
  [first_jellyfin, second_jellyfin, "Jellyfin"],
  [first_immich, second_immich, "Immich"],
  [first_paperless, second_paperless, "Paperless"],
  [first_arr, second_arr, "Arr"],
  [first_downloaders, second_downloaders, "downloaders"]
].each do |first, second, stack|
  assert_dozzle_aliases_and_distinct_names(first, second, stack)
end

raise "Beszel project namespaces collide" if first_beszel["name"] == second_beszel["name"]
raise "ntfy project namespaces collide" if first_ntfy["name"] == second_ntfy["name"]
raise "Dozzle project namespaces collide" if first_dozzle["name"] == second_dozzle["name"]
raise "Audiobookshelf project namespaces collide" if first_audiobookshelf["name"] == second_audiobookshelf["name"]
raise "Komga project namespaces collide" if first_komga["name"] == second_komga["name"]
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
raise "first Audiobookshelf backup bind escaped its Docker state root" unless
  bind_source(first_audiobookshelf, "audiobookshelf", "/metadata/backups") ==
    File.join(directory, "first/audiobookshelf/backups")
raise "second Audiobookshelf backup bind escaped its Docker state root" unless
  bind_source(second_audiobookshelf, "audiobookshelf", "/metadata/backups") ==
    File.join(directory, "second/audiobookshelf/backups")
raise "Komga container names collide" if first_komga.dig("services", "komga", "container_name") ==
                                         second_komga.dig("services", "komga", "container_name")
raise "Komga published ports collide" if published(first_komga, "komga") == published(second_komga, "komga")
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
raise "Immich project namespaces collide" if first_immich["name"] == second_immich["name"]
# Immich is four containers; every one of them must be namespaced, or a second
# sandbox would collide on the database or the cache rather than on the server.
first_immich.fetch("services").each_key do |service|
  first_name = first_immich.dig("services", service, "container_name")
  second_name = second_immich.dig("services", service, "container_name")
  raise "Immich #{service} container name is absent" unless first_name && second_name
  raise "Immich #{service} container names collide" if first_name == second_name
end
raise "Immich published ports collide" if
  published(first_immich, "immich-server") == published(second_immich, "immich-server")
raise "Immich Mac runtime kept the NAS render device" unless
  first_immich.dig("services", "immich-server", "devices").to_a.empty?
%w[immich-machine-learning redis database].each do |service|
  raise "Immich #{service} publishes a host port" if
    first_immich.dig("services", service).key?("ports")
end

raise "Paperless project namespaces collide" if first_paperless["name"] == second_paperless["name"]
first_paperless.fetch("services").each_key do |service|
  first_name = first_paperless.dig("services", service, "container_name")
  second_name = second_paperless.dig("services", service, "container_name")
  raise "Paperless #{service} container name is absent" unless first_name && second_name
  raise "Paperless #{service} container names collide" if first_name == second_name
end
raise "Paperless published ports collide" if
  published(first_paperless, "webserver") == published(second_paperless, "webserver")
raise "Paperless Mac runtime left the Compose network" if
  first_paperless.dig("services", "webserver").key?("network_mode")
%w[broker db gotenberg tika].each do |service|
  raise "Paperless #{service} publishes a host port" if
    first_paperless.dig("services", service).key?("ports")
end

%w[radarr sonarr prowlarr bazarr].each do |service|
  raise "Arr #{service} published ports collide" if
    published(first_arr, service) == published(second_arr, service)
end
raise "SABnzbd published ports collide" if
  published(first_downloaders, "sabnzbd") == published(second_downloaders, "sabnzbd")
raise "Unpackerr publishes a host port" if
  first_downloaders.dig("services", "unpackerr").key?("ports")

raise "Pinchflat project namespaces collide" if first_pinchflat["name"] == second_pinchflat["name"]
raise "Pinchflat container names collide" if
  first_pinchflat.dig("services", "pinchflat", "container_name") ==
  second_pinchflat.dig("services", "pinchflat", "container_name")
raise "Pinchflat published ports collide" if
  published(first_pinchflat, "pinchflat") == published(second_pinchflat, "pinchflat")

raise "Kapowarr project namespaces collide" if first_kapowarr["name"] == second_kapowarr["name"]
raise "Kapowarr container names collide" if
  first_kapowarr.dig("services", "kapowarr", "container_name") ==
  second_kapowarr.dig("services", "kapowarr", "container_name")
raise "Kapowarr published ports collide" if
  published(first_kapowarr, "kapowarr") == published(second_kapowarr, "kapowarr")

raise "Bindery project namespaces collide" if first_bindery["name"] == second_bindery["name"]
raise "Bindery container names collide" if
  first_bindery.dig("services", "bindery", "container_name") ==
  second_bindery.dig("services", "bindery", "container_name")
raise "Bindery published ports collide" if
  published(first_bindery, "bindery") == published(second_bindery, "bindery")
# Bindery is the only Phase 2 project on the shared control network, so a
# sandbox copy must take its own rather than joining the neighbour's.
raise "Bindery control networks collide" if
  first_bindery.dig("networks", "media-control", "name") ==
  second_bindery.dig("networks", "media-control", "name")

raise "Mac socket proxy publishes a host port" if first_beszel.dig("services", "socket-proxy").key?("ports")
raise "Dozzle socket proxy publishes a host port" if first_dozzle.dig("services", "socket-proxy").key?("ports")

puts "Mac Compose isolation: distinct projects, names, and ports"
RUBY
