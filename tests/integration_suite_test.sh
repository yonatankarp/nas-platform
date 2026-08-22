#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -P "$(dirname "$0")/.." && pwd -P)
integration=${INTEGRATION_SUITE_RUNNER:-$repo_dir/tests/integration.sh}
fake_bin=$(mktemp -d "${TMPDIR:-/tmp}/nas-platform-suite-test.XXXXXX")
docker_log=$fake_bin/docker.log

cleanup() {
  case $fake_bin in
    */nas-platform-suite-test.??????) ;;
    *) printf 'refusing to remove unexpected suite test root: %s\n' "$fake_bin" >&2; return 1 ;;
  esac
  [ -d "$fake_bin" ] && [ ! -L "$fake_bin" ] || return 1
  rm -rf -- "$fake_bin"
}
trap cleanup EXIT HUP INT TERM

cat > "$fake_bin/docker" <<'EOF'
#!/bin/sh
printf 'docker invoked: %s\n' "$*" >> "$DOCKER_LOG"
exit 99
EOF
chmod +x "$fake_bin/docker"

cat > "$fake_bin/mktemp" <<'EOF'
#!/bin/sh
printf 'mktemp invoked: %s\n' "$*" >> "$DOCKER_LOG"
exit 98
EOF
chmod +x "$fake_bin/mktemp"

run_integration() {
  PATH="$fake_bin:$PATH" DOCKER_LOG=$docker_log "$integration" "$@"
}

assert_output() {
  expected=$1
  shift
  actual=$(run_integration "$@")
  [ "$actual" = "$expected" ] || {
    printf 'expected: %s\nactual:   %s\n' "$expected" "$actual" >&2
    exit 1
  }
}

assert_rejected() {
  expected=$1
  shift
  status=0
  output=$(run_integration "$@" 2>&1) || status=$?
  [ "$status" -eq 2 ] || {
    printf 'expected exit 2, got %s: %s\n' "$status" "$output" >&2
    exit 1
  }
  printf '%s\n' "$output" | grep -qF "$expected" || {
    printf 'missing rejection %s in: %s\n' "$expected" "$output" >&2
    exit 1
  }
  [ ! -e "$docker_log" ] || {
    printf 'rejected invocation reached Docker: %s\n' "$(cat "$docker_log")" >&2
    exit 1
  }
}

assert_output \
  'foundation smoke beszel dozzle audiobookshelf komga tinymediamanager jellyfin immich paperless idempotence-check full' \
  --list-suites

assert_output 'suite=foundation tags=deployment_bundle playbook=site.yml scenarios=true' \
  --describe-suite foundation
assert_output 'suite=beszel tags=host_prep,deployment_bundle,ntfy,beszel playbook=site.yml scenarios=true' \
  --describe-suite beszel
assert_output 'suite=dozzle tags=host_prep,deployment_bundle,ntfy,dozzle playbook=site.yml scenarios=true' \
  --describe-suite dozzle
assert_output 'suite=audiobookshelf tags=host_prep,deployment_bundle,ntfy,audiobookshelf playbook=site.yml scenarios=true' \
  --describe-suite audiobookshelf
assert_output 'suite=komga tags=host_prep,deployment_bundle,ntfy,komga playbook=site.yml scenarios=true' \
  --describe-suite komga
assert_output 'suite=tinymediamanager tags=host_prep,deployment_bundle,ntfy,tinymediamanager playbook=site.yml scenarios=true' \
  --describe-suite tinymediamanager
assert_output 'suite=jellyfin tags=host_prep,deployment_bundle,ntfy,jellyfin playbook=site.yml scenarios=true' \
  --describe-suite jellyfin
assert_output 'suite=immich tags=host_prep,deployment_bundle,ntfy,immich playbook=site.yml scenarios=true' \
  --describe-suite immich
assert_output 'suite=paperless tags=host_prep,deployment_bundle,ntfy,paperless playbook=site.yml scenarios=true' \
  --describe-suite paperless
assert_output 'suite=full tags= playbook=site.yml scenarios=true' --describe-suite full

assert_output 'suite=smoke tags=host_prep,deployment_bundle,ntfy,beszel playbook=custom.yml scenarios=true' \
  --describe-suite smoke --tags host_prep,deployment_bundle,ntfy,beszel custom.yml
assert_output 'suite=smoke tags= playbook=site.yml scenarios=true' \
  --describe-suite smoke --tags ''
assert_output 'suite=idempotence-check tags=host_prep,deployment_bundle,ntfy playbook=site.yml scenarios=true' \
  --describe-suite idempotence-check --tags host_prep,deployment_bundle,ntfy
assert_output 'suite=idempotence-check tags= playbook=site.yml scenarios=true' \
  --describe-suite idempotence-check

