#!/bin/sh
set -eu
set +x
umask 077

test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
temporary_input=$(mktemp -d "${TMPDIR:-/tmp}/nas-platform-legacy-fixture-path.XXXXXX")
temporary_root=$(CDPATH= cd -- "$temporary_input" && pwd -P)
cleanup() {
  fixture_test_status=$?
  trap - EXIT HUP INT TERM
  [ -z "${contract_server_pid:-}" ] || kill "$contract_server_pid" 2>/dev/null || true
  /usr/bin/find "$temporary_root" -depth -delete
  exit "$fixture_test_status"
}
trap cleanup EXIT HUP INT TERM

fail() { printf '%s\n' "$1" >&2; exit 1; }
tab=$(printf '\t')

sandbox=$temporary_root/nas-platform-mac.Abc123
mkdir -m 0700 "$sandbox" "$sandbox/legacy" "$sandbox/legacy/komga" \
  "$sandbox/legacy/komga/library" "$sandbox/legacy/komga/config"
printf 'schema=1\nproject=nas-platform-mac-abc123\n' > "$sandbox/.nas-platform-mac-owned"
chmod 0600 "$sandbox/.nas-platform-mac-owned"

# shellcheck source=../contracts/legacy-fixture-paths.sh
[ -f "$test_dir/../contracts/legacy-fixture-paths.sh" ] || fail 'legacy fixture path validator is absent'
. "$test_dir/../contracts/legacy-fixture-paths.sh"
export PLATFORM_MAC_TMPDIR=$temporary_root
export PLATFORM_LEGACY_FIXTURE_MODE=nas-platform-owned-legacy-v1
export PLATFORM_LEGACY_FIXTURE_SANDBOX=$sandbox
export PLATFORM_KOMGA_LIBRARY_PATH=$sandbox/legacy/komga/library
export PLATFORM_KOMGA_CONFIG_PATH=$sandbox/legacy/komga/config
legacy_fixture_validate PLATFORM_KOMGA_LIBRARY_PATH legacy/komga/library ||
  fail 'exact owned legacy fixture path was rejected'
legacy_fixture_validate PLATFORM_KOMGA_CONFIG_PATH legacy/komga/config ||
  fail 'exact owned legacy Komga config path was rejected'

default_parent=$temporary_root/default-tmp
default_sandbox=$default_parent/nas-platform-mac.Def456
mkdir -m 0700 "$default_parent" "$default_sandbox"
printf 'schema=1\nproject=nas-platform-mac-def456\n' > "$default_sandbox/.nas-platform-mac-owned"
chmod 0600 "$default_sandbox/.nas-platform-mac-owned"
default_driver=$default_sandbox/default-driver.sh
cat > "$default_driver" <<'SH'
#!/bin/sh
[ "${PLATFORM_MAC_TMPDIR:?}" = "${TMPDIR:?}" ] || exit 71
[ "$PLATFORM_LEGACY_FIXTURE_SANDBOX" = "${TMPDIR}/nas-platform-mac.Def456" ] || exit 72
[ "$PLATFORM_LEGACY_FIXTURE_MODE" = nas-platform-owned-legacy-v1 ] || exit 73
case $1:$2 in
  audiobookshelf:seed-progress|komga:seed|tinymediamanager:seed|jellyfin:seed|immich:seed|paperless-ngx:seed) ;;
  *) exit 74 ;;
esac
[ "$1" != komga ] ||
  [ "$PLATFORM_KOMGA_CONFIG_PATH" = "$PLATFORM_MAC_SANDBOX/legacy/komga/config" ] || exit 75
printf '%s\n' "$1:$2" >> "${DEFAULT_DRIVER_LOG:?}"
SH
chmod 0700 "$default_driver"
default_driver_log=$temporary_root/default-driver.log
(
  unset PLATFORM_MAC_TMPDIR
  TMPDIR=$default_parent DEFAULT_DRIVER_LOG=$default_driver_log \
    PLATFORM_MAC_SANDBOX=$default_sandbox PLATFORM_PROJECT_NAME=nas-platform-mac-def456 \
    PLATFORM_KOMGA_CONFIG_PATH=$temporary_root/hostile-komga-config \
    PLATFORM_LEGACY_FIXTURE_DRIVER=$default_driver \
    "$test_dir/legacy-fixtures.sh" seed
) || fail 'legacy fixtures require undocumented PLATFORM_MAC_TMPDIR input'
[ "$(wc -l < "$default_driver_log" | tr -d ' ')" -eq 6 ] ||
  fail 'default temporary parent legacy fixture flow was incomplete'
