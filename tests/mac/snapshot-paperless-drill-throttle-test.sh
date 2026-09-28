#!/bin/sh
# Regression proof for the Paperless drill's login budget: a per-pass login in the
# deletion poll hit HTTP 429 on warm runs. The stub allows exactly the three logins
# a correct drill needs, so the check is a count rather than wall-clock timing.
set -eu
set +x
umask 077

mac_test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
fixture=$(mktemp -d "${TMPDIR:-/tmp}/nas-platform-paperless-throttle.XXXXXX")
# Resolved physically: the script refuses a snapshot dir whose realpath differs (macOS /var).
fixture=$(CDPATH= cd -- "$fixture" && pwd -P)
stub_pid=

cleanup_fixture() {
  fixture_status=$?
  trap - EXIT HUP INT TERM
  if [ -n "$stub_pid" ]; then
    kill "$stub_pid" 2>/dev/null || true
    wait "$stub_pid" 2>/dev/null || true
  fi
  if [ -d "$fixture" ] && [ ! -L "$fixture" ]; then
    find "$fixture" -depth -mindepth 1 -delete
    rmdir -- "$fixture"
  fi
  exit "$fixture_status"
}
trap cleanup_fixture EXIT HUP INT TERM

fail() {
  printf 'paperless-throttle: %s\n' "$1" >&2
  exit 1
}

sandbox=$fixture/sandbox
snapshot=$fixture/snapshot
docker_ledger=$fixture/docker-ledger
api_ledger=$fixture/api-ledger
port_file=$fixture/api-port
restore_marker=$fixture/restored
mkdir -p "$fixture/bin" "$snapshot" \
  "$sandbox/docker/paperless-ngx/data" \
  "$sandbox/media/Documents/archive" "$sandbox/media/Documents/inbox"
printf 'archive\n' > "$sandbox/media/Documents/archive/document.txt"
printf 'application\n' > "$sandbox/docker/paperless-ngx/data/index.json"
printf 'inbox\n' > "$sandbox/media/Documents/inbox/incoming.txt"
: > "$docker_ledger"
: > "$api_ledger"

# The vault supplies the database and administrator names the drill logs in with.
cat > "$fixture/bin/ansible-vault" <<'STUB'
#!/bin/sh
set -eu
[ "$1" = view ] || exit 64
cat <<'YAML'
vault_paperless_db_username: throttle
vault_paperless_db_name: throttle
vault_paperless_admin_username: throttle
vault_paperless_admin_password: throttle
YAML
STUB

# The psql stub records the restore so the API stub's catalogue matches again after it.
cat > "$fixture/bin/docker" <<'STUB'
#!/bin/sh
set -eu
printf '%s\n' "$*" >> "${STUB_LEDGER:?}"
case $1 in
  stop | start)
    exit 0
    ;;
  inspect)
    printf 'healthy\n'
    exit 0
    ;;
  exec)
    shift
    [ "$1" = -i ] && shift
    shift
    case $1 in
      pg_dump)
        printf -- '-- stub paperless dump\n'
        exit 0
        ;;
      psql)
        cat > /dev/null
        printf 'restored\n' > "${STUB_RESTORE_MARKER:?}"
        exit 0
        ;;
    esac
    exit 0
    ;;
esac
exit 0
STUB
chmod 0700 "$fixture/bin/ansible-vault" "$fixture/bin/docker"

# A Paperless stub with a fixed login allowance and asynchronous deletion, so the
# poll really iterates; every request is logged with its status.
cat > "$fixture/bin/paperless-api-stub.rb" <<'STUB'
require "json"
require "socket"

LEDGER = ENV.fetch("STUB_API_LEDGER")
PORT_FILE = ENV.fetch("STUB_API_PORT_FILE")
RESTORE_MARKER = ENV.fetch("STUB_RESTORE_MARKER")
BUDGET = Integer(ENV.fetch("STUB_TOKEN_BUDGET"), 10)
POLLS_BEFORE_EMPTY = Integer(ENV.fetch("STUB_POLLS_BEFORE_EMPTY"), 10)
DOCUMENTS = [
  { "id" => 1, "checksum" => "1" * 32 },
  { "id" => 2, "checksum" => "2" * 32 }
].freeze

def catalogue(documents)
  {
    "count" => documents.length,
    "results" => documents.map do |document|
      { "id" => document.fetch("id"),
        "versions" => [
          { "is_root" => false, "checksum" => "0" * 32 },
          { "is_root" => true, "checksum" => document.fetch("checksum") }
        ] }
    end
  }
end

server = TCPServer.new("127.0.0.1", 0)
# Published atomically so the shell never reads a half-written port.
File.write("#{PORT_FILE}.partial", "#{server.addr.fetch(1)}\n")
File.rename("#{PORT_FILE}.partial", PORT_FILE)

