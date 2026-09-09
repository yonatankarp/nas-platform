#!/bin/sh
# Policy validation entry point. Run from the repository root.
#
# The check list is data, not straight-line shell: this script reads its own
# manifest and runs the checks concurrently. Run one after another they took
# 15m28s, which made `static` the second-longest job in CI and made a full local
# run impractical enough to skip.
#
# Each check stays one bare command per line. tests/gate_manifest_coverage_test.rb
# declares this whole list and refuses any line it does not name, in either
# direction; tests/policy_ci_test.rb requires about ninety of them individually,
# with the reason each has to keep running; and tests/policy_manifest_test.rb
# proves that deleting one of those named lines is caught. Wrapping these lines
# in a helper, or prefixing them, silently disables those guards while leaving
# this script working, so keep the shape.
#
# Adding a check means adding it in two places: one shard of this list, and the
# matching shard of that declaration. That is the price of the first guard and it
# is deliberate: for about forty of these lines nothing required them at all
# until #469, so deleting any one left every check green and the gate faster than
# before.
#
# POLICY_JOBS sets concurrency and defaults to the CPU count. POLICY_JOBS=1
# restores the original one-at-a-time order, which is what to use when bisecting
# a failure that only shows up under load.
#
# The gate reports its own wall time and its slowest checks on every run, pass or
# fail. Its budget has been exceeded four times, and the first three times naming
# the check responsible meant timing them by hand; the pool already knows, so it
# says so. A check that has grown into the gate's floor is visible in that report
# before it is visible as a cancelled job. Read the seconds for what they are:
# each is a check's wall time while POLICY_JOBS-1 others were running, so a total
# cannot tell a gate bound by its work apart from one waiting on a timeout.
# Changing the width and re-reading the list is what separates them.
#
# Unlike the sequential version this does not stop at the first failure: every
# check runs and every failure is reported, so one broken check no longer hides
# the state of the other fifty-six.
set -eu

if [ "$#" -gt 1 ]; then
  printf 'usage: %s [SHARD]\n' "$0" >&2
  exit 2
fi
policy_shard=${1:-}

# The list is partitioned into three shards, one heredoc each, and CI runs each
# shard on a runner of its own. No argument runs all three, which is the
# unsharded gate a developer runs locally and what every caller but CI still
# does; `tests/validate-policy.sh 2` runs shard 2 alone.
#
# tests/gate_manifest_coverage_test.rb holds the three lists a second time and
# asserts their union is exactly this manifest, in both directions, with a floor
# under each shard. That guard is the precondition for sharding at all: dropping
# a line from a partition removes a check from the gate and makes the gate
# *faster*, with nothing else in the repository to notice.
#
# The partition was balanced against the post-merge `main` run of bab1dc0
# (2026-09-07): 2342s of check time across 155 checks, whose ten slowest ran from
# 247s down to 75s. Those ten are placed by hand so that no two of the top three
# share a shard; every other line is round robin, which balances count, because
# count is all a partition without a cost table can balance.
#
# SPREAD THE WAITS, and this rule outranks the one above it. A check that spends
# its time waiting -- on a timeout, a poll, a port -- still occupies one of the
# four worker slots, but it consumes none of the CPU the other three are
# competing for. Two long waits in one shard therefore cut that shard's effective
# pool from four workers to two, and every CPU-bound check in it stretches. This
# is measured, not reasoned: #484 moved the two beszel contract checks, then 86s
# and 85s of pure wait, into the same shard, and that shard's *other* checks
# inflated by 298s on 412s of work added -- `komga_library_
# reconciliation_test.rb` 134s to 236s, `dozzle_contract_test.rb --self-test`
# 111s to 185s -- while the two shards that shed work got 15% and 24% cheaper in
# the same run. The move was reverted.
#
# The rule stands; its only measured subjects are gone. #485 made both beszel
# polling budgets environment inputs, so those two checks are work-bound now and
# no line in this manifest is currently KNOWN to be a wait -- which is not the
# same as there being none, because only those two were ever measured that way.
# When the next one arrives, recognise it rather than rediscovering it: run the
# check alone and read `time`'s user+sys against its elapsed. Sleep consumes no
# CPU and contention does not change that, so a low ratio is a wait however
# loaded the machine was, and it costs one run instead of a width sweep. The two
# beszel checks were 14.5s of CPU in 99.6s elapsed and 19.1s in 101.5s before the
# fix, and 13.9s in 19.6s and 18.5s in 31.8s after it -- the same work, and the
# 150s of sleep those four numbers bracket is the local half of the 171s of CI
# wait the retired sentence above recorded.
#
# Rebalancing as checks change is a manual act, and the slowest-checks report
# below is what informs it -- but read #484 before trusting an arithmetic
# projection from it. A check's recorded seconds are its wall time at that
# shard's load, so they are not work you can carry to another shard: the
# rebalance above predicted a largest shard of 1170s and measured 1453s. #484
# carries the isolated per-check table (elapsed and CPU measured separately, one
# check at a time) that says which checks are work and which are wait, and the
# arithmetic showing the gate cannot beat its own longest check -- 241-305s for
# `config_managed_users_test.rb --self-test` against a worst observed shard wall
# of 394s, so a perfect partition is worth about 90s and the two levers that
# actually lower the floor are elsewhere.
#
# That baseline predates #485 and #488, which took both of those levers. The two
# beszel lines were 100s and 109s in it and are work-bound now, and the
# `config_managed_users_test.rb --self-test` figure the floor argument rests on
# was measured before its conversion, so their places among the ten slowest are
# stale. Re-deriving the partition needs a fresh gate run rather than an
# adjustment of these numbers.
#
# One line of shard 1 is DELIBERATELY DUPLICATED in CI, and this is the half of
# that note the manifest can carry -- a comment between the heredoc markers would
# be dispatched as a check. `ruby tests/ci/workflow_test.rb` runs here and again
# as a step of the `validate` job in .github/workflows/ci.yml, whose own comment
# carries the reasoning. In short: what it pins is the shape of the workflow that
# runs it, so from here alone `static` gated `if: false`, deleted, or given an
# empty matrix takes its own objection out of the run and reports success (#480).
# `validate` runs under `always()` and cannot be skipped, so the second route is
# the one that survives. Neither copy is redundant, and the check asserts both:
# that `validate` still invokes it, and that this manifest still registers it
# exactly once.

