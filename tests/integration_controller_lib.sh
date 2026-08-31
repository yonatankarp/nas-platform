# Play, contract and verification launchers for the integration controller.
#
# The controller is one double-quoted argument to `sh -eu -c` in
# tests/integration.sh, so everything written there is escaped shell inside a
# shell string: `sh -n` never reaches it, shellcheck cannot read it, and the
# tests that guard it have to pin its escaped source text. This file is the
# part of that program that says how a play, a contract and a verification are
# launched, moved out to where all three of those work normally.
#
# It is sourced, not executed: the launchers read the vault the controller
# generated and the positional playbook it was handed, and they run in the
# controller's own shell so `exit 1` still ends the suite.
#
# Inputs. The first two arrive as container environment; the rest the
# controller assigns before it sources this file. Restating them here is what
# lets shellcheck read the file as a whole program, and it turns a missing
# input into a refusal at source time rather than a play with a blank path in
# its arguments.
sandbox=${PLATFORM_INTEGRATION_SANDBOX:?integration controller sandbox is unset}
integration_project_namespace=${PLATFORM_INTEGRATION_PROJECT_NAMESPACE:?integration controller namespace is unset}
playbook=${playbook?}
vault_file=${vault_file?}
vault_password_file=${vault_password_file?}
fixture_vars_file=${fixture_vars_file?}
integration_media_usenet_enabled=${integration_media_usenet_enabled?}
integration_media_adopt_existing=${integration_media_adopt_existing?}

run_play() {
  ansible-playbook \
    -i inventory/local.yml \
    --vault-password-file "$vault_password_file" \
    -e @"$vault_file" \
    -e @"$fixture_vars_file" \
    -e platform_vault_file="$vault_file" \
    -e nas_docker_root="$sandbox/volume1/Docker" \
    -e nas_media_root="$sandbox/volume2" \
    -e platform_compose_kind=integration \
    -e platform_project_name="$integration_project_namespace" \
    -e arr_platform_project_name="$integration_project_namespace" \
    -e downloaders_platform_project_name="$integration_project_namespace" \
    -e platform_beszel_agent_kind=portable \
    -e media_usenet_enabled="$integration_media_usenet_enabled" \
    -e media_acquisition_adopt_existing_libraries="$integration_media_adopt_existing" \
    -e deployment_bundle_test_mode=true \
    -e deployment_bundle_allow_dirty_controller=true \
    "$playbook" "$@"
}

enabled_idempotence_recap_is_clean() {
  idempotence_recap_file=$1
  idempotence_escape=$(printf '\033')
  sed "s/${idempotence_escape}\[[0-9;]*[[:alpha:]]//g" \
    "$idempotence_recap_file" |
    awk '
      /^PLAY RECAP[[:space:]]+\*+[[:space:]]*$/ {
        recap_count++
        in_recap = 1
        next
      }
      in_recap && $1 == "nas" && $2 == ":" {
        target_count++
        valid = 1
        delete seen
        delete value
        for (field = 3; field <= NF; field++) {
          parts = split($field, pair, "=")
          if (parts != 2 || pair[1] == "" || pair[2] !~ /^[0-9]+$/) {
            valid = 0
            continue
          }
          if (seen[pair[1]]++) {
            valid = 0
          }
          value[pair[1]] = pair[2]
        }
        target_clean = valid &&
          seen["changed"] == 1 && value["changed"] == "0" &&
          seen["unreachable"] == 1 && value["unreachable"] == "0" &&
          seen["failed"] == 1 && value["failed"] == "0"
      }
      END {
        exit !(recap_count == 1 && target_count == 1 && target_clean)
      }
    '
}

run_enabled_idempotence() {
  idempotence_tags=$1
  idempotence_output=/tmp/media-acquisition-idempotence.txt
  if ! run_play --tags "$idempotence_tags" \
      >$idempotence_output 2>&1; then
    cat $idempotence_output >&2
    printf '%s\n' \
      'enabled media acquisition convergence did not complete' >&2
    exit 1
  fi
  if ! enabled_idempotence_recap_is_clean $idempotence_output; then
    cat $idempotence_output >&2
    printf '%s\n' \
      'enabled media acquisition convergence was not idempotent' >&2
    exit 1
  fi
}