[ ! -e "$temporary_root/hostile-komga-config" ] ||
  fail 'hostile ambient Komga config path was mutated by the legacy fixture adapter'

outside=$temporary_root/outside
mkdir -m 0700 "$outside"
PLATFORM_KOMGA_LIBRARY_PATH=$outside
export PLATFORM_KOMGA_LIBRARY_PATH
if legacy_fixture_validate PLATFORM_KOMGA_LIBRARY_PATH legacy/komga/library >/dev/null 2>&1; then
  fail 'outside legacy fixture path was accepted'
fi
[ -z "$(find "$outside" -mindepth 1 -print -quit)" ] || fail 'outside path was mutated'

PLATFORM_KOMGA_CONFIG_PATH=$outside
export PLATFORM_KOMGA_CONFIG_PATH
if legacy_fixture_validate PLATFORM_KOMGA_CONFIG_PATH legacy/komga/config >/dev/null 2>&1; then
  fail 'outside legacy Komga config path was accepted'
fi
[ -z "$(find "$outside" -mindepth 1 -print -quit)" ] ||
  fail 'outside Komga config path was mutated'

rmdir "$sandbox/legacy/komga/library"
ln -s "$outside" "$sandbox/legacy/komga/library"
PLATFORM_KOMGA_LIBRARY_PATH=$sandbox/legacy/komga/library
export PLATFORM_KOMGA_LIBRARY_PATH
if legacy_fixture_validate PLATFORM_KOMGA_LIBRARY_PATH legacy/komga/library >/dev/null 2>&1; then
  fail 'symlinked legacy fixture path was accepted'
fi
[ -z "$(find "$outside" -mindepth 1 -print -quit)" ] || fail 'symlink target was mutated'
rm "$sandbox/legacy/komga/library"
mkdir -m 0700 "$sandbox/legacy/komga/library"

fake_bin=$temporary_root/bin
mkdir -m 0700 "$fake_bin"
cat > "$fake_bin/ruby" <<'SH'
#!/bin/sh
env | grep -E '^PLATFORM_(LEGACY_FIXTURE_|FIXTURE_COMPOSE_|AUDIOBOOKSHELF_MEDIA_LIBRARY|KOMGA_(LIBRARY|CONFIG)_PATH|TINYMEDIAMANAGER_.*_ROOT|JELLYFIN_.*_ROOT|IMMICH_.*_ROOT|PAPERLESS_.*_ROOT)=' && exit 91
for variable in PLATFORM_TINYMEDIAMANAGER_CONTAINER PLATFORM_JELLYFIN_CONTAINER \
    PLATFORM_IMMICH_SERVER_CONTAINER PLATFORM_IMMICH_MACHINE_LEARNING_CONTAINER \
    PLATFORM_IMMICH_REDIS_CONTAINER PLATFORM_IMMICH_POSTGRES_CONTAINER \
    PLATFORM_PAPERLESS_WEBSERVER_CONTAINER; do
  container=$(printenv "$variable" 2>/dev/null || true)
  [ -z "$container" ] || docker inspect "$container"
