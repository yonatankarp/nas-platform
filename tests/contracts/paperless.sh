#!/bin/sh
set -eu
set +x

mode=${1:-run}
# Two roots, and they are not the same thing. $contract_repo_dir is the checkout
# this script belongs to, which is where its three Ruby programs live -- a
# heredoc had that property by construction, because the program travelled inside
# the file. $repo_dir is the tree those programs *inspect*, which
# PLATFORM_CONTRACT_REPO_DIR lets a caller point at a fixture. Resolving a
# program from $repo_dir would make this contract read its own assertions out of
# the tree it is judging.
contract_repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
repo_dir=${PLATFORM_CONTRACT_REPO_DIR:-$contract_repo_dir}
# The Ruby programs below read tests/policy_support.rb from here instead of
# carrying their own copy of flatten_tasks. It names the inspected tree.
PLATFORM_CONTRACT_REPO_DIR=$repo_dir
export PLATFORM_CONTRACT_REPO_DIR
render_program=$contract_repo_dir/tests/contracts/paperless-render.rb
static_program=$contract_repo_dir/tests/contracts/paperless-static.rb
# The three greps below read this program's source for constants no static
# assertion can observe. They read the copy that will actually run, which is the
# one in this checkout -- exactly what "$0" named while the code lived here.
runtime_program=$contract_repo_dir/tests/contracts/paperless-runtime.rb
compose=$repo_dir/services/paperless-ngx/compose.yml
mac_compose=$repo_dir/services/paperless-ngx/compose.mac.yml
integration_compose=$repo_dir/services/paperless-ngx/compose.integration.yml
role=$repo_dir/roles/paperless_ngx/tasks/main.yml
defaults=$repo_dir/roles/paperless_ngx/defaults/main.yml
argument_specs=$repo_dir/roles/paperless_ngx/meta/argument_specs.yml
storage_inventory=$repo_dir/inventory/group_vars/all/main.yml
host_prep=$repo_dir/roles/host_prep/tasks/main.yml
generator=$repo_dir/generate-secrets.yml
snapshot=$repo_dir/tests/mac/snapshot-paperless.sh
environment_template=$repo_dir/roles/paperless_ngx/templates/env.j2
ocr_fixture=$repo_dir/tests/fixtures/paperless-ocr.png.base64

fail_contract() {
  printf 'Paperless contract failed: %s\n' "$1" >&2
  exit 1
}

[ -f "$compose" ] || fail_contract 'services/paperless-ngx/compose.yml is absent'
[ -f "$mac_compose" ] || fail_contract 'services/paperless-ngx/compose.mac.yml is absent'
[ -f "$integration_compose" ] ||
  fail_contract 'services/paperless-ngx/compose.integration.yml is absent'
[ -f "$role" ] || fail_contract 'roles/paperless_ngx/tasks/main.yml is absent'
[ -f "$defaults" ] || fail_contract 'roles/paperless_ngx/defaults/main.yml is absent'
[ -f "$argument_specs" ] || fail_contract 'roles/paperless_ngx/meta/argument_specs.yml is absent'
[ -f "$storage_inventory" ] || fail_contract 'inventory/group_vars/all/main.yml is absent'
[ -f "$host_prep" ] || fail_contract 'roles/host_prep/tasks/main.yml is absent'
[ -x "$snapshot" ] || fail_contract 'tests/mac/snapshot-paperless.sh is absent or not executable'
[ -f "$ocr_fixture" ] || fail_contract 'tests/fixtures/paperless-ocr.png.base64 is absent'
grep -qx 'DOCUMENT_INDEX_TIMEOUT_SECONDS = 600' "$runtime_program" ||
  fail_contract 'document indexing timeout differs'

render_paperless_mounts() {
  variant=$1
  shift
  cache_path=/volume1/Docker/paperless-ngx/cache
  rendered=$(env \
    PLATFORM_PROJECT_NAME=paperless-contract PLATFORM_CONTAINER_CPUSET=0-2 \
    PAPERLESS_HOST_PORT=38000 PAPERLESS_POSTGRES_PATH=/volume1/Docker/paperless-ngx/postgres \
    PAPERLESS_REDIS_PATH=/volume1/Docker/paperless-ngx/redis \
    PAPERLESS_DATA_PATH=/volume1/Docker/paperless-ngx/data \
    PAPERLESS_CACHE_PATH="$cache_path" \
    PAPERLESS_TESSDATA_PATH=/volume1/Docker/paperless-ngx/tessdata \
    PAPERLESS_MEDIA_PATH=/volume2/Documents/archive \
    PAPERLESS_CONSUME_PATH=/volume2/Documents/inbox \
    PAPERLESS_EXPORT_PATH=/volume2/Documents/export \
    PAPERLESS_ADMIN_USER=contract PAPERLESS_ADMIN_PASSWORD=contract \
    PAPERLESS_ADMIN_MAIL=contract@example.invalid PAPERLESS_DBHOST=db \
    PAPERLESS_REDIS=redis://broker:6379 PAPERLESS_TIKA_ENDPOINT=http://tika:9998 \
    PAPERLESS_GOTENBERG_ENDPOINT=http://gotenberg:3000 PAPERLESS_AI_ENABLED=false \
    PAPERLESS_AI_LLM_ENDPOINT=http://example.invalid:11434 PAPERLESS_AI_LLM_MODEL=contract \
    PAPERLESS_SECRET_KEY=contract DB_NAME=contract DB_USER=contract DB_PASSWORD=contract \
    USER_ID=1000 GROUP_ID=100 TZ=UTC \
    docker compose --project-name "paperless-contract-$variant" "$@" config --format json) ||
    fail_contract "$variant effective Compose render failed"

  PAPERLESS_RENDERED_COMPOSE=$rendered ruby -rjson -rpathname \
    "$render_program" "$variant" </dev/null
}