policy_shard_1() {
  cat <<'POLICY_CHECKS_1'
ruby tests/policy_test.rb
ruby tests/policy_beszel_test.rb
shellcheck --shell=sh -x --exclude=SC2068,SC2070,SC2086 tests/integration_controller.sh
ruby tests/policy_vault_test.rb
"$ansible_python" tests/generate_secrets_jinja_regex_test.py
ruby tests/host_prep_integration_writer_test.rb
ruby tests/media_acquisition_phase1_test.rb
ruby tests/media_acquisition_adoption_test.rb
tests/mac/media-acquisition-foundation-cleanup-test.sh
ruby tests/paperless_mail_reconciliation_test.rb
PYTHONDONTWRITEBYTECODE=1 "$ansible_python" -m unittest -v tests.image_prune_test
ruby tests/beszel_telemetry_timeout_test.rb
python3 -m unittest -v tests/dozzle_alert_relay_test.py
ruby tests/immich_restore_lifecycle_test.rb
tests/mac/beszel-telemetry-hook-test.sh
ruby tests/ci/workflow_test.rb
ruby tests/docs_links_test.rb --self-test
tests/mac/snapshot-paperless-context-test.sh
python3 tests/deployment_target_validator_test.py
python3 tests/deployment_release_compare_test.py
ruby tests/managed_users_vault_test.rb
ruby tests/config_managed_users_test.rb --self-test
ruby tests/komga_library_reconciliation_test.rb --self-test
ruby tests/audiobookshelf_initial_scan_test.rb
ruby tests/immich_user_onboarding_test.rb
ruby tests/database_managed_users_test.rb
ruby tests/deployment_summary_test.rb
PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/acquisition_filter_native_arguments_test.py
ruby tests/acquisition_configarr_field_coverage_test.rb --self-test
PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/acquisition_owned_field_coverage_test.py
PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/acquisition_configarr_filter_test.py
PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/media_usenet_provider_test.py
PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/managed_user_identity_filter_test.py
PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/jellyfin_plugin_repositories_filter_test.py
PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/safe_slurp_test.py
ruby tests/run_contracts.rb --validate-only
ruby tests/jellyfin_transcode_contract_test.rb
ruby tests/pinchflat_contract_test.rb
ruby tests/immich_contract_test.rb --self-test
ruby tests/nextcloud_contract_test.rb
ruby tests/arr_contract_test.rb
ruby tests/downloaders_contract_test.rb --self-test
ruby tests/trailarr_contract_test.rb
ruby tests/bindery_contract_test.rb --self-test
ruby tests/beszel_contract_test.rb --self-test
ruby tests/contract_structure_mutation_test.rb
tests/integration_lock_test.sh
tests/mac/config-isolation.sh
tests/mac/dozzle-drift-hook-test.sh
tests/mac/hook-coverage-test.sh
tests/mac/cleanup.sh --self-test
ruby tests/mac/sanitize-logs.rb --self-test
ruby tests/mac/read-integration-ports-test.rb
POLICY_CHECKS_1
}