done
exit 0
SH
cat > "$fake_bin/docker" <<'SH'
#!/bin/sh
printf 'docker' >> "${FAKE_DOCKER_LOG:?}"
for argument in "$@"; do printf '\t%s' "$argument" >> "$FAKE_DOCKER_LOG"; done
printf '\n' >> "$FAKE_DOCKER_LOG"
SH
chmod 0700 "$fake_bin/ruby" "$fake_bin/docker"
docker_log=$temporary_root/docker.log
run_fresh_wrapper() {
  env PATH="$fake_bin:$PATH" FAKE_DOCKER_LOG="$docker_log" \
    PLATFORM_MAC_VAULT_FILE=x PLATFORM_MAC_VAULT_PASSWORD_FILE=x \
    PLATFORM_MEDIA_ROOT=/outside PLATFORM_DOCKER_ROOT=/outside \
    PLATFORM_REPORT_ROOT=/outside PLATFORM_PROJECT_NAME=fresh \
    PLATFORM_AUDIOBOOKSHELF_PORT=1 PLATFORM_KOMGA_PORT=1 \
    PLATFORM_TINYMEDIAMANAGER_API_PORT=1 PLATFORM_JELLYFIN_PORT=1 \
    PLATFORM_IMMICH_PORT=1 PLATFORM_PAPERLESS_PORT=1 \
    PLATFORM_LEGACY_FIXTURE_MODE=nas-platform-owned-legacy-v1 \
    PLATFORM_LEGACY_FIXTURE_SANDBOX="$sandbox" \
    PLATFORM_FIXTURE_COMPOSE_PROJECT=hostile-project \
    PLATFORM_FIXTURE_COMPOSE_SERVICE=hostile-service \
    PLATFORM_KOMGA_LIBRARY_PATH="$outside" \
    PLATFORM_KOMGA_CONFIG_PATH="$outside" \
    PLATFORM_TINYMEDIAMANAGER_CONTAINER=hostile-tmm \
    PLATFORM_JELLYFIN_CONTAINER=hostile-jellyfin \
    PLATFORM_IMMICH_SERVER_CONTAINER=hostile-immich-server \
    PLATFORM_IMMICH_MACHINE_LEARNING_CONTAINER=hostile-immich-ml \
    PLATFORM_IMMICH_REDIS_CONTAINER=hostile-immich-redis \
    PLATFORM_IMMICH_POSTGRES_CONTAINER=hostile-immich-postgres \
    PLATFORM_PAPERLESS_WEBSERVER_CONTAINER=hostile-paperless "$@"
}
for wrapper_mode in 'audiobookshelf seed-progress' 'komga seed' 'tinymediamanager seed' \
    'jellyfin seed' 'immich seed' 'paperless seed'; do
  set -- $wrapper_mode
  wrapper=$1
  fixture_mode=$2
  # The fake Ruby process observes the wrapper's final environment without executing fixtures.
  : > "$docker_log"
  run_fresh_wrapper "$test_dir/run-$wrapper-contract.sh" "$fixture_mode" >/dev/null 2>&1 ||
    fail "fresh $wrapper wrapper preserved ambient legacy fixture controls"
  grep -F 'hostile-' "$docker_log" >/dev/null 2>&1 &&
    fail "fresh $wrapper wrapper used a hostile container identifier"
  case $wrapper in
    tinymediamanager) expected='fresh-tinymediamanager' ;;
    jellyfin) expected='fresh-jellyfin' ;;
    immich) expected='fresh-immich-server fresh-immich-machine-learning fresh-immich-redis fresh-immich-postgres' ;;
    paperless) expected='fresh-paperless-webserver' ;;
    *) expected= ;;
  esac
  for container in $expected; do
    grep -q "^docker${tab}inspect${tab}$container$" "$docker_log" ||
      fail "fresh $wrapper wrapper omitted canonical container $container"
  done
done

# Exercise the real legacy fixture driver and Komga contract with a disposable API.
contract_bin=$temporary_root/contract-bin
contract_report=$temporary_root/contract-report
contract_port_file=$temporary_root/contract-port
contract_request_log=$temporary_root/contract-requests.jsonl
contract_docker_log=$temporary_root/contract-docker.log
contract_library_name=$temporary_root/contract-library-name
mkdir -m 0700 "$contract_bin" "$contract_report"
printf '%s\n' Books > "$contract_library_name"
printf '%s\n' disposable > "$temporary_root/vault.yml"
printf '%s\n' disposable > "$temporary_root/vault-password"
chmod 0600 "$temporary_root/vault.yml" "$temporary_root/vault-password"
cat > "$contract_bin/ansible-vault" <<'SH'
#!/bin/sh
printf '%s\n' \
  'vault_komga_admin_email: admin@example.invalid' \
  'vault_komga_admin_password: admin-secret'
SH
chmod 0700 "$contract_bin/ansible-vault"
cat > "$contract_bin/docker" <<'SH'
#!/bin/sh
[ "$#" -eq 4 ] && [ "$1" = inspect ] && [ "$2" = --format ] || exit 2
printf '%s\n' "$*" >> "${CONTRACT_DOCKER_LOG:?}"
case $3:$4 in
  '{{if .State.Health}}present{{else}}absent{{end}}':nas-platform-mac-abc123-legacy-komga-komga-1)
    printf '%s\n' absent
    ;;
  '{{.State.Health.Status}}':komga|'{{.State.Health.Status}}':nas-platform-mac-abc123-komga)
    printf '%s\n' healthy
    ;;
  *) exit 2 ;;
esac
SH
chmod 0700 "$contract_bin/docker"
cat > "$temporary_root/komga-baseline.rb" <<'RUBY'
abort unless ARGV == ["--emit-probe", "komga"]
puts "{}"
RUBY
cat > "$temporary_root/komga-api.rb" <<'RUBY'
require "base64"
require "json"
require "socket"

