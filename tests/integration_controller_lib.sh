# Play, contract and verification launchers for the integration controller,
# moved out of tests/integration.sh's `sh -eu -c` string so sh -n and shellcheck
# can read them. Sourced, not executed, so `exit 1` still ends the suite.
# Inputs are restated below so a missing one is refused at source time.
sandbox=${PLATFORM_INTEGRATION_SANDBOX:?integration controller sandbox is unset}
integration_project_namespace=${PLATFORM_INTEGRATION_PROJECT_NAMESPACE:?integration controller namespace is unset}
playbook=${playbook?}
vault_file=${vault_file?}
vault_password_file=${vault_password_file?}
fixture_vars_file=${fixture_vars_file?}
integration_media_usenet_enabled=${integration_media_usenet_enabled?}
integration_media_usenet_provider=${integration_media_usenet_provider?}
integration_media_adopt_existing=${integration_media_adopt_existing?}

# roles/vaultwarden refuses an IPv4 literal for DOMAIN (WebAuthn needs a
# domain), and the sandbox's PLATFORM_PUBLIC_HOST is one. Every lane, since full
# and idempotence-check converge it too. `.invalid` never resolves (RFC 2606).
integration_vaultwarden_domain=https://vaultwarden.integration.invalid

# Every lane must redirect the Dozzle alert relay, or it would push each sandbox
# container event to the household's real Pushover account. The port is
# tests/contracts/dozzle.sh's recorder; tests/dozzle_contract_test.rb pins them equal.
integration_dozzle_pushover_api_url='http://{{ platform_callback_host }}:32587/1/messages.json'

# Deployment reports go to a port nothing listens on; no lane asserts them.
# tests/deployment_summary_test.rb refuses a site.yml caller without it.
integration_deployment_pushover_api_url='http://127.0.0.1:1/1/messages.json'

# nas_compose_minimum: the integration overrides use `!override` (Compose
# 2.24.4), above the NAS floor. It sits after `-i` because
# tests/integration_controller_execution_test.sh pins the leading argv literally.
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
    -e "$integration_media_usenet_provider" \
    -e media_acquisition_adopt_existing_libraries="$integration_media_adopt_existing" \
    -e vaultwarden_domain="$integration_vaultwarden_domain" \
    -e dozzle_pushover_api_url="$integration_dozzle_pushover_api_url" \
    -e deployment_pushover_api_url="$integration_deployment_pushover_api_url" \
    -e nas_compose_minimum=2.24.4 \
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
  if ! enabled_idempotence_recap_is_clean "$idempotence_output"; then
    cat $idempotence_output >&2
    printf '%s\n' \
      'enabled media acquisition convergence was not idempotent' >&2
    exit 1
  fi
}

# Emitted only on a failed Nextcloud converge. Every docker call is guarded (sh -eu),
# inspect is limited to .State.Health (a bare inspect prints the passwords in
# Env), and logs print only after a scan against the ephemeral vault.
dump_nextcloud_diagnostics() {
  nextcloud_diagnostics_project=$integration_project_namespace-nextcloud
  nextcloud_diagnostics_logs=/tmp/nextcloud-converge-failure-logs.txt
  printf '=== NEXTCLOUD CONVERGE FAILURE DIAGNOSTICS ===\n' >&2
  for nextcloud_diagnostics_container in \
      "$integration_project_namespace-nextcloud" \
      "$integration_project_namespace-nextcloud-cron" \
      "$integration_project_namespace-nextcloud-db" \
      "$integration_project_namespace-nextcloud-cache"; do
    printf -- '--- health log: %s ---\n' "$nextcloud_diagnostics_container" >&2
    docker inspect --format '{{json .State.Health}}' \
      "$nextcloud_diagnostics_container" >&2 ||
      printf 'no health state recorded for %s\n' \
        "$nextcloud_diagnostics_container" >&2
  done
  printf -- '--- container states: %s ---\n' "$nextcloud_diagnostics_project" >&2
  docker ps --all \
    --filter "label=com.docker.compose.project=$nextcloud_diagnostics_project" \
    --format '{{.Names}} {{.Status}} {{.Image}}' >&2 ||
    printf 'container states unavailable for %s\n' \
      "$nextcloud_diagnostics_project" >&2
  if docker compose --project-name "$nextcloud_diagnostics_project" \
      logs --no-color --timestamps --tail 200 \
      >"$nextcloud_diagnostics_logs" 2>&1; then
    if /repo/tests/assert-no-vault-secrets.rb \
        "$vault_file" "$vault_password_file" "$nextcloud_diagnostics_logs" \
        >/dev/null 2>&1; then
      printf -- '--- compose logs, last 200 lines per container ---\n' >&2
      cat "$nextcloud_diagnostics_logs" >&2
    else
      printf '%s\n' \
        "compose logs WITHHELD: they matched ephemeral vault material and were" \
        "left at $nextcloud_diagnostics_logs inside the disposable container." \
        "Read the health log above: it carries the probes' own output, and" \
        "never the probe command, so no credential in a probe argv reaches it." >&2
    fi
  else
    printf 'compose logs unavailable for %s\n' \
      "$nextcloud_diagnostics_project" >&2
  fi
  printf '=== END NEXTCLOUD CONVERGE FAILURE DIAGNOSTICS ===\n' >&2
}

