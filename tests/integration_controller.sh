#!/bin/sh
# The integration controller, run inside the pinned controller container
# (sources tests/integration_controller_lib.sh).
# Two roots, neither inferred from where this file sits: /repo is the checkout
# copy under test, $sandbox the disposable deploy target. Both arrive as
# environment; tests/policy_test.rb refuses path resolution from this file's location.
set -eu

: "${CONTROLLER_REPO_DIR:?}"
[ "$CONTROLLER_REPO_DIR" = /repo ] || {
  printf 'controller checkout is not mounted at /repo: %s\n' \
    "$CONTROLLER_REPO_DIR" >&2
  exit 1
}

# Bound once here: recomputed in the container they would be computed against
# the /repo copy (expected_release_id and manifest_fixture_sha especially).
sandbox=${CONTROLLER_SANDBOX:?}
integration_project_namespace=${CONTROLLER_PROJECT_NAMESPACE:?}
ruby_package=${CONTROLLER_RUBY_PACKAGE:?}
curl_package=${CONTROLLER_CURL_PACKAGE:?}
ansible_core_version=${CONTROLLER_ANSIBLE_CORE_VERSION:?}
requests_version=${CONTROLLER_REQUESTS_VERSION:?}
expected_release_id=${CONTROLLER_EXPECTED_RELEASE_ID:?}
active_release_dir=${CONTROLLER_ACTIVE_RELEASE_DIR:?}
stale_docker_root=${CONTROLLER_STALE_DOCKER_ROOT:?}
stale_deploy_root=${CONTROLLER_STALE_DEPLOY_ROOT:?}
stale_release_dir=${CONTROLLER_STALE_RELEASE_DIR:?}
manifest_controller=${CONTROLLER_MANIFEST_CONTROLLER:?}
manifest_docker_root=${CONTROLLER_MANIFEST_DOCKER_ROOT:?}
manifest_media_root=${CONTROLLER_MANIFEST_MEDIA_ROOT:?}
manifest_fixture_sha=${CONTROLLER_MANIFEST_FIXTURE_SHA:?}
controller_test_dir=${CONTROLLER_TEST_DIR:?}
controller_test_playbook=${CONTROLLER_TEST_PLAYBOOK:?}
controller_test_target=${CONTROLLER_TEST_TARGET:?}
controller_test_sentinel=${CONTROLLER_TEST_SENTINEL:?}
    # Kept literally identical to tests/integration.Dockerfile, for runs without the image.
    if [ "$INTEGRATION_TOOLCHAIN_PREINSTALLED" != true ]; then
      apk add --no-cache --quiet docker-cli docker-cli-compose git tar openssl \
        apache2-utils openssh-client "$ruby_package" "$curl_package" >/dev/null
      pip install --quiet --no-input "ansible-core==$ansible_core_version" \
        "requests==$requests_version"
      ansible-galaxy collection install --no-cache -r /repo/requirements.yml >/dev/null
    fi

    # Root container, caller-owned sandbox: git would refuse it as dubious ownership.
    # Scoped to this throwaway container.
    git config --global --add safe.directory '*'

    suite_is() {
      [ "$INTEGRATION_SUITE" = full ] || [ "$INTEGRATION_SUITE" = "$1" ]
    }

    # The idempotence-* shards owe the same second and third phases as the whole.
    idempotence_phases() {
      case $INTEGRATION_SUITE in
        full|idempotence-*) return 0 ;;
        *) return 1 ;;
      esac
    }

    playbook=$1
    shift

    vault_directory="$sandbox/nas-platform-vault.000000"
    vault_file="$vault_directory/vault.yml"
    vault_password_file="$vault_directory/password"
    mkdir "$vault_directory"
    chmod 0700 "$vault_directory"
    # The downloaders lane converges with no Usenet provider, the state #274 broke;
    # the bindery lane converges the declared state (the two cannot share a sandbox:
    # the servers reconciliation only upserts). One invocation: policy_manifest_test.rb
    # plants on the output argument as a single occurrence.
    undeclared_provider_argument=
    if [ "$INTEGRATION_SUITE" = downloaders ]; then
      undeclared_provider_argument='--undeclared usenet'
    fi
    # Unquoted on purpose: the flag and its group are two words or none (#640).
    # shellcheck disable=SC2086
    TMPDIR="$sandbox" /repo/tests/generate-ephemeral-vault.sh \
      $undeclared_provider_argument \
      --output "$vault_file" --password-file "$vault_password_file"

    fixture_input_directory="$sandbox/protected-inputs"
    fixture_vars_file="$fixture_input_directory/immich-fixture-vars.yml"
    fixture_vault_view="$fixture_input_directory/.immich-vault-view.yml"
    mkdir "$fixture_input_directory"
    chmod 0700 "$fixture_input_directory"
    cleanup_fixture_vault_view() {
      rm -f "$fixture_vault_view"
    }
    trap cleanup_fixture_vault_view EXIT
    umask 077
    ANSIBLE_VAULT_PASSWORD_FILE="$vault_password_file" ansible-vault view \
      "$vault_file" > "$fixture_vault_view"
    install -m 0600 /dev/null "$fixture_vars_file"
    ruby /repo/tests/mac/generate-immich-fixture-vars.rb \
      "$fixture_vars_file" /repo/inventory/group_vars/all/service_immich.yml \
      < "$fixture_vault_view"
    chmod 0600 "$fixture_vars_file"
    rm -f "$fixture_vault_view"

    cleanup_vault() {
      TMPDIR="$sandbox" /repo/tests/generate-ephemeral-vault.sh --cleanup \
        "$vault_directory"
    }

    # An operator's untracked vault.yml is overwritten in this clone; a symlink
    # (even dangling) must never be there, since the install would follow it.
    test ! -L /repo/inventory/group_vars/all/vault.yml
    # The committed per-service vaults are encrypted under the operator's password.
    rm -f /repo/inventory/group_vars/all/vault_*.yml
    install -m 0600 "$vault_file" /repo/inventory/group_vars/all/vault.yml
    export ANSIBLE_VAULT_PASSWORD_FILE="$vault_password_file"

    if suite_is foundation; then
    PLATFORM_DOCKER_ROOT="$sandbox/var/folders/path fixture/missing/Docker" \
    PLATFORM_MEDIA_ROOT="$sandbox/var/folders/path fixture/missing/media" \
    EXPECTED_PLATFORM_DOCKER_ROOT="$sandbox/private/var/folders/path fixture/missing/Docker" \
    EXPECTED_PLATFORM_MEDIA_ROOT="$sandbox/private/var/folders/path fixture/missing/media" \
      ansible-playbook -i inventory/mac.yml tests/mac_inventory_path_test.yml
    printf 'MAC_PATH_CANONICAL\n'

    if PLATFORM_DOCKER_ROOT="$sandbox/var/folders/path fixture/../escape/Docker" \
       PLATFORM_MEDIA_ROOT="$sandbox/var/folders/path fixture/missing/media" \
       EXPECTED_PLATFORM_DOCKER_ROOT="$sandbox/private/var/folders/escape/Docker" \
       EXPECTED_PLATFORM_MEDIA_ROOT="$sandbox/private/var/folders/path fixture/missing/media" \
         ansible-playbook -i inventory/mac.yml tests/mac_inventory_path_test.yml \
         >/tmp/mac-path-lexical.txt 2>&1; then
      cat /tmp/mac-path-lexical.txt >&2
      printf 'LEXICALLY AMBIGUOUS MAC PATH ACCEPTED\n' >&2
      exit 1
    fi
    grep -qF 'platform storage paths must be lexically normalized' \
      /tmp/mac-path-lexical.txt
    printf 'MAC_PATH_LEXICAL_REFUSED\n'

    assert_dirty_refused() {
      evidence=$1
      expected=$2
      shift 2
      rm -f "$controller_test_target"
      if ansible-playbook -i localhost, "$controller_test_playbook" "$@" \
          >/tmp/dirty-controller.txt 2>&1; then
        cat /tmp/dirty-controller.txt >&2
        printf 'DIRTY CONTROLLER ACCEPTED UNEXPECTEDLY: %s\n' "$evidence" >&2
        exit 1
      fi
      if ! grep -qF "$expected" /tmp/dirty-controller.txt; then
        cat /tmp/dirty-controller.txt >&2
        printf 'DIRTY CONTROLLER FAILED FOR WRONG REASON: %s\n' "$evidence" >&2
        exit 1
      fi
      if [ -e "$controller_test_target" ] || \
         [ "$(cat "$controller_test_sentinel")" != pristine ]; then
        printf 'DIRTY REFUSAL MUTATED TARGET: %s\n' "$evidence" >&2
        exit 1
      fi
      printf '%s\n' "$evidence"
      printf 'DIRTY_REFUSAL_TARGET_UNCHANGED\n'
    }

    printf '%s\n' dirty >> "$controller_test_dir/services/beszel/compose.yml"
    assert_dirty_refused DIRTY_TRACKED_REFUSED \
      'Controller checkout differs from Git HEAD' \
      -e platform_kind=nas -e platform_compose_kind=nas
    git -C "$controller_test_dir" checkout -q -- .

    printf '%s\n' untracked > "$controller_test_dir/services/untracked.yml"
    assert_dirty_refused DIRTY_UNTRACKED_REFUSED \
      'Controller checkout differs from Git HEAD' \
      -e platform_kind=nas -e platform_compose_kind=nas
    rm "$controller_test_dir/services/untracked.yml"

    printf '%s\n' dirty >> \
      "$controller_test_dir/roles/deployment_bundle/templates/manifest.yml.j2"
    assert_dirty_refused DIRTY_MANIFEST_TEMPLATE_REFUSED \
      'Controller checkout differs from Git HEAD' \
      -e platform_kind=nas -e platform_compose_kind=nas
    git -C "$controller_test_dir" checkout -q -- .

    printf '%s\n' '# dirty arbitrary controller file' >> "$controller_test_playbook"
    assert_dirty_refused DIRTY_ARBITRARY_CONTROLLER_FILE_REFUSED \
      'Controller checkout differs from Git HEAD' \
      -e platform_kind=nas -e platform_compose_kind=nas
    git -C "$controller_test_dir" checkout -q -- .

    printf '%s\n' dirty >> "$controller_test_dir/services/beszel/compose.yml"
    assert_dirty_refused DIRTY_PRODUCTION_BYPASS_REFUSED \
      'requires explicit deployment_bundle_test_mode' \
      -e platform_kind=nas \
      -e platform_compose_kind=integration \
      -e deployment_bundle_allow_dirty_controller=true

    rm -f "$controller_test_target"
    if ! ansible-playbook -i localhost, "$controller_test_playbook" \
        -e platform_kind=nas \
        -e platform_compose_kind=integration \
        -e platform_beszel_agent_kind=portable \
        -e deployment_bundle_test_mode=true \
        -e deployment_bundle_allow_dirty_controller=true \
        >/tmp/dirty-controller-integration.txt 2>&1; then
      cat /tmp/dirty-controller-integration.txt >&2
      exit 1
    fi
    test -f "$controller_test_target"
    printf 'DIRTY_INTEGRATION_ACCEPTED\n'
    git -C "$controller_test_dir" checkout -q -- .
    fi

    integration_media_usenet_enabled=false
    integration_media_adopt_existing=false
    case $INTEGRATION_SUITE in
      arr|downloaders|bindery|trailarr|seerr)
        integration_media_usenet_enabled=true
        integration_media_adopt_existing=true
        ;;
    esac

    # Nextcloud's gate is deliberately not narrowed here (#564): inventory is the
    # single source every lane inherits, and an `-e` would outrank it. The disabled
    # path is requested by name in the nextcloud lane.

    # The operator-owned half of the provider (#298), requested explicitly (#295).
    # Empty exactly on the lane whose credentials are left undeclared above.
    integration_media_usenet_host=news.usenet.invalid
    case $INTEGRATION_SUITE in
      downloaders) integration_media_usenet_host= ;;
    esac
    integration_media_usenet_provider="{\"media_usenet_provider\":\
{\"host\":\"$integration_media_usenet_host\",\"port\":563,\
\"connections\":8,\"ssl\":true}}"

    # Sourced rather than executed: the launchers read this controller's vault and
    # run in its shell, so a refusal still ends the suite.
    # shellcheck source=tests/integration_controller_lib.sh
    . /repo/tests/integration_controller_lib.sh

    assert_controller_symlink_refused() {
      evidence=$1
      fixture_name=$2
      expected_path=$3
      expected_reason=$4
      fixture_root="$sandbox/controller-"$fixture_name
      outside_root="$sandbox/controller-"$fixture_name'-outside'
      target="$sandbox/controller-"$fixture_name'-target'
      expected_refusal="Unsafe controller bundle input $fixture_root/$expected_path: $expected_reason"
      before_outside=$(tar -C "$outside_root" -cf - . | sha256sum | cut -d' ' -f1)
      rm -f "$target"

      if ansible-playbook -i localhost, \
          "$fixture_root/controller-input-test.yml" \
          >/tmp/controller-input-refusal.txt 2>&1; then
        cat /tmp/controller-input-refusal.txt >&2
        printf 'UNSAFE CONTROLLER INPUT ACCEPTED: %s\n' "$evidence" >&2
        exit 1
      fi
      if ! grep -qF "$expected_refusal" /tmp/controller-input-refusal.txt || \
         [ -e "$target" ] || \
         [ "$(tar -C "$outside_root" -cf - . | sha256sum | cut -d' ' -f1)" != \
           "$before_outside" ]; then
        cat /tmp/controller-input-refusal.txt >&2
        printf 'CONTROLLER INPUT REFUSAL MUTATED STATE: %s\n' "$evidence" >&2
        exit 1
      fi
      printf '%s\n' "$evidence"
      printf 'CONTROLLER_SYMLINK_TARGET_UNCHANGED\n'
    }

    if suite_is foundation; then
    assert_controller_symlink_refused CONTROLLER_MANIFEST_SYMLINK_REFUSED \
      manifest services/manifest.yml 'must be a regular non-symlink file'
    assert_controller_symlink_refused CONTROLLER_OVERRIDE_SYMLINK_REFUSED \
      override services/demo/compose.fixture.yml 'must be a regular non-symlink file'

    assert_symlink_refused() {
      evidence=$1
      docker_root=$2
      guarded_link=$3
      outside_root=$4
      pointer_path=$docker_root/nas-platform/current
      target_marker=$docker_root/nas-platform/target-mutated
      before_outside=$(tar -C "$outside_root" -cf - . | sha256sum | cut -d' ' -f1)
      before_guard=$(readlink "$guarded_link")
      before_pointer=absent
      if [ -L "$pointer_path" ]; then
        before_pointer=$(readlink "$pointer_path")
      fi

      if run_play -e nas_docker_root="$docker_root" --tags preflight \
          >/tmp/symlink-refusal.txt 2>&1; then
        cat /tmp/symlink-refusal.txt >&2
        printf 'SYMLINK ESCAPE ACCEPTED: %s\n' "$evidence" >&2
        exit 1
      fi
      if ! grep -qF 'Unsafe deployment target' /tmp/symlink-refusal.txt; then
        cat /tmp/symlink-refusal.txt >&2
        printf 'SYMLINK ESCAPE FAILED FOR WRONG REASON: %s\n' "$evidence" >&2
        exit 1
      fi

      after_outside=$(tar -C "$outside_root" -cf - . | sha256sum | cut -d' ' -f1)
      after_pointer=absent
      if [ -L "$pointer_path" ]; then
        after_pointer=$(readlink "$pointer_path")
      fi
      if [ "$before_outside" != "$after_outside" ] || \
         [ "$(readlink "$guarded_link")" != "$before_guard" ] || \
         [ "$before_pointer" != "$after_pointer" ] || \
         [ -e "$target_marker" ]; then
        printf 'SYMLINK ESCAPE MUTATED STATE: %s\n' "$evidence" >&2
        exit 1
      fi
      printf '%s\n' "$evidence"
      printf 'SYMLINK_ESCAPE_STATE_UNCHANGED\n'
    }

    old_release=0000000000000000000000000000000000000001

    docker_link="$sandbox/symlink-docker-root"
    docker_outside="$sandbox/symlink-outside/docker-root"
    mkdir -p "$docker_outside/nas-platform/releases/$old_release"
    ln -s "$docker_outside/nas-platform/releases/$old_release" \
      "$docker_outside/nas-platform/current"
    printf sentinel > "$docker_outside/sentinel"
    ln -s "$docker_outside" "$docker_link"
    assert_symlink_refused SYMLINK_DOCKER_ROOT_REFUSED \
      "$docker_link" "$docker_link" "$docker_outside"

    deploy_root="$sandbox/symlink-deploy/Docker"
    deploy_outside="$sandbox/symlink-outside/deploy-root"
    mkdir -p "$deploy_root" "$deploy_outside/releases/$old_release"
    ln -s "$deploy_outside/releases/$old_release" "$deploy_outside/current"
    printf sentinel > "$deploy_outside/sentinel"
    ln -s "$deploy_outside" "$deploy_root/nas-platform"
    assert_symlink_refused SYMLINK_DEPLOY_ROOT_REFUSED \
      "$deploy_root" "$deploy_root/nas-platform" "$deploy_outside"

    releases_root="$sandbox/symlink-releases/Docker"
    releases_outside="$sandbox/symlink-outside/releases-root"
    mkdir -p "$releases_root/nas-platform" "$releases_outside/$old_release"
    printf sentinel > "$releases_outside/sentinel"
    ln -s "$releases_outside" "$releases_root/nas-platform/releases"
    ln -s "$releases_root/nas-platform/releases/$old_release" \
      "$releases_root/nas-platform/current"
    assert_symlink_refused SYMLINK_RELEASES_REFUSED \
      "$releases_root" "$releases_root/nas-platform/releases" "$releases_outside"

    runtime_root="$sandbox/symlink-runtime/Docker"
    runtime_outside="$sandbox/symlink-outside/runtime-root"
    mkdir -p "$runtime_root/nas-platform/releases/$old_release" "$runtime_outside"
    printf sentinel > "$runtime_outside/sentinel"
    ln -s "$runtime_outside" "$runtime_root/nas-platform/runtime"
    ln -s "$runtime_root/nas-platform/releases/$old_release" \
      "$runtime_root/nas-platform/current"
    assert_symlink_refused SYMLINK_RUNTIME_REFUSED \
      "$runtime_root" "$runtime_root/nas-platform/runtime" "$runtime_outside"

    runtime_service_root="$sandbox/symlink-runtime-service/Docker"
    runtime_service_outside="$sandbox/symlink-outside/runtime-service"
    runtime_service_link="$runtime_service_root/nas-platform/runtime/services/beszel"
    runtime_service_pointer="$runtime_service_root/nas-platform/current"
    mkdir -p "$runtime_service_root/nas-platform/runtime/services" \
      "$runtime_service_root/nas-platform/releases/$old_release" \
      "$runtime_service_outside"
    chmod 0700 "$runtime_service_outside"
    printf sentinel > "$runtime_service_outside/user-data"
    ln -s "$runtime_service_outside" "$runtime_service_link"
    ln -s "$runtime_service_root/nas-platform/releases/$old_release" \
      "$runtime_service_pointer"
    runtime_service_checksum=$(sha256sum "$runtime_service_outside/user-data" | cut -d' ' -f1)
    runtime_service_pointer_before=$(readlink "$runtime_service_pointer")
    if run_play -e nas_docker_root="$runtime_service_root" --tags deployment_bundle \
        >/tmp/runtime-service-symlink.txt 2>&1; then
      cat /tmp/runtime-service-symlink.txt >&2
      printf 'RUNTIME SERVICE SYMLINK ACCEPTED\n' >&2
      exit 1
    fi
    if ! grep -qF 'Unsafe deployment target' /tmp/runtime-service-symlink.txt || \
       [ "$(readlink "$runtime_service_link")" != "$runtime_service_outside" ] || \
       [ "$(stat -c %a "$runtime_service_outside")" != 700 ] || \
       [ "$(sha256sum "$runtime_service_outside/user-data" | cut -d' ' -f1)" != \
         "$runtime_service_checksum" ] || \
       [ "$(readlink "$runtime_service_pointer")" != \
         "$runtime_service_pointer_before" ]; then
      cat /tmp/runtime-service-symlink.txt >&2
      printf 'RUNTIME SERVICE SYMLINK MUTATED STATE\n' >&2
      exit 1
    fi
    printf 'RUNTIME_SERVICE_SYMLINK_REFUSED\n'
    printf 'RUNTIME_SERVICE_SYMLINK_PRESERVED\n'

    ancestor_parent="$sandbox/symlink-ancestor"
    ancestor_outside="$sandbox/symlink-outside/root-ancestor"
    mkdir -p "$ancestor_parent" \
      "$ancestor_outside/Docker/nas-platform/releases/$old_release"
    printf sentinel > "$ancestor_outside/sentinel"
    ln -s "$ancestor_outside/Docker/nas-platform/releases/$old_release" \
      "$ancestor_outside/Docker/nas-platform/current"
    ln -s "$ancestor_outside" "$ancestor_parent/link"
    assert_symlink_refused SYMLINK_ROOT_ANCESTOR_REFUSED \
      "$ancestor_parent/link/Docker" "$ancestor_parent/link" "$ancestor_outside"

    probe_root="$sandbox/symlink-probe/Docker"
    probe_outside="$sandbox/symlink-outside/probe-root"
    mkdir -p "$probe_root" "$probe_outside/target"
    printf sentinel > "$probe_outside/target/sentinel"
    ln -s "$probe_outside/target" \
      "$probe_root/.nas-platform-preflight-probe"
    assert_symlink_refused SYMLINK_PREFLIGHT_PROBE_REFUSED \
      "$probe_root" "$probe_root/.nas-platform-preflight-probe" "$probe_outside"

    existing_probe="$sandbox/volume1/Docker/.nas-platform-preflight-probe"
    mkdir -p "$existing_probe"
    printf sentinel > "$existing_probe/user-data"
    if run_play --tags preflight >/tmp/existing-probe-refusal.txt 2>&1; then
      cat /tmp/existing-probe-refusal.txt >&2
      printf 'EXISTING PREFLIGHT PROBE ACCEPTED\n' >&2
      exit 1
    fi
    if ! grep -qF 'already exists and is not the empty directory' \
      /tmp/existing-probe-refusal.txt; then
      cat /tmp/existing-probe-refusal.txt >&2
      printf 'EXISTING PREFLIGHT PROBE FAILED FOR WRONG REASON\n' >&2
      exit 1
    fi
    printf 'EXISTING_PREFLIGHT_PROBE_REFUSED\n'
    if [ "$(cat "$existing_probe/user-data")" != sentinel ]; then
      printf 'EXISTING PREFLIGHT PROBE CONTENT MUTATED\n' >&2
      exit 1
    fi
    printf 'EXISTING_PREFLIGHT_PROBE_PRESERVED\n'
    rm -rf "$existing_probe"

    # An interrupted run's empty probe directory is the role's own debris to reclaim.
    mkdir -p "$existing_probe"
    if ! run_play --tags preflight >/tmp/interrupted-probe.txt 2>&1; then
      cat /tmp/interrupted-probe.txt >&2
      printf 'INTERRUPTED PREFLIGHT PROBE NOT RECLAIMED\n' >&2
      exit 1
    fi
    if [ -e "$existing_probe" ]; then
      printf 'INTERRUPTED PREFLIGHT PROBE SURVIVED\n' >&2
      exit 1
    fi
    printf 'INTERRUPTED_PREFLIGHT_PROBE_RECLAIMED\n'

    if [ "$(cat "$stale_deploy_root/current/services/beszel/compose.yml")" = \
         legacy-current-compose ] && \
       [ "$(cat "$stale_release_dir/services/beszel/compose.yml")" = \
         stale-same-sha-compose ] && \
       [ -f "$stale_release_dir/services/beszel/compose.mac.yml" ] && \
       [ -f "$stale_release_dir/services/undeclared/compose.yml" ]; then
      printf 'STALE_ROOT_SEEDED\n'
    else
      printf 'STALE ROOT FIXTURE INCOMPLETE\n' >&2
      exit 1
    fi

    run_play -e nas_docker_root="$stale_docker_root" --tags deployment_bundle
    stale_current="$stale_deploy_root/current"
    if [ ! -L "$stale_current" ] || \
       [ "$(readlink "$stale_current")" != "$stale_release_dir" ] || \
       ! cmp -s /repo/services/beszel/compose.yml \
         "$stale_release_dir/services/beszel/compose.yml" || \
       [ "$(sha256sum /repo/services/beszel/compose.yml | cut -d' ' -f1)" != \
         "$(sha256sum "$stale_release_dir/services/beszel/compose.yml" | cut -d' ' -f1)" ]; then
      printf 'STALE BUNDLE WAS NOT REPLACED EXACTLY\n' >&2
      exit 1
    fi
    printf 'STALE_BUNDLE_REPLACED\n'
    if [ -e "$stale_release_dir/services/beszel/compose.mac.yml" ] || \
       [ -e "$stale_release_dir/services/undeclared" ]; then
      printf 'STALE TARGET-ONLY CONTENT SURVIVED\n' >&2
      exit 1
    fi
    printf 'STALE_BUNDLE_CLEAN\n'
    ruby /repo/tests/verify_deployment_manifest.rb \
      "$stale_release_dir/manifest.yml" \
      /repo /repo/services/manifest.yml nas integration "$expected_release_id"
    printf 'STALE_MANIFEST_EXACT\n'

    ansible-playbook -i localhost, \
      "$manifest_controller/manifest-fixture.yml" \
      -e nas_docker_root="$manifest_docker_root" \
      -e nas_media_root="$manifest_media_root" \
      -e platform_release_id="$manifest_fixture_sha"
    ruby /repo/tests/verify_deployment_manifest.rb \
      "$manifest_docker_root/nas-platform/current/manifest.yml" \
      "$manifest_controller" "$manifest_controller/services/manifest.yml" \
      nas fixture "$manifest_fixture_sha" require-image-merge
    printf 'ISOLATED_IMAGE_MERGE_EXACT\n'

    test ! -e "$sandbox/volume1/Docker/nas-platform"

    fi

    # Both expansions quoted: unquoted, `[ -n ]` is true on an empty value (SC2070)
    # and phases 2 and 3 ran `--tags ""`. perform_initial_converge stays as a seam:
    # the execution test plants on it and policy_integration_test.rb reads its
    # bare `run_play` line by exact indentation.
    run_selected_play() {
      if [ -n "$INTEGRATION_TAGS" ]; then
        run_play --tags "$INTEGRATION_TAGS" "$@"
      elif [ $# -eq 0 ]; then
        run_play
      else
        run_play "$@"
      fi
    }

    perform_initial_converge() {
      if [ -z "$INTEGRATION_TAGS" ] && [ $# -eq 0 ]; then
    run_play
      else
        run_selected_play "$@"
      fi
    }

    # THE UPGRADE LANE'S PIN SURGERY is two commits, not two file writes:
    # deployment_bundle keys releases on `git rev-parse HEAD` and refuses to mutate
    # the active one. expected_release_id moves with the second commit.
    upgrade_service=${INTEGRATION_UPGRADE_SERVICE:-}
    upgrade_base_image=${INTEGRATION_UPGRADE_BASE_IMAGE:-}
    upgrade_compose=
    upgrade_head_image=

    # Exact whole-line match, exactly one replacement, indentation kept. A read loop,
    # not awk: tests/policy_test.rb refuses awk's whole-record variable here.
    rewrite_subject_image() {
      rewrite_from=$1
      rewrite_to=$2
      rewrite_count=0
      : > "$upgrade_compose.repin"
      # The `|| [ -n "$rewrite_line" ]` keeps a final line with no trailing newline.
      while IFS= read -r rewrite_line || [ -n "$rewrite_line" ]; do
        rewrite_indent=${rewrite_line%%[! ]*}
        rewrite_stripped=${rewrite_line#"$rewrite_indent"}
        if [ "$rewrite_stripped" = "image: $rewrite_from" ]; then
          printf '%simage: %s\n' "$rewrite_indent" "$rewrite_to" \
            >> "$upgrade_compose.repin"
          rewrite_count=$((rewrite_count + 1))
        else
          printf '%s\n' "$rewrite_line" >> "$upgrade_compose.repin"
        fi
      done < "$upgrade_compose"
      [ "$rewrite_count" -eq 1 ] || return 1
      mv "$upgrade_compose.repin" "$upgrade_compose"
    }

    commit_subject_image() {
      git -C /repo \
        -c user.email=integration@nas-platform.invalid \
        -c user.name='nas-platform integration' \
        commit -q -m "$1" -- "services/$upgrade_service/compose.yml"
    }

    if [ "$INTEGRATION_SUITE" = upgrade ]; then
      # An explicit `if`, not `A && B || C` (SC2015 reds the gate: this file's lint
      # line has no --exclude). Never begin a comment line with the linter's name.
      if [ -z "$upgrade_service" ] || [ -z "$upgrade_base_image" ]; then
        printf '%s\n' \
          'the upgrade lane requires INTEGRATION_UPGRADE_SERVICE and INTEGRATION_UPGRADE_BASE_IMAGE' >&2
        exit 1
      fi
      upgrade_compose=/repo/services/$upgrade_service/compose.yml
      [ -f "$upgrade_compose" ] || {
        printf 'no compose definition for the upgrade subject %s\n' \
          "$upgrade_service" >&2
        exit 1
      }
      upgrade_head_image=$(sed -n 's/^[[:space:]]*image:[[:space:]]*//p' \
        "$upgrade_compose")
      case $upgrade_head_image in
        *"
"*|'')
          printf 'the upgrade subject %s does not pin exactly one image\n' \
            "$upgrade_service" >&2
          exit 1
          ;;
      esac
      # A rollback reds this lane at roles/image_downgrade_guard, deliberately.
      # A base equal to the head converges one version twice and proves nothing.
      [ "$upgrade_head_image" != "$upgrade_base_image" ] || {
        printf 'the upgrade base and head pins of %s are identical: %s\n' \
          "$upgrade_service" "$upgrade_head_image" >&2
        exit 1
      }
      rewrite_subject_image "$upgrade_head_image" "$upgrade_base_image" || {
        printf 'could not pin %s back to its base image %s\n' \
          "$upgrade_service" "$upgrade_base_image" >&2
        exit 1
      }
      commit_subject_image "integration: $upgrade_service at its base pin"
      printf 'UPGRADE_BASE_PINNED: %s -> %s\n' \
        "$upgrade_service" "$upgrade_base_image"
    fi

    if lifecycle_plan=$(
      /repo/tests/integration.sh --consume-lifecycle --suite "$INTEGRATION_SUITE"
    ); then
      :
    else
      lifecycle_status=$?
      printf 'integration lifecycle validation failed with status %s\n' \
        $lifecycle_status >&2
      exit $lifecycle_status
    fi

    lifecycle_success=false
    # Reads the lifecycle ordering: only `repinned:converge` arrives here true.
    upgrade_repinned=false
    while IFS= read -r lifecycle_event; do
      case $lifecycle_event in
        converge)
          # A failing converge ends the controller silently under `sh -eu`, so dump the
          # containers if any exist. Spelled once: the execution test plants on this call
          # as a single occurrence.
          if [ "$upgrade_repinned" = true ]; then
            # The upgrade converge: the head image migrates a store the base image wrote.
            # Not the initial-converge call site or its indentation: two tests anchor on
            # that text as a single occurrence.
            upgrade_converge_status=0
            run_selected_play "$@" || upgrade_converge_status=$?
            if [ $upgrade_converge_status -ne 0 ]; then
              printf 'integration upgrade converge did not complete (status %s)\n' \
                $upgrade_converge_status >&2
              exit $upgrade_converge_status
            fi
            printf 'UPGRADE_CONVERGED: %s migrated onto %s\n' \
              "$upgrade_service" "$upgrade_head_image"
            continue
          fi
          converge_status=0
          perform_initial_converge "$@" || converge_status=$?
          if [ $converge_status -ne 0 ]; then
            if docker ps --all --format '{{.Names}}' |
                grep -q '^'"$integration_project_namespace"'-nextcloud'; then
              dump_nextcloud_diagnostics
            fi
            printf 'integration converge did not complete (status %s)\n' \
              $converge_status >&2
            exit $converge_status
          fi
          integration_media_adopt_existing=false
          ;;
        seed)
          # Seed rows while the BASE pin serves (#511, #671).
          run_contract "$upgrade_service" seed
          printf 'UPGRADE_SEEDED: %s at %s\n' \
            "$upgrade_service" "$upgrade_base_image"
          ;;
        repin)
          # Back to the head pin, committed so platform_release_id moves.
          rewrite_subject_image "$upgrade_base_image" "$upgrade_head_image" || {
            printf 'could not repin %s to its head image %s\n' \
              "$upgrade_service" "$upgrade_head_image" >&2
            exit 1
          }
          commit_subject_image "integration: $upgrade_service at its head pin"
          expected_release_id=$(git -C /repo rev-parse HEAD)
          upgrade_repinned=true
          printf 'UPGRADE_REPINNED: %s -> %s\n' \
            "$upgrade_service" "$upgrade_head_image"
          ;;
        verify)
          run_contract "$upgrade_service" verify
          printf 'UPGRADE_VERIFIED: %s survived %s -> %s\n' \
            "$upgrade_service" "$upgrade_base_image" "$upgrade_head_image"
          ;;
        stop)
          # THE SHUTDOWN HALF OF #671 (#781). The exit code is the measurement: 137 means
          # the container's own StopTimeout expired, 0 or 143 that it did not; elapsed time
          # is reported, never asserted. It would catch #671 itself only by luck (a race),
          # but covers the deterministic regressions. The base container's stop is unobservable.
          upgrade_project=$integration_project_namespace-$upgrade_service
          upgrade_running=$(docker ps \
            --filter "label=com.docker.compose.project=$upgrade_project" \
            --filter status=running --format '{{.Names}}')
          # Running state required before the stop: an exited container answers
          # `docker stop` with 0, and an empty enumeration is refused.
          [ -n "$upgrade_running" ] || {
            printf 'no running container in the upgrade subject project %s to stop\n' \
              "$upgrade_project" >&2
            exit 1
          }
          upgrade_stop_started=$(date +%s)
          for upgrade_container in $upgrade_running; do
            docker stop "$upgrade_container" >/dev/null || {
              printf 'could not stop the upgraded container %s\n' \
                "$upgrade_container" >&2
              exit 1
            }
          done
          upgrade_stop_elapsed=$(($(date +%s) - upgrade_stop_started))
          for upgrade_container in $upgrade_running; do
            upgrade_stop_state=$(docker inspect \
              --format '{{.State.Status}}:{{.State.ExitCode}}' \
              "$upgrade_container") || {
              printf 'could not read the stopped state of %s\n' \
                "$upgrade_container" >&2
              exit 1
            }
            # StopTimeout prints <nil> when undeclared; reported verbatim.
            upgrade_stop_grace=$(docker inspect \
              --format '{{.Config.StopTimeout}}' "$upgrade_container" 2>/dev/null) \
              || upgrade_stop_grace=unreadable
            case $upgrade_stop_state in
              exited:0|exited:143) ;;
              *)
                printf '%s did not stop cleanly: %s, against a configured StopTimeout of %s (<nil> means the service declared no stop_grace_period, so the daemon default of ten seconds applied). 137 is SIGKILL, which is what a stop that was swallowed and waited out to the end of its grace period reports (#671). On a FIRST dispatch for a subject, check whether that subject ever stopped cleanly before blaming the bump: CLAUDE.md records eleven containers here whose stop inside Docker default grace is an expectation rather than a measurement, and Bindery is one of them.\n' \
                  "$upgrade_container" "$upgrade_stop_state" \
                  "$upgrade_stop_grace" >&2
                exit 1
                ;;
            esac
            # Per container: the window is per container, the elapsed is the loop's.
            printf 'UPGRADE_STOPPED_CONTAINER: %s %s against a configured StopTimeout of %s\n' \
              "$upgrade_container" "$upgrade_stop_state" "$upgrade_stop_grace"
          done
          printf 'UPGRADE_STOPPED: %s stopped cleanly, %ss for the project as a whole, on %s\n' \
            "$upgrade_project" "$upgrade_stop_elapsed" "$upgrade_head_image"
          ;;
        success)
          lifecycle_success=true
          ;;
        *)
          printf 'unexpected integration lifecycle event: %s\n' \
            "$lifecycle_event" >&2
          exit 1
          ;;
      esac
    done <<EOF
