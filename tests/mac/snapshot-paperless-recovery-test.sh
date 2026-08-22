#!/bin/sh
# Regression proof for the Paperless restore recovery path.
#
# The restore path stops the webserver and redis together, and its ensure block
# starts redis and immediately flushes the valkey queue. docker start returns
# once the container process has been launched, not once valkey has bound
# 127.0.0.1:6379, so as a one-shot exec that flushall raced the socket: it
# intermittently reported "Connection refused" and turned a restore that had
# actually succeeded into "application recovery failed" and a failing job. It
# passed seven consecutive CI runs before failing run 32590260858, which is the
# signature of a race rather than a logic error, and a race is exactly the kind
# of defect a green suite cannot be used to prove absent.
#
# So the wait is proven here instead, by driving the real script against a stub
# docker whose valkey refuses a chosen number of connections. Restore mode needs
# no network at all (the API calls live behind MODE == "drill"), so docker and
# ansible-vault are the only two commands that need stubbing, and each case
# costs about a second.
#
# The cases are:
#
#   - a valkey that refuses twice and then answers must still produce a
#     successful restore, with the flushall retried and the webserver started
#     only after it succeeded,
#   - a valkey that never answers must be reported as a recovery failure and
#     must not abort the ensure block: the remaining recovery steps and the
#     health wait have to run, because dying inside an ensure that is unwinding
#     a restore failure would replace the real diagnosis with a recovery one,
#   - a failed restore with a dead valkey must still surface the restore failure
#     rather than the recovery failure, and
#   - the deadline cannot be configured away: zero still leaves a retry.
set -eu
set +x
umask 077

mac_test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
fixture=$(mktemp -d "${TMPDIR:-/tmp}/nas-platform-paperless-recovery.XXXXXX")
# Resolved physically because the script under test refuses any snapshot
# directory whose realpath differs from the path it was given, and on macOS
# TMPDIR sits under the /var symlink.
fixture=$(CDPATH= cd -- "$fixture" && pwd -P)

cleanup_fixture() {
  fixture_status=$?
  trap - EXIT HUP INT TERM
  if [ -d "$fixture" ] && [ ! -L "$fixture" ]; then
    find "$fixture" -depth -mindepth 1 -delete
    rmdir -- "$fixture"
  fi
  exit "$fixture_status"
}
trap cleanup_fixture EXIT HUP INT TERM

fail() {
  printf 'paperless-recovery: %s\n' "$1" >&2
  exit 1
}

sandbox=$fixture/sandbox
snapshot=$fixture/snapshot
ledger=$fixture/ledger
attempts=$fixture/valkey-attempts
mkdir -p "$fixture/bin" "$snapshot" \
  "$sandbox/docker/paperless-ngx/data" \
  "$sandbox/media/Documents/archive" "$sandbox/media/Documents/inbox" \
  "$fixture/seed/archive" "$fixture/seed/application" "$fixture/seed/inbox"

# The vault is only read for database and administrator names, and restore mode
# never authenticates against the API, so a plain document is enough.
cat > "$fixture/bin/ansible-vault" <<'STUB'
#!/bin/sh
set -eu
[ "$1" = view ] || exit 64
cat <<'YAML'
vault_paperless_db_username: recovery
vault_paperless_db_name: recovery
vault_paperless_admin_username: recovery
vault_paperless_admin_password: recovery
YAML
STUB

# Every invocation is appended to the ledger, which is what makes the ordering
# and the retry count observable. STUB_VALKEY_REFUSALS decides how many flushall
# attempts are refused the way a valkey that has not yet bound its port refuses
# them, and STUB_PSQL_FAILS breaks the restore itself.
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
      valkey-cli)
        attempt=$(($(cat "${STUB_VALKEY_ATTEMPTS:?}" 2>/dev/null || printf 0) + 1))
        printf '%s\n' "$attempt" > "$STUB_VALKEY_ATTEMPTS"
        if [ "$attempt" -le "${STUB_VALKEY_REFUSALS:-0}" ]; then
          printf 'Could not connect to Redis at 127.0.0.1:6379: Connection refused\n' >&2
          exit 1
        fi
        exit 0
        ;;
      psql)
        cat > /dev/null
        [ "${STUB_PSQL_FAILS:-0}" = 1 ] || exit 0
        printf 'psql: FATAL: the stub refused the restore\n' >&2
        exit 1
        ;;
    esac
    exit 0
    ;;
esac
exit 0
STUB
chmod 0700 "$fixture/bin/ansible-vault" "$fixture/bin/docker"

printf 'archive\n' > "$fixture/seed/archive/document.txt"
printf 'application\n' > "$fixture/seed/application/index.json"
printf 'inbox\n' > "$fixture/seed/inbox/incoming.txt"
tar -C "$fixture/seed/archive" -cf "$snapshot/archive.tar" .
tar -C "$fixture/seed/application" -cf "$snapshot/application.tar" .
tar -C "$fixture/seed/inbox" -cf "$snapshot/inbox.tar" .
printf 'SELECT 1;\n' > "$snapshot/database.sql"
ruby -rjson -rdigest -e '
  directory = ARGV.fetch(0)
  members = %w[archive.tar application.tar database.sql inbox.tar].map do |name|
    path = File.join(directory, name)
    { "name" => name, "bytes" => File.size(path),
      "sha256" => Digest::SHA256.file(path).hexdigest }
  end
  File.write(File.join(directory, "manifest.json"),
             JSON.pretty_generate({ "schema" => 1, "members" => members }) + "\n")
