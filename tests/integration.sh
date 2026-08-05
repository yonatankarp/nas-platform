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
runner_image=docker.io/library/python:3.13-alpine@sha256:399babc8b49529dabfd9c922f2b5eea81d611e4512e3ed250d75bd2e7683f4b0
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

mkdir -p "$sandbox/volume1/Docker" "$sandbox/volume2" "$sandbox/repo" \
  "$sandbox/fixtures" "$sandbox/reports"
chmod 0777 "$sandbox/fixtures" "$sandbox/reports"

# Prove that deployment definitions are owned by the controller revision, not
# trusted from whatever happens to exist on the target. The bundle role must
# replace this deliberately stale definition and identify its controller commit.
expected_release_id=$(git -C "$repo_dir" rev-parse HEAD)
stale_service_dir="$sandbox/volume1/Docker/nas-platform/current/services/ntfy"
stale_release_dir="$sandbox/volume1/Docker/nas-platform/releases/$expected_release_id"
mkdir -p "$stale_service_dir" \
  "$stale_release_dir/services/ntfy" \
  "$stale_release_dir/services/undeclared"
printf '%s\n' 'stale target compose definition' > "$stale_service_dir/compose.yml"
printf '%s\n' 'stale release compose definition' \
  > "$stale_release_dir/services/ntfy/compose.yml"
printf '%s\n' 'stale target-only override' \
  > "$stale_release_dir/services/ntfy/compose.nas.yml"
printf '%s\n' 'undeclared target service' \
  > "$stale_release_dir/services/undeclared/compose.yml"

# A copy of the repository, so a play cannot modify the working tree.
tar -C "$repo_dir" -cf - --exclude .git . | tar -C "$sandbox/repo" -xf -

# Exercise the controller guard in an isolated Git checkout. Its play has a
# target-mutating task immediately after validation, so each refusal also proves
# the guard runs before target state can change.
controller_test_dir="$sandbox/controller-checkout"
controller_test_playbook="$controller_test_dir/dirty-controller-test.yml"
controller_test_target="$sandbox/dirty-controller-target"
controller_test_sentinel="$sandbox/dirty-controller-sentinel"
mkdir -p "$controller_test_dir/services/ntfy" "$controller_test_dir/roles"
cp "$repo_dir/services/manifest.yml" "$controller_test_dir/services/manifest.yml"
cp "$repo_dir/services/ntfy/compose.yml" "$controller_test_dir/services/ntfy/compose.yml"
cp -R "$repo_dir/roles/deployment_bundle" "$controller_test_dir/roles/"
cat > "$controller_test_playbook" <<EOF
---
- name: Prove dirty controller validation precedes target mutation
  hosts: localhost
  connection: local
  gather_facts: false
  pre_tasks:
    - name: Validate isolated controller sources
      ansible.builtin.include_role:
        name: deployment_bundle
        tasks_from: controller
  tasks:
    - name: Mutate the target only after validation
      ansible.builtin.copy:
        content: mutated
        dest: $controller_test_target
        mode: "0600"