# One launcher for every contract. The environment ABI every contract reads
# is written once here and a service's extras arrive as a case arm, so the
# ten wrappers below carry only the name they run under. Each layer is
# prepended onto the positional parameters rather than pasted into an
# unquoted string, so every path stays one word however it is spelled.
run_contract() {
  contract_service=$1
  shift
  set -- "/repo/tests/contracts/$contract_service.sh" "$@"
  case "$contract_service" in
    beszel|dozzle)
      ;;
    audiobookshelf)
      set -- PLATFORM_AUDIOBOOKSHELF_PORT=13378 \
        PLATFORM_PROJECT_NAME="$integration_project_namespace" \
        PLATFORM_AUDIOBOOKSHELF_CONTAINER="$integration_project_namespace-audiobookshelf" \
        "$@"
      ;;
    komga)
      set -- PLATFORM_KOMGA_RUNTIME_CONTEXT=base \
        PLATFORM_PROJECT_NAME="$integration_project_namespace" \
        "$@"
      ;;
    kapowarr|pinchflat)
      set -- PLATFORM_PROJECT_NAME="$integration_project_namespace" \
        "$@"
      ;;
    bindery)
      # The lane converges arr and downloaders with the transport enabled, so
      # Prowlarr and SABnzbd are resolvable by name and both of Bindery's
      # integration rows are expected to exist.
      set -- PLATFORM_PROJECT_NAME="$integration_project_namespace" \
        PLATFORM_BINDERY_USENET=true \
        "$@"
      ;;
    jellyfin)
      set -- PLATFORM_JELLYFIN_CONTAINER="$integration_project_namespace-jellyfin" \
        "$@"
      ;;
    immich)
      set -- PLATFORM_MAC_FIXTURE_VARS_FILE="$fixture_vars_file" \
        PLATFORM_IMMICH_SERVER_CONTAINER="$integration_project_namespace-immich-server" \
        PLATFORM_IMMICH_MACHINE_LEARNING_CONTAINER="$integration_project_namespace-immich-machine-learning" \
        PLATFORM_IMMICH_REDIS_CONTAINER="$integration_project_namespace-immich-redis" \
        PLATFORM_IMMICH_POSTGRES_CONTAINER="$integration_project_namespace-immich-postgres" \
        "$@"
      ;;
    paperless)
      set -- PLATFORM_PAPERLESS_WEBSERVER_CONTAINER="$integration_project_namespace-paperless-webserver" \
        "$@"
      ;;
    *)
      printf 'unknown integration contract: %s\n' "$contract_service" >&2
      exit 1
      ;;
  esac
  set -- PLATFORM_REPORT_ROOT="$sandbox/reports" "$@"
  case "$contract_service" in
    beszel|dozzle|audiobookshelf|immich)
      set -- PLATFORM_FIXTURE_ROOT="$sandbox/fixtures" "$@"
      ;;
  esac
  set -- PLATFORM_MEDIA_ROOT="$sandbox/volume2" "$@"
  case "$contract_service" in
    komga)
      ;;
    *)
      set -- PLATFORM_DOCKER_ROOT="$sandbox/volume1/Docker" "$@"
      ;;
  esac
  env \
    PLATFORM_KIND=integration \
    PLATFORM_CONTRACT_VAULT_FILE="$vault_file" \
    PLATFORM_CONTRACT_VAULT_PASSWORD_FILE="$vault_password_file" \
    "$@"
}

run_beszel_contract() {
  run_contract beszel "$@"
}

run_dozzle_contract() {
  run_contract dozzle "$@"
}

run_audiobookshelf_contract() {
  run_contract audiobookshelf "$@"
}

run_komga_contract() {
  run_contract komga "$@"
}

run_bindery_contract() {
  run_contract bindery "$@"
}

run_kapowarr_contract() {
  run_contract kapowarr "$@"
}

run_pinchflat_contract() {
  run_contract pinchflat "$@"
}