render_paperless_mounts nas -f "$compose"
render_paperless_mounts mac -f "$compose" -f "$mac_compose"
render_paperless_mounts integration -f "$compose" -f "$integration_compose"

ruby -ryaml "$static_program" "$compose" "$mac_compose" "$integration_compose" \
  "$role" "$defaults" "$argument_specs" "$storage_inventory" "$host_prep" \
  "$generator" "$environment_template" "$snapshot" </dev/null

# Two of these three subjects live in the controller program that
# tests/integration.sh runs inside the container; the fixture pre-seed is the
# launcher's own work, on the Docker host, before the container starts. Reading
# each from the file that actually spells it is what keeps all three able to
# fail.
grep -qF 'run_paperless_contract seed' "$repo_dir/tests/integration_controller.sh" ||
  fail_contract 'integration does not exercise Paperless document fixtures'
grep -qF '"$repo_dir/tests/contracts/paperless.sh" seed-fixture-only' \
  "$repo_dir/tests/integration.sh" ||
  fail_contract 'integration does not prepare Paperless fixtures on the Docker host'
grep -qF 'run_paperless_snapshot drill' "$repo_dir/tests/integration_controller.sh" ||
  fail_contract 'integration does not exercise coordinated Paperless recovery'
grep -qF 'run("docker", "stop", WEBSERVER, REDIS)' "$snapshot" ||
  fail_contract 'Paperless snapshot does not quiesce writers'
grep -qF 'wait_healthy(REDIS, WEBSERVER)' "$snapshot" ||
  fail_contract 'Paperless restore does not wait for application health'
grep -qF 'request("delete", "/api/documents/' "$snapshot" ||
  fail_contract 'Paperless rollback drill does not destructively test restoration'
if [ "$mode" = static ]; then
  # These two were vacuous while the runtime half shared this file: `grep -F`
  # matches a substring, and the grep line spells its own pattern, so each
  # assertion was satisfied by itself and a planted defect in the runtime code
  # passed. Reading the runtime program instead is what makes them bite.
  grep -F 'MAIL_PROBE_READ_TIMEOUT = 180' "$runtime_program" >/dev/null ||
    fail_contract 'runtime Gmail probe timeout constant differs'
  grep -F 'read_timeout: MAIL_PROBE_READ_TIMEOUT' "$runtime_program" >/dev/null ||
    fail_contract 'runtime Gmail probe lacks its explicit bounded timeout'
  printf '%s\n' 'Paperless static contract passed'
  exit 0
fi

: "${PLATFORM_CONTRACT_VAULT_FILE:=${PLATFORM_MAC_VAULT_FILE:-}}"
: "${PLATFORM_CONTRACT_VAULT_PASSWORD_FILE:=${PLATFORM_MAC_VAULT_PASSWORD_FILE:-}}"
: "${PLATFORM_MEDIA_ROOT:?}"
: "${PLATFORM_REPORT_ROOT:?}"
: "${PLATFORM_PAPERLESS_PORT:=8000}"
: "${PLATFORM_PAPERLESS_WEBSERVER_CONTAINER:=paperless_webserver}"
: "${PLATFORM_PAPERLESS_FIXTURE_PRESEEDED:=false}"
PLATFORM_CONTRACT_REPO_DIR=$repo_dir
export PLATFORM_CONTRACT_VAULT_FILE PLATFORM_CONTRACT_VAULT_PASSWORD_FILE
export PLATFORM_MEDIA_ROOT PLATFORM_REPORT_ROOT PLATFORM_PAPERLESS_PORT
export PLATFORM_PAPERLESS_WEBSERVER_CONTAINER PLATFORM_CONTRACT_REPO_DIR
export PLATFORM_PAPERLESS_FIXTURE_PRESEEDED

shift || true
exec ruby "$runtime_program" "$mode" "$@" </dev/null
