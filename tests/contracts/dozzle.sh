#!/bin/sh
set -eu
set +x
umask 077

mode=${1:-verify}
case $mode in
  static|verify|drift|drift-verify|notify|\
  duplicate-dispatcher-create|duplicate-dispatcher-verify|\
  duplicate-dispatcher-assert-output|duplicate-dispatcher-cleanup|\
  duplicate-rule-create|duplicate-rule-verify|duplicate-rule-assert-output|\
  duplicate-rule-cleanup|surplus-create|surplus-verify|surplus-removed|\
  surplus-cleanup|check-mixed-create|check-mixed-unchanged|\
  check-mixed-cleanup|check-mixed-recover|check-missing-create|\
  check-missing-unchanged|check-missing-cleanup|assert-check-mixed-output|\
  assert-check-missing-output|beszel-notify) ;;
  *) exit 2 ;;
esac
[ "$#" -eq 0 ] || shift

# Two roots, and they are not the same thing. $contract_repo_dir is the checkout
# this script belongs to, which is where its six Ruby programs live -- a heredoc
# had that property by construction, because the program travelled inside the
# file. $repo_dir is the tree those programs *inspect*, which
# PLATFORM_CONTRACT_REPO_DIR lets a caller point at a fixture. Resolving a
# program from $repo_dir would make this contract read its own assertions out of
# the tree it is judging.
contract_repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
repo_dir=${PLATFORM_CONTRACT_REPO_DIR:-$contract_repo_dir}
group_render_program=$contract_repo_dir/tests/contracts/dozzle-group-render.rb
labels_program=$contract_repo_dir/tests/contracts/dozzle-labels.rb
stack_program=$contract_repo_dir/tests/contracts/dozzle-stack.rb
alerts_program=$contract_repo_dir/tests/contracts/dozzle-alerts.rb
planned_output_program=$contract_repo_dir/tests/contracts/dozzle-planned-output.rb
runtime_program=$contract_repo_dir/tests/contracts/dozzle-runtime.rb
compose=$repo_dir/services/dozzle/compose.yml
relay_script=$repo_dir/services/dozzle/alert_relay.py
role=$repo_dir/roles/dozzle/tasks/main.yml
defaults=$repo_dir/roles/dozzle/defaults/main.yml
service_vars=$repo_dir/inventory/group_vars/all/service_dozzle.yml
env_template=$repo_dir/roles/dozzle/templates/env.j2
deployment_inputs=$repo_dir/roles/deployment_bundle/tasks/inputs.yml
deployment_bundle=$repo_dir/roles/deployment_bundle/tasks/main.yml
# The five scenario markers this contract insists the integration lane prints
# are spelled in the controller program, not in the launcher that starts it.
integration=$repo_dir/tests/integration_controller.sh
mac_drift=$repo_dir/tests/mac/hooks/drift/20-dozzle.sh
mac_verify=$repo_dir/tests/mac/hooks/verify/20-dozzle.sh
# The verification hook's label assertions are a program beside it since #315.
# Both are read out of the tree under inspection: the hook for the inspection it
# performs, the program for the labels it names.
mac_verify_labels=$repo_dir/tests/mac/hooks/verify/20-dozzle-labels.rb

fail_contract() {
  printf 'Dozzle contract failed: %s\n' "$1" >&2
  exit 1
}

# Deliberately not the deployed 8081: rendering with a value the repo never
# contains is what proves the relay's listener port really is read from one
# variable. A copy left behind anywhere in the alert-relay service renders as
# 8081 and disagrees with this probe.
relay_probe_port=53081

[ -f "$compose" ] || fail_contract 'services/dozzle/compose.yml is absent'
[ -f "$relay_script" ] || fail_contract 'services/dozzle/alert_relay.py is absent'
[ -f "$role" ] || fail_contract 'roles/dozzle/tasks/main.yml is absent'

