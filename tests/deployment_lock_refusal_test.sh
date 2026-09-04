#!/bin/sh
# Proof for issue #326: a second converge is refused at the first task of the
# role that would race, with a message that says a deployment is running -- not
# with the containment guard's unsafe-deployment-target refusal, which is what an
# operator actually saw when the poller repointed `current` underneath a hand-run
# converge.
#
# Everything here is executed rather than asserted from the task file: the lock is
# taken through scripts/production_auto_deploy.py's own deployment_lock, and the
# refusal is read out of a real ansible-playbook run of the real role.
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
ansible_playbook=$(command -v ansible-playbook) || {
  printf '%s\n' 'ansible-playbook is required for the deployment lock proof' >&2
  exit 1
}
python=${PYTHON:-python3}
command -v "$python" >/dev/null || {
  printf '%s\n' 'python3 is required for the deployment lock proof' >&2
  exit 1
}

# -P: the containment validator lstats every ancestor of the deployment root, and
# on a Mac the temporary directory hangs below /var, which is a symlink.
fixture=$(CDPATH= cd -- "$(mktemp -d "${TMPDIR:-/tmp}/nas-platform-deploy-lock.XXXXXX")" && pwd -P)
holder_pid=
cleanup() {
  if [ -n "$holder_pid" ]; then
    kill "$holder_pid" 2>/dev/null || true
    wait "$holder_pid" 2>/dev/null || true
  fi
  rm -R -- "$fixture"
}
trap cleanup EXIT HUP INT TERM

state_root=$fixture/state
docker_root=$fixture/docker
media_root=$fixture/media
mkdir -m 0755 "$state_root" "$docker_root" "$media_root"
lock_path=$state_root/deployment.lock
holder_record=$fixture/holder-pid

run_play() {
  DEPLOYMENT_LOCK_DOCKER_ROOT=$docker_root \
  DEPLOYMENT_LOCK_MEDIA_ROOT=$media_root \
  DEPLOYMENT_LOCK_PATH=$lock_path \
  ANSIBLE_CONFIG=$repo_dir/ansible.cfg \
    "$ansible_playbook" -i localhost, -c local \
      "$repo_dir/tests/deployment_lock_refusal_test.yml" \
      >"$1" 2>&1
}

output=$fixture/no-holder
set +e
(cd "$repo_dir" && run_play "$output")
status=$?
set -e
[ "$status" -eq 0 ] || {
  cat "$output" >&2
  printf '%s\n' 'target validation failed with no deployment lock held' >&2
  exit 1
}
grep -qF 'deployment lock probe accepted this converge' "$output" || {
  cat "$output" >&2
  printf '%s\n' 'target validation stopped short with no deployment lock held' >&2
  exit 1
}

# The holder is the poller's own deployment_lock, not a hand-rolled flock: the
# point of the guard is that both paths serialise on one mechanism, so a proof
# that used a second one would prove nothing about the first.
"$python" -c '
import os, signal, sys, time
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, sys.argv[1])
import production_auto_deploy

config = SimpleNamespace(state_root=Path(sys.argv[2]))
signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
with production_auto_deploy.deployment_lock(config, holder="operator converge") as acquired:
    if not acquired:
        raise SystemExit("the fixture lock was already held")
    Path(sys.argv[3]).write_text(f"{os.getpid()}\n", encoding="ascii")
    # Released by the harness terminating this process. Bounded so a harness that
    # dies without its trap cannot leave a holder behind for an hour.
    time.sleep(900)
' "$repo_dir/scripts" "$state_root" "$holder_record" &
holder_pid=$!

# Bounded on the holder still being alive, not on the clock: the wait ends when
# the record appears or when the process that would write it is gone.
while [ ! -s "$holder_record" ]; do
  kill -0 "$holder_pid" 2>/dev/null || {
    printf '%s\n' 'the deployment lock holder exited before taking the lock' >&2
    exit 1
  }
  sleep 0.2 2>/dev/null || sleep 1
done
holder_recorded_pid=$(cat "$holder_record")
[ "$holder_recorded_pid" = "$holder_pid" ] || {
  printf '%s\n' 'the holder reported a pid that is not the process holding the lock' >&2
  exit 1
}

output=$fixture/refused
set +e
(cd "$repo_dir" && run_play "$output")
status=$?
set -e
[ "$status" -ne 0 ] || {
  cat "$output" >&2
  printf '%s\n' 'target validation accepted a converge while another holds the lock' >&2
  exit 1
}
grep -qF 'A deployment is already running on this host' "$output" || {
  cat "$output" >&2
  printf '%s\n' 'the concurrent deployment was not named as the reason for the failure' >&2
  exit 1
}
grep -qF "operator converge (pid $holder_pid" "$output" || {
  cat "$output" >&2
  printf '%s\n' 'the refusal did not name the holder it found' >&2
  exit 1
}
# The whole point of #326: the run must not reach the containment guard, whose
# message describes an integrity violation the operator does not have.
if grep -qF 'Unsafe deployment target /' "$output"; then
  cat "$output" >&2
  printf '%s\n' 'the race still surfaced as a containment refusal' >&2
  exit 1
fi
# The exact task banner, not the task name: the arg-spec validation task quotes
# the entry point's own short_description, which is that same sentence.
if grep -qF 'TASK [deployment_bundle : Validate target path ancestry and canonical containment]' "$output"; then
  cat "$output" >&2
  printf '%s\n' 'containment validation ran after a concurrent deployment was found' >&2
  exit 1
fi

# Same held lock, this time declared as this run's own holder, which is what
# `nas-platform-deploy --converge` and the poller's own plays export. Without
# this the guard would refuse the very converge that took the lock.
output=$fixture/owner
set +e
(cd "$repo_dir" && PLATFORM_DEPLOYMENT_LOCK_OWNER=$holder_pid run_play "$output")
status=$?
set -e
[ "$status" -eq 0 ] || {
  cat "$output" >&2
  printf '%s\n' 'a converge holding the lock itself was refused by its own guard' >&2
  exit 1
}
grep -qF 'deployment lock probe accepted this converge' "$output" || {
  cat "$output" >&2
  printf '%s\n' 'the lock-holding converge stopped short of containment validation' >&2
  exit 1
}

# A stale declaration must not disarm the guard: exporting somebody else's pid,
# or a leftover one, is not evidence that this run holds anything.
output=$fixture/wrong-owner
set +e
(cd "$repo_dir" && PLATFORM_DEPLOYMENT_LOCK_OWNER=$((holder_pid + 1)) run_play "$output")
status=$?
set -e
[ "$status" -ne 0 ] || {
  cat "$output" >&2
  printf '%s\n' 'a mismatched lock owner declaration disarmed the concurrency guard' >&2
  exit 1
}

printf '%s\n' 'concurrent deployment refused before containment validation'
