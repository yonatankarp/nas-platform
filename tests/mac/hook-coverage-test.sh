#!/bin/sh
# Regression proof for the collapsed Mac hook groups and the shared contract
# runner.
#
# Four hook groups that used to be one file per service are now one table-driven
# file each. The failure that collapse makes possible is silent: a service
# dropped from a table stops being proved while the lane still reports success,
# because mac_run_hooks only refuses a group with no hook files at all. The hooks
# answer that with mac_assert_service_coverage, and this is what proves the
# answer is live rather than decorative. Each group runs against a stub contract
# runner, and the test requires that
#
#   - the group accounts for every service in tests/contracts/registry.yml plus
#     the one Mac-only service the registry does not list,
#   - the stub log names each service with the exact phase and, for the recreate
#     group, the exact Compose bundle and container set the old per-service hooks
#     used, so a table row cannot be quietly rewritten, and
#   - a service added to the registry, a row removed from a table, a delegated
#     hook file deleted, or the Mac-only service list emptied all make the group
#     fail.
#
# The runner's own refusals are proved here too: an unknown service and a
# missing or malformed phase must both stop the lane instead of dispatching
# nothing and reporting success.
set -eu
set +x
umask 077

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
fixture=$(mktemp -d "${TMPDIR:-/tmp}/nas-platform-hook-coverage.XXXXXX")
fixture=$(CDPATH= cd -- "$fixture" && pwd -P)
trap 'rm -rf "$fixture"' EXIT HUP INT TERM

fail() {
  printf 'hook-coverage-error: %s\n' "$1" >&2
  exit 1
}

# A fresh copy of the harness under $1, so each mutation starts from the real
# files rather than from a previous case's leftovers.
build_tree() {
  tree=$1
  mkdir -p "$tree/tests/contracts" "$tree/tests/mac/hooks/fixtures-seed" \
    "$tree/tests/mac/hooks/fixtures-persistence" "$tree/tests/mac/hooks/fixtures-recreate" \
    "$tree/tests/mac/hooks/verify" "$tree/bin" "$tree/log"
  cp "$repo_dir/tests/contracts/registry.yml" "$tree/tests/contracts/registry.yml"
  cp "$repo_dir/tests/mac/lib.sh" "$tree/tests/mac/lib.sh"
  for group in fixtures-seed fixtures-persistence fixtures-recreate; do
    cp "$repo_dir/tests/mac/hooks/$group/00-services.sh" "$tree/tests/mac/hooks/$group/"
  done
  cp "$repo_dir/tests/mac/hooks/verify/30-services.sh" "$tree/tests/mac/hooks/verify/"

  # The runner is stubbed: this test is about which services and phases the hooks
  # dispatch, not about what the contracts then do.
  cat > "$tree/tests/mac/run-contract.sh" <<'STUB'
#!/bin/sh
set -eu
printf '%s %s\n' "$1" "$2" >> "${HOOK_LOG:?}"
STUB

  # Hook files the collapsed groups delegate to. Only their names carry meaning
  # for coverage, except the ntfy verify hook, which the recreate group runs.
  cat > "$tree/tests/mac/hooks/verify/15-ntfy.sh" <<'STUB'
#!/bin/sh
set -eu
printf '%s\n' 'ntfy verify-hook' >> "${HOOK_LOG:?}"
STUB
  for delegate in verify/10-beszel.sh verify/20-dozzle.sh \
      fixtures-persistence/80-paperless.sh; do
    printf '%s\n' '#!/bin/sh' 'exit 0' > "$tree/tests/mac/hooks/$delegate"
  done

  cat > "$tree/bin/docker" <<'STUB'
#!/bin/sh
set -eu
project=
env_file=
files=
targets=
after_wait=false
while [ "$#" -gt 0 ]; do
  case $1 in
    --project-name) project=$2; shift 2; continue ;;
    --env-file) env_file=${2#"$DOCKER_PREFIX"}; shift 2; continue ;;
    -f) files="$files ${2#"$DOCKER_PREFIX"}"; shift 2; continue ;;
    --wait) after_wait=true; shift; continue ;;
  esac
  [ "$after_wait" = false ] || targets="$targets $1"
  shift
