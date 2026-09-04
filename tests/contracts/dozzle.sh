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
  assert-check-missing-output) ;;
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
    PLATFORM_DOCKER_ROOT=/tmp/dozzle-contract/docker \
    PLATFORM_CURRENT_DIR="$repo_dir" DOZZLE_STATE_ROOT=/tmp/dozzle-contract/docker/dozzle/data \
    NAS_DOCKER_ROOT=/tmp/dozzle-contract/docker \
    NAS_MEDIA_ROOT=/tmp/dozzle-contract/media NAS_RENDER_DEVICE=/dev/null \
    NAS_UID=1000 NAS_GID=100 \
    BESZEL_APP_URL=http://127.0.0.1:8090 BESZEL_SYSTEM_NAME=contract \
    BESZEL_AGENT_KEY=contract BESZEL_AGENT_TOKEN=contract BESZEL_HOST_PORT=38090 \
    DOZZLE_HOST_PORT=38080 NTFY_HOST_PORT=32586 NTFY_BASE_URL=http://127.0.0.1:32586 \
    ALERT_RELAY_SCRIPT_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    ALERT_RELAY_TOKEN=contract-relay-token ALERT_RELAY_PORT="$relay_probe_port" \
    NTFY_PUBLISH_URL=http://host.docker.internal:32586/ \
    NTFY_TOPIC=nas-critical NTFY_CONTAINERS_TOPIC=nas-containers NTFY_TOKEN=contract-ntfy-token \
    NTFY_AUTH_USERS= NTFY_AUTH_ACCESS= NTFY_AUTH_TOKENS= \
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
    USER_ID=1000 GROUP_ID=100 TZ=UTC \
    docker compose --project-name "dozzle-contract-$stack-$variant" "$@" config --format json) ||
    fail_contract "$stack $variant Compose render failed"

  DOZZLE_RENDERED_COMPOSE=$rendered ruby -rjson "$group_render_program" \
    "$stack" "$variant" "$expected_group" "$relay_probe_port" </dev/null
}

# Every stack now carries an integration override, so the disposable lane is
# rendered here rather than named service by service: a new override that
# breaks the Dozzle grouping cannot slip in unrendered.
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
    "$repo_dir/services/audiobookshelf/compose.yml" \
    "$repo_dir/services/beszel/compose.yml" \
    "$repo_dir/services/dozzle/compose.yml" \
    "$repo_dir/services/immich/compose.yml" \
    "$repo_dir/services/jellyfin/compose.yml" \
    "$repo_dir/services/komga/compose.yml" \
    "$repo_dir/services/ntfy/compose.yml" \
    "$repo_dir/services/paperless-ngx/compose.yml" </dev/null
  render_group_variants beszel beszel
  render_group_variants dozzle dozzle
  render_group_variants paperless-ngx paperless
  render_group_variants immich immich
  render_group_variants audiobookshelf ""
  render_group_variants jellyfin ""
  render_group_variants komga ""
  render_group_variants ntfy ""
fi

ruby -ryaml "$stack_program" "$compose" "$role" "$env_template" \
  "$deployment_inputs" "$deployment_bundle" </dev/null

ruby -ryaml "$alerts_program" "$defaults" "$role" "$integration" "$mac_drift" \
  "$mac_verify" "$mac_verify_labels" "$mode" </dev/null

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
: "${PLATFORM_NTFY_PORT:=2586}"
PLATFORM_CONTRACT_DOZZLE_DEFAULTS=$defaults
export PLATFORM_DOZZLE_PORT PLATFORM_NTFY_PORT PLATFORM_CONTRACT_DOZZLE_DEFAULTS

exec ruby "$runtime_program" "$mode" "$@" </dev/null