# The same parser identifies legacy playbook-first invocations as full without
# touching Docker. Extra Ansible arguments remain available to the runner.
actual=$(PATH="$fake_bin:$PATH" DOCKER_LOG=$docker_log \
  INTEGRATION_DESCRIBE_ONLY=1 "$integration")
[ "$actual" = 'suite=full tags= playbook=site.yml scenarios=true' ]
actual=$(PATH="$fake_bin:$PATH" DOCKER_LOG=$docker_log \
  INTEGRATION_DESCRIBE_ONLY=1 "$integration" custom.yml --check --diff)
[ "$actual" = 'suite=full tags= playbook=custom.yml scenarios=false' ]
actual=$(PATH="$fake_bin:$PATH" DOCKER_LOG=$docker_log \
  INTEGRATION_DESCRIBE_ONLY=1 "$integration" --suite dozzle)
[ "$actual" = 'suite=dozzle tags=host_prep,deployment_bundle,ntfy,dozzle playbook=site.yml scenarios=true' ]

# Dispatch crosses the Docker boundary as quoted argv/environment rather than
# being interpolated into the runner program.
grep -qF -- '-e INTEGRATION_SUITE="$suite"' "$integration"
grep -qF -- '-e INTEGRATION_TAGS="$suite_tags"' "$integration"
grep -qF -- '" integration-run "$playbook" "$@"' "$integration"
grep -qF -- '\"\$playbook\" \"\$@\"' "$integration"
grep -qF -- 'run_play --tags \"\$INTEGRATION_TAGS\" \"\$@\"' "$integration"
grep -qF -- 'run_play \"\$@\"' "$integration"

# Service fixtures consumed through nested Docker bind mounts must exist on the
# daemon host before the controller container establishes its sandbox mount.
paperless_preseed_line=$(grep -nF '"$repo_dir/tests/contracts/paperless.sh" seed-fixture-only' \
  "$integration" | cut -d: -f1)
controller_line=$(grep -nF 'docker run --rm' "$integration" | head -1 | cut -d: -f1)
[ -n "$paperless_preseed_line" ] && [ "$paperless_preseed_line" -lt "$controller_line" ] || {
  printf '%s\n' 'Paperless integration fixture is not prepared before the controller mount' >&2
  exit 1
}
grep -qF 'paperless:true|full:true)' "$integration"
grep -qF -- '-e PLATFORM_PAPERLESS_FIXTURE_PRESEEDED="$paperless_fixture_preseeded"' "$integration"
for contract in komga jellyfin; do
  preseed_line=$(grep -nF \
    '"$repo_dir/tests/contracts/'"$contract"'.sh" seed-fixture-only' \
    "$integration" | cut -d: -f1)
  [ -n "$preseed_line" ] && [ "$preseed_line" -lt "$controller_line" ] || {
    printf '%s\n' "$contract integration fixture is not prepared before the controller mount" >&2
    exit 1
  }
done
grep -qF 'komga:true|full:true)' "$integration"
grep -qF 'tinymediamanager:true|full:true)' "$integration"
grep -qF 'jellyfin:true|full:true)' "$integration"
grep -qF -- '-e PLATFORM_KOMGA_FIXTURE_PRESEEDED="$komga_fixture_preseeded"' "$integration"
grep -qF -- '-e PLATFORM_JELLYFIN_FIXTURE_PRESEEDED="$jellyfin_fixture_preseeded"' \
  "$integration"

# Exercise the actual shell routing with a disposable Git checkout. Docker is
# replaced at the process boundary: the host runner executes normally, while
# the controller command it submits is run locally with Docker/Ansible/package
# commands stubbed. Only executed contract calls reach the event log.
routing_root=$fake_bin/routing
routing_repo=$routing_root/repo
routing_host_bin=$routing_root/host-bin
routing_controller_bin=$routing_root/controller-bin
routing_tmp_parent=$routing_root/tmp
routing_events=$routing_root/events.log
routing_payload=$routing_root/controller.sh
routing_output=$routing_root/output.log
mkdir -p "$routing_host_bin" "$routing_controller_bin" "$routing_tmp_parent"
routing_tmp_parent=$(CDPATH= cd -P "$routing_tmp_parent" && pwd -P)
git clone --quiet --no-local "$repo_dir" "$routing_repo"
cp "$integration" "$routing_repo/tests/integration.sh"
chmod +x "$routing_repo/tests/integration.sh"

cat > "$routing_repo/tests/contracts/tinymediamanager.sh" <<'EOF'
#!/bin/sh
set -eu
printf '%s:%s\n' "$ROUTING_PHASE" "${1:-<missing>}" >> "$ROUTING_EVENTS"
EOF
chmod +x "$routing_repo/tests/contracts/tinymediamanager.sh"

