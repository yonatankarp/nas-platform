#!/bin/sh
set -eu
set +x

mac_test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_dir=$(CDPATH= cd -- "$mac_test_dir/../.." && pwd -P)
temporary_input=$(mktemp -d "${TMPDIR:-/tmp}/nas-platform-dozzle-drift-hook.XXXXXX")
fixture_root=$temporary_input/repo
fake_bin=$temporary_input/bin

cleanup_fixture() {
  fixture_status=$?
  trap - EXIT HUP INT TERM
  if [ -d "$temporary_input" ] && [ ! -L "$temporary_input" ]; then
    find "$temporary_input" -depth -mindepth 1 -delete
    rmdir -- "$temporary_input"
  fi
  exit "$fixture_status"
}
trap cleanup_fixture EXIT HUP INT TERM

mkdir -p "$fixture_root/tests/mac/hooks/drift" "$fixture_root/tests/mac/hooks/verify" \
  "$fixture_root/tests/mac" \
  "$fixture_root/tests" "$fixture_root/inventory" "$fake_bin" \
  "$fixture_root/current/services/dozzle" "$fixture_root/runtime/services/dozzle"
cp "$repo_dir/tests/mac/hooks/drift/20-dozzle.sh" \
  "$fixture_root/tests/mac/hooks/drift/20-dozzle.sh"
cp "$repo_dir/tests/mac/hooks/verify/20-dozzle.sh" \
  "$fixture_root/tests/mac/hooks/verify/20-dozzle.sh"
cp "$repo_dir/tests/mac/lib.sh" "$fixture_root/tests/mac/lib.sh"
chmod 0755 "$fixture_root/tests/mac/hooks/drift/20-dozzle.sh" \
  "$fixture_root/tests/mac/hooks/verify/20-dozzle.sh"
: > "$fixture_root/site.yml"
: > "$fixture_root/verify.yml"
: > "$fixture_root/inventory/mac.yml"
: > "$fixture_root/current/services/dozzle/compose.yml"
: > "$fixture_root/current/services/dozzle/compose.mac.yml"
: > "$fixture_root/runtime/services/dozzle/.env"

cat > "$fixture_root/tests/mac/run-dozzle-contract.sh" <<'STUB'
#!/bin/sh
mode=${1-}
printf '%s\n' "$mode" >> "${PLATFORM_HOOK_EVENTS:?}"
case $mode in
  check-mixed-create)
    : > "${PLATFORM_HOOK_FIXTURE:?}"
    ;;
  check-mixed-recover)
    unlink "${PLATFORM_HOOK_FIXTURE:?}" 2>/dev/null || true
    : > "${PLATFORM_HOOK_RECOVERED:?}"
    ;;
  assert-check-mixed-output)
    [ "${PLATFORM_HOOK_SCENARIO:?}" != assertion-failure ]
    ;;
esac
STUB
chmod 0755 "$fixture_root/tests/mac/run-dozzle-contract.sh"

cat > "$fixture_root/tests/mac/verify.sh" <<'STUB'
#!/bin/sh
printf '%s\n' VERIFY_ALL >> "${PLATFORM_HOOK_EVENTS:?}"
printf '%s\n' 'Beszel verification failed because fixture drift remains.' >&2
exit 1
STUB
chmod 0755 "$fixture_root/tests/mac/verify.sh"

cat > "$fixture_root/tests/assert-no-vault-secrets.rb" <<'STUB'
#!/bin/sh
exit 0
STUB
chmod 0755 "$fixture_root/tests/assert-no-vault-secrets.rb"

cat > "$fake_bin/ansible-playbook" <<'STUB'
#!/bin/sh
case " $* " in
  *" --check "*)
    if [ "${PLATFORM_HOOK_SCENARIO:?}" = signal ]; then
      : > "${PLATFORM_HOOK_READY:?}"
      sleep 1
    fi
    cat <<'OUTPUT'
