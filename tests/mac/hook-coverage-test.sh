#!/bin/sh
# Proves the collapsed Mac hook groups, the drift and pre-converge rosters and the
# shared contract runner account for every registered service and fail on drops.
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

# A fresh copy of the harness under $1 for each mutation.
build_tree() {
  tree=$1
  mkdir -p "$tree/tests/contracts" "$tree/tests/mac/hooks/fixtures-seed" \
    "$tree/tests/mac/hooks/fixtures-persistence" "$tree/tests/mac/hooks/fixtures-recreate" \
    "$tree/tests/mac/hooks/verify" "$tree/tests/mac/hooks/drift" \
    "$tree/tests/mac/hooks/pre-converge" "$tree/bin" "$tree/log"
  cp "$repo_dir/tests/contracts/registry.yml" "$tree/tests/contracts/registry.yml"
  cp "$repo_dir/tests/mac/lib.sh" "$tree/tests/mac/lib.sh"
  for group in fixtures-seed fixtures-persistence fixtures-recreate; do
    cp "$repo_dir/tests/mac/hooks/$group/00-services.sh" "$tree/tests/mac/hooks/$group/"
  done
  cp "$repo_dir/tests/mac/hooks/verify/30-services.sh" "$tree/tests/mac/hooks/verify/"

  # Drift siblings are stubbed from the real directory; the roster under test is 00-coverage.sh's.
  cp "$repo_dir/tests/mac/hooks/drift/00-coverage.sh" "$tree/tests/mac/hooks/drift/"
  chmod 0755 "$tree/tests/mac/hooks/drift/00-coverage.sh"
  for drift_hook in "$repo_dir"/tests/mac/hooks/drift/*.sh; do
    drift_basename=${drift_hook##*/}
    [ "$drift_basename" != 00-coverage.sh ] || continue
    printf '%s\n' '#!/bin/sh' 'exit 0' > "$tree/tests/mac/hooks/drift/$drift_basename"
    chmod 0755 "$tree/tests/mac/hooks/drift/$drift_basename"
  done

  # Pre-converge is stubbed the same way.
  cp "$repo_dir/tests/mac/hooks/pre-converge/00-coverage.sh" \
    "$tree/tests/mac/hooks/pre-converge/"
  chmod 0755 "$tree/tests/mac/hooks/pre-converge/00-coverage.sh"
  for preconverge_hook in "$repo_dir"/tests/mac/hooks/pre-converge/*.sh; do
    preconverge_basename=${preconverge_hook##*/}
    [ "$preconverge_basename" != 00-coverage.sh ] || continue
    printf '%s\n' '#!/bin/sh' 'exit 0' > \
      "$tree/tests/mac/hooks/pre-converge/$preconverge_basename"
    chmod 0755 "$tree/tests/mac/hooks/pre-converge/$preconverge_basename"
  done

  # The runner is stubbed: this test is about dispatch, not contract behaviour.
  cat > "$tree/tests/mac/run-contract.sh" <<'STUB'
#!/bin/sh
set -eu
printf '%s %s\n' "$1" "$2" >> "${HOOK_LOG:?}"
STUB

  # Hook files the collapsed groups delegate to; only their names matter.
  cat > "$tree/tests/mac/hooks/verify/15-media-acquisition-foundation.sh" <<'STUB'
#!/bin/sh
exit 0
STUB
  cat > "$tree/tests/mac/hooks/verify/10-beszel.sh" <<'STUB'
#!/bin/sh
set -eu
printf '%s\n' 'beszel verify-hook' >> "${HOOK_LOG:?}"
STUB
  cat > "$tree/tests/mac/hooks/verify/20-dozzle.sh" <<'STUB'
#!/bin/sh
set -eu
printf '%s\n' 'dozzle verify-hook' >> "${HOOK_LOG:?}"
STUB
  printf '%s\n' '#!/bin/sh' 'exit 0' > \
    "$tree/tests/mac/hooks/fixtures-persistence/80-paperless.sh"

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
    "$tree/tests/mac/hooks/verify/10-beszel.sh" \
    "$tree/tests/mac/hooks/verify/20-dozzle.sh" \
    "$tree/tests/mac/hooks/verify/15-media-acquisition-foundation.sh" \
    "$tree/tests/mac/hooks/fixtures-persistence/80-paperless.sh"
}

