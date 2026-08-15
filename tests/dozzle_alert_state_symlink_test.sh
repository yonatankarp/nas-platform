#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
ansible_playbook=$(command -v ansible-playbook) || {
  printf '%s\n' 'ansible-playbook is required for the Dozzle state symlink proof' >&2
  exit 1
}
fixture=$(mktemp -d "${TMPDIR:-/tmp}/nas-platform-dozzle-state.XXXXXX")
cleanup() {
  rm -R -- "$fixture"
}
trap cleanup EXIT HUP INT TERM

state_root=$fixture/state
sentinel_target=$fixture/sentinel-target
mkdir -m 0755 "$state_root" "$sentinel_target"
printf '%s\n' 'dozzle relay sentinel' > "$sentinel_target/contents"
chmod 0644 "$sentinel_target/contents"
ln -s "$sentinel_target" "$state_root/alert-relay"

snapshot() {
  ruby -rdigest -e '
    path, content = ARGV
    details = File.stat(path)
    puts [details.uid, details.gid, details.mode & 07777,
          Digest::SHA256.file(content).hexdigest].join(":")
  ' "$sentinel_target" "$sentinel_target/contents"
}

before=$(snapshot)
output=$fixture/ansible-output
set +e
DOZZLE_SYMLINK_STATE_ROOT=$state_root \
DOZZLE_SYMLINK_UID=$(id -u) \
DOZZLE_SYMLINK_GID=$(id -g) \
DOZZLE_SYMLINK_REPO_ROOT=$repo_dir \
  "$ansible_playbook" -i localhost, -c local \
    "$repo_dir/tests/dozzle_alert_state_symlink_test.yml" \
    --start-at-task 'dozzle : Inspect the selected Dozzle state parent before child creation' \
    >"$output" 2>&1
status=$?
set -e

[ "$status" -ne 0 ] || {
  printf '%s\n' 'Dozzle role accepted a relay child symlink' >&2
  exit 1
}
grep -qF 'Dozzle alert relay state child is unsafe before mutation.' "$output" || {
  cat "$output" >&2
  printf '%s\n' 'Dozzle role failed outside the pre-mutation child safety gate' >&2
  exit 1
}
[ -L "$state_root/alert-relay" ] || {
  printf '%s\n' 'Dozzle role replaced the relay child symlink' >&2
  exit 1
}
[ "$(readlink "$state_root/alert-relay")" = "$sentinel_target" ] || {
  printf '%s\n' 'Dozzle role changed the relay child symlink target' >&2
  exit 1
}
[ "$(snapshot)" = "$before" ] || {
  printf '%s\n' 'Dozzle role mutated the relay child symlink target' >&2
  exit 1
}
[ "$(cat "$sentinel_target/contents")" = 'dozzle relay sentinel' ] || {
  printf '%s\n' 'Dozzle role changed the relay child sentinel content' >&2
  exit 1
}

printf '%s\n' 'Dozzle alert relay child symlink refused before mutation'