render_group_contract() {
  stack=$1
  expected_group=$2
  variant=$3
  shift 3
  rendered=$(env \
    PLATFORM_PROJECT_NAME=dozzle-contract PLATFORM_CONTAINER_CPUSET=0-2 \
    PLATFORM_MEDIA_NETWORK=dozzle-contract-media-control \
    PLATFORM_ALERT_RELAY_NETWORK=dozzle-contract-alert-relay \
    PLATFORM_DOCKER_ROOT=/tmp/dozzle-contract/docker \
    PLATFORM_CURRENT_DIR="$repo_dir" DOZZLE_STATE_ROOT=/tmp/dozzle-contract/docker/dozzle/data \
    NAS_DOCKER_ROOT=/tmp/dozzle-contract/docker \
    NAS_MEDIA_ROOT=/tmp/dozzle-contract/media NAS_RENDER_DEVICE=/dev/null \
    NAS_SMART_SATA_DEVICE_1=/dev/null NAS_SMART_SATA_DEVICE_2=/dev/null \
    NAS_SMART_SATA_DEVICE_3=/dev/null NAS_SMART_NVME_NAMESPACE_1=/dev/null \
    NAS_SMART_NVME_NAMESPACE_2=/dev/null \
    NAS_UID=1000 NAS_GID=100 \
    BESZEL_APP_URL=http://127.0.0.1:8090 BESZEL_SYSTEM_NAME=contract \
    BESZEL_AGENT_KEY=contract BESZEL_AGENT_TOKEN=contract BESZEL_HOST_PORT=38090 \
    DOZZLE_HOST_PORT=38080 \
    ALERT_RELAY_SCRIPT_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    ALERT_RELAY_TOKEN=contract-relay-token ALERT_RELAY_PORT="$relay_probe_port" \
    PUSHOVER_API_URL=http://127.0.0.1:1/1/messages.json ALERT_RELAY_LINK_BASE=http://127.0.0.1:38080 \
    PUSHOVER_TOKEN=contract-pushover-token PUSHOVER_USER_KEY=contract-pushover-user-key \
    ALERT_DAILY_CONTAINER_CEILING=10 ALERT_DAILY_OOM_CONTAINER_CEILING=25 \
    ALERT_DAILY_GLOBAL_CEILING=200 \
    PUSHOVER_ALERTS_TOKEN=test-pushover-alerts-token BESZEL_LINK_BASE=http://127.0.0.1:8090 \
    AUDIOBOOKSHELF_HOST_PORT=33378 \
    AUDIOBOOKSHELF_CONFIG_PATH=/tmp/dozzle-contract/audiobookshelf-config \
    AUDIOBOOKSHELF_METADATA_PATH=/tmp/dozzle-contract/audiobookshelf-metadata \
    AUDIOBOOKSHELF_BACKUP_PATH=/tmp/dozzle-contract/audiobookshelf-backups \
    AUDIOBOOKSHELF_MEDIA_PATH=/tmp/dozzle-contract/audiobooks \
    KOMGA_HOST_PORT=35600 KOMGA_CONFIG_PATH=/tmp/dozzle-contract/komga-config \
    KOMGA_LIBRARY_PATH=/tmp/dozzle-contract/books JELLYFIN_HOST_PORT=38096 \
    JELLYFIN_CONFIG_PATH=/tmp/dozzle-contract/jellyfin-config \
    JELLYFIN_CACHE_PATH=/tmp/dozzle-contract/jellyfin-cache \
    JELLYFIN_MEDIA_PATH=/tmp/dozzle-contract/media IMMICH_HOST_PORT=32283 \
    IMMICH_DB_NAME=contract IMMICH_DB_USERNAME=contract IMMICH_DB_PASSWORD=contract \
    PAPERLESS_HOST_PORT=38000 PAPERLESS_POSTGRES_PATH=/tmp/dozzle-contract/paperless-postgres \
    PAPERLESS_REDIS_PATH=/tmp/dozzle-contract/paperless-redis \
    PAPERLESS_DATA_PATH=/tmp/dozzle-contract/paperless-data \
    PAPERLESS_CACHE_PATH=/tmp/dozzle-contract/paperless-cache \
    PAPERLESS_TESSDATA_PATH=/tmp/dozzle-contract/paperless-tessdata \
    PAPERLESS_MEDIA_PATH=/tmp/dozzle-contract/paperless-media \
    PAPERLESS_CONSUME_PATH=/tmp/dozzle-contract/paperless-consume \
    PAPERLESS_EXPORT_PATH=/tmp/dozzle-contract/paperless-export \
    PAPERLESS_ADMIN_USER=contract PAPERLESS_ADMIN_PASSWORD=contract \
    PAPERLESS_ADMIN_MAIL=contract@example.invalid PAPERLESS_DBHOST=db \
    PAPERLESS_REDIS=redis://broker:6379 PAPERLESS_TIKA_ENDPOINT=http://tika:9998 \
    PAPERLESS_GOTENBERG_ENDPOINT=http://gotenberg:3000 PAPERLESS_AI_ENABLED=false \
    PAPERLESS_AI_LLM_ENDPOINT=http://example.invalid:11434 PAPERLESS_AI_LLM_MODEL=contract \
    PAPERLESS_SECRET_KEY=contract DB_NAME=contract DB_USER=contract DB_PASSWORD=contract \
    NEXTCLOUD_HOST_PORT=38084 NEXTCLOUD_PHP_MEMORY_LIMIT=512M \
    NEXTCLOUD_DATA_PATH=/tmp/dozzle-contract/nextcloud-data \
    NEXTCLOUD_POSTGRES_PATH=/tmp/dozzle-contract/nextcloud-postgres \
    NEXTCLOUD_DB_NAME=contract NEXTCLOUD_DB_USERNAME=contract \
    NEXTCLOUD_DB_PASSWORD=contract NEXTCLOUD_CACHE_PASSWORD=contract \
    NEXTCLOUD_ADMIN_USERNAME=contract NEXTCLOUD_ADMIN_PASSWORD=contract \
    NEXTCLOUD_TRUSTED_DOMAINS=127.0.0.1 \
    NEXTCLOUD_OVERWRITE_CLI_URL=http://nextcloud.contract.invalid:38084 \
    MEDIA_ROOT=/tmp/dozzle-contract/media \
    RADARR_HOST_PORT=37878 RADARR_CONFIG_PATH=/tmp/dozzle-contract/radarr-config \
    SONARR_HOST_PORT=38989 SONARR_CONFIG_PATH=/tmp/dozzle-contract/sonarr-config \
    PROWLARR_HOST_PORT=39696 PROWLARR_CONFIG_PATH=/tmp/dozzle-contract/prowlarr-config \
    BAZARR_HOST_PORT=36767 BAZARR_CONFIG_PATH=/tmp/dozzle-contract/bazarr-config \
    RADARR_API_KEY=contract SONARR_API_KEY=contract \
    CONFIGARR_CONFIG_PATH=/tmp/dozzle-contract/configarr-config.yml \
    CONFIGARR_SECRETS_PATH=/tmp/dozzle-contract/configarr-secrets.yml \
    CONFIGARR_REPOS_PATH=/tmp/dozzle-contract/configarr-repos \
    SABNZBD_HOST_PORT=38085 SABNZBD_CONFIG_PATH=/tmp/dozzle-contract/sabnzbd-config \
    SABNZBD_API_KEY=contract \
    MEDIA_ACQUISITION_PATH=/tmp/dozzle-contract/media/.acquisition \
    BOOKS_ACQUISITION_PATH=/tmp/dozzle-contract/books/.acquisition \
    BINDERY_HOST_PORT=38787 BINDERY_API_KEY=contract \
    BINDERY_CONFIG_PATH=/tmp/dozzle-contract/bindery-config \
    BINDERY_BOOKS_PATH=/tmp/dozzle-contract/books \
    BINDERY_MEDIA_PATH=/tmp/dozzle-contract/media \
    KAPOWARR_HOST_PORT=35656 KAPOWARR_CONFIG_PATH=/tmp/dozzle-contract/kapowarr-config \
    KAPOWARR_BOOKS_PATH=/tmp/dozzle-contract/books \
    KAPOWARR_TASK_PATCH_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    KAPOWARR_COMICS_PATH=/tmp/dozzle-contract/comics \
    KAPOWARR_DOWNLOADS_PATH=/tmp/dozzle-contract/kapowarr-downloads \
    KARAKEEP_HOST_PORT=33000 KARAKEEP_PUBLISH_ADDRESS=127.0.0.1 \
    KARAKEEP_DATA_PATH=/tmp/dozzle-contract/karakeep-data \
    KARAKEEP_MEILISEARCH_PATH=/tmp/dozzle-contract/karakeep-meilisearch \
    KARAKEEP_MEILI_MASTER_KEY=contract KARAKEEP_NEXTAUTH_SECRET=contract \
    KARAKEEP_NEXTAUTH_URL=http://127.0.0.1:33000 KARAKEEP_DISABLE_SIGNUPS=true \
    PINCHFLAT_HOST_PORT=38945 PINCHFLAT_CONFIG_PATH=/tmp/dozzle-contract/pinchflat-config \
    PINCHFLAT_DOWNLOADS_PATH=/tmp/dozzle-contract/pinchflat-downloads \
    PINCHFLAT_YTDLP_PATH=/tmp/dozzle-contract/pinchflat-ytdlp \
    PINCHFLAT_BASIC_AUTH_USERNAME=contract PINCHFLAT_BASIC_AUTH_PASSWORD=contract \
    SEERR_HOST_PORT=35055 SEERR_API_KEY=contract \
    SEERR_CONFIG_PATH=/tmp/dozzle-contract/seerr-config \
    TRAILARR_HOST_PORT=37889 TRAILARR_API_KEY=contract \
    TRAILARR_CONFIG_PATH=/tmp/dozzle-contract/trailarr-config \
    TRAILARR_MOVIES_PATH=/tmp/dozzle-contract/media/Movies \
    TRAILARR_SERIES_PATH=/tmp/dozzle-contract/media/Series \
    TRAILARR_MONITOR_ENABLED=false TRAILARR_DOWNLOADS_ENABLED=false \
    TRAILARR_WEBUI_USERNAME=contract TRAILARR_WEBUI_PASSWORD_HASH=contract \
    VAULTWARDEN_HOST_PORT=38222 VAULTWARDEN_DATA_PATH=/tmp/dozzle-contract/vaultwarden-data \
    VAULTWARDEN_DOMAIN=http://127.0.0.1:38222 \
    VAULTWARDEN_SIGNUPS_ALLOWED=true VAULTWARDEN_INVITATIONS_ALLOWED=true \
    USER_ID=1000 GROUP_ID=100 TZ=UTC \
    docker compose --project-name "dozzle-contract-$stack-$variant" "$@" config --format json) ||
    fail_contract "$stack $variant Compose render failed"

  DOZZLE_RENDERED_COMPOSE=$rendered ruby -rjson "$group_render_program" \
    "$stack" "$variant" "$expected_group" "$relay_probe_port" </dev/null
}