run_jellyfin_contract() {
  run_contract jellyfin "$@"
}

run_immich_contract() {
  run_contract immich "$@"
}

run_immich_clean_restore() {
  immich_runtime="$sandbox/volume1/Docker/nas-platform/runtime/services/immich/.env"
  immich_release="$sandbox/volume1/Docker/nas-platform/current/services/immich"
  immich_postgres="$sandbox/volume1/Docker/immich/postgres"
  immich_quarantine="$sandbox/reports/immich-postgres-quarantine"
  immich_stale_redis_key=nas-platform-restore-stale
  test ! -e "$immich_quarantine"
  redis_seed_result=$(docker compose --project-name "$integration_project_namespace-immich" \
    --env-file "$immich_runtime" \
    -f "$immich_release/compose.yml" \
    -f "$immich_release/compose.integration.yml" \
    exec -T redis redis-cli --raw set $immich_stale_redis_key stale)
  test "$redis_seed_result" = OK
  docker compose --project-name "$integration_project_namespace-immich" \
    --env-file "$immich_runtime" \
    -f "$immich_release/compose.yml" \
    -f "$immich_release/compose.integration.yml" \
    stop immich-server immich-machine-learning database
  docker compose --project-name "$integration_project_namespace-immich" \
    --env-file "$immich_runtime" \
    -f "$immich_release/compose.yml" \
    -f "$immich_release/compose.integration.yml" \
    rm -f database
  test -d "$immich_postgres"
  test ! -L "$immich_postgres"
  mv "$immich_postgres" "$immich_quarantine"
  mkdir -m 0755 "$immich_postgres"

  run_play --tags immich
  redis_stale_count=$(docker compose --project-name "$integration_project_namespace-immich" \
    --env-file "$immich_runtime" \
    -f "$immich_release/compose.yml" \
    -f "$immich_release/compose.integration.yml" \
    exec -T redis redis-cli --raw exists $immich_stale_redis_key)
  test "$redis_stale_count" = 0
  run_immich_contract clean-restore-assert
  test ! -e "$sandbox/volume1/Docker/immich/.restore-failed"

  # Piping into tee would hand the pipeline tee's status, and this shell has
  # no pipefail: a play that died would arrive at the recap grep below as if
  # it had merely printed nothing.
  immich_clean_restore_status=0
  run_play --tags immich >/tmp/immich-clean-restore-second.txt 2>&1 ||
    immich_clean_restore_status=$?
  cat /tmp/immich-clean-restore-second.txt
  if [ "$immich_clean_restore_status" -ne 0 ]; then
    printf 'IMMICH CLEAN RESTORE REPLAY FAILED: status %s\n' \
      "$immich_clean_restore_status" >&2
    exit 1
  fi
  grep -qE 'changed=0 .*failed=0 ' /tmp/immich-clean-restore-second.txt
  run_immich_contract clean-restore-assert
  printf 'IMMICH_CLEAN_RESTORE_IDEMPOTENT\n'
}