# A runnable copy of the real verify wrapper, with infrastructure hooks and Ansible stubbed.
build_verify_tree() {
  tree=$1
  build_tree "$tree"
  cp "$repo_dir/tests/mac/verify.sh" "$tree/tests/mac/verify.sh"
  cat > "$tree/tests/mac/hooks/verify/15-media-acquisition-foundation.sh" <<'STUB'
#!/bin/sh
set -eu
printf '%s\n' 'media-acquisition-foundation verify-hook' >> "${HOOK_LOG:?}"
STUB
  cat > "$tree/bin/ansible-playbook" <<'STUB'
#!/bin/sh
exit 0
STUB
  chmod 0755 "$tree/tests/mac/verify.sh" "$tree/bin/ansible-playbook" \
    "$tree/tests/mac/hooks/verify/15-media-acquisition-foundation.sh"
}

run_verify_wrapper() {
  tree=$1
  : > "$tree/log/hooks"
  env PATH="$tree/bin:$PATH" HOOK_LOG="$tree/log/hooks" \
    PLATFORM_MAC_VAULT_FILE="$tree/vault.yml" \
    PLATFORM_MAC_VAULT_PASSWORD_FILE="$tree/vault-password" \
    PLATFORM_MAC_FIXTURE_VARS_FILE="$tree/fixture-vars.yml" \
    "$tree/tests/mac/verify.sh"
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

# Every group accounts for every registered contract plus the Mac-only services.
summary=$(run_group "$tree" fixtures-seed 00-services.sh)
expect_summary "$summary" \
  'mac fixtures-seed hooks: covered 17 of 17 registered services (ran 7, delegated 0, exempt 10)'
expect_log "$(cat "$tree/log/hooks")" 'beszel verify
dozzle verify
audiobookshelf seed-progress
komga seed
jellyfin seed
immich seed
paperless seed' 'fixtures-seed'

summary=$(run_group "$tree" fixtures-persistence 00-services.sh)
expect_summary "$summary" \
  'mac fixtures-persistence hooks: covered 17 of 17 registered services (ran 12, delegated 1, exempt 4)'
expect_log "$(cat "$tree/log/hooks")" 'beszel verify
dozzle verify
audiobookshelf assert-persistence
komga assert-persistence
jellyfin assert-persistence
immich assert-persistence
pinchflat run
kapowarr run
bindery run
trailarr run
seerr run
nextcloud run' 'fixtures-persistence'

summary=$(run_group "$tree" verify 30-services.sh)
expect_summary "$summary" \
  'mac verify hooks: covered 17 of 17 registered services (ran 11, delegated 2, exempt 4)'
expect_log "$(cat "$tree/log/hooks")" 'audiobookshelf run
komga run
jellyfin run
immich run
paperless run
pinchflat run
kapowarr run
bindery run
trailarr run
seerr run
nextcloud run' 'verify'

summary=$(run_group "$tree" fixtures-recreate 00-services.sh)
expect_summary "$summary" \
  'mac fixtures-recreate hooks: covered 17 of 17 registered services (ran 13, delegated 0, exempt 4)'
expect_log "$(cat "$tree/log/hooks")" 'beszel verify
dozzle verify
audiobookshelf run
komga run
jellyfin run
immich run
paperless run
pinchflat run
kapowarr run
bindery run
trailarr run
seerr run
nextcloud run' 'fixtures-recreate'
# Paperless is the one service whose bundle directory is not its Mac alias.
expect_log "$(cat "$tree/log/docker")" 'proof-beszel |runtime/services/beszel/.env |current/services/beszel/compose.yml |hub agent-portable socket-proxy
proof-dozzle |runtime/services/dozzle/.env |current/services/dozzle/compose.yml |alert-relay dozzle socket-proxy
proof-audiobookshelf |runtime/services/audiobookshelf/.env |current/services/audiobookshelf/compose.yml |audiobookshelf
proof-komga |runtime/services/komga/.env |current/services/komga/compose.yml |komga
proof-jellyfin |runtime/services/jellyfin/.env |current/services/jellyfin/compose.yml |jellyfin
proof-immich |runtime/services/immich/.env |current/services/immich/compose.yml |immich-server immich-machine-learning redis database
proof-paperless |runtime/services/paperless-ngx/.env |current/services/paperless-ngx/compose.yml |broker db webserver gotenberg tika
proof-pinchflat |runtime/services/pinchflat/.env |current/services/pinchflat/compose.yml |pinchflat
proof-kapowarr |runtime/services/kapowarr/.env |current/services/kapowarr/compose.yml |kapowarr
proof-bindery |runtime/services/bindery/.env |current/services/bindery/compose.yml |bindery
proof-trailarr |runtime/services/trailarr/.env |current/services/trailarr/compose.yml |trailarr
proof-seerr |runtime/services/seerr/.env |current/services/seerr/compose.yml |seerr
proof-nextcloud |runtime/services/nextcloud/.env |current/services/nextcloud/compose.yml |nextcloud cron db cache' \
  'fixtures-recreate compose'

# Drift never collapsed; its accounting hook is credited from sibling filenames.
summary=$(run_group "$tree" drift 00-coverage.sh)
expect_summary "$summary" \
  'mac drift hooks: covered 17 of 17 registered services (ran 0, delegated 13, exempt 4)'
expect_log "$(cat "$tree/log/hooks")" '' 'drift'

# Pre-converge holds only Audiobookshelf; every other service is exempt.
summary=$(run_group "$tree" pre-converge 00-coverage.sh)
expect_summary "$summary" \
  'mac pre-converge hooks: covered 17 of 17 registered services (ran 0, delegated 1, exempt 16)'
expect_log "$(cat "$tree/log/hooks")" '' 'pre-converge'

# A drift hook deleted must fail the group.
tree=$fixture/dropped-drift-hook
build_tree "$tree"
unlink "$tree/tests/mac/hooks/drift/58-seerr.sh"
if run_group "$tree" drift 00-coverage.sh >/dev/null 2>&1; then
  fail 'drift accepted a deleted service hook'
fi

# A drift hook added outside the roster must fail too.
tree=$fixture/extra-drift-hook
build_tree "$tree"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$tree/tests/mac/hooks/drift/90-newcomer.sh"
chmod 0755 "$tree/tests/mac/hooks/drift/90-newcomer.sh"
if run_group "$tree" drift 00-coverage.sh >/dev/null 2>&1; then
  fail 'drift accepted a service hook outside its exact roster'
fi

tree=$fixture/dropped-preconverge-hook
build_tree "$tree"
unlink "$tree/tests/mac/hooks/pre-converge/30-audiobookshelf.sh"
if run_group "$tree" pre-converge 00-coverage.sh >/dev/null 2>&1; then
  fail 'pre-converge accepted a deleted service hook'
fi

# A hook added outside the roster must fail pre-converge.
tree=$fixture/extra-preconverge-hook
build_tree "$tree"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$tree/tests/mac/hooks/pre-converge/90-newcomer.sh"
chmod 0755 "$tree/tests/mac/hooks/pre-converge/90-newcomer.sh"
if run_group "$tree" pre-converge 00-coverage.sh >/dev/null 2>&1; then
  fail 'pre-converge accepted a service hook outside its exact roster'
fi

# The lifecycle calls verify.sh, so the wrapper must stay on the coverage-asserting path.
tree=$fixture/verify-wrapper
build_verify_tree "$tree"
summary=$(run_verify_wrapper "$tree")
expect_summary "$summary" \
  'mac verify hooks: covered 17 of 17 registered services (ran 11, delegated 2, exempt 4)'
expect_log "$(cat "$tree/log/hooks")" 'beszel verify-hook
media-acquisition-foundation verify-hook
dozzle verify-hook
audiobookshelf run
komga run
jellyfin run
immich run
paperless run
pinchflat run
kapowarr run
bindery run
trailarr run
seerr run
nextcloud run' 'verify wrapper'

tree=$fixture/verify-wrapper-registered-surplus
build_verify_tree "$tree"
printf '%s\n' '  - service: newcomer' '    path: tests/contracts/newcomer.sh' >> \
  "$tree/tests/contracts/registry.yml"
if run_verify_wrapper "$tree" >/dev/null 2>&1; then
  fail 'verify wrapper accepted a registered service it never ran'
fi

tree=$fixture/verify-wrapper-registered-removal
build_verify_tree "$tree"
ruby -e 'path = ARGV.fetch(0)
source = File.read(path)
entry = "  - service: beszel\n    path: tests/contracts/beszel.sh\n"
abort "beszel registry entry is absent" unless source.include?(entry)
File.write(path, source.sub(entry, ""))' "$tree/tests/contracts/registry.yml"
if run_verify_wrapper "$tree" >/dev/null 2>&1; then
  fail 'verify wrapper accepted a service hook whose registry entry was removed'
fi

tree=$fixture/verify-wrapper-extra-infrastructure
build_verify_tree "$tree"
cat > "$tree/tests/mac/hooks/verify/25-unexpected-infrastructure.sh" <<'STUB'
#!/bin/sh
exit 0
STUB
chmod 0755 "$tree/tests/mac/hooks/verify/25-unexpected-infrastructure.sh"
if run_verify_wrapper "$tree" >/dev/null 2>&1; then
  fail 'verify wrapper accepted an infrastructure hook outside its exact roster'
fi

tree=$fixture/verify-wrapper-missing-foundation
build_verify_tree "$tree"
unlink "$tree/tests/mac/hooks/verify/15-media-acquisition-foundation.sh"
if run_verify_wrapper "$tree" >/dev/null 2>&1; then
  fail 'verify wrapper accepted a missing media acquisition foundation hook'
fi

# A service registered after a table was written must fail every group.
tree=$fixture/registered-surplus
build_tree "$tree"
printf '%s\n' '  - service: newcomer' '    path: tests/contracts/newcomer.sh' >> \
  "$tree/tests/contracts/registry.yml"
for group_hook in fixtures-seed:00-services.sh fixtures-persistence:00-services.sh \
    fixtures-recreate:00-services.sh verify:30-services.sh drift:00-coverage.sh \
    pre-converge:00-coverage.sh; do
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

# The recreate table is a list of calls rather than a loop, so plant a row drop there too.
tree=$fixture/dropped-recreate-row
build_tree "$tree"
ruby -e 'path = ARGV.fetch(0)
prefix = "mac_recreate_and_reassert dozzle "
lines = File.readlines(path)
abort "dozzle recreate row is absent" unless lines.count { |line| line.start_with?(prefix) } == 1
File.write(path, lines.reject { |line| line.start_with?(prefix) }.join)' \
  "$tree/tests/mac/hooks/fixtures-recreate/00-services.sh"
if run_group "$tree" fixtures-recreate 00-services.sh >/dev/null 2>&1; then
  fail 'fixtures-recreate accepted a table with dozzle removed'
fi

# Delegation is credited from sibling filenames, so deleting the delegate must fail.
tree=$fixture/dropped-delegate
build_tree "$tree"
unlink "$tree/tests/mac/hooks/fixtures-persistence/80-paperless.sh"
if run_group "$tree" fixtures-persistence 00-services.sh >/dev/null 2>&1; then
  fail 'fixtures-persistence accepted a missing delegated hook'
fi

# With the Mac-only service list emptied, the exemptions naming it are stale.
tree=$fixture/stale-exemption
build_tree "$tree"
ruby -e 'path = ARGV.fetch(0)
source = File.read(path)
abort "Mac-only service list is absent" unless source.include?("MAC_UNREGISTERED_SERVICES='"'"'vaultwarden karakeep'"'"'")
File.write(path, source.sub("MAC_UNREGISTERED_SERVICES='"'"'vaultwarden karakeep'"'"'", "MAC_UNREGISTERED_SERVICES="))' \
  "$tree/tests/mac/lib.sh"
if run_group "$tree" fixtures-seed 00-services.sh >/dev/null 2>&1; then
  fail 'fixtures-seed accepted a stale exemption'
fi

# The runner's own refusals stop before any environment is read.
runner=$repo_dir/tests/mac/run-contract.sh
for lifecycle_hook in \
    tests/mac/hooks/drift/15-media-acquisition-foundation.sh \
    tests/mac/hooks/verify/15-media-acquisition-foundation.sh; do
  [ -x "$repo_dir/$lifecycle_hook" ] || fail "$lifecycle_hook is absent or not executable"
done
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