# Every stack now carries an integration override, so the disposable lane is
# rendered here rather than named service by service: a new override that
# breaks the Dozzle grouping cannot slip in unrendered.
#
# `docker compose config` renders the default profile only, so a service behind
# `profiles:` is not part of the document this judges -- configarr, the one such
# service in the tree, is deliberately outside it. That mirrors the exemption
# tests/policy_test.rb already makes for a `profiles: [jobs]` service, which
# owes no Dozzle event identity because it is not a container the Running
# Containers panel watches; the subject of this rule is exactly the set a
# converge leaves running. The mirroring is enforced rather than assumed: if
# Compose ever stopped filtering, configarr would arrive carrying no
# dev.dozzle.name and the render below would refuse it by name.
render_group_variants() {
  stack=$1
  expected_group=$2
  service_dir=$repo_dir/services/$stack
  render_group_contract "$stack" "$expected_group" base -f "$service_dir/compose.yml"
  render_group_contract "$stack" "$expected_group" mac \
    -f "$service_dir/compose.yml" -f "$service_dir/compose.mac.yml"
  render_group_contract "$stack" "$expected_group" integration \
    -f "$service_dir/compose.yml" -f "$service_dir/compose.integration.yml"
}

if [ "$mode" = static ]; then
  # The `-r` preload names the INSPECTED tree, not this checkout, and that is
  # deliberate rather than an oversight of the two-roots rule above: it is the
  # inspected tree's own flatten helpers that must agree with the inspected
  # tree's Compose files. Binding it to $contract_repo_dir would look like
  # following the convention and would quietly stop a fixture from being able to
  # break it.
  ruby -r"$repo_dir/tests/policy_support.rb" "$labels_program" \
    "$repo_dir/services/arr/compose.yml" \
    "$repo_dir/services/audiobookshelf/compose.yml" \
    "$repo_dir/services/beszel/compose.yml" \
    "$repo_dir/services/bindery/compose.yml" \
    "$repo_dir/services/downloaders/compose.yml" \
    "$repo_dir/services/dozzle/compose.yml" \
    "$repo_dir/services/immich/compose.yml" \
    "$repo_dir/services/jellyfin/compose.yml" \
    "$repo_dir/services/kapowarr/compose.yml" \
    "$repo_dir/services/karakeep/compose.yml" \
    "$repo_dir/services/komga/compose.yml" \
    "$repo_dir/services/nextcloud/compose.yml" \
    "$repo_dir/services/paperless-ngx/compose.yml" \
    "$repo_dir/services/pinchflat/compose.yml" \
    "$repo_dir/services/seerr/compose.yml" \
    "$repo_dir/services/trailarr/compose.yml" \
    "$repo_dir/services/vaultwarden/compose.yml" </dev/null
  # Every stack in services/manifest.yml, and nothing short of it. The list was
  # nine of seventeen until #656, which is how the grouping rule came to hold
  # for immich and paperless while arr and downloaders -- the other two
  # multi-container stacks -- carried names and no group at all, their seven
  # containers loose in the Running Containers panel. A subset renders as a rule
  # that happens to be true where somebody looked. tests/dozzle_contract_test.rb
  # holds these against the manifest in both directions, so a stack added there
  # and not here fails rather than going unrendered.
  render_group_variants arr arr
  render_group_variants beszel beszel
  render_group_variants downloaders downloaders
  render_group_variants dozzle dozzle
  render_group_variants karakeep karakeep
  render_group_variants paperless-ngx paperless
  render_group_variants immich immich
  render_group_variants nextcloud nextcloud
  render_group_variants audiobookshelf ""
  render_group_variants bindery ""
  render_group_variants jellyfin ""
  render_group_variants kapowarr ""
  render_group_variants komga ""
  render_group_variants pinchflat ""
  render_group_variants seerr ""
  render_group_variants trailarr ""
  render_group_variants vaultwarden ""