TASK [dozzle : Report planned managed Dozzle dispatcher creation]
TASK [dozzle : Report planned managed Dozzle dispatcher repair]
TASK [dozzle : Report planned managed Dozzle alert rule creation]
TASK [dozzle : Report planned managed Dozzle alert rule repair]
TASK [dozzle : Report planned managed Dozzle alert rule enabled-state repair]
TASK [dozzle : Report planned unmanaged Dozzle alert rule removal]
TASK [dozzle : Report planned unmanaged Dozzle dispatcher removal]
DOZZLE_PLAN_DISPATCHER_REPAIR
DOZZLE_PLAN_RULE_CREATE
DOZZLE_PLAN_RULE_REPAIR
DOZZLE_PLAN_RULE_ENABLE_REPAIR
DOZZLE_PLAN_RULE_REMOVE
DOZZLE_PLAN_DISPATCHER_REMOVE
mac : ok=1 changed=6 unreachable=0 failed=0 skipped=6 rescued=0 ignored=0
OUTPUT
    ;;
  *)
    printf '%s\n' VERIFY_DOZZLE >> "${PLATFORM_HOOK_EVENTS:?}"
    if [ "${PLATFORM_HOOK_SCENARIO:?}" = dozzle-accept ]; then
      exit 0
    fi
    printf '%s\n' 'Dozzle ntfy dispatcher is absent or drifted.' >&2
    exit 2
    ;;
esac
STUB
chmod 0755 "$fake_bin/ansible-playbook"

cat > "$fake_bin/docker" <<'STUB'
#!/bin/sh
case " $* " in
  *" container inspect "*)
    for argument in "$@"; do container=$argument; done
    printf 'INSPECT %s\n' "$container" >> "${PLATFORM_HOOK_EVENTS:?}"
    case $container in
      *-audiobookshelf) expected_name=audiobookshelf; expected_group= ;;
      *-beszel) expected_name=hub; expected_group=beszel ;;
      *-beszel-agent-portable) expected_name=agent-portable; expected_group=beszel ;;
      *-beszel-socket-proxy) expected_name=socket-proxy; expected_group=beszel ;;
      *-dozzle-alert-relay) expected_name=alert-relay; expected_group=dozzle ;;
      *-dozzle) expected_name=dozzle; expected_group=dozzle ;;
      *-dozzle-socket-proxy) expected_name=socket-proxy; expected_group=dozzle ;;
      *-immich-server) expected_name=immich-server; expected_group=immich ;;
      *-immich-machine-learning) expected_name=immich-machine-learning; expected_group=immich ;;
      *-immich-redis) expected_name=redis; expected_group=immich ;;
      *-immich-postgres) expected_name=database; expected_group=immich ;;
      *-jellyfin) expected_name=jellyfin; expected_group= ;;
      *-komga) expected_name=komga; expected_group= ;;
      *-ntfy) expected_name=ntfy; expected_group= ;;
      *-paperless-redis) expected_name=broker; expected_group=paperless ;;
      *-paperless-postgres) expected_name=db; expected_group=paperless ;;
      *-paperless-webserver) expected_name=webserver; expected_group=paperless ;;
      *-paperless-gotenberg) expected_name=gotenberg; expected_group=paperless ;;
      *-paperless-tika) expected_name=tika; expected_group=paperless ;;
      *-tinymediamanager)
        printf 'Error: No such container: %s\n' "$container" >&2
        exit 1
        ;;
      *) exit 2 ;;
    esac
    label_state=$(cat "${PLATFORM_HOOK_LABEL_STATE:?}")
    if [ "$container" = dozzle-hook-test-dozzle-socket-proxy ]; then
      case $label_state in
        drifted)
          printf '%s\n' '{"dev.dozzle.group":"dozzle-contract-drift","dev.dozzle.name":"dozzle-contract-drift","dev.dozzle.contract.sentinel":"unrelated-label-must-not-survive-reconciliation"}'
          exit 0
          ;;
        wrong-group)
          printf '%s\n' '{"dev.dozzle.group":"dozzle-contract-drift","dev.dozzle.name":"socket-proxy"}'
          exit 0
          ;;
        sentinel)
          printf '%s\n' '{"dev.dozzle.group":"dozzle","dev.dozzle.name":"socket-proxy","dev.dozzle.contract.sentinel":"unrelated-label-must-not-survive-reconciliation"}'
          exit 0
          ;;
        wrong-name)
          printf '%s\n' '{"dev.dozzle.group":"dozzle","dev.dozzle.name":"dozzle-contract-drift"}'
          exit 0
          ;;
        missing-name)
          printf '%s\n' '{"dev.dozzle.group":"dozzle"}'
          exit 0
          ;;
        non-object)
          printf '%s\n' 'null'
          exit 0
          ;;
      esac
    fi
    if [ -n "$expected_group" ]; then
      printf '{"dev.dozzle.group":"%s","dev.dozzle.name":"%s"}\n' \
        "$expected_group" "$expected_name"
    else
      printf '{"dev.dozzle.name":"%s"}\n' "$expected_name"
    fi
    ;;
  *"dozzle-label-drift."*)
    printf '%s\n' drifted > "${PLATFORM_HOOK_LABEL_STATE:?}"
    printf '%s\n' LABEL_DRIFT >> "${PLATFORM_HOOK_EVENTS:?}"
    ;;
  *" compose "*)
    printf '%s\n' managed > "${PLATFORM_HOOK_LABEL_STATE:?}"
    printf '%s\n' LABEL_RECOVER >> "${PLATFORM_HOOK_EVENTS:?}"
    ;;
  *) exit 2 ;;