cat > "$routing_root/noop-contract" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$routing_root/noop-contract"
for contract in "$routing_repo"/tests/contracts/*.sh; do
  [ "${contract##*/}" = tinymediamanager.sh ] || cp "$routing_root/noop-contract" "$contract"
done

cat > "$routing_repo/tests/generate-ephemeral-vault.sh" <<'EOF'
#!/bin/sh
set -eu
[ "${1:-}" != --cleanup ] || exit 0
output=
password=
while [ "$#" -gt 0 ]; do
  case $1 in
    --output) output=$2; shift 2 ;;
    --password-file) password=$2; shift 2 ;;
    *) shift ;;
  esac
done
mkdir -p "${output%/*}" "${password%/*}"
: > "$output"
: > "$password"
EOF
chmod +x "$routing_repo/tests/generate-ephemeral-vault.sh"

cat > "$routing_controller_bin/noop" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$routing_controller_bin/noop"
for command in apk pip ansible-galaxy ansible-playbook ruby git cmp docker; do
  ln -s noop "$routing_controller_bin/$command"
done
cat > "$routing_controller_bin/network-probe" <<'EOF'
#!/bin/sh
set -eu
printf 'controller:network-probe:%s\n' "$*" >> "$ROUTING_EVENTS"
EOF
chmod +x "$routing_controller_bin/network-probe"
for command in curl wget; do
  ln -s network-probe "$routing_controller_bin/$command"
done
cat > "$routing_controller_bin/ansible-vault" <<'EOF'
#!/bin/sh
[ "${1:-}" = view ] && printf '%s\n' '---'
exit 0
EOF
chmod +x "$routing_controller_bin/ansible-vault"

cat > "$routing_host_bin/docker" <<'EOF'
#!/bin/sh
set -eu

case ${1:-} in
  info)
    printf '%s\n' 'Docker Desktop routing harness'
    exit 0
    ;;
  network)
    printf '%s\n' '127.0.0.1'
    exit 0
    ;;
  ps|rm)
    exit 0
    ;;
  run) ;;
  *)
    printf 'unexpected routing Docker command: %s\n' "$*" >&2
    exit 97
    ;;
esac

for argument in "$@"; do
  if [ "$argument" = -i ]; then
    cleanup_parent=
    cleanup_name=
    while [ "$#" -gt 0 ]; do
      if [ "$1" = -v ]; then
        shift
        case $1 in
          *:/sandbox-parent) cleanup_parent=${1%:/sandbox-parent} ;;
        esac
      elif [ "$1" = python ] && [ "${2:-}" = - ]; then
        cleanup_name=${3:-}
        break
      fi
      shift
    done
    [ "$cleanup_parent" = "$ROUTING_TMP_PARENT" ] || exit 96
    case $cleanup_name in
      nas-platform-integration.??????) ;;
      *) exit 95 ;;
    esac
    find "$cleanup_parent/$cleanup_name" -depth -mindepth 1 -delete
    exit 0
  fi
done

controller_repo=
controller_program=
controller_zero=integration-run
while [ "$#" -gt 0 ]; do
  case $1 in
    -v)
      shift
      case $1 in
        *:/repo) controller_repo=${1%:/repo} ;;
      esac
      ;;
    -e)
      shift
      export "$1"
      ;;
    -c)
      shift
      controller_program=$1
      shift
      controller_zero=${1:-integration-run}
      [ "$#" -eq 0 ] || shift
      break
      ;;
  esac
  shift
done
[ -n "$controller_repo" ] && [ -n "$controller_program" ] || exit 94
printf '%s' "$controller_program" > "$ROUTING_PAYLOAD.raw"
"$ROUTING_REAL_RUBY" - "$ROUTING_PAYLOAD.raw" "$ROUTING_PAYLOAD" "$controller_repo" <<'RUBY'
input, output, repository = ARGV
File.write(output, File.read(input).gsub(%r{/repo(?=/)}, repository))
RUBY
ROUTING_PHASE=controller PATH="$ROUTING_CONTROLLER_BIN:$PATH" \
  sh -eu -c "$(cat "$ROUTING_PAYLOAD")" "$controller_zero" "$@"
EOF
chmod +x "$routing_host_bin/docker"
ln -s "$(command -v mktemp)" "$routing_host_bin/mktemp"

run_routing_suite() {
  routing_status=0
  : > "$routing_events"
  PATH="$routing_host_bin:$PATH" \
  DOCKER_LOG=$docker_log \
  ROUTING_EVENTS=$routing_events \
  ROUTING_PHASE=host \
  ROUTING_PAYLOAD=$routing_payload \
  ROUTING_REAL_RUBY=$(command -v ruby) \
  ROUTING_CONTROLLER_BIN=$routing_controller_bin \
  ROUTING_TMP_PARENT=$routing_tmp_parent \
  TMPDIR=$routing_tmp_parent \
    "$routing_repo/tests/integration.sh" --suite "$1" \
    >"$routing_output" 2>&1 || routing_status=$?
}

