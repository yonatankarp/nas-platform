#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -P "$(dirname "$0")/.." && pwd -P)
integration=$repo_dir/tests/integration.sh
fake_bin=$(mktemp -d "${TMPDIR:-/tmp}/nas-platform-suite-test.XXXXXX")
docker_log=$fake_bin/docker.log
prepull_bin=$(mktemp -d "${TMPDIR:-/tmp}/nas-platform-prepull-test.XXXXXX")
pull_log=$prepull_bin/pull.log

cleanup() {
  rm -f "$fake_bin/docker" "$fake_bin/mktemp" "$docker_log"
  rmdir "$fake_bin"
  rm -f "$prepull_bin/docker" "$pull_log"
  rmdir "$prepull_bin"
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
for contract in komga tinymediamanager jellyfin; do
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
grep -qF -- '-e PLATFORM_TINYMEDIAMANAGER_FIXTURE_PRESEEDED="$tinymediamanager_fixture_preseeded"' \
  "$integration"
grep -qF -- '-e PLATFORM_JELLYFIN_FIXTURE_PRESEEDED="$jellyfin_fixture_preseeded"' \
  "$integration"

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

# Image pre-pull and its retry.
#
# The plays pull digest-pinned images through community.docker.docker_compose_v2,
# which reports a registry refusal as a module failure that aborts the converge:
# PR #84's smoke and idempotence-check legs died that way on
# "toomanyrequests: retry-after: 218.093us, allowed: 44000/minute" and passed on a
# re-run of the same commits. The harness therefore pulls the images itself first,
# with a bounded retry, and once a digest-pinned layer set is local the play's own
# `docker compose up` reaches no registry at all.
#
# That retry is proven here by driving the real script against a stub docker whose
# registry refuses a chosen number of times per image. Pull-only mode needs no
# sandbox, so each case costs about a second.

prepull_fail() {
  printf 'prepull: %s\n' "$1" >&2
  exit 1
}

cat > "$prepull_bin/docker" <<'EOF'
#!/bin/sh
set -eu
if [ "${1:-}" = pull ]; then
  printf '%s\n' "$2" >> "${STUB_PULL_LOG:?}"
  attempt=$(grep -Fxc -- "$2" "$STUB_PULL_LOG" || true)
  if [ "$attempt" -le "${STUB_PULL_REFUSALS:-0}" ]; then
    printf 'toomanyrequests: retry-after: 218.093us, allowed: 44000/minute\n' >&2
    exit 1
  fi
  exit 0
fi
# Pull-only mode must reach the registry and nothing else; anything else here
# would mean the mode had started building a sandbox.
printf 'unexpected docker invocation: %s\n' "$*" >&2
exit 97
EOF
chmod +x "$prepull_bin/docker"

# Read back rather than restated: Renovate bumps every one of these digests.
runner_image=$(sed -n 's/^runner_image=//p' "$integration")
[ -n "$runner_image" ] || prepull_fail 'could not read the controller image pin'

compose_images() {
  sed -n 's/^[[:space:]]*image:[[:space:]]*//p' "$repo_dir/services/$1/compose.yml"
}

run_prepull() {
  prepull_refusals=$1
  prepull_attempts=$2
  shift 2
  : > "$pull_log"
  prepull_status=0
  PATH="$prepull_bin:$PATH" \
    STUB_PULL_LOG=$pull_log \
    STUB_PULL_REFUSALS=$prepull_refusals \
    INTEGRATION_PREPULL_ONLY=1 \
    INTEGRATION_IMAGE_PULL_ATTEMPTS=$prepull_attempts \
    INTEGRATION_IMAGE_PULL_DELAY=1 \
    "$integration" "$@" >/dev/null 2>&1 || prepull_status=$?
}

assert_pull_set() {
  expected=$1
  actual=$(sort -u "$pull_log")
  [ "$expected" = "$actual" ] || {
    printf 'expected pulls:\n%s\nactual pulls:\n%s\n' "$expected" "$actual" >&2
    exit 1
  }
}

assert_pull_count() {
  observed=$(grep -Fxc -- "$1" "$pull_log" || true)
  [ "$observed" -eq "$2" ] ||
    prepull_fail "expected $2 attempt(s) at $1, saw $observed"
}

# A suite pulls the controller image plus the images of the services its tags
# converge, and nothing else. Pulling the whole tree for a one-service suite would
# cost gigabytes of runner disk for images the run never starts.
run_prepull 0 4 --suite beszel
[ "$prepull_status" -eq 0 ] || prepull_fail "an answering registry failed the pre-pull ($prepull_status)"
assert_pull_set "$({ printf '%s\n' "$runner_image"; compose_images ntfy; compose_images beszel; } | sort -u)"
if grep -q 'immich' "$pull_log"; then
  prepull_fail 'the beszel suite pulled images it never converges'
fi

# The paperless suite is the one whose tag and service directory differ, so it is
# the case that proves the map rather than the naming coincidence.
run_prepull 0 4 --suite paperless
[ "$prepull_status" -eq 0 ] || prepull_fail "the paperless pre-pull failed ($prepull_status)"
assert_pull_set \
  "$({ printf '%s\n' "$runner_image"; compose_images ntfy; compose_images paperless-ngx; } | sort -u)"

# An untagged smoke run converges everything, so every service directory in the
# tree must be reachable from the harness map. A directory the map forgot shows up
# here as a missing pull.
run_prepull 0 4 --suite smoke
[ "$prepull_status" -eq 0 ] || prepull_fail "the untagged smoke pre-pull failed ($prepull_status)"
all_service_images=$(printf '%s\n' "$runner_image"
                     for compose in "$repo_dir"/services/*/compose.yml; do
                       sed -n 's/^[[:space:]]*image:[[:space:]]*//p' "$compose"
                     done)
assert_pull_set "$(printf '%s\n' "$all_service_images" | sort -u)"

# CI narrows smoke to the changed service, and the pre-pull has to narrow with it.
run_prepull 0 4 --suite smoke --tags host_prep,deployment_bundle,ntfy,immich
[ "$prepull_status" -eq 0 ] || prepull_fail "the tagged smoke pre-pull failed ($prepull_status)"
assert_pull_set "$({ printf '%s\n' "$runner_image"; compose_images ntfy; compose_images immich; } | sort -u)"

# A registry that refuses twice and then answers must still produce a successful
# pre-pull, with the pull retried rather than the suite failed. foundation
# converges no service, so this costs one image and two backoffs.
run_prepull 2 4 --suite foundation
[ "$prepull_status" -eq 0 ] || prepull_fail "two refusals failed the pre-pull ($prepull_status)"
assert_pull_count "$runner_image" 3
[ "$(wc -l < "$pull_log" | tr -d " ")" -eq 3 ] ||
  prepull_fail "foundation pulled service images it never converges: $(sort -u "$pull_log")"

# A registry that refuses more times than the budget allows must fail, and must
# not go on pulling the rest: under a rate limit the remaining pulls would only
# extend the outage, and the diagnosis belongs at the first refusal.
#
# Three refusals against a two-attempt budget rather than a registry that never
# answers, deliberately: a retry that lost its bound would answer on the fourth
# attempt and fail this assertion, where against a permanent refusal it would
# instead spin until the job timeout and prove nothing.
run_prepull 3 2 --suite beszel
[ "$prepull_status" -ne 0 ] || prepull_fail 'refusals past the budget produced a successful pre-pull'
assert_pull_count "$runner_image" 2
[ "$(wc -l < "$pull_log" | tr -d " ")" -eq 2 ] ||
  prepull_fail "the pre-pull continued past an exhausted budget: $(cat "$pull_log")"

# The retry cannot be configured away: a zero budget is floored, so one refusal is
# still survived.
run_prepull 1 0 --suite foundation
[ "$prepull_status" -eq 0 ] ||
  prepull_fail "a zero attempt budget removed the retry instead of being floored ($prepull_status)"
assert_pull_count "$runner_image" 2

# Counterexample: the stub must be able to fail a pre-pull at all, otherwise every
# assertion above is vacuous.
run_prepull 3 2 --suite foundation
[ "$prepull_status" -ne 0 ] || prepull_fail 'the stub registry cannot refuse'

printf 'integration suite dispatch and image pre-pull tests passed\n'