policy_shard_2() {
  cat <<'POLICY_CHECKS_2'
ruby tests/policy_platform_test.rb
ruby tests/policy_integration_test.rb
ruby tests/policy_deployment_test.rb
ruby tests/gate_manifest_coverage_test.rb
tests/target_docker_dependency_preflight_test.sh
ruby tests/media_acquisition_foundation_test.rb
ruby tests/configarr_job_test.rb
tests/mac/media-acquisition-foundation-hook-test.sh
ruby tests/renovate_policy_test.rb
PYTHONDONTWRITEBYTECODE=1 "$ansible_python" -m unittest -v tests.production_auto_deploy_test
ruby tests/image_prune_role_test.rb
ruby tests/beszel_telemetry_ansible_test.rb
python3 -m unittest -v tests/immich_restore_classifier_test.py
ruby tests/immich_release_helper_test.rb
ruby tests/immich_selective_helper_integrity_test.rb
ruby tests/ci/classify_changes_test.rb
ruby tests/secrets_docs_test.rb
ruby tests/assert_no_vault_secrets_test.rb
tests/mac/snapshot-paperless-recovery-test.sh
python3 tests/deployment_lock_probe_test.py
python3 tests/deployment_controller_input_test.py
ruby tests/beszel_password_preservation_test.rb --self-test
ruby tests/media_managed_users_test.rb
ruby tests/komga_contract_test.rb
ruby tests/audiobookshelf_initial_scan_behavior_test.rb
ruby tests/audiobookshelf_contract_test.rb
ruby tests/immich_configured_password_test.rb
ruby tests/database_managed_users_test.rb --self-test
PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/managed_user_state_filter_test.py
PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/acquisition_filter_native_arguments_test.py --self-test
ruby tests/bazarr_provider_schema_test.rb
PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/acquisition_servarr_filter_test.py
PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/vault_managed_user_schema_test.py
PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/immich_preference_schema_test.py
PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/container_cpu_filter_test.py
PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/jellyfin_encoding_schema_test.py
ansible-playbook -i localhost, -c local tests/compose_metadata_filter_test.yml
ruby tests/dozzle_quality_test.rb
ruby tests/jellyfin_contract_test.rb
ruby tests/pinchflat_contract_test.rb --self-test
ruby tests/paperless_contract_test.rb
ruby tests/arr_contract_test.rb --self-test
ruby tests/seerr_contract_test.rb
ruby tests/trailarr_contract_test.rb --self-test
ruby tests/kapowarr_contract_test.rb
tests/integration_suite_test.sh
tests/sandbox_cleanup_acquisition_ownership_test.sh
tests/mac/run-phase-status-test.sh
tests/mac/audiobookshelf-drift-hook-test.sh
tests/contracts/audiobookshelf-audio-test.sh
tests/mac/snapshot-immich.sh --self-test
ruby tests/mac/pin-protected-input-test.rb
ruby tests/mac/read-integration-ports-test.rb --self-test
POLICY_CHECKS_2
}