run_routing_suite tinymediamanager

host_events=$(sed -n '/^host:/p' "$routing_events" 2>/dev/null || true)
[ "$host_events" = 'host:seed-retirement-fixture' ] || {
  printf '%s\n' 'tinyMediaManager retirement fixture is not prepared before convergence' >&2
  exit 1
}
[ "$routing_status" -eq 0 ] || {
  cat "$routing_output" >&2
  printf '%s\n' 'tinyMediaManager retirement routing did not complete' >&2
  exit 1
}
controller_events=$(sed -n '/^controller:/p' "$routing_events" 2>/dev/null || true)
[ "$controller_events" = 'controller:assert-retired' ] || {
  printf '%s\n' 'tinyMediaManager retirement is not asserted after convergence' >&2
  exit 1
}
[ "$(wc -l < "$routing_events" | tr -d ' ')" -eq 2 ] || {
  printf '%s\n' 'tinyMediaManager integration still invokes active-service modes' >&2
  exit 1
}
for routing_suite in foundation beszel dozzle audiobookshelf komga jellyfin immich paperless; do
  run_routing_suite "$routing_suite"
  [ ! -s "$routing_events" ] || {
    printf '%s\n' 'tinyMediaManager integration still invokes active-service modes' >&2
    exit 1
  }
done
for suite in komga tinymediamanager jellyfin immich; do
  grep -qF "suite_is $suite" "$integration" || {
    printf '%s\n' "$suite has no independent scenario dispatch" >&2
    exit 1
  }
done
jellyfin_scenarios=$(sed -n '/suite_is jellyfin/,/^    fi$/p' "$integration")
printf '%s\n' "$jellyfin_scenarios" | grep -qF 'run_jellyfin_contract seed'
printf '%s\n' "$jellyfin_scenarios" | grep -qF 'run_jellyfin_contract run'
if printf '%s\n' "$jellyfin_scenarios" | grep -qi tinymediamanager; then
  printf '%s\n' 'Jellyfin scenario dispatch depends on tinyMediaManager' >&2
  exit 1
fi

# The committed deployment vault is intentionally encrypted with an operator
# password unavailable to CI. Every suite must use an isolated controller copy,
# replace only that copy with its generated ephemeral vault, and export the
# matching password before any Ansible invocation.
grep -qF -- 'controller_mount=$sandbox/repo' "$integration"
grep -qF -- 'install -m 0600 \"\$vault_file\" /repo/inventory/group_vars/all/vault.yml' "$integration"
grep -qF -- 'export ANSIBLE_VAULT_PASSWORD_FILE=\"\$vault_password_file\"' "$integration"
grep -qF -- '-e @\"\$fixture_vars_file\"' "$integration" || {
  printf '%s\n' 'integration deployment does not consume the protected Immich fixture policy' >&2
  exit 1
}
if grep -qF -- 'controller_mount=$repo_dir' "$integration"; then
  printf '%s\n' 'integration may mount the committed deployment vault directly' >&2
  exit 1
fi

assert_rejected 'unknown integration suite: unknown' --suite unknown
assert_rejected 'unknown integration suite: media' --suite media
assert_rejected 'unknown integration suite: <missing>' --suite
assert_rejected 'unknown integration suite: <missing>' --suite --tags ntfy
assert_rejected 'unknown integration suite: <missing>' --describe-suite
assert_rejected 'missing value for --tags' --suite smoke --tags
assert_rejected 'invalid integration tags: Bad' --suite smoke --tags Bad
assert_rejected 'invalid integration tags: ntfy,,beszel' \
  --suite smoke --tags ntfy,,beszel
for suite in foundation beszel dozzle audiobookshelf komga tinymediamanager jellyfin immich paperless full; do
  assert_rejected "integration suite $suite does not accept --tags" \
    --suite "$suite" --tags ntfy
done
assert_rejected 'integration suite foundation does not accept --tags' \
  --suite foundation custom.yml --tags ntfy
assert_rejected 'integration suite options must precede the playbook' \
  --suite smoke custom.yml --tags 'Bad;touch'
assert_rejected 'integration suite options must precede the playbook' \
  --suite smoke custom.yml --tags=ntfy
assert_rejected 'unexpected integration suite argument: --check' \
  --suite smoke custom.yml --check

[ ! -e "$docker_log" ] || {
  printf 'dispatch inspection reached Docker: %s\n' "$(cat "$docker_log")" >&2
  exit 1
}

printf 'integration suite dispatch tests passed\n'