done
printf '%s |%s |%s |%s\n' "$project" "$env_file" "${files# }" "${targets# }" >> "${DOCKER_LOG:?}"
STUB

  chmod 0755 "$tree/tests/mac/run-contract.sh" "$tree/bin/docker" \
    "$tree/tests/mac/hooks/verify/15-ntfy.sh" "$tree/tests/mac/hooks/verify/10-beszel.sh" \
    "$tree/tests/mac/hooks/verify/20-dozzle.sh" \
    "$tree/tests/mac/hooks/fixtures-persistence/80-paperless.sh"
}

# Run one collapsed hook out of $1, with the stub logs reset.
run_group() {
  tree=$1
  group=$2
  hook=$3
  : > "$tree/log/hooks"
  : > "$tree/log/docker"
  env PATH="$tree/bin:$PATH" \
    HOOK_LOG="$tree/log/hooks" DOCKER_LOG="$tree/log/docker" \
    DOCKER_PREFIX="$tree/docker/nas-platform/" \
    PLATFORM_DOCKER_ROOT="$tree/docker" PLATFORM_PROJECT_NAME=proof \
    "$tree/tests/mac/hooks/$group/$hook"
}

expect_summary() {
  output=$1
  expected=$2
  printf '%s\n' "$output" | grep -qxF "$expected" ||
    fail "coverage summary differs, expected: $expected"
}

expect_log() {
  actual=$1
  expected=$2
  label=$3
  [ "$actual" = "$expected" ] || {
    printf 'hook-coverage-error: %s log differs\n--- expected ---\n%s\n--- actual ---\n%s\n' \
      "$label" "$expected" "$actual" >&2
    exit 1
  }
}

tree=$fixture/accepted
build_tree "$tree"

# Every group must account for all nine services: the eight registered contracts
# plus ntfy, which has no contract of its own and so is never in the registry.
summary=$(run_group "$tree" fixtures-seed 00-services.sh)
expect_summary "$summary" \
  'mac fixtures-seed hooks: covered 9 of 9 registered services (ran 8, delegated 0, exempt 1)'
expect_log "$(cat "$tree/log/hooks")" 'beszel verify
dozzle verify
audiobookshelf seed-progress
komga seed
tinymediamanager seed
jellyfin seed
immich seed
paperless seed' 'fixtures-seed'

summary=$(run_group "$tree" fixtures-persistence 00-services.sh)
expect_summary "$summary" \
  'mac fixtures-persistence hooks: covered 9 of 9 registered services (ran 7, delegated 1, exempt 1)'
expect_log "$(cat "$tree/log/hooks")" 'beszel verify
dozzle verify
audiobookshelf assert-persistence
komga assert-persistence
tinymediamanager assert-persistence
jellyfin assert-persistence
immich assert-persistence' 'fixtures-persistence'

summary=$(run_group "$tree" verify 30-services.sh)
expect_summary "$summary" \
  'mac verify hooks: covered 9 of 9 registered services (ran 6, delegated 3, exempt 0)'
expect_log "$(cat "$tree/log/hooks")" 'audiobookshelf run
komga run
tinymediamanager run
jellyfin run
immich run
paperless run' 'verify'

summary=$(run_group "$tree" fixtures-recreate 00-services.sh)
expect_summary "$summary" \
  'mac fixtures-recreate hooks: covered 9 of 9 registered services (ran 9, delegated 0, exempt 0)'
expect_log "$(cat "$tree/log/hooks")" 'beszel verify
ntfy verify-hook
dozzle verify
audiobookshelf run
komga run
tinymediamanager run
jellyfin run
immich run
paperless run' 'fixtures-recreate'
# The recreate table also carries the deployed bundle directory and the Compose
# container set, which no other assertion here would notice going wrong.
# Paperless is the one service whose bundle directory is not its Mac alias.
expect_log "$(cat "$tree/log/docker")" 'proof-beszel |runtime/services/beszel/.env |current/services/beszel/compose.yml |hub agent-portable socket-proxy
proof-ntfy |runtime/services/ntfy/.env |current/services/ntfy/compose.yml |ntfy
proof-dozzle |runtime/services/dozzle/.env |current/services/dozzle/compose.yml |alert-relay dozzle socket-proxy
proof-audiobookshelf |runtime/services/audiobookshelf/.env |current/services/audiobookshelf/compose.yml |audiobookshelf
proof-komga |runtime/services/komga/.env |current/services/komga/compose.yml |komga
proof-tinymediamanager |runtime/services/tinymediamanager/.env |current/services/tinymediamanager/compose.yml |tinymediamanager
proof-jellyfin |runtime/services/jellyfin/.env |current/services/jellyfin/compose.yml |jellyfin
proof-immich |runtime/services/immich/.env |current/services/immich/compose.yml |immich-server immich-machine-learning redis database
proof-paperless |runtime/services/paperless-ngx/.env |current/services/paperless-ngx/compose.yml |broker db webserver gotenberg tika' \
  'fixtures-recreate compose'