settings = {
  "scanInterval" => "DISABLED", "scanOnStartup" => false, "scanCbx" => true,
  "scanPdf" => true, "scanEpub" => true, "repairExtensions" => false,
  "convertToCbz" => false, "emptyTrashAfterScan" => false, "hashFiles" => true,
  "hashPages" => false, "hashKoreader" => false, "analyzeDimensions" => true
}
library_name = ARGV.fetch(2)
libraries = [{ "id" => "legacy-library", "name" => "Books", "root" => "/data" }.merge(settings)]
server = TCPServer.new("127.0.0.1", 0)
File.write(ARGV.fetch(0), server.addr.fetch(1).to_s)
loop do
  socket = server.accept
  request_line = socket.gets.to_s
  method, target = request_line.split
  headers = {}
  while (line = socket.gets)
    break if line == "\r\n"
    key, value = line.split(":", 2)
    headers[key.downcase] = value.to_s.strip
  end
  body = socket.read(headers.fetch("content-length", "0").to_i)
  status = 200
  payload = nil
  case [method, target]
  when ["GET", "/actuator/health"]
    payload = { "status" => "UP" }
  when ["GET", "/api/v2/users/me"]
    credentials = Base64.decode64(headers.fetch("authorization", "").sub(/\ABasic /, ""))
    if credentials.end_with?(":contract-wrong-password")
      status = 401
      payload = { "error" => "unauthorized" }
    else
      payload = { "email" => "admin@example.invalid", "roles" => ["ADMIN"] }
    end
  when ["GET", "/api/v1/libraries"]
    libraries.first["name"] = File.read(library_name).strip
    payload = libraries
  when ["POST", "/api/v1/libraries"]
    document = JSON.parse(body)
    File.open(ARGV.fetch(1), "a", 0o600) { |file| file.puts(JSON.generate(document)) }
    libraries << document.merge("id" => "unrelated-library")
    payload = libraries.last
  when ["POST", "/api/v1/libraries/legacy-library/scan"]
    status = 202
  else
    if method == "GET" && target.start_with?("/api/v1/books?")
      payload = { "content" => [{ "url" => "/data/task-10-contract-comic/Task 10 Contract Comic.cbz" }] }
    else
      status = 404
      payload = { "error" => "missing" }
    end
  end
  response = payload.nil? ? "" : JSON.generate(payload)
  reason = { 200 => "OK", 202 => "Accepted", 401 => "Unauthorized", 404 => "Not Found" }.fetch(status)
  socket.write("HTTP/1.1 #{status} #{reason}\r\nContent-Type: application/json\r\n" \
               "Content-Length: #{response.bytesize}\r\nConnection: close\r\n\r\n#{response}")
  socket.close
end
RUBY
ruby "$temporary_root/komga-api.rb" "$contract_port_file" "$contract_request_log" \
  "$contract_library_name" &
contract_server_pid=$!
contract_wait=0
while [ ! -s "$contract_port_file" ]; do
  contract_wait=$((contract_wait + 1))
  [ "$contract_wait" -lt 100 ] || fail 'disposable Komga API did not start'
  sleep 0.05
done
contract_port=$(cat "$contract_port_file")
PATH="$contract_bin:$PATH" PLATFORM_MAC_TMPDIR=$temporary_root \
  PLATFORM_MAC_SANDBOX=$sandbox PLATFORM_LEGACY_FIXTURE_SANDBOX=$sandbox \
  PLATFORM_LEGACY_FIXTURE_MODE=nas-platform-owned-legacy-v1 PLATFORM_PROOF_LANE=adoption \
  PLATFORM_PROJECT_NAME=nas-platform-mac-abc123 CONTRACT_DOCKER_LOG=$contract_docker_log \
  PLATFORM_KOMGA_LIBRARY_PATH=$sandbox/legacy/komga/library \
  PLATFORM_KOMGA_CONFIG_PATH=$sandbox/legacy/komga/config \
  PLATFORM_MEDIA_ROOT=$sandbox/legacy/komga/library PLATFORM_REPORT_ROOT=$contract_report \
  PLATFORM_KOMGA_PORT=$contract_port PLATFORM_MAC_VAULT_FILE=$temporary_root/vault.yml \
  PLATFORM_MAC_VAULT_PASSWORD_FILE=$temporary_root/vault-password \
  "$test_dir/legacy-fixture-service.sh" komga seed >/dev/null ||
  fail 'real legacy Komga fixture driver failed'