logins = 0
deleted = false
polls = 0
loop do
  socket = server.accept
  method, path, = socket.gets.to_s.split(" ")
  headers = {}
  while (line = socket.gets) && line.strip != ""
    name, value = line.split(":", 2)
    headers[name.to_s.strip.downcase] = value.to_s.strip
  end
  length = Integer(headers.fetch("content-length", "0"), 10)
  socket.read(length) if length > 0
  route = path.to_s.split("?").fetch(0)
  status = 200
  body = nil
  if method == "POST" && route == "/api/token/"
    logins += 1
    if logins > BUDGET
      status = 429
      body = { "detail" => "Request was throttled." }
    else
      body = { "token" => "stub-token-#{logins}" }
    end
  elsif method == "GET" && route == "/api/documents/"
    if deleted && !File.exist?(RESTORE_MARKER)
      polls += 1
      body = catalogue(polls >= POLLS_BEFORE_EMPTY ? [] : DOCUMENTS)
    else
      body = catalogue(DOCUMENTS)
    end
  elsif method == "DELETE" && route.match?(%r{\A/api/documents/\d+/\z})
    deleted = true
    status = 204
  else
    status = 404
    body = { "detail" => "the stub has no route for #{method} #{route}" }
  end
  File.open(LEDGER, "a") { |file| file.puts("#{method} #{route} #{status}") }
  payload = body.nil? ? "" : JSON.generate(body)
  socket.print(
    "HTTP/1.1 #{status} STUB\r\n" \
    "Content-Type: application/json\r\n" \
    "Content-Length: #{payload.bytesize}\r\n" \
    "Connection: close\r\n\r\n"
  )
  socket.print(payload)
  socket.close
end
STUB

env STUB_API_LEDGER="$api_ledger" STUB_API_PORT_FILE="$port_file" \
  STUB_RESTORE_MARKER="$restore_marker" \
  STUB_TOKEN_BUDGET=3 STUB_POLLS_BEFORE_EMPTY=3 \
  ruby "$fixture/bin/paperless-api-stub.rb" &
stub_pid=$!

attempt=0
while [ ! -s "$port_file" ]; do
  attempt=$((attempt + 1))
  [ "$attempt" -le 200 ] || fail 'the stub Paperless API never published its port'
  kill -0 "$stub_pid" 2>/dev/null || fail 'the stub Paperless API exited before it was ready'
  sleep 0.05
done
port=$(cat "$port_file")

set +e
env PATH="$fixture/bin:$PATH" \
  STUB_LEDGER="$docker_ledger" STUB_RESTORE_MARKER="$restore_marker" \
  PLATFORM_KIND=mac PLATFORM_PROJECT_NAME=nas-platform-mac-throttle \
  PLATFORM_PAPERLESS_PORT="$port" \
  PLATFORM_PAPERLESS_RECOVERY_DEADLINE=1 \
  PLATFORM_DOCKER_ROOT="$sandbox/docker" \
  PLATFORM_MEDIA_ROOT="$sandbox/media" \
  PLATFORM_CONTRACT_VAULT_FILE="$fixture/vault" \
  PLATFORM_CONTRACT_VAULT_PASSWORD_FILE="$fixture/password" \
  "$mac_test_dir/snapshot-paperless.sh" drill "$snapshot" \
  > "$fixture/stdout" 2> "$fixture/stderr"
drill_status=$?
set -e

# grep -c prints 0 and exits non-zero on no match; discard the status, not the count.
ledger_count() {
  grep -c "$1" "$api_ledger" || true
}

[ "$drill_status" -eq 0 ] ||
  fail "the drill exited $drill_status: $(cat "$fixture/stderr")"
grep -qF 'Paperless coordinated snapshot created' "$fixture/stdout" ||
  fail 'the drill did not report the coordinated snapshot'
grep -qF 'Paperless coordinated snapshot restored' "$fixture/stdout" ||
  fail 'the drill did not report the restore it exists to prove'

# Exact on purpose: a fourth login is the loop authenticating again.
logins=$(ledger_count '^POST /api/token/ ')
[ "$logins" -eq 3 ] ||
  fail "the drill spent $logins login(s) rather than one per phase that needs one"
[ "$(ledger_count ' 429$')" -eq 0 ] ||
  fail 'the drill tripped the login throttle'

deletes=$(ledger_count '^DELETE /api/documents/')
[ "$deletes" -eq 2 ] ||
  fail "the drill deleted $deletes document(s) rather than the seeded two"
reads=$(ledger_count '^GET /api/documents/ ')
[ "$reads" -ge 4 ] ||
  fail "the drill read the catalogue $reads time(s), so the deletion poll did not iterate"

printf '%s\n' 'Paperless drill: the deletion poll reuses one token and stays inside the login budget'
