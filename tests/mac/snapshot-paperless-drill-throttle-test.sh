#!/bin/sh
# Regression proof for the Paperless rollback drill's login budget.
#
# The drill deletes the seeded documents and then waits for the deletion to
# settle by re-reading the catalogue every two seconds for up to two minutes.
# That poll used to authenticate on every pass, which is roughly sixty POSTs to
# /api/token/ inside one loop, on top of the logins fixture seeding has already
# spent. Paperless rate-limits that endpoint, and request dies on any status it
# did not expect, so the drill aborted the whole suite with "POST /api/token/
# returned HTTP 429" before it ever reached the restore it exists to prove.
#
# It only bites on a warm environment, which is what makes it worth proving here
# rather than trusting a green run: whether the throttle is reached depends on how
# much of its allowance the run before it spent, so the same code passes cold and
# fails warm. Driving the real script against a stub API with a fixed login
# allowance turns that into a deterministic check.
#
# The allowance is three, because a correct drill authenticates exactly three
# times: once to read the catalogue it is about to snapshot, once to authorize the
# deletion, and once after the restore, whose database roll-back may have removed
# the token issued after the dump. A fourth login means something is logging in
# inside a loop again, and the stub answers it the way Paperless does.
#
# Three is deliberately the exact number a correct drill needs rather than a copy
# of the real rate. Paperless caps /api/token/ at five a minute by default
# (PAPERLESS_TOKEN_THROTTLE_RATE), and a per-pass login is thirty a minute, so
# reproducing the rate would prove the defect too but would make the assertion
# about wall-clock timing. The count is the property worth pinning: it holds
# whatever the endpoint in front of the drill is configured to allow.
#
# Restore mode is already covered by snapshot-paperless-recovery-test.sh; this
# test is the drill, so it needs an API as well as a docker stub. Both stubs are
# process-local, and the whole run costs a few seconds.
set -eu
set +x
umask 077

mac_test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
fixture=$(mktemp -d "${TMPDIR:-/tmp}/nas-platform-paperless-throttle.XXXXXX")
# Resolved physically because the script under test refuses any snapshot
# directory whose realpath differs from the path it was given, and on macOS
# TMPDIR sits under the /var symlink.
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

# The psql restore is what brings the deleted rows back, so the stub records it
# where the API stub can see it: after the restore the catalogue has to match the
# snapshot again, exactly as it does against a real Postgres.
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

# A Paperless whose login endpoint has a fixed allowance, and whose deletion is
# asynchronous the way the real one is: the documents stay in the catalogue for
# STUB_POLLS_BEFORE_EMPTY reads after the delete, so the poll loop under test
# really does iterate rather than break on its first pass.
#
# Every request is appended to the ledger with its status, which is what makes the
# login count and the throttle observable from the assertions below.
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

# grep -c prints its zero and then exits non-zero when nothing matched, so the
# status is discarded rather than substituted for: printing a second zero here
# would make every count unparseable.
ledger_count() {
  grep -c "$1" "$api_ledger" || true
}

[ "$drill_status" -eq 0 ] ||
  fail "the drill exited $drill_status: $(cat "$fixture/stderr")"
grep -qF 'Paperless coordinated snapshot created' "$fixture/stdout" ||
  fail 'the drill did not report the coordinated snapshot'
grep -qF 'Paperless coordinated snapshot restored' "$fixture/stdout" ||
  fail 'the drill did not report the restore it exists to prove'

# The login count is the assertion the defect fails, and it is exact on purpose:
# a fourth login is the loop authenticating again, whether or not the endpoint in
# front of it happens to be throttling that day.
logins=$(ledger_count '^POST /api/token/ ')
[ "$logins" -eq 3 ] ||
  fail "the drill spent $logins login(s) rather than one per phase that needs one"
[ "$(ledger_count ' 429$')" -eq 0 ] ||
  fail 'the drill tripped the login throttle'

# Without these the same pass would be reported by a drill that had deleted its
# poll, or its deletion, altogether.
deletes=$(ledger_count '^DELETE /api/documents/')
[ "$deletes" -eq 2 ] ||
  fail "the drill deleted $deletes document(s) rather than the seeded two"
reads=$(ledger_count '^GET /api/documents/ ')
[ "$reads" -ge 4 ] ||
  fail "the drill read the catalogue $reads time(s), so the deletion poll did not iterate"

printf '%s\n' 'Paperless drill: the deletion poll reuses one token and stays inside the login budget'