esac
STUB
chmod 0755 "$fake_bin/docker"

run_hook() {
  scenario=$1
  case_root=$temporary_input/$scenario
  report_root=$case_root/reports
  mkdir -p "$report_root"
  : > "$case_root/vault.yml"
  : > "$case_root/password"
  : > "$case_root/events"
  printf '%s\n' managed > "$case_root/labels"
  PLATFORM_REPORT_ROOT="$report_root" \
    PLATFORM_MAC_VAULT_FILE="$case_root/vault.yml" \
    PLATFORM_MAC_VAULT_PASSWORD_FILE="$case_root/password" \
    PLATFORM_HOOK_EVENTS="$case_root/events" \
    PLATFORM_HOOK_FIXTURE="$case_root/fixture" \
    PLATFORM_HOOK_RECOVERED="$case_root/recovered" \
    PLATFORM_HOOK_READY="$case_root/ready" \
    PLATFORM_HOOK_LABEL_STATE="$case_root/labels" \
    PLATFORM_HOOK_SCENARIO="$scenario" \
    PLATFORM_DOCKER_ROOT="$fixture_root" \
    PLATFORM_PROJECT_NAME=dozzle-hook-test \
    PLATFORM_PROOF_LANE=fresh \
    PLATFORM_COMPOSE_KIND=mac \
    PATH="$fake_bin:$PATH" \
    "$fixture_root/tests/mac/hooks/drift/20-dozzle.sh"
}

run_verify_hook() {
  case_root=$1
  PLATFORM_REPORT_ROOT="$case_root/reports" \
    PLATFORM_HOOK_EVENTS="$case_root/events" \
    PLATFORM_HOOK_LABEL_STATE="$case_root/labels" \
    PLATFORM_PROJECT_NAME=dozzle-hook-test \
    PLATFORM_PROOF_PLATFORM=mac \
    PATH="$fake_bin:$PATH" \
    "$fixture_root/tests/mac/hooks/verify/20-dozzle.sh"
}

false_status=0
run_hook dozzle-accept >/dev/null 2>&1 || false_status=$?
[ "$false_status" -ne 0 ] &&
  [ -f "$temporary_input/dozzle-accept/recovered" ] &&
  [ ! -e "$temporary_input/dozzle-accept/fixture" ] &&
  [ "$(cat "$temporary_input/dozzle-accept/labels")" = managed ] &&
  grep -q '^LABEL_RECOVER$' "$temporary_input/dozzle-accept/events" || {
  printf '%s\n' 'Dozzle drift hook accepted a Beszel-only failure or did not recover' >&2
  exit 1
}