EOF
git -C "$controller_test_dir" init -q
git -C "$controller_test_dir" config user.name 'NAS platform integration'
git -C "$controller_test_dir" config user.email 'integration@example.invalid'
git -C "$controller_test_dir" add .
git -C "$controller_test_dir" commit -qm 'fixture baseline'
printf '%s\n' pristine > "$controller_test_sentinel"

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
    apk add --no-cache --quiet docker-cli docker-cli-compose git tar '$ruby_package' '$curl_package' >/dev/null
    pip install --quiet --no-input 'ansible-core==$ansible_core_version'
    ansible-galaxy collection install -r /repo/requirements.yml >/dev/null

    assert_dirty_refused() {
      evidence=\$1
      expected=\$2
      shift 2
      rm -f '$controller_test_target'
      if ansible-playbook -i localhost, '$controller_test_playbook' \"\$@\" \
          >/tmp/dirty-controller.txt 2>&1; then
        cat /tmp/dirty-controller.txt >&2
        printf 'DIRTY CONTROLLER ACCEPTED UNEXPECTEDLY: %s\n' \"\$evidence\" >&2
        exit 1
      fi
      if ! grep -qF \"\$expected\" /tmp/dirty-controller.txt; then
        cat /tmp/dirty-controller.txt >&2
        printf 'DIRTY CONTROLLER FAILED FOR WRONG REASON: %s\n' \"\$evidence\" >&2
        exit 1
      fi
      if [ -e '$controller_test_target' ] || \
         [ \"\$(cat '$controller_test_sentinel')\" != pristine ]; then
        printf 'DIRTY REFUSAL MUTATED TARGET: %s\n' \"\$evidence\" >&2
        exit 1
      fi
      printf '%s\n' \"\$evidence\"
      printf 'DIRTY_REFUSAL_TARGET_UNCHANGED\n'
    }

    printf '%s\n' dirty >> '$controller_test_dir/services/ntfy/compose.yml'
    assert_dirty_refused DIRTY_TRACKED_REFUSED \
      'Controller checkout differs from Git HEAD' \
      -e platform_kind=production
    git -C '$controller_test_dir' checkout -q -- .

    printf '%s\n' untracked > '$controller_test_dir/services/untracked.yml'
    assert_dirty_refused DIRTY_UNTRACKED_REFUSED \
      'Controller checkout differs from Git HEAD' \
      -e platform_kind=production
    rm '$controller_test_dir/services/untracked.yml'

    printf '%s\n' dirty >> \
      '$controller_test_dir/roles/deployment_bundle/templates/manifest.yml.j2'
    assert_dirty_refused DIRTY_MANIFEST_TEMPLATE_REFUSED \
      'Controller checkout differs from Git HEAD' \
      -e platform_kind=production
    git -C '$controller_test_dir' checkout -q -- .

    printf '%s\n' '# dirty arbitrary controller file' >> '$controller_test_playbook'
    assert_dirty_refused DIRTY_ARBITRARY_CONTROLLER_FILE_REFUSED \
      'Controller checkout differs from Git HEAD' \
      -e platform_kind=production
    git -C '$controller_test_dir' checkout -q -- .

    printf '%s\n' dirty >> '$controller_test_dir/services/ntfy/compose.yml'
    assert_dirty_refused DIRTY_PRODUCTION_BYPASS_REFUSED \
      'permitted only when platform_kind is integration' \
      -e platform_kind=production \
      -e deployment_bundle_allow_dirty_controller=true

    rm -f '$controller_test_target'
    if ! ansible-playbook -i localhost, '$controller_test_playbook' \
        -e platform_kind=integration \
        -e deployment_bundle_allow_dirty_controller=true \
        >/tmp/dirty-controller-integration.txt 2>&1; then
      cat /tmp/dirty-controller-integration.txt >&2
      exit 1
    fi
    test -f '$controller_test_target'
    printf 'DIRTY_INTEGRATION_ACCEPTED\n'
    git -C '$controller_test_dir' checkout -q -- .

    run_play() {
      ansible-playbook \
        -i inventory/local.yml \
        -e @$sandbox/sandbox-vault.yml \
        -e nas_docker_root=$sandbox/volume1/Docker \
        -e nas_media_root=$sandbox/volume2 \
        -e platform_kind=integration \
        -e deployment_bundle_allow_dirty_controller=true \
        '$playbook' \"\$@\"
    }

    if [ "\$#" -eq 0 ]; then
    run_play
    else
      run_play "\$@"
    fi

    if cmp -s \
      /repo/services/ntfy/compose.yml \
      '$sandbox/volume1/Docker/nas-platform/current/services/ntfy/compose.yml'; then
      printf 'BUNDLE OWNED: target compose matches controller source\n'
    else
      printf 'BUNDLE STALE: target compose does not match controller source\n' >&2
      exit 1
    fi

    if grep -qF 'git_sha: $expected_release_id' \
      '$sandbox/volume1/Docker/nas-platform/current/manifest.yml'; then
      printf 'BUNDLE IDENTIFIED: deployment manifest records controller Git SHA\n'
    else
      printf 'BUNDLE UNIDENTIFIED: deployment manifest lacks controller Git SHA\n' >&2
      exit 1
    fi

    expected_ntfy_checksum=\$(sha256sum /repo/services/ntfy/compose.yml | cut -d' ' -f1)
    if grep -qF "\$expected_ntfy_checksum" \
      '$sandbox/volume1/Docker/nas-platform/current/manifest.yml'; then
      printf 'BUNDLE CHECKSUMMED: manifest binds controller content\n'
    else
      printf 'BUNDLE UNCHECKSUMMED: manifest lacks controller checksum\n' >&2
      exit 1
    fi

    if [ ! -e '$stale_release_dir/services/ntfy/compose.nas.yml' ] && \
       [ ! -e '$stale_release_dir/services/undeclared' ]; then
      printf 'BUNDLE CLEAN: target-only release content was removed\n'
    else
      printf 'BUNDLE DIRTY: target-only release content survived assembly\n' >&2
      exit 1
    fi

    if [ "\$#" -eq 0 ]; then
      env \
        PLATFORM_KIND=integration \
        PLATFORM_CONTRACT_VAULT_FILE='$sandbox/sandbox-vault.yml' \
        PLATFORM_DOCKER_ROOT='$sandbox/volume1/Docker' \
        PLATFORM_MEDIA_ROOT='$sandbox/volume2' \
        PLATFORM_FIXTURE_ROOT='$sandbox/fixtures' \
        PLATFORM_REPORT_ROOT='$sandbox/reports' \
        ruby /repo/tests/run_contracts.rb --execute
    fi

    printf '\n=== phase 2: asserting idempotence ===\n'
    run_play "\$@" | tee /tmp/second.txt
    # Must also require failed=0: a run that changed nothing because it died
    # early is not idempotent, and an earlier version of this check passed on it.
    if grep -qE 'changed=0 ' /tmp/second.txt && grep -qE 'failed=0 ' /tmp/second.txt; then
      printf 'IDEMPOTENT: second run changed nothing\n'
    else
      printf 'NOT IDEMPOTENT: second run reported changes\n' >&2
      exit 1
    fi

    printf '\n=== phase 3: asserting --check --diff works ===\n'
    if run_play "\$@" --check --diff; then
      printf 'CHECK MODE OK: dry run completed\n'
    else
      printf 'CHECK MODE BROKEN: dry run failed\n' >&2
      exit 1
    fi
  " integration-run "$@"