fi

ruby -ryaml "$stack_program" "$compose" "$role" "$env_template" \
  "$deployment_inputs" "$deployment_bundle" "$defaults" </dev/null

ruby -ryaml "$alerts_program" "$defaults" "$role" "$integration" "$mac_drift" \
  "$mac_verify" "$mac_verify_labels" "$service_vars" "$mode" </dev/null

[ "$mode" = static ] && { printf '%s\n' 'Dozzle static contract passed'; exit 0; }

case $mode in
  assert-check-mixed-output|assert-check-missing-output)
    exec ruby "$planned_output_program" "$mode" "$@" </dev/null
    ;;
esac

: "${PLATFORM_CONTRACT_VAULT_FILE:?}"
: "${PLATFORM_CONTRACT_VAULT_PASSWORD_FILE:?}"
: "${PLATFORM_REPORT_ROOT:?}"
: "${PLATFORM_DOZZLE_PORT:=8080}"
# The port the notify mode's Pushover recorder listens on, and the one every
# lane redirects dozzle_pushover_api_url at. The number has to agree with the
# lane that converged the relay, because the endpoint is rendered into the
# relay's environment file long before this program runs: it is written here,
# in tests/integration_controller_lib.sh and in tests/mac/lib.sh, and
# tests/dozzle_contract_test.rb refuses the three disagreeing.
: "${PLATFORM_DOZZLE_PUSHOVER_PORT:=32587}"
# The Beszel hub the beszel-notify mode asks to send a test notification. The
# default is beszel_port, which tests/contracts/beszel.sh defaults the same way.
: "${PLATFORM_BESZEL_PORT:=8090}"
PLATFORM_CONTRACT_DOZZLE_SERVICE_VARS=$service_vars
# The notify mode's throwaway containers are started from the alert relay's
# image for one reason only: a lane that converged Dozzle has already pulled it.
# That is true of the deployed pin and of nothing else, so the pin is read out
# of the deployment rather than restated here.
PLATFORM_CONTRACT_DOZZLE_COMPOSE=$compose
export PLATFORM_DOZZLE_PORT PLATFORM_CONTRACT_DOZZLE_SERVICE_VARS
export PLATFORM_DOZZLE_PUSHOVER_PORT PLATFORM_BESZEL_PORT
export PLATFORM_CONTRACT_DOZZLE_COMPOSE

exec ruby "$runtime_program" "$mode" "$@" </dev/null