# One launcher for every contract; a service's extras arrive as a case arm.
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
    trailarr)
      set -- PLATFORM_PROJECT_NAME="$integration_project_namespace" \
        PLATFORM_TRAILARR_ARRS=true \
        "$@"
      ;;
    seerr)
      set -- PLATFORM_PROJECT_NAME="$integration_project_namespace" \
        PLATFORM_SEERR_ARRS=true \
        "$@"
      ;;
    bindery)
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
    nextcloud)
      set -- PLATFORM_PROJECT_NAME="$integration_project_namespace" \
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

run_trailarr_contract() {
  run_contract trailarr "$@"
}

run_seerr_contract() {
  run_contract seerr "$@"
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

run_nextcloud_contract() {
  run_contract nextcloud "$@"
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

  # No pipefail here, so tee would mask the play's status.
  immich_clean_restore_status=0
  run_play --tags immich >/tmp/immich-clean-restore-second.txt 2>&1 ||
    immich_clean_restore_status=$?
  cat /tmp/immich-clean-restore-second.txt
  if [ "$immich_clean_restore_status" -ne 0 ]; then
    printf 'IMMICH CLEAN RESTORE REPLAY FAILED: status %s\n' \
      "$immich_clean_restore_status" >&2
    exit 1
  fi
  # The shared recap parser: a bare grep also accepted a printed line and never
  # read `unreachable`.
  if ! enabled_idempotence_recap_is_clean "/tmp/immich-clean-restore-second.txt"; then
    cat "/tmp/immich-clean-restore-second.txt" >&2
    printf '%s\n' 'immich clean restore replay was not idempotent' >&2
    exit 1
  fi
  run_immich_contract clean-restore-assert
  printf 'IMMICH_CLEAN_RESTORE_IDEMPOTENT\n'
}

run_immich_restore_negative_matrix() {
  immich_server_before=$(docker inspect --format '{{.Id}}:{{.State.StartedAt}}' "$integration_project_namespace-immich-server")
  immich_database_before=$(docker inspect --format '{{.Id}}:{{.State.StartedAt}}' "$integration_project_namespace-immich-postgres")

  # One root and one bundle render for all scenarios; each asserts its storage
  # sha is unchanged, so a fresh root per scenario buys nothing.
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

  for scenario in no-backup corrupt-newest ambiguous-newest unsafe-permissions prior-marker postgres-major-mismatch stale-backup; do
    # Leftover fixtures would change which failure the next scenario reports.
    rm -rf "$backup_root" "$marker" "$postgres_root/PG_VERSION"
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
      postgres-major-mismatch)
        # Another major than the pin: refused before any Compose operation.
        printf '13\n' > "$postgres_root/PG_VERSION"
        expected_failure=postgres-major-mismatch
        ;;
      stale-backup)
        # A dump older than the originals: refused before any Compose operation (#900).
        printf 'SELECT 1;\n' | gzip -c > \
          "$backup_root/immich-db-backup-20260815T010000-v3.1.0-pg14.19.sql.gz"
        touch -t 200001010000 \
          "$backup_root/immich-db-backup-20260815T010000-v3.1.0-pg14.19.sql.gz"
        expected_failure=stale-newest-backup
        ;;
    esac

    storage_before=$(tar -C "$scenario_root" -cf - docker/immich media | sha256sum)
    output=/tmp/immich-negative-$scenario.txt
    # Versions are pinned beside the fixtures: compatibility is checked first, so
    # a derived version would change which failure each scenario reports.
    if run_play \
        -e nas_docker_root="$scenario_root/docker" \
        -e nas_media_root="$scenario_root/media" \
        -e platform_project_name="$integration_project_namespace-negative" \
        -e immich_restore_expected_immich_version=3.1.0 \
        -e immich_restore_expected_postgres_major=14 \
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

# Written once so a wrapper cannot drop the namespace or vault-path quoting.
run_verification() {
  verification_tag=$1
  set -- /repo/verify.yml --tags "platform_verify_$verification_tag"
  # verify.yml branches on the provider flag, and this is a separate argv from
  # run_play, so it must be passed here too. The comment stays above the `case`:
  # tests/integration_suite_test.sh requires the line before the fact to be the arm.
  case "$verification_tag" in
    arr|downloaders)
      set -- -e media_usenet_enabled=true \
        -e "$integration_media_usenet_provider" "$@"
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
    -e vaultwarden_domain="$integration_vaultwarden_domain" \
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

run_trailarr_verify_only() {
  run_verification trailarr
}

run_seerr_verify_only() {
  run_verification seerr
}

run_nextcloud_verify_only() {
  run_verification nextcloud
}

# The one lane whose verification is the role's own (tasks/verify.yml): no
# vault credential exists to sign in with, so it proves the door.
run_vaultwarden_verify_only() {
  run_verification vaultwarden
}

run_karakeep_verify_only() {
  run_verification karakeep
}

# Only Audiobookshelf: the other prerequisites are converged above and persist;
# deployment_bundle's Compose selection is tagged always for this case.
converge_media_acquisition_reader_prerequisites() {
  run_play --tags audiobookshelf
}

run_media_acquisition_foundation_verify() {
  run_verification media_acquisition_foundation
}