policy_shard_3() {
  cat <<'POLICY_CHECKS_3'
ruby tests/policy_ci_test.rb
shellcheck --shell=sh tests/integration_controller_lib.sh
ruby tests/policy_mac_test.rb
ruby tests/policy_audit_coverage_test.rb
tests/media_control_network_collision_test.sh static
ruby tests/media_acquisition_foundation_verifier_test.rb
ruby tests/reader_platform_identity_test.rb
ruby tests/capture_helper_identity_test.rb
ruby tests/dozzle_exit_code_exclusion_identity_test.rb
ruby tests/dozzle_exit_code_exclusion_identity_test.rb --self-test
ruby tests/mac/media-acquisition-foundation-report-test.rb
tests/policy_runner_test.sh
ruby tests/production_auto_deploy_role_test.rb
ruby tests/beszel_telemetry_probe_test.rb
python3 tests/beszel_telemetry_module_test.py
ruby tests/immich_restore_quality_test.rb
tests/dozzle_alert_state_symlink_test.sh
ruby tests/ci/validate_results_test.rb
ruby tests/docs_links_test.rb
tests/mac/integration-context-test.sh
tests/mac/snapshot-paperless-drill-throttle-test.sh
tests/deployment_lock_refusal_test.sh
ruby tests/managed_user_capabilities_test.rb --self-test
ruby tests/media_managed_users_test.rb --self-test
ruby tests/komga_library_reconciliation_test.rb
ruby tests/komga_contract_test.rb --self-test
ruby tests/audiobookshelf_contract_test.rb --self-test
ruby tests/immich_smart_search_retry_test.rb
ruby tests/ntfy_verify_execution_test.rb
PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/acquisition_identity_rules_test.py
ruby tests/acquisition_configarr_field_coverage_test.rb
ruby tests/bazarr_provider_schema_test.rb --self-test
PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/acquisition_bazarr_filter_test.py
PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/vault_credential_schema_test.py
PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/immich_response_schema_test.py
PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/deployment_summary_filter_test.py
PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/filter_input_argument_spec_test.py
ruby tests/run_contracts_test.rb
ruby tests/dozzle_contract_test.rb
ruby tests/dozzle_contract_test.rb --self-test
ruby tests/jellyfin_contract_test.rb --self-test
ruby tests/immich_contract_test.rb
ruby tests/paperless_contract_test.rb --self-test
ruby tests/nextcloud_contract_test.rb --self-test
ruby tests/downloaders_contract_test.rb
ruby tests/seerr_contract_test.rb --self-test
ruby tests/bindery_contract_test.rb
ruby tests/kapowarr_contract_test.rb --self-test
ruby tests/beszel_contract_test.rb
tests/integration_controller_execution_test.sh
tests/mac/manual-validation-runner-test.sh
tests/mac/immich-drift-hook-test.sh
ruby tests/mac/report.rb --self-test
tests/mac/snapshot-paperless.sh --self-test
ruby tests/mac/pin-protected-input-test.rb --self-test
ruby tests/case_pool_locals_test.rb --self-test
ruby tests/case_pool_behavior_test.rb --self-test
POLICY_CHECKS_3
}

POLICY_SHARD_IDS='1 2 3'

# An identifier no shard answers to is refused with a non-zero status rather
# than run as nothing, so a typo in the CI matrix is a red leg instead of a job
# reporting success having executed no check at all.
policy_checks() {
  wanted=${1:-}
  emitted=0
  for shard in $POLICY_SHARD_IDS; do
    if [ -z "$wanted" ] || [ "$wanted" = "$shard" ]; then
      "policy_shard_$shard"
      emitted=$((emitted + 1))
    fi
  done
  if [ "$emitted" -eq 0 ]; then
    printf 'unknown policy shard: %s\n' "$wanted" >&2
    printf 'the manifest declares shards: %s\n' "$POLICY_SHARD_IDS" >&2
    exit 2
  fi
}

# Resolved before the checks run because two of them invoke this interpreter
# directly, and exported because each check is executed in its own shell.
ansible_playbook=$(command -v ansible-playbook) || {
  printf '%s\n' 'ansible-playbook is required for managed-user behavior tests' >&2
  exit 1
}
ansible_python=$(
  "$ansible_playbook" --version |
    sed -n 's/^  python version = .* (\(\/[^()]*\))$/\1/p'
)
[ -x "$ansible_python" ] || {
  printf '%s\n' 'the ansible-playbook Python interpreter is unavailable' >&2
  exit 1
}
export ansible_python

jobs=${POLICY_JOBS:-}
if [ -z "$jobs" ]; then
  jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
fi
case $jobs in
  '' | *[!0-9]*) jobs=4 ;;
esac
[ "$jobs" -ge 1 ] || jobs=1

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM

# One file per check rather than a delimited record, so a command containing any
# character at all still round-trips to its runner intact.
policy_checks "$policy_shard" >"$work/manifest"
total=$(awk 'END { print NR }' "$work/manifest")
# A shard whose list is empty would otherwise run no check, report "all 0
# checks passed" and exit 0 -- the silent green this whole partition has to be
# incapable of. The declaration's per-shard floor guards the lists; this
# guards the run.
if [ "$total" -eq 0 ]; then
  printf 'policy validation found no checks to run\n' >&2
  exit 1
fi
if [ -n "$policy_shard" ]; then
  printf 'policy gate shard %s (of %s): %s checks\n' \
    "$policy_shard" "$POLICY_SHARD_IDS" "$total"
fi
index=0
while [ "$index" -lt "$total" ]; do
  index=$((index + 1))
  awk -v n="$index" 'NR == n { print; exit }' "$work/manifest" >"$work/cmd.$index"
  printf '%s\n' "$work/cmd.$index" >>"$work/queue"
done

# Always exits 0: the parent decides pass or fail from the recorded status, so a
# failing check neither aborts the pool nor leaves the remaining checks unrun.
cat >"$work/run-check" <<'RUNNER'
spec=$1
dir=$(dirname "$spec")
index=${spec##*/cmd.}
started=$(date +%s)
sh -c "$(cat "$spec")" >"$dir/out.$index" 2>&1
status=$?
printf '%s\n' "$(($(date +%s) - started))" >"$dir/seconds.$index"
printf '%s\n' "$status" >"$dir/status.$index"
exit 0
RUNNER

# A child killed by a signal makes xargs abandon the pool, so its status is
# recorded rather than allowed to abort the script: the accounting below is what
# names the checks that never reported, and it has to run for that to be said.
dispatch=0
gate_started=$(date +%s)
tr '\n' '\0' <"$work/queue" |
  xargs -0 -n 1 -P "$jobs" sh "$work/run-check" || dispatch=$?
gate_seconds=$(($(date +%s) - gate_started))

ran=0
failed=0
index=0
while [ "$index" -lt "$total" ]; do
  index=$((index + 1))
  check=$(cat "$work/cmd.$index")
  if [ ! -f "$work/status.$index" ]; then
    printf 'POLICY CHECK NEVER RAN: %s\n' "$check" >&2
    failed=$((failed + 1))
    continue
  fi
  ran=$((ran + 1))
  status=$(cat "$work/status.$index")
  if [ "$status" -eq 0 ]; then
    cat "$work/out.$index"
  else
    printf '\n=== FAILED (exit %s): %s ===\n' "$status" "$check" >&2
    cat "$work/out.$index" >&2
  fi
  [ "$status" -eq 0 ] || failed=$((failed + 1))
  printf '%s\t%s\n' "$(cat "$work/seconds.$index")" "$check" >>"$work/durations"
done

# The gate has outgrown its budget three times, and each time finding the check
# responsible meant timing them by hand. The pool already knows, so it says so:
# its wall time, the check time it had to place into that wall time, and the ten
# checks it took longest to place. A pool cannot finish faster than its longest
# single item, so the top of this list is what the gate's floor actually is.
# Reported on success too -- a gate that only explains itself once it is already
# too slow is a gate nobody reads until CI is red.
if [ -f "$work/durations" ]; then
  busiest=$(sort -rn "$work/durations" | head -10)
  work_seconds=$(awk -F'\t' '{ total += $1 } END { print total + 0 }' "$work/durations")
  printf '\npolicy gate: %ss wall, %ss of check time across %s checks on %s workers\n' \
    "$gate_seconds" "$work_seconds" "$ran" "$jobs"
  printf 'slowest checks:\n'
  printf '%s\n' "$busiest" | awk -F'\t' '{ printf "  %5ds  %s\n", $1, $2 }'
fi

if [ "$ran" -ne "$total" ] || [ "$failed" -ne 0 ] || [ "$dispatch" -ne 0 ]; then
  printf '\npolicy validation failed: %s of %s checks ran, %s failed' \
    "$ran" "$total" "$failed" >&2
  [ "$dispatch" -eq 0 ] || printf ', dispatcher exited %s' "$dispatch" >&2
  printf '\n' >&2
  exit 1
fi

printf 'policy validation: all %s checks passed\n' "$total"