run_immich_restore_negative_matrix() {
  immich_server_before=$(docker inspect --format '{{.Id}}:{{.State.StartedAt}}' "$integration_project_namespace-immich-server")
  immich_database_before=$(docker inspect --format '{{.Id}}:{{.State.StartedAt}}' "$integration_project_namespace-immich-postgres")

  # One root, and one bundle render for all five scenarios. Each scenario
  # already asserts its own storage sha is unchanged across its play, which is
  # the proof that no scenario mutates the tree, so a pristine root each time
  # only bought five more renders of the same bundle at 66s apiece.
  scenario_root="$sandbox/reports/immich-negative"
  test ! -e "$scenario_root"
  mkdir -m 0755 "$scenario_root"
  mkdir -m 0755 "$scenario_root/docker" "$scenario_root/media"

  run_play \
    -e nas_docker_root="$scenario_root/docker" \
    -e nas_media_root="$scenario_root/media" \
    -e platform_project_name="$integration_project_namespace-negative" \
    --tags host_prep,deployment_bundle

  postgres_root="$scenario_root/docker/immich/postgres"
  originals_root="$scenario_root/media/Immich/upload"
  backup_root="$scenario_root/media/Immich-backups/database"
  marker="$scenario_root/docker/immich/.restore-failed"

  for scenario in no-backup corrupt-newest ambiguous-newest unsafe-permissions prior-marker; do
    # The fixtures are the only state that would carry between scenarios, and
    # each expected failure is derived from exactly them: a backup left behind
    # would make unsafe-permissions report ambiguous-newest-backup, and would
    # stop no-backup from ever seeing an empty directory.
    rm -rf "$backup_root" "$marker"
    mkdir -p "$postgres_root" "$originals_root" "$backup_root"
    printf 'negative-matrix-original\n' > "$originals_root/asset.jpg"
    expected_failure=

    case $scenario in
      no-backup)
        expected_failure=missing-safe-backup
        ;;
      corrupt-newest)
        printf 'SELECT 1;\n' | gzip -c > \
          "$backup_root/immich-db-backup-20260814T010000-v3.1.0-pg14.19.sql.gz"
        printf 'not-a-gzip-stream\n' > \
          "$backup_root/immich-db-backup-20260815T010000-v3.1.0-pg14.19.sql.gz"
        expected_failure=unsafe-newest-backup
        ;;
      ambiguous-newest)
        printf 'SELECT 1;\n' | gzip -c > \
          "$backup_root/immich-db-backup-20260815T010000-v3.1.0-pg14.19.sql.gz"
        printf 'SELECT 2;\n' | gzip -c > \
          "$backup_root/immich-db-backup-20260815T010000-v3.1.1-pg14.20.sql.gz"
        expected_failure=ambiguous-newest-backup
        ;;
      unsafe-permissions)
        printf 'SELECT 1;\n' | gzip -c > \
          "$backup_root/immich-db-backup-20260815T010000-v3.1.0-pg14.19.sql.gz"
        chmod 0666 \
          "$backup_root/immich-db-backup-20260815T010000-v3.1.0-pg14.19.sql.gz"
        expected_failure=unsafe-newest-backup
        ;;
      prior-marker)
        printf '{"version":1,"stage":"database-restore"}\n' > "$marker"
        chmod 0600 "$marker"
        expected_failure=previous-failed-restore
        ;;
    esac

    storage_before=$(tar -C "$scenario_root" -cf - docker/immich media | sha256sum)
    output=/tmp/immich-negative-$scenario.txt
    if run_play \
        -e nas_docker_root="$scenario_root/docker" \
        -e nas_media_root="$scenario_root/media" \
        -e platform_project_name="$integration_project_namespace-negative" \
        --tags immich >"$output" 2>&1; then
      cat "$output" >&2
      printf 'IMMICH NEGATIVE RESTORE SCENARIO SUCCEEDED: %s\n' "$scenario" >&2
      exit 1
    fi
    grep -qF "$expected_failure" "$output"
    if grep -qF "$scenario_root" "$output" || \
       grep -qF 'immich-db-backup-20260815T010000' "$output" || \
       grep -qF 'TASK [immich : Restore and verify the Immich database]' "$output" || \
       grep -qF 'TASK [immich : Deploy Immich]' "$output" || \
       grep -qF 'TASK [immich : Create the vault Immich administrator]' "$output"; then
      cat "$output" >&2
      printf 'IMMICH NEGATIVE RESTORE BOUNDARY FAILED: %s\n' "$scenario" >&2
      exit 1
    fi
    /repo/tests/assert-no-vault-secrets.rb \
      "$vault_file" "$vault_password_file" "$output"
    storage_after=$(tar -C "$scenario_root" -cf - docker/immich media | sha256sum)
    test "$storage_after" = "$storage_before"
    test "$(docker inspect --format '{{.Id}}:{{.State.StartedAt}}' "$integration_project_namespace-immich-server")" = \
      "$immich_server_before"
    test "$(docker inspect --format '{{.Id}}:{{.State.StartedAt}}' "$integration_project_namespace-immich-postgres")" = \
      "$immich_database_before"
  done

  existing_backup="$sandbox/volume2/Immich-backups/database/"\