printf '%s\n' Comics > "$contract_library_name"
PATH="$contract_bin:$PATH" PLATFORM_MAC_TMPDIR=$temporary_root \
  PLATFORM_MAC_SANDBOX=$sandbox PLATFORM_LEGACY_FIXTURE_SANDBOX=$sandbox \
  PLATFORM_LEGACY_FIXTURE_MODE=nas-platform-owned-legacy-v1 PLATFORM_PROOF_LANE=adoption \
  PLATFORM_PROOF_PLATFORM=mac PLATFORM_PROJECT_NAME=nas-platform-mac-abc123 \
  CONTRACT_DOCKER_LOG=$contract_docker_log PLATFORM_MEDIA_ROOT=$sandbox/legacy/komga/library \
  PLATFORM_KOMGA_CONFIG_PATH=$sandbox/legacy/komga/config \
  PLATFORM_REPORT_ROOT=$contract_report PLATFORM_KOMGA_PORT=$contract_port \
  PLATFORM_MAC_VAULT_FILE=$temporary_root/vault.yml \
  PLATFORM_MAC_VAULT_PASSWORD_FILE=$temporary_root/vault-password \
  PLATFORM_ADOPTION_BASELINE_FILE=$temporary_root/komga-baseline.rb \
  "$test_dir/adoption-probes/komga.sh" >/dev/null ||
  fail 'pre-cutover Komga adoption baseline used the wrong runtime health context'

PATH="$contract_bin:$PATH" PLATFORM_KIND=integration PLATFORM_KOMGA_RUNTIME_CONTEXT=base \
  PLATFORM_PROJECT_NAME=ambient-project PLATFORM_KOMGA_CONTAINER=hostile-container \
  PLATFORM_KOMGA_DOCKER_HEALTH_REQUIRED=false CONTRACT_DOCKER_LOG=$contract_docker_log \
  PLATFORM_CONTRACT_VAULT_FILE=$temporary_root/vault.yml \
  PLATFORM_CONTRACT_VAULT_PASSWORD_FILE=$temporary_root/vault-password \
  PLATFORM_MEDIA_ROOT=$sandbox/legacy/komga/library PLATFORM_REPORT_ROOT=$contract_report \
  PLATFORM_KOMGA_PORT=$contract_port "$test_dir/../contracts/komga.sh" run >/dev/null ||
  fail 'integration Komga contract used project-derived or ambient container health controls'

PATH="$contract_bin:$PATH" PLATFORM_MAC_TMPDIR=$temporary_root \
  PLATFORM_MAC_SANDBOX=$sandbox PLATFORM_LEGACY_FIXTURE_SANDBOX=$sandbox \
  PLATFORM_LEGACY_FIXTURE_MODE=nas-platform-owned-legacy-v1 PLATFORM_PROOF_LANE=adoption \
  PLATFORM_PROOF_PLATFORM=mac PLATFORM_ADOPTION_PROBE_TARGET=true \
  PLATFORM_PROJECT_NAME=nas-platform-mac-abc123 CONTRACT_DOCKER_LOG=$contract_docker_log \
  PLATFORM_KOMGA_CONFIG_PATH=$sandbox/legacy/komga/config \
  PLATFORM_MEDIA_ROOT=$sandbox/legacy/komga/library PLATFORM_REPORT_ROOT=$contract_report \
  PLATFORM_KOMGA_PORT=$contract_port PLATFORM_MAC_VAULT_FILE=$temporary_root/vault.yml \
  PLATFORM_MAC_VAULT_PASSWORD_FILE=$temporary_root/vault-password \
  PLATFORM_ADOPTION_BASELINE_FILE=$temporary_root/komga-baseline.rb \
  "$test_dir/adoption-probes/komga.sh" >/dev/null ||
  fail 'target-adoption Komga probe used the wrong runtime health context'

kill "$contract_server_pid" 2>/dev/null || true
wait "$contract_server_pid" 2>/dev/null || true
[ -d "$sandbox/legacy/komga/config/.nas-platform-unmanaged" ] ||
  fail 'legacy Komga fixture was not created under the mounted config root'
expected_docker_log=$temporary_root/expected-contract-docker.log
cat > "$expected_docker_log" <<'EOF'
inspect --format {{if .State.Health}}present{{else}}absent{{end}} nas-platform-mac-abc123-legacy-komga-komga-1
inspect --format {{if .State.Health}}present{{else}}absent{{end}} nas-platform-mac-abc123-legacy-komga-komga-1
inspect --format {{.State.Health.Status}} komga
inspect --format {{.State.Health.Status}} nas-platform-mac-abc123-komga
EOF
cmp -s "$expected_docker_log" "$contract_docker_log" ||
  fail 'Komga runtime contexts inspected the wrong container or Docker health policy'
ruby -rjson - "$contract_request_log" <<'RUBY'
requests = File.readlines(ARGV.fetch(0), chomp: true).map { |line| JSON.parse(line) }
raise unless requests == [{ "name" => "Komga Contract Reference", "root" => "/config/.nas-platform-unmanaged" }]
RUBY

printf '%s\n' 'Legacy fixture paths: controlled owned roots resist ambient and symlink injection'