# A service registered after a table was written must fail every group rather
# than be silently skipped, which is the whole point of asserting against the
# registry instead of against the table.
tree=$fixture/registered-surplus
build_tree "$tree"
printf '%s\n' '  - service: newcomer' '    path: tests/contracts/newcomer.sh' >> \
  "$tree/tests/contracts/registry.yml"
for group_hook in fixtures-seed:00-services.sh fixtures-persistence:00-services.sh \
    fixtures-recreate:00-services.sh verify:30-services.sh; do
  if run_group "$tree" "${group_hook%%:*}" "${group_hook#*:}" >/dev/null 2>&1; then
    fail "${group_hook%%:*} accepted a registered service it never ran"
  fi
done

# A row removed from a table must fail its group.
tree=$fixture/dropped-row
build_tree "$tree"
seed_hook=$tree/tests/mac/hooks/fixtures-seed/00-services.sh
ruby -e 'path = ARGV.fetch(0)
source = File.read(path)
abort "seed table row is absent" unless source.include?(" komga:seed ")
File.write(path, source.sub(" komga:seed ", " "))' "$seed_hook"
if run_group "$tree" fixtures-seed 00-services.sh >/dev/null 2>&1; then
  fail 'fixtures-seed accepted a table with a service removed'
fi

# ntfy is the service this is most likely to lose, because the seed and
# persistence groups legitimately exempt it and only the recreate and verify
# groups prove it. Dropping its recreate row must fail rather than leave the one
# service the registry cannot vouch for unproved everywhere.
tree=$fixture/dropped-ntfy
build_tree "$tree"
ruby -e 'path = ARGV.fetch(0)
prefix = "mac_recreate_and_reassert ntfy "
lines = File.readlines(path)
abort "ntfy recreate row is absent" unless lines.count { |line| line.start_with?(prefix) } == 1
File.write(path, lines.reject { |line| line.start_with?(prefix) }.join)' \
  "$tree/tests/mac/hooks/fixtures-recreate/00-services.sh"
if run_group "$tree" fixtures-recreate 00-services.sh >/dev/null 2>&1; then
  fail 'fixtures-recreate accepted a table with ntfy removed'
fi

# Delegation is credited from the sibling hook filenames, so deleting the file a
# group delegates to must fail the group rather than leave the service unproved.
tree=$fixture/dropped-delegate
build_tree "$tree"
unlink "$tree/tests/mac/hooks/fixtures-persistence/80-paperless.sh"
if run_group "$tree" fixtures-persistence 00-services.sh >/dev/null 2>&1; then
  fail 'fixtures-persistence accepted a missing delegated hook'
fi

# The exemptions are held to the same standard: with ntfy no longer named as a
# Mac-only service, the exemptions that name it are stale and must fail.
tree=$fixture/stale-exemption
build_tree "$tree"
ruby -e 'path = ARGV.fetch(0)
source = File.read(path)
abort "Mac-only service list is absent" unless source.include?("MAC_UNREGISTERED_SERVICES='"'"'ntfy'"'"'")
File.write(path, source.sub("MAC_UNREGISTERED_SERVICES='"'"'ntfy'"'"'", "MAC_UNREGISTERED_SERVICES="))' \
  "$tree/tests/mac/lib.sh"
if run_group "$tree" fixtures-seed 00-services.sh >/dev/null 2>&1; then
  fail 'fixtures-seed accepted a stale exemption'
fi

# The runner's own refusals. These stop before any environment is read, so they
# need no sandbox.
runner=$repo_dir/tests/mac/run-contract.sh
if "$runner" >/dev/null 2>&1; then
  fail 'contract runner accepted no arguments'
fi
if "$runner" beszel >/dev/null 2>&1; then
  fail 'contract runner accepted a service with no phase'
fi
for invalid_phase in '' -verify 'verify run' verify- Verify; do
  if "$runner" beszel "$invalid_phase" >/dev/null 2>&1; then
    fail "contract runner accepted an invalid phase: $invalid_phase"
  fi
done
if "$runner" nosuchservice verify >/dev/null 2>&1; then
  fail 'contract runner accepted an unregistered service'
fi

printf '%s\n' 'Mac hook coverage: every registered service is accounted for in every group'