run_hook success
success_root=$temporary_input/success
[ -f "$success_root/fixture" ] && [ ! -e "$success_root/recovered" ] || {
  printf '%s\n' 'successful Dozzle drift hook did not leave only its fixture for reconcile' >&2
  exit 1
}
grep -q '^LABEL_DRIFT$' "$success_root/events" &&
  ! grep -q '^LABEL_RECOVER$' "$success_root/events" || {
  printf '%s\n' 'successful Dozzle drift hook did not leave container-label drift for reconcile' >&2
  exit 1
}
[ "$(cat "$success_root/labels")" = drifted ] || {
  printf '%s\n' 'successful Dozzle drift hook did not retain the drifted label map' >&2
  exit 1
}
for name_state in wrong-name missing-name; do
  name_verify_status=0
  name_verify_output=$success_root/$name_state-output
  : > "$success_root/events"
  printf '%s\n' "$name_state" > "$success_root/labels"
  run_verify_hook "$success_root" >"$name_verify_output" 2>&1 || name_verify_status=$?
  [ "$name_verify_status" -ne 0 ] &&
    [ "$(cat "$name_verify_output")" = \
      'dozzle-hook-test-dozzle-socket-proxy has an incorrect dev.dozzle.name label' ] &&
    ! grep -Eq '^(verify|notify)$' "$success_root/events" || {
    printf 'Dozzle runtime verification accepted %s, emitted an unsafe diagnostic, or reached the contract runner\n' \
      "$name_state" >&2
    exit 1
  }
done
non_object_verify_status=0
non_object_verify_output=$success_root/non-object-output
: > "$success_root/events"
printf '%s\n' non-object > "$success_root/labels"
run_verify_hook "$success_root" >"$non_object_verify_output" 2>&1 ||
  non_object_verify_status=$?
[ "$non_object_verify_status" -ne 0 ] &&
  [ "$(cat "$non_object_verify_output")" = \
    'dozzle-hook-test-dozzle-socket-proxy returned non-object Docker labels' ] &&
  ! grep -Eq '^(verify|notify)$' "$success_root/events" || {
  printf '%s\n' \
    'Dozzle runtime verification accepted non-object labels, emitted an unsafe diagnostic, or reached the contract runner' >&2
  exit 1
}
drift_verify_status=0
printf '%s\n' wrong-group > "$success_root/labels"
run_verify_hook "$success_root" >/dev/null 2>&1 || drift_verify_status=$?
[ "$drift_verify_status" -ne 0 ] || {
  printf '%s\n' 'Dozzle runtime verification accepted the drifted group' >&2
  exit 1
}
sentinel_verify_status=0
printf '%s\n' sentinel > "$success_root/labels"
run_verify_hook "$success_root" >/dev/null 2>&1 || sentinel_verify_status=$?
[ "$sentinel_verify_status" -ne 0 ] || {
  printf '%s\n' 'Dozzle runtime verification accepted the unmanaged sentinel' >&2
  exit 1
}
: > "$success_root/events"
PLATFORM_HOOK_EVENTS="$success_root/events" \
  PLATFORM_HOOK_LABEL_STATE="$success_root/labels" \
  PATH="$fake_bin:$PATH" docker compose --project-name dozzle-hook-test-dozzle up -d
[ "$(cat "$success_root/labels")" = managed ] && run_verify_hook "$success_root" || {
  printf '%s\n' 'Dozzle Compose reconciliation did not restore the managed runtime labels' >&2
  exit 1
}
grep -q '^verify$' "$success_root/events" && grep -q '^notify$' "$success_root/events" || {
  printf '%s\n' 'Dozzle runtime verification did not complete after label reconciliation' >&2
  exit 1
}
for container in \
  dozzle-hook-test-audiobookshelf \
  dozzle-hook-test-beszel \
  dozzle-hook-test-beszel-agent-portable \
  dozzle-hook-test-beszel-socket-proxy \
  dozzle-hook-test-dozzle-alert-relay \
  dozzle-hook-test-dozzle \
  dozzle-hook-test-dozzle-socket-proxy \
  dozzle-hook-test-immich-server \
  dozzle-hook-test-immich-machine-learning \
  dozzle-hook-test-immich-redis \
  dozzle-hook-test-immich-postgres \
  dozzle-hook-test-jellyfin \
  dozzle-hook-test-komga \
  dozzle-hook-test-ntfy \
  dozzle-hook-test-paperless-redis \
  dozzle-hook-test-paperless-postgres \
  dozzle-hook-test-paperless-webserver \
  dozzle-hook-test-paperless-gotenberg \
  dozzle-hook-test-paperless-tika; do
  grep -Fqx "INSPECT $container" "$success_root/events" || {
    printf 'Dozzle runtime verification omitted %s\n' "$container" >&2
    exit 1
  }