'immich-db-backup-20260816T010000-v3.1.0-pg14.19.sql.gz'
  existing_quarantine="$sandbox/reports/immich-existing-newer-backup.quarantine"
  test ! -e "$existing_backup"
  test ! -e "$existing_quarantine"
  printf 'newer-backup-must-not-be-read\n' > "$existing_backup"
  existing_backup_before=$(sha256sum "$existing_backup")
  run_play --tags immich > /tmp/immich-existing-database-backup.txt 2>&1
  test "$(sha256sum "$existing_backup")" = "$existing_backup_before"
  test ! -e "$sandbox/volume1/Docker/immich/.restore-failed"
  test "$(docker inspect --format '{{.Id}}:{{.State.StartedAt}}' "$integration_project_namespace-immich-server")" = \
    "$immich_server_before"
  run_immich_contract clean-restore-assert
  mv "$existing_backup" "$existing_quarantine"
  printf 'IMMICH_EXISTING_DATABASE_BACKUP_IGNORED\n'

  run_immich_contract run
  printf 'IMMICH_NEGATIVE_RESTORE_MATRIX_OK\n'
}

run_paperless_contract() {
  run_contract paperless "$@"
}

run_paperless_snapshot() {
  env \
    PLATFORM_KIND=integration \
    PLATFORM_CONTRACT_VAULT_FILE="$vault_file" \
    PLATFORM_CONTRACT_VAULT_PASSWORD_FILE="$vault_password_file" \
    PLATFORM_DOCKER_ROOT="$sandbox/volume1/Docker" \
    PLATFORM_MEDIA_ROOT="$sandbox/volume2" \
    PLATFORM_PAPERLESS_WEBSERVER_CONTAINER="$integration_project_namespace-paperless-webserver" \
    PLATFORM_PAPERLESS_POSTGRES_CONTAINER="$integration_project_namespace-paperless-postgres" \
    PLATFORM_PAPERLESS_REDIS_CONTAINER="$integration_project_namespace-paperless-redis" \
    /repo/tests/mac/snapshot-paperless.sh "$@"
}

# Every per-service verification runs the same play against the same
# disposable sandbox; only the tag differs, and the one stack that needs an
# extra fact declares it in the case below. Written once so a wrapper cannot
# quietly drop the namespace or the quoting around the vault paths.
run_verification() {
  verification_tag=$1
  set -- /repo/verify.yml --tags "platform_verify_$verification_tag"
  case "$verification_tag" in
    arr|downloaders)
      set -- -e media_usenet_enabled=true "$@"
      ;;
  esac
  PLATFORM_VAULT_FILE="$vault_file" ansible-playbook \
    -i inventory/local.yml \
    --vault-password-file "$vault_password_file" \
    -e @"$vault_file" \
    -e platform_vault_file="$vault_file" \
    -e nas_docker_root="$sandbox/volume1/Docker" \
    -e nas_media_root="$sandbox/volume2" \
    -e platform_compose_kind=integration \
    -e platform_project_name="$integration_project_namespace" \
    -e platform_beszel_agent_kind=portable \
    -e deployment_bundle_test_mode=true \
    -e deployment_bundle_allow_dirty_controller=true \
    "$@"
}

run_verify_only() {
  run_verification beszel
}

run_dozzle_verify_only() {
  run_verification dozzle
}

run_audiobookshelf_verify_only() {
  run_verification audiobookshelf
}

run_arr_verify_only() {
  run_verification arr
}

run_downloaders_verify_only() {
  run_verification downloaders
}

run_bindery_verify_only() {
  run_verification bindery
}

run_kapowarr_verify_only() {
  run_verification kapowarr
}

run_pinchflat_verify_only() {
  run_verification pinchflat
}

converge_media_acquisition_reader_prerequisites() {
  run_play --tags host_prep,deployment_bundle,ntfy,audiobookshelf,jellyfin
}

run_media_acquisition_foundation_verify() {
  run_verification media_acquisition_foundation
}