$lifecycle_plan
EOF
    [ $lifecycle_success = true ] || {
      printf '%s\n' 'integration lifecycle ended before success' >&2
      exit 1
    }
    printf 'FRESH_ROOT_OK: clean deployment root converged\n'

    if cmp -s \
      /repo/services/beszel/compose.yml \
      "$sandbox/volume1/Docker/nas-platform/current/services/beszel/compose.yml"; then
      printf 'BUNDLE OWNED: target compose matches controller source\n'
    else
      printf 'BUNDLE STALE: target compose does not match controller source\n' >&2
      exit 1
    fi

    ruby /repo/tests/verify_deployment_manifest.rb \
      "$sandbox/volume1/Docker/nas-platform/current/manifest.yml" \
      /repo /repo/services/manifest.yml nas integration "$expected_release_id"

    # Seerr's lane carries the shared foundation's runtime proof, then falls
    # through to Seerr's own arm (#639).
    case $INTEGRATION_SUITE in
      seerr)
        converge_media_acquisition_reader_prerequisites
        run_media_acquisition_foundation_verify
        printf 'MEDIA_ACQUISITION_FOUNDATION_RUNTIME_VERIFIED\n'
        ;;
    esac

    if [ "$INTEGRATION_SUITE" = arr ]; then
      /repo/tests/media_control_network_collision_test.sh live
      /repo/tests/contracts/arr.sh static
      run_arr_verify_only
      run_enabled_idempotence arr
      run_play --tags arr --check --diff
      printf 'ARR_PHASE1_RUNTIME_VERIFIED\n'
      cleanup_vault
      exit 0
    fi

    if [ "$INTEGRATION_SUITE" = downloaders ]; then
      /repo/tests/contracts/arr.sh static
      /repo/tests/contracts/downloaders.sh static
      run_arr_verify_only
      # The undeclared half of the downloader pair (#295).
      run_downloaders_verify_only
      run_enabled_idempotence arr,downloaders
      run_play --tags arr,downloaders --check --diff
      printf 'DOWNLOADERS_UNDECLARED_PROVIDER_RUNTIME_VERIFIED\n'
      cleanup_vault
      exit 0
    fi

    if [ "$INTEGRATION_SUITE" = bindery ]; then
      /repo/tests/contracts/arr.sh static
      /repo/tests/contracts/downloaders.sh static
      /repo/tests/contracts/bindery.sh static
      run_bindery_contract run
      # The declared half of the downloader pair, as a standalone verify play.
      run_downloaders_verify_only
      run_bindery_verify_only
      run_enabled_idempotence arr,downloaders,audiobookshelf,bindery
      run_play --tags arr,downloaders,audiobookshelf,bindery --check --diff
      printf 'BINDERY_PHASE2_RUNTIME_VERIFIED\n'
      cleanup_vault
      exit 0
    fi

    if [ "$INTEGRATION_SUITE" = kapowarr ]; then
      /repo/tests/contracts/kapowarr.sh static
      run_kapowarr_contract run
      run_kapowarr_verify_only
      run_enabled_idempotence kapowarr
      run_play --tags kapowarr --check --diff
      printf 'KAPOWARR_PHASE2_RUNTIME_VERIFIED\n'
      cleanup_vault
      exit 0
    fi

    if [ "$INTEGRATION_SUITE" = pinchflat ]; then
      /repo/tests/contracts/pinchflat.sh static
      run_pinchflat_contract run
      run_pinchflat_verify_only
      run_enabled_idempotence pinchflat
      run_play --tags pinchflat --check --diff
      printf 'PINCHFLAT_PHASE2_RUNTIME_VERIFIED\n'
      cleanup_vault
      exit 0
    fi

    if [ "$INTEGRATION_SUITE" = trailarr ]; then
      /repo/tests/contracts/arr.sh static
      /repo/tests/contracts/trailarr.sh static
      run_trailarr_contract run
      run_trailarr_verify_only
      run_enabled_idempotence arr,trailarr
      run_play --tags arr,trailarr --check --diff
      printf 'TRAILARR_PHASE3_RUNTIME_VERIFIED\n'
      cleanup_vault
      exit 0
    fi

    if [ "$INTEGRATION_SUITE" = seerr ]; then
      /repo/tests/contracts/arr.sh static
      /repo/tests/contracts/seerr.sh static
      run_seerr_contract run
      run_seerr_verify_only
      run_enabled_idempotence arr,jellyfin,seerr
      run_play --tags arr,jellyfin,seerr --check --diff
      printf 'SEERR_PHASE4_RUNTIME_VERIFIED\n'
      cleanup_vault
      exit 0
    fi

    if [ "$INTEGRATION_SUITE" = smoke ]; then
      cleanup_vault
      exit 0
    fi

    # The upgrade lane owns no idempotence or check-mode pass: the service lane
    # proves both against the head pin.
    if [ "$INTEGRATION_SUITE" = upgrade ]; then
      printf 'UPGRADE_LANE_COMPLETE: %s migrated from %s to %s with its seeded rows intact\n' \
        "$upgrade_service" "$upgrade_base_image" "$upgrade_head_image"
      cleanup_vault
      exit 0
    fi

    # Bundle drift and symlink refusal belong to deployment_bundle, so the
    # foundation lane proves them once for every suite.
    if [ "$INTEGRATION_SUITE" = foundation ] || [ "$INTEGRATION_SUITE" = full ]; then
    assert_selective_compose_refused() {
      service=$1
      evidence=$2
      selective_compose="$active_release_dir/services/"$service'/compose.yml'
      selective_outside="$sandbox/symlink-outside/selective-"$service
      selective_pointer="$sandbox/volume1/Docker/nas-platform/current"
      mkdir -p "$selective_outside"
      printf '%s\n' outside-safe > "$selective_outside/compose.yml"
      outside_checksum=$(sha256sum "$selective_outside/compose.yml" | cut -d' ' -f1)
      pointer_before=$(readlink "$selective_pointer")
      rm "$selective_compose"
      ln -s "$selective_outside/compose.yml" "$selective_compose"
      if run_play --tags "$service" >/tmp/selective-compose.txt 2>&1; then
        cat /tmp/selective-compose.txt >&2
        printf 'SELECTIVE COMPOSE SYMLINK ACCEPTED: %s\n' "$service" >&2
        exit 1
      fi
      if ! grep -qF 'Unsafe deployment target' /tmp/selective-compose.txt || \
         [ "$(readlink "$selective_compose")" != "$selective_outside/compose.yml" ] || \
         [ "$(sha256sum "$selective_outside/compose.yml" | cut -d' ' -f1)" != \
           "$outside_checksum" ] || \
         [ "$(readlink "$selective_pointer")" != "$pointer_before" ]; then
        cat /tmp/selective-compose.txt >&2
        printf 'SELECTIVE COMPOSE SYMLINK MUTATED STATE: %s\n' "$service" >&2
        exit 1
      fi
      printf '%s\n' "$evidence"
      printf 'SYMLINK_ESCAPE_STATE_UNCHANGED\n'
      rm "$selective_compose"
      cp /repo/services/"$service"/compose.yml "$selective_compose"
      chmod 0644 "$selective_compose"
    }

    assert_selective_compose_refused beszel SYMLINK_BESZEL_COMPOSE_REFUSED
    assert_selective_compose_refused audiobookshelf SYMLINK_AUDIOBOOKSHELF_COMPOSE_REFUSED

    assert_active_drift_refused() {
      evidence=$1
      active_compose="$active_release_dir/services/beszel/compose.yml"
      current_pointer="$sandbox/volume1/Docker/nas-platform/current"
      before_checksum=$(sha256sum "$active_compose" | cut -d' ' -f1)
      before_mode=$(stat -c %a "$active_compose")
      before_owner=$(stat -c %u:%g "$active_compose")
      before_pointer=$(readlink "$current_pointer")

      if run_play --tags deployment_bundle >/tmp/active-drift.txt 2>&1; then
        cat /tmp/active-drift.txt >&2
        printf 'ACTIVE DRIFT ACCEPTED: %s\n' "$evidence" >&2
        exit 1
      fi
      if ! grep -qF 'differs from the controller bundle' /tmp/active-drift.txt || \
         [ "$(sha256sum "$active_compose" | cut -d' ' -f1)" != "$before_checksum" ] || \
         [ "$(stat -c %a "$active_compose")" != "$before_mode" ] || \
         [ "$(stat -c %u:%g "$active_compose")" != "$before_owner" ] || \
         [ "$(readlink "$current_pointer")" != "$before_pointer" ]; then
        cat /tmp/active-drift.txt >&2
        printf 'ACTIVE DRIFT WAS NOT PRESERVED: %s\n' "$evidence" >&2
        exit 1
      fi
      printf '%s\n' "$evidence"
      printf 'ACTIVE_DRIFT_PRESERVED\n'
    }

    printf '%s\n' drift >> "$active_release_dir/services/beszel/compose.yml"
    assert_active_drift_refused ACTIVE_BYTE_DRIFT_REFUSED
    cp /repo/services/beszel/compose.yml "$active_release_dir/services/beszel/compose.yml"
    chmod 0644 "$active_release_dir/services/beszel/compose.yml"

    chmod 0755 "$active_release_dir/services/beszel/compose.yml"
    assert_active_drift_refused ACTIVE_MODE_DRIFT_REFUSED
    chmod 0644 "$active_release_dir/services/beszel/compose.yml"

    chown 123:456 "$active_release_dir/services/beszel/compose.yml"
    assert_active_drift_refused ACTIVE_OWNERSHIP_DRIFT_REFUSED
    chown 0:0 "$active_release_dir/services/beszel/compose.yml"
    fi

    if [ "$INTEGRATION_SUITE" = foundation ]; then
      cleanup_vault
      exit 0
    fi

    if [ "$INTEGRATION_RUN_SERVICE_SCENARIOS" = true ] && suite_is beszel; then
      # Named rather than the default `verify` (#667): exercises the wrapper itself.
      run_beszel_contract static
      run_beszel_contract verify
      printf 'BESZEL_INITIAL_CONTRACT_OK\n'

      run_beszel_contract drift
      run_beszel_contract drift-verify
      # No pipeline: POSIX sh has no pipefail, so an unreadable .env would yield an
      # empty checksum unnoticed (#640).
      beszel_env_checksum_before_check=$(sha256sum \
        "$sandbox/volume1/Docker/nas-platform/runtime/services/beszel/.env") ||
        { printf 'BESZEL DRIFTED CHECK COULD NOT READ RUNTIME .env\n' >&2; exit 1; }
      beszel_env_checksum_before_check=${beszel_env_checksum_before_check%% *}
      if ! run_play --tags beszel --check --diff \
          >/tmp/beszel-drifted-check.txt 2>&1; then
        cat /tmp/beszel-drifted-check.txt >&2
        exit 1
      fi
      cat /tmp/beszel-drifted-check.txt
      for webhook_sentinel in sentinel-user sentinel-password sentinel-query-key example.invalid; do
        if grep -qF "$webhook_sentinel" /tmp/beszel-drifted-check.txt; then
          printf 'BESZEL DRIFTED CHECK LEAKED WEBHOOK SENTINEL\n' >&2
          exit 1
        fi
      done
      if ! grep -qE 'changed=[1-9][0-9]* .*failed=0 ' \
          /tmp/beszel-drifted-check.txt; then
        printf 'BESZEL DRIFTED CHECK DID NOT REPORT PLANNED CHANGES\n' >&2
        exit 1
      fi
      run_beszel_contract drift-verify
      beszel_env_checksum_after_check=$(sha256sum \
        "$sandbox/volume1/Docker/nas-platform/runtime/services/beszel/.env") ||
        { printf 'BESZEL DRIFTED CHECK COULD NOT READ RUNTIME .env\n' >&2; exit 1; }
      beszel_env_checksum_after_check=${beszel_env_checksum_after_check%% *}
      if [ "$beszel_env_checksum_before_check" != "$beszel_env_checksum_after_check" ]; then
        printf 'BESZEL DRIFTED CHECK MUTATED RUNTIME BYTES\n' >&2
        exit 1
      fi
      printf 'BESZEL_DRIFTED_CHECK_PRESERVED_STATE\n'

      if run_verify_only >/tmp/beszel-verify-drift.txt 2>&1; then
        printf 'BESZEL VERIFY-ONLY ACCEPTED DRIFT\n' >&2
        exit 1
      fi
      if run_beszel_contract verify >/tmp/beszel-contract-drift.txt 2>&1; then
        printf 'BESZEL VERIFY-ONLY CONVERGED DRIFT\n' >&2
        exit 1
      fi
      /repo/tests/assert-no-vault-secrets.rb \
        "$vault_file" "$vault_password_file" /tmp/beszel-verify-drift.txt
      for webhook_sentinel in sentinel-user sentinel-password sentinel-query-key example.invalid; do
        if grep -qF "$webhook_sentinel" /tmp/beszel-verify-drift.txt; then
          printf 'BESZEL VERIFY LEAKED WEBHOOK SENTINEL\n' >&2
          exit 1
        fi
      done
      printf 'BESZEL_VERIFY_ONLY_REFUSED_DRIFT\n'

      run_play --tags beszel
      run_beszel_contract verify
      run_beszel_contract notify
      printf 'BESZEL_DRIFT_RECONCILED_AND_NOTIFIED\n'

      run_beszel_contract duplicate
      if run_play --tags beszel >/tmp/beszel-duplicate.txt 2>&1; then
        printf 'BESZEL DUPLICATE IDENTITY ACCEPTED\n' >&2
        exit 1
      fi
      while IFS= read -r duplicate_id; do
        grep -qF "$duplicate_id" /tmp/beszel-duplicate.txt || {
          printf 'BESZEL DUPLICATE FAILURE OMITTED RECORD ID\n' >&2
          exit 1
        }
      done < "$sandbox/reports/beszel-duplicate-ids.txt"
      /repo/tests/assert-no-vault-secrets.rb \
        "$vault_file" "$vault_password_file" /tmp/beszel-duplicate.txt
      printf 'BESZEL_DUPLICATE_REFUSED_WITH_IDS\n'
      run_beszel_contract remove-duplicate
      run_play --tags beszel
      run_beszel_contract verify

      run_beszel_contract wrong-owner
      if run_play --tags beszel >/tmp/beszel-wrong-owner.txt 2>&1; then
        printf 'BESZEL WRONG-OWNER IDENTITY ACCEPTED\n' >&2
        exit 1
      fi
      tail -n +2 "$sandbox/reports/beszel-duplicate-ids.txt" | while IFS= read -r wrong_owner_id; do
        grep -qF "$wrong_owner_id" /tmp/beszel-wrong-owner.txt || {
          printf 'BESZEL WRONG-OWNER FAILURE OMITTED RECORD ID\n' >&2
          exit 1
        }
      done
      /repo/tests/assert-no-vault-secrets.rb \
        "$vault_file" "$vault_password_file" /tmp/beszel-wrong-owner.txt
      printf 'BESZEL_WRONG_OWNER_REFUSED_WITH_IDS\n'
      run_beszel_contract remove-duplicate
      run_play --tags beszel
      run_beszel_contract verify

      run_play -e platform_beszel_agent_available=false --tags beszel
      if docker ps -a --format '{{.Names}}' | \
          grep -Eq '^('"$integration_project_namespace"'-beszel-agent-intel|'"$integration_project_namespace"'-beszel-agent-portable)$'; then
        printf 'BESZEL CAPABILITY-FALSE LEFT A MANAGED AGENT\n' >&2
        exit 1
      fi
      printf 'BESZEL_CAPABILITY_FALSE_REMOVED_AGENT\n'
      run_play --tags beszel
      run_beszel_contract verify

    fi

    if [ "$INTEGRATION_RUN_SERVICE_SCENARIOS" = true ] && suite_is dozzle; then

      # Judges dev.dozzle.* labels on a real render; nothing did before #667 (#656).
      run_dozzle_contract static
      run_dozzle_contract verify
      printf 'DOZZLE_INITIAL_CONTRACT_OK\n'
      run_dozzle_contract duplicate-dispatcher-create
      run_dozzle_contract duplicate-dispatcher-verify
      if run_dozzle_verify_only >/tmp/dozzle-duplicate-dispatcher-verify.txt 2>&1; then
        printf 'DOZZLE DUPLICATE DISPATCHER VERIFICATION ACCEPTED\n' >&2
        exit 1
      fi
      if run_play --tags dozzle >/tmp/dozzle-duplicate-dispatcher.txt 2>&1; then
        printf 'DOZZLE DUPLICATE DISPATCHER CONVERGENCE ACCEPTED\n' >&2
        exit 1
      fi
      run_dozzle_contract duplicate-dispatcher-assert-output \
        /tmp/dozzle-duplicate-dispatcher.txt
      /repo/tests/assert-no-vault-secrets.rb \
        "$vault_file" "$vault_password_file" \
        /tmp/dozzle-duplicate-dispatcher-verify.txt \
        /tmp/dozzle-duplicate-dispatcher.txt
      run_dozzle_contract duplicate-dispatcher-cleanup
      printf 'DOZZLE_DUPLICATE_DISPATCHER_REFUSED_WITH_SAFE_IDS\n'

      run_dozzle_contract duplicate-rule-create
      run_dozzle_contract duplicate-rule-verify
      if run_dozzle_verify_only >/tmp/dozzle-duplicate-rule-verify.txt 2>&1; then
        printf 'DOZZLE DUPLICATE RULE VERIFICATION ACCEPTED\n' >&2
        exit 1
      fi
      if run_play --tags dozzle >/tmp/dozzle-duplicate-rule.txt 2>&1; then
        printf 'DOZZLE DUPLICATE RULE CONVERGENCE ACCEPTED\n' >&2
        exit 1
      fi
      run_dozzle_contract duplicate-rule-assert-output /tmp/dozzle-duplicate-rule.txt
      /repo/tests/assert-no-vault-secrets.rb \
        "$vault_file" "$vault_password_file" \
        /tmp/dozzle-duplicate-rule-verify.txt /tmp/dozzle-duplicate-rule.txt
      run_dozzle_contract duplicate-rule-cleanup
      printf 'DOZZLE_DUPLICATE_RULE_REFUSED_WITH_SAFE_IDS\n'

      run_dozzle_contract surplus-create
      run_dozzle_contract surplus-verify
      if ! run_play --tags dozzle; then
        run_dozzle_contract surplus-cleanup
        exit 1
      fi
      run_dozzle_contract surplus-removed
      run_dozzle_contract verify
      printf 'DOZZLE_SURPLUS_STATE_REMOVED\n'

      run_dozzle_contract check-mixed-create
      if ! run_play --tags dozzle --check --diff >/tmp/dozzle-check-mixed.txt 2>&1; then
        /repo/tests/assert-no-vault-secrets.rb \
          "$vault_file" "$vault_password_file" /tmp/dozzle-check-mixed.txt
        cat /tmp/dozzle-check-mixed.txt >&2
        run_dozzle_contract check-mixed-recover
        exit 1
      fi
      /repo/tests/assert-no-vault-secrets.rb \
        "$vault_file" "$vault_password_file" /tmp/dozzle-check-mixed.txt
      grep -qE 'changed=[1-9][0-9]* .*failed=0 ' /tmp/dozzle-check-mixed.txt
      run_dozzle_contract assert-check-mixed-output /tmp/dozzle-check-mixed.txt
      run_dozzle_contract check-mixed-unchanged
      if run_dozzle_verify_only >/tmp/dozzle-check-mixed-verify.txt 2>&1; then
        printf 'DOZZLE VERIFY-ONLY ACCEPTED MIXED CHECK-MODE DRIFT\n' >&2
        exit 1
      fi
      /repo/tests/assert-no-vault-secrets.rb \
        "$vault_file" "$vault_password_file" /tmp/dozzle-check-mixed-verify.txt
      run_play --tags dozzle
      run_dozzle_contract verify
      run_dozzle_contract check-mixed-cleanup
      printf 'DOZZLE_CHECK_MIXED_PLANNED_IMMUTABLE_AND_REPAIRED\n'

      run_dozzle_contract check-missing-create
      if ! run_play --tags dozzle --check --diff >/tmp/dozzle-check-missing.txt 2>&1; then
        /repo/tests/assert-no-vault-secrets.rb \
          "$vault_file" "$vault_password_file" /tmp/dozzle-check-missing.txt
        cat /tmp/dozzle-check-missing.txt >&2
        exit 1
      fi
      /repo/tests/assert-no-vault-secrets.rb \
        "$vault_file" "$vault_password_file" /tmp/dozzle-check-missing.txt
      grep -qE 'changed=[1-9][0-9]* .*failed=0 ' /tmp/dozzle-check-missing.txt
      run_dozzle_contract assert-check-missing-output /tmp/dozzle-check-missing.txt
      run_dozzle_contract check-missing-unchanged
      if run_dozzle_verify_only >/tmp/dozzle-check-missing-verify.txt 2>&1; then
        printf 'DOZZLE VERIFY-ONLY ACCEPTED MISSING CHECK-MODE STATE\n' >&2
        exit 1
      fi
      /repo/tests/assert-no-vault-secrets.rb \
        "$vault_file" "$vault_password_file" /tmp/dozzle-check-missing-verify.txt
      run_play --tags dozzle
      run_dozzle_contract verify
      run_dozzle_contract check-missing-cleanup
      printf 'DOZZLE_CHECK_MISSING_PLANNED_IMMUTABLE_AND_REPAIRED\n'

      run_dozzle_contract drift
      run_dozzle_contract drift-verify
      run_play --tags dozzle
      run_dozzle_contract verify
      run_dozzle_contract notify
      printf 'DOZZLE_DRIFT_RECONCILED_AND_NOTIFIED\n'
      # The one proof that Beszel's stored webhook reaches Pushover.
      run_dozzle_contract beszel-notify
      printf 'DOZZLE_BESZEL_NOTIFICATION_THROUGH_RELAY\n'

    fi

    if [ "$INTEGRATION_RUN_SERVICE_SCENARIOS" = true ] && suite_is audiobookshelf; then

      run_audiobookshelf_contract run
      printf 'AUDIOBOOKSHELF_INITIAL_CONTRACT_OK\n'

      run_audiobookshelf_contract inactive-admin-refusal
      printf 'AUDIOBOOKSHELF_INACTIVE_ADMIN_REFUSED_AND_RECOVERED\n'

      run_audiobookshelf_contract duplicate-admin-api-refusal
      printf 'AUDIOBOOKSHELF_DUPLICATE_ADMIN_REFUSED\n'

      run_audiobookshelf_contract duplicate-library-create
      run_audiobookshelf_contract duplicate-library-verify
      if run_audiobookshelf_verify_only >/tmp/audiobookshelf-duplicate-verify.txt 2>&1; then
        printf 'AUDIOBOOKSHELF DUPLICATE LIBRARY VERIFICATION ACCEPTED\n' >&2
        exit 1
      fi
      if run_play --tags audiobookshelf >/tmp/audiobookshelf-duplicate.txt 2>&1; then
        printf 'AUDIOBOOKSHELF DUPLICATE LIBRARY CONVERGENCE ACCEPTED\n' >&2
        exit 1
      fi
      run_audiobookshelf_contract duplicate-library-assert-output \
        /tmp/audiobookshelf-duplicate.txt
      /repo/tests/assert-no-vault-secrets.rb \
        "$vault_file" "$vault_password_file" \
        /tmp/audiobookshelf-duplicate-verify.txt \
        /tmp/audiobookshelf-duplicate.txt
      run_audiobookshelf_contract duplicate-library-cleanup
      run_play --tags audiobookshelf
      run_audiobookshelf_contract run
      printf 'AUDIOBOOKSHELF_DUPLICATE_LIBRARY_REFUSED_WITH_SAFE_IDS\n'

      run_audiobookshelf_contract check-repair-seed
      if ! run_play --tags audiobookshelf --check --diff \
          >/tmp/audiobookshelf-check-repair.txt 2>&1; then
        /repo/tests/assert-no-vault-secrets.rb \
          "$vault_file" "$vault_password_file" \
          /tmp/audiobookshelf-check-repair.txt
        cat /tmp/audiobookshelf-check-repair.txt >&2
        exit 1
      fi
      /repo/tests/assert-no-vault-secrets.rb \
        "$vault_file" "$vault_password_file" \
        /tmp/audiobookshelf-check-repair.txt
      grep -qE 'changed=[1-9][0-9]* .*failed=0 ' \
        /tmp/audiobookshelf-check-repair.txt
      run_audiobookshelf_contract assert-check-output \
        /tmp/audiobookshelf-check-repair.txt repair
      run_audiobookshelf_contract check-repair-unchanged
      if run_audiobookshelf_verify_only >/tmp/audiobookshelf-check-repair-verify.txt 2>&1; then
        printf 'AUDIOBOOKSHELF VERIFY-ONLY ACCEPTED REPAIR CHECK-MODE DRIFT\n' >&2
        exit 1
      fi
      /repo/tests/assert-no-vault-secrets.rb \
        "$vault_file" "$vault_password_file" \
        /tmp/audiobookshelf-check-repair-verify.txt
      run_play --tags audiobookshelf
      run_audiobookshelf_contract run
      run_audiobookshelf_contract check-repair-cleanup
      printf 'AUDIOBOOKSHELF_CHECK_REPAIR_PLANNED_IMMUTABLE\n'

      run_audiobookshelf_contract drift
      run_audiobookshelf_contract drift-verify
      if run_audiobookshelf_verify_only >/tmp/audiobookshelf-verify-drift.txt 2>&1; then
        printf 'AUDIOBOOKSHELF VERIFY-ONLY ACCEPTED DRIFT\n' >&2
        exit 1
      fi
      /repo/tests/assert-no-vault-secrets.rb \
        "$vault_file" "$vault_password_file" \
        /tmp/audiobookshelf-verify-drift.txt
      run_play --tags audiobookshelf
      run_audiobookshelf_contract run
      printf 'AUDIOBOOKSHELF_DRIFT_REPAIRED\n'

      run_audiobookshelf_contract check-missing-seed
      if ! run_play --tags audiobookshelf --check --diff \
          >/tmp/audiobookshelf-check-missing.txt 2>&1; then
        /repo/tests/assert-no-vault-secrets.rb \
          "$vault_file" "$vault_password_file" \
          /tmp/audiobookshelf-check-missing.txt
        cat /tmp/audiobookshelf-check-missing.txt >&2
        exit 1
      fi
      /repo/tests/assert-no-vault-secrets.rb \
        "$vault_file" "$vault_password_file" \
        /tmp/audiobookshelf-check-missing.txt
      grep -qE 'changed=[1-9][0-9]* .*failed=0 ' \
        /tmp/audiobookshelf-check-missing.txt
      run_audiobookshelf_contract assert-check-output \
        /tmp/audiobookshelf-check-missing.txt missing
      run_audiobookshelf_contract check-missing-unchanged
      if run_audiobookshelf_verify_only >/tmp/audiobookshelf-check-missing-verify.txt 2>&1; then
        printf 'AUDIOBOOKSHELF VERIFY-ONLY ACCEPTED MISSING CHECK-MODE STATE\n' >&2
        exit 1
      fi
      /repo/tests/assert-no-vault-secrets.rb \
        "$vault_file" "$vault_password_file" \
        /tmp/audiobookshelf-check-missing-verify.txt
      run_play --tags audiobookshelf
      run_audiobookshelf_contract check-missing-cleanup
      run_audiobookshelf_contract run
      printf 'AUDIOBOOKSHELF_CHECK_CREATE_PLANNED_IMMUTABLE\n'

      run_audiobookshelf_contract seed-progress
      docker compose --project-name "$integration_project_namespace-audiobookshelf" \
        --env-file "$sandbox/volume1/Docker/nas-platform/runtime/services/audiobookshelf/.env" \
        -f "$sandbox/volume1/Docker/nas-platform/current/services/audiobookshelf/compose.yml" \
        -f "$sandbox/volume1/Docker/nas-platform/current/services/audiobookshelf/compose.integration.yml" \
        up -d --force-recreate --wait
      run_audiobookshelf_contract assert-persistence
      printf 'AUDIOBOOKSHELF_RECREATE_PERSISTENCE_OK\n'

    fi

    if [ "$INTEGRATION_RUN_SERVICE_SCENARIOS" = true ] && suite_is komga; then
      run_komga_contract seed
      if [ "$INTEGRATION_SUITE" = komga ]; then
        run_komga_contract run

      fi
    fi

    if [ "$INTEGRATION_RUN_SERVICE_SCENARIOS" = true ] && suite_is jellyfin; then
      run_jellyfin_contract seed
      if [ "$INTEGRATION_SUITE" = jellyfin ]; then
        run_jellyfin_contract run
      fi
    fi

    if [ "$INTEGRATION_RUN_SERVICE_SCENARIOS" = true ] && suite_is immich; then
      if [ "$INTEGRATION_SUITE" = immich ]; then
        run_immich_contract clean-restore-seed
        run_immich_clean_restore
        run_immich_restore_negative_matrix
        run_immich_contract run
      fi
    fi

    if [ "$INTEGRATION_RUN_SERVICE_SCENARIOS" = true ] && suite_is paperless; then
      run_paperless_contract seed
      mkdir -m 0700 "$sandbox/reports/paperless-coordinated-snapshot"
      run_paperless_snapshot drill "$sandbox/reports/paperless-coordinated-snapshot"
      run_paperless_contract assert-persistence
      docker compose --project-name "$integration_project_namespace-paperless" \
        --env-file "$sandbox/volume1/Docker/nas-platform/runtime/services/paperless-ngx/.env" \
        -f "$sandbox/volume1/Docker/nas-platform/current/services/paperless-ngx/compose.yml" \
        -f "$sandbox/volume1/Docker/nas-platform/current/services/paperless-ngx/compose.integration.yml" \
        up -d --force-recreate --wait
      run_paperless_contract assert-persistence
    fi

    if [ "$INTEGRATION_RUN_SERVICE_SCENARIOS" = true ] && suite_is nextcloud; then
      run_nextcloud_contract run
      if [ "$INTEGRATION_SUITE" = nextcloud ]; then
        # The second converge refutes a Nextcloud that rewrites its trusted_domains.
        run_enabled_idempotence nextcloud
        run_play --tags nextcloud --check --diff
        run_nextcloud_verify_only
        printf 'NEXTCLOUD_RUNTIME_VERIFIED\n'
        # The way back, exercised rather than claimed (#564). Anchored before (the app
        # must exist), unanchored after (no `-nextcloud*` container may survive).
        if ! docker ps --all --format '{{.Names}}' |
            grep -Eq '^'"$integration_project_namespace"'-nextcloud$'; then
          printf '%s\n' \
            'the nextcloud container is not present, so the teardown below proves nothing' >&2
          exit 1
        fi
        run_play --tags nextcloud -e nextcloud_deployment_enabled=false
        if docker ps --all --format '{{.Names}}' |
            grep -Eq '^'"$integration_project_namespace"'-nextcloud'; then
          printf '%s\n' \
            'disabling nextcloud_deployment_enabled left a nextcloud container in place' >&2
          exit 1
        fi
        printf 'NEXTCLOUD_TEARDOWN_VERIFIED\n'
        # And back on: also proves an existing-install start over a surviving data root.
        run_play --tags nextcloud
        run_nextcloud_verify_only
        printf 'NEXTCLOUD_RETURN_VERIFIED\n'
      fi
    fi

    if [ "$INTEGRATION_RUN_SERVICE_SCENARIOS" = true ] && suite_is vaultwarden; then
      if [ "$INTEGRATION_SUITE" = vaultwarden ]; then
        # No contract: the one role that reads no vault credential. The second converge
        # refutes a Vaultwarden that writes its own config.json.
        run_enabled_idempotence vaultwarden
        run_play --tags vaultwarden --check --diff
        run_vaultwarden_verify_only
        printf 'VAULTWARDEN_RUNTIME_VERIFIED\n'
        # The way back, exercised rather than claimed: the only proof a deployment gate
        # switches OFF. The container must exist first.
        if ! docker ps -a --format '{{.Names}}' |
            grep -Eq '^'"$integration_project_namespace"'-vaultwarden$'; then
          printf '%s\n' \
            'the vaultwarden container is not present, so the teardown below proves nothing' >&2
          exit 1
        fi
        # After the playbook path, where the last `-e` wins (measured). Compose is
        # asked directly: what must be gone is the container.
        run_play --tags vaultwarden -e vaultwarden_deployment_enabled=false
        if docker ps -a --format '{{.Names}}' |
            grep -Eq '^'"$integration_project_namespace"'-vaultwarden$'; then
          printf '%s\n' \
            'disabling vaultwarden_deployment_enabled left the container in place' >&2
          exit 1
        fi
        printf 'VAULTWARDEN_TEARDOWN_VERIFIED\n'
        # And back on, over the data root the tear-down left.
        run_play --tags vaultwarden
        run_vaultwarden_verify_only
        printf 'VAULTWARDEN_RETURN_VERIFIED\n'
      fi
    fi

    if [ "$INTEGRATION_RUN_SERVICE_SCENARIOS" = true ] && suite_is karakeep; then
      if [ "$INTEGRATION_SUITE" = karakeep ]; then
        # The first converge bootstrapped; the second must sign in, read a user count
        # of 1, skip the bootstrap and change nothing.
        run_enabled_idempotence karakeep
        run_play --tags karakeep --check --diff
        run_karakeep_verify_only
        printf 'KARAKEEP_RUNTIME_VERIFIED\n'
        # The way back: afterwards no `-karakeep*` container may survive.
        if ! docker ps --all --format '{{.Names}}' |
            grep -Eq '^'"$integration_project_namespace"'-karakeep$'; then
          printf '%s\n' \
            'the karakeep container is not present, so the teardown below proves nothing' >&2
          exit 1
        fi
        run_play --tags karakeep -e karakeep_deployment_enabled=false
        if docker ps --all --format '{{.Names}}' |
            grep -Eq '^'"$integration_project_namespace"'-karakeep'; then
          printf '%s\n' \
            'disabling karakeep_deployment_enabled left a karakeep container in place' >&2
          exit 1
        fi
        printf 'KARAKEEP_TEARDOWN_VERIFIED\n'
        # And back on over an existing administrator: the door must never open.
        run_play --tags karakeep
        run_karakeep_verify_only
        printf 'KARAKEEP_RETURN_VERIFIED\n'
      fi
    fi
      # The full lane skips the CPU-ML seed contract (an 800 MB model download).

    if [ "$INTEGRATION_SUITE" = full ] && \
       [ "$INTEGRATION_RUN_SERVICE_SCENARIOS" = true ]; then
      env \
        PLATFORM_KIND=integration \
        PLATFORM_CONTRACT_VAULT_FILE="$vault_file" \
        PLATFORM_CONTRACT_VAULT_PASSWORD_FILE="$vault_password_file" \
        PLATFORM_DOCKER_ROOT="$sandbox/volume1/Docker" \
        PLATFORM_MEDIA_ROOT="$sandbox/volume2" \
        PLATFORM_FIXTURE_ROOT="$sandbox/fixtures" \
        PLATFORM_REPORT_ROOT="$sandbox/reports" \
        PLATFORM_JELLYFIN_CONTAINER="$integration_project_namespace-jellyfin" \
        PLATFORM_PROJECT_NAME="$integration_project_namespace" \
        PLATFORM_AUDIOBOOKSHELF_CONTAINER="$integration_project_namespace-audiobookshelf" \
        PLATFORM_IMMICH_SERVER_CONTAINER="$integration_project_namespace-immich-server" \
        PLATFORM_IMMICH_MACHINE_LEARNING_CONTAINER="$integration_project_namespace-immich-machine-learning" \
        PLATFORM_IMMICH_REDIS_CONTAINER="$integration_project_namespace-immich-redis" \
        PLATFORM_IMMICH_POSTGRES_CONTAINER="$integration_project_namespace-immich-postgres" \
        PLATFORM_PAPERLESS_WEBSERVER_CONTAINER="$integration_project_namespace-paperless-webserver" \
        ruby /repo/tests/run_contracts.rb --execute
      run_audiobookshelf_contract authentication-session-cleanup
    fi

    if idempotence_phases; then
    printf '\n=== phase 2: asserting idempotence ===\n'
    # Not piped into tee: no pipefail, so tee's status would hide a dead play.
    idempotence_status=0
    run_selected_play "$@" >/tmp/second.txt 2>&1 || idempotence_status=$?
    cat /tmp/second.txt
    if [ "$idempotence_status" -ne 0 ]; then
      printf 'NOT IDEMPOTENT: second run failed with status %s\n' \
        "$idempotence_status" >&2
      exit 1
    fi
    # The strict recap parser (one recap, one target line, changed/unreachable/failed
    # zero): two greps passed on printed text and ignored `unreachable`.
    if enabled_idempotence_recap_is_clean /tmp/second.txt; then
      printf 'IDEMPOTENT: second run changed nothing\n'
    else
      printf 'NOT IDEMPOTENT: second run reported changes\n' >&2
      exit 1
    fi
    printf '\n=== phase 3: asserting --check --diff works ===\n'
    if run_selected_play "$@" --check --diff; then
      printf 'CHECK MODE OK: dry run completed\n'
    else
      printf 'CHECK MODE BROKEN: dry run failed\n' >&2
      exit 1
    fi
    fi
    cleanup_vault