done
! grep -Fqx 'INSPECT dozzle-hook-test-tinymediamanager' "$success_root/events" || {
  printf '%s\n' 'Dozzle runtime verification inspected retired tinyMediaManager' >&2
  exit 1
}
! grep -q '^VERIFY_ALL$' "$success_root/events" || {
  printf '%s\n' 'Dozzle drift hook used all-service verification' >&2
  exit 1
}
[ -z "$(find "$success_root/reports" -mindepth 1 -maxdepth 1 -print -quit)" ] || {
  printf '%s\n' 'successful Dozzle drift hook retained raw report output' >&2
  exit 1
}

assertion_status=0
run_hook assertion-failure >/dev/null 2>&1 || assertion_status=$?
[ "$assertion_status" -ne 0 ] &&
  [ -f "$temporary_input/assertion-failure/recovered" ] &&
  [ ! -e "$temporary_input/assertion-failure/fixture" ] &&
  [ "$(cat "$temporary_input/assertion-failure/labels")" = managed ] &&
  grep -q '^LABEL_RECOVER$' "$temporary_input/assertion-failure/events" || {
  printf '%s\n' 'Dozzle drift assertion failure did not recover its fixture' >&2
  exit 1
}

for signal in HUP INT TERM; do
  case $signal in HUP) expected=129 ;; INT) expected=130 ;; TERM) expected=143 ;; esac
  signal_root=$temporary_input/signal-$signal
  mkdir -p "$signal_root/reports"
  : > "$signal_root/vault.yml"
  : > "$signal_root/password"
  : > "$signal_root/events"
  printf '%s\n' managed > "$signal_root/labels"
  signal_status_file=$signal_root/status
  PLATFORM_REPORT_ROOT="$signal_root/reports" \
    PLATFORM_MAC_VAULT_FILE="$signal_root/vault.yml" \
    PLATFORM_MAC_VAULT_PASSWORD_FILE="$signal_root/password" \
    PLATFORM_HOOK_EVENTS="$signal_root/events" \
    PLATFORM_HOOK_FIXTURE="$signal_root/fixture" \
    PLATFORM_HOOK_RECOVERED="$signal_root/recovered" \
    PLATFORM_HOOK_READY="$signal_root/ready" \
    PLATFORM_HOOK_LABEL_STATE="$signal_root/labels" \
    PLATFORM_HOOK_SCENARIO=signal \
    PLATFORM_DOCKER_ROOT="$fixture_root" \
    PLATFORM_PROJECT_NAME=dozzle-hook-test \
    PLATFORM_PROOF_LANE=fresh \
    PLATFORM_COMPOSE_KIND=mac \
    PATH="$fake_bin:$PATH" \
    ruby - "$signal" "$fixture_root/tests/mac/hooks/drift/20-dozzle.sh" \
      "$signal_root/ready" "$signal_status_file" <<'RUBY'
signal, hook, ready, status_file = ARGV
pid = Process.spawn(hook, out: File::NULL, err: File::NULL)
deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
until File.file?(ready)
  if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    Process.kill("KILL", pid)
    Process.wait(pid)
    abort "Dozzle drift hook did not reach signal fixture for #{signal}"
  end
  sleep 0.02
end
Process.kill(signal, pid)
_waited, status = Process.wait2(pid)
File.write(status_file, status.exitstatus.to_s)
RUBY
  signal_status=$(cat "$signal_status_file")
  [ "$signal_status" -eq "$expected" ] &&
    [ -f "$signal_root/recovered" ] &&
    [ ! -e "$signal_root/fixture" ] &&
    [ "$(cat "$signal_root/labels")" = managed ] &&
    grep -q '^LABEL_RECOVER$' "$signal_root/events" &&
    [ -z "$(find "$signal_root/reports" -mindepth 1 -maxdepth 1 -print -quit)" ] || {
    printf 'Dozzle drift hook mishandled %s (status %s)\n' "$signal" "$signal_status" >&2
    exit 1
  }
done

printf '%s\n' 'Mac Dozzle drift hook: isolated proof, cleanup, recovery, and signals hold'