' "$snapshot" || fail 'snapshot manifest fixture could not be built'

# run_restore REFUSALS DEADLINE PSQL_FAILS. Taken as arguments rather than as
# variable assignments prefixed to the call, because a prefixed assignment to a
# function persists in the calling shell and would leak one case into the next.
#
# Each case starts from an empty ledger and attempt counter so the assertions
# below read one restore rather than the accumulation of every earlier one.
run_restore() {
  : > "$ledger"
  : > "$attempts"
  set +e
  env PATH="$fixture/bin:$PATH" \
    STUB_LEDGER="$ledger" STUB_VALKEY_ATTEMPTS="$attempts" \
    STUB_VALKEY_REFUSALS="$1" \
    STUB_PSQL_FAILS="$3" \
    PLATFORM_PAPERLESS_RECOVERY_DEADLINE="$2" \
    PLATFORM_DOCKER_ROOT="$sandbox/docker" \
    PLATFORM_MEDIA_ROOT="$sandbox/media" \
    PLATFORM_CONTRACT_VAULT_FILE="$fixture/vault" \
    PLATFORM_CONTRACT_VAULT_PASSWORD_FILE="$fixture/password" \
    "$mac_test_dir/snapshot-paperless.sh" restore "$snapshot" \
    > "$fixture/stdout" 2> "$fixture/stderr"
  case_status=$?
  set -e
}

valkey_attempts() {
  cat "$attempts" 2>/dev/null || printf 0
}

ledger_line() {
  grep -n -x -F "$1" "$ledger" | tail -1 | cut -d: -f1
}

# A refusing valkey must not fail the restore: the flushall has to be retried
# until it lands, and only then may the webserver come back.
run_restore 2 60 0
[ "$case_status" -eq 0 ] ||
  fail "a valkey that answers on the third attempt failed the restore: $(cat "$fixture/stderr")"
grep -qF 'Paperless coordinated snapshot restored' "$fixture/stdout" ||
  fail 'the recovered restore did not report success'
! grep -qF 'recovery failed' "$fixture/stderr" ||
  fail 'a retried flushall was still reported as a recovery failure'
[ "$(valkey_attempts)" -eq 3 ] ||
  fail "the flushall was attempted $(valkey_attempts) times rather than retried to success"
flushall_line=$(ledger_line 'exec paperless_redis valkey-cli flushall')
webserver_line=$(ledger_line 'start paperless_webserver')
[ -n "$flushall_line" ] && [ -n "$webserver_line" ] ||
  fail 'the recovery ledger did not record the flushall and the webserver start'
[ "$flushall_line" -lt "$webserver_line" ] ||
  fail 'the webserver was started before the queue flush succeeded'

# A valkey that never answers must be reported, and must not abort recovery: the
# webserver start and the health wait after it still have to run, because a die
# inside this ensure block would discard whatever failure it is unwinding.
run_restore 9999 1 0
[ "$case_status" -eq 1 ] ||
  fail "a valkey that never answers exited $case_status rather than 1"
grep -qF 'Paperless snapshot recovery failed' "$fixture/stderr" ||
  fail 'an unreachable valkey was not reported as a recovery failure'
grep -qF 'valkey-cli flushall' "$fixture/stderr" ||
  fail 'the recovery failure did not name the flushall'
grep -qF 'Paperless snapshot failed: application recovery failed' "$fixture/stderr" ||
  fail 'an unreachable valkey did not fail the run'
[ "$(valkey_attempts)" -ge 2 ] ||
  fail 'the flushall was not retried before the deadline expired'
[ -n "$(ledger_line 'start paperless_webserver')" ] ||
  fail 'the readiness wait aborted recovery instead of returning its failure'
[ -n "$(ledger_line 'inspect --format {{.State.Health.Status}} paperless_redis')" ] ||
  fail 'the readiness wait skipped the health wait that follows it'

# The restore failure is the one worth reporting. A recovery failure on top of it
# must not become the diagnosis.
run_restore 9999 1 1
[ "$case_status" -eq 1 ] ||
  fail "a failed restore exited $case_status rather than 1"
grep -qF 'Paperless snapshot failed: docker failed' "$fixture/stderr" ||
  fail 'a failed restore did not report its own failure'
! grep -qF 'application recovery failed' "$fixture/stderr" ||
  fail 'a recovery failure masked the restore failure that caused it'

# The deadline is an environment seam so this test can reach the timeout branch
# quickly. It must not be a way to switch the wait off.
run_restore 1 0 0
[ "$case_status" -eq 0 ] ||
  fail 'a zero deadline removed the retry instead of being floored'
[ "$(valkey_attempts)" -eq 2 ] ||
  fail "a zero deadline left $(valkey_attempts) flushall attempt(s) rather than a retry"

printf '%s\n' 'Paperless recovery: the restore path waits for valkey and reports without masking'
