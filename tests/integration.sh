#!/bin/sh
# Runs the plays against a disposable sandbox instead of the NAS.
#
# Ansible executes inside a Linux container so the plays meet a real
# /proc/mounts, real numeric uid and gid, and a real Docker socket. Because the
# Compose definitions take NAS_DOCKER_ROOT and NAS_MEDIA_ROOT rather than
# absolute paths, the sandbox needs only to point those at a temporary directory:
# no override files, and the definitions run byte-identical to production.
#
# Three phases, all of which must pass:
#   1. converge
#   2. converge again, asserting nothing changes
#   3. --check --diff, asserting a dry run works
#
# Usage: tests/integration.sh [playbook]
set -eu

ansible_core_version=2.21.2
runner_image=docker.io/library/python:3.13-alpine
ruby_package='ruby=3.4.9-r0'
curl_package='curl=8.21.0-r0'

playbook=${1:-site.yml}
[ "$#" -gt 0 ] && shift || true

repo_dir=$(CDPATH= cd -P "$(dirname "$0")/.." && pwd -P)
. "$repo_dir/tests/sandbox_cleanup.sh"

# Bind sources must be valid for the Docker daemon as well as this container. On
# macOS TMPDIR lives under /private, which Docker Desktop shares by default; on
# Linux the daemon shares the host filesystem, so /tmp is correct.
temporary_parent=${TMPDIR:-/tmp}
temporary_parent=${temporary_parent%/}
sandbox=$(mktemp -d "$temporary_parent/nas-platform-integration.XXXXXX")
trap 'cleanup_sandbox_on_exit "$sandbox" "$?"' EXIT
trap 'exit 130' HUP INT TERM
chmod 0777 "$sandbox"

mkdir -p "$sandbox/volume1/Docker" "$sandbox/volume2" "$sandbox/repo"

# A copy of the repository, so a play cannot modify the working tree.
tar -C "$repo_dir" -cf - --exclude .git . | tar -C "$sandbox/repo" -xf -

# Sandbox stand-ins for vault. Hashes and tokens are generated at run time by the
# service's own pinned image, so no credential is committed and every value is in
# exactly the format the service accepts.
ntfy_image=$(grep -oE 'image: [^ ]+' "$repo_dir/services/ntfy/compose.yml" | head -1 | cut -d' ' -f2)
random_password() { LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24; }
bcrypt_of() {
  printf '%s\n%s\n' "$1" "$1" \
    | docker run --rm -i "$ntfy_image" user hash 2>/dev/null \
    | grep -oE '\$2[aby]\$[0-9]{2}\$[./A-Za-z0-9]{53}'
}
ntfy_token() { docker run --rm "$ntfy_image" token generate 2>/dev/null | grep -oE 'tk_[a-z0-9]{29}'; }

# Beszel's hub keypair is authored, not read back, so the sandbox authors one too.
ssh-keygen -q -t ed25519 -N '' -C 'sandbox beszel hub' -f "$sandbox/beszel_hub_key"

umask 077
cat > "$sandbox/sandbox-vault.yml" <<EOF
vault_nas_address: 127.0.0.1
vault_nas_user: sandbox
vault_ntfy_admin_user: sandboxadmin
vault_ntfy_admin_password_hash: "$(bcrypt_of "$(random_password)")"
vault_ntfy_dozzle_password_hash: "$(bcrypt_of "$(random_password)")"
vault_ntfy_dozzle_token: $(ntfy_token)
vault_ntfy_beszel_password_hash: "$(bcrypt_of "$(random_password)")"
vault_ntfy_beszel_token: $(ntfy_token)
vault_beszel_superuser_email: sandbox@example.invalid
vault_beszel_superuser_password: $(random_password)
vault_beszel_app_user_email: sandboxuser@example.invalid
vault_beszel_app_user_password: $(random_password)
vault_beszel_agent_key: "$(awk '{print $1, $2}' "$sandbox/beszel_hub_key.pub")"
vault_beszel_universal_token: $(uuidgen | tr 'A-Z' 'a-z')
vault_beszel_hub_private_key: |
$(sed 's/^/  /' "$sandbox/beszel_hub_key")
EOF
umask 022

printf 'sandbox: %s\n' "$sandbox"

docker run --rm \
  --network host \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$repo_dir":/repo:ro \
  `# Mounted at its own path so the storage roots resolve identically inside` \
  `# this container and on the Docker daemon's host.` \
  -v "$sandbox":"$sandbox" \
  -e ANSIBLE_CONFIG=/repo/ansible.cfg \
  -w /repo \
  "$runner_image" \
  sh -eu -c "
    apk add --no-cache --quiet docker-cli docker-cli-compose tar '$ruby_package' '$curl_package' >/dev/null
    pip install --quiet --no-input 'ansible-core==$ansible_core_version'
    ansible-galaxy collection install -r /repo/requirements.yml >/dev/null

    run_play() {
      ansible-playbook \
        -i inventory/local.yml \
        -e @$sandbox/sandbox-vault.yml \
        -e nas_repo_dir=$sandbox/repo \
        -e nas_docker_root=$sandbox/volume1/Docker \
        -e nas_media_root=$sandbox/volume2 \
        '$playbook' \"\$@\"
    }

    run_play

    ruby /repo/tests/run_contracts.rb --execute

    printf '\n=== phase 2: asserting idempotence ===\n'
    run_play | tee /tmp/second.txt
    # Must also require failed=0: a run that changed nothing because it died
    # early is not idempotent, and an earlier version of this check passed on it.
    if grep -qE 'changed=0 ' /tmp/second.txt && grep -qE 'failed=0 ' /tmp/second.txt; then
      printf 'IDEMPOTENT: second run changed nothing\n'
    else
      printf 'NOT IDEMPOTENT: second run reported changes\n' >&2
      exit 1
    fi

    printf '\n=== phase 3: asserting --check --diff works ===\n'
    if run_play --check --diff; then
      printf 'CHECK MODE OK: dry run completed\n'
    else
      printf 'CHECK MODE BROKEN: dry run failed\n' >&2
      exit 1
    fi
  "
