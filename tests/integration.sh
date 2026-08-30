#!/bin/sh
# Runs the plays against a disposable sandbox instead of the NAS.
#
# Ansible executes inside a Linux container so the plays meet a real
# /proc/mounts, real numeric uid and gid, and a real Docker socket. Because the
# Compose definitions take NAS_DOCKER_ROOT and NAS_MEDIA_ROOT rather than
# absolute paths, the sandbox needs only to point those at a temporary directory:
# no override files, and the definitions run byte-identical to production.
#
# Full and idempotence-check run three phases: converge, an unchanged second
# converge, and --check --diff. Selective suites stop after their owned scenario
# block, while smoke stops after the first converge and manifest verification.
#
# Usage: tests/integration.sh [--suite NAME [--tags TAGS]] [playbook] [ansible arguments]
set -eu

ansible_core_version=2.21.3
# community.docker.docker_container_info imports requests on the managed host;
# the disposable controller is that host for the local inventory.
requests_version=2.34.2
runner_image=docker.io/library/python:3.14-alpine@sha256:05b2b8b732ecd268fee8727a369f936f022d1321b59befd13c30ede22769dcdc
# Fuzzy `~` rather than `=`: apk's `=` requires the distro revision, so a
# packaging-only bump from -r0 to -r1 drops the pinned version out of the index
# and every suite fails at sandbox setup with "unable to select packages". `~`
# pins the upstream version and accepts any revision of it. Dropping the
# revision is also what lets Renovate track these, since repology reports
# Alpine versions without one.
ruby_package='ruby~3.4.9'
curl_package='curl~8.21.0'

suite=full
suite_tags=
tags_explicit=false
describe_suite=false
explicit_suite=false
observe_lifecycle=false
consume_lifecycle=false
lifecycle_mode_count=0
lifecycle_list_requested=false
lifecycle_describe_requested=false

for integration_argument in "$@"; do
  case $integration_argument in
    --observe-lifecycle|--consume-lifecycle)
      lifecycle_mode_count=$((lifecycle_mode_count + 1))
      ;;
    --list-suites) lifecycle_list_requested=true ;;
    --describe-suite) lifecycle_describe_requested=true ;;
  esac
done

if [ "$lifecycle_mode_count" -gt 1 ]; then
  printf '%s\n' 'integration lifecycle modes conflict' >&2
  exit 2
fi
if [ "$lifecycle_mode_count" -eq 1 ]; then
  if [ "$lifecycle_list_requested" = true ]; then
    printf '%s\n' 'integration lifecycle mode conflicts with suite listing' >&2
    exit 2
  fi
  if [ "$lifecycle_describe_requested" = true ] ||
     [ "${INTEGRATION_DESCRIBE_ONLY:-0}" = 1 ]; then
    printf '%s\n' 'integration lifecycle mode conflicts with describe-only' >&2
    exit 2
  fi
  case "${1:-}" in
    --observe-lifecycle|--consume-lifecycle) ;;
    *)
      printf '%s\n' 'integration lifecycle mode must be the first argument' >&2
      exit 2
      ;;
  esac
fi

case "${1:-}" in
  --observe-lifecycle) observe_lifecycle=true; shift ;;
  --consume-lifecycle) consume_lifecycle=true; shift ;;
esac

# Which suites exist, and what each one converges, is data rather than code:
# tests/ci/suites.conf holds one row per suite and tests/ci/classify_changes.rb
# derives its lanes, its CI matrix and its tag plans from the same rows. Reading
# the file here is what stops the runner and CI from disagreeing about what a
# suite is -- they used to hold separate copies kept equal by a policy check.
repo_dir=$(CDPATH= cd -P "$(dirname "$0")/.." && pwd -P)
suite_table=$repo_dir/tests/ci/suites.conf
if [ ! -f "$suite_table" ]; then
  printf 'missing integration suite table: %s\n' "$suite_table" >&2
  exit 2
fi

# Sets suite_names to every suite in row order, suite_known to whether $1 is one
# of them, and fixed_tags to the tags that suite converges. Reads the file in the
# current shell rather than through a pipeline so a malformed row can exit.
read_suite_table() {
  suite_names=
  suite_known=false
  fixed_tags=
  while read -r table_suite table_kind table_tags; do
    case $table_suite in
      ''|'#'*) continue ;;
    esac
    if [ -z "$table_kind" ] || [ -z "$table_tags" ]; then
      printf 'malformed integration suite table row: %s\n' "$table_suite" >&2
      exit 2
    fi
    suite_names="${suite_names:+$suite_names }$table_suite"
    if [ "$table_suite" = "$1" ]; then
      suite_known=true
      [ "$table_tags" = - ] || fixed_tags=$table_tags
    fi
  done < "$suite_table"
  if [ -z "$suite_names" ]; then
    printf 'empty integration suite table: %s\n' "$suite_table" >&2
    exit 2
  fi
}

if [ "${1:-}" = --list-suites ]; then
  read_suite_table ''
  printf '%s\n' "$suite_names"
  exit 0
fi

case "${1:-}" in
  --suite)
    explicit_suite=true
    shift
    case "${1:-}" in
      ''|--*)
        printf 'unknown integration suite: <missing>\n' >&2
        exit 2
        ;;
    esac
    suite=$1
    shift
    ;;
  --describe-suite)
    explicit_suite=true
    describe_suite=true
    shift
    case "${1:-}" in
      ''|--*)
        printf 'unknown integration suite: <missing>\n' >&2
        exit 2
        ;;
    esac
    suite=$1
    shift
    ;;
esac

if [ "${1:-}" = --tags ]; then
  tags_explicit=true
  shift
  [ "$#" -gt 0 ] || {
    printf 'missing value for --tags\n' >&2
    exit 2
  }
  suite_tags=$1
  shift
fi

read_suite_table "$suite"
if [ "$suite_known" != true ]; then
  printf 'unknown integration suite: %s\n' "$suite" >&2
  exit 2
fi

if [ "$tags_explicit" = true ]; then
  case "$suite" in
    smoke|idempotence-check) ;;
    *)
      printf 'integration suite %s does not accept --tags\n' "$suite" >&2
      exit 2
      ;;
  esac
  if [ -n "$suite_tags" ]; then
    old_ifs=$IFS
    IFS=,
    set -f
    for tag in $suite_tags; do
      case "$tag" in
        ''|*[!abcdefghijklmnopqrstuvwxyz0123456789_-]*)
          printf 'invalid integration tags: %s\n' "$suite_tags" >&2
          exit 2
          ;;
      esac
    done
    set +f
    IFS=$old_ifs
    case "$suite_tags" in
      ,*|*,|*,,*)
        printf 'invalid integration tags: %s\n' "$suite_tags" >&2
        exit 2
        ;;
    esac
  fi
else
  suite_tags=$fixed_tags
fi

if [ "$explicit_suite" = true ]; then
  case "${1:-}" in
    -*)
      printf 'unexpected integration suite argument: %s\n' "$1" >&2
      exit 2
      ;;
  esac
fi

playbook=${1:-site.yml}
[ "$#" -gt 0 ] && shift || true

run_service_scenarios=true
if [ "$explicit_suite" = false ] && [ "$#" -gt 0 ]; then
  run_service_scenarios=false
fi

if [ "$explicit_suite" = true ]; then
  for argument in "$@"; do
    case "$argument" in
      --tags|--tags=*)
        case "$suite" in
          smoke|idempotence-check)
            printf 'integration suite options must precede the playbook\n' >&2
            ;;
          *)
            printf 'integration suite %s does not accept --tags\n' "$suite" >&2
            ;;
        esac
        exit 2
        ;;
      *)
        printf 'unexpected integration suite argument: %s\n' "$argument" >&2
        exit 2
        ;;
    esac
  done
fi

if [ "$observe_lifecycle" = true ] &&
   [ "${INTEGRATION_RUN_SERVICE_SCENARIOS+x}" = x ]; then
  case "$INTEGRATION_RUN_SERVICE_SCENARIOS" in
    true|false) run_service_scenarios=$INTEGRATION_RUN_SERVICE_SCENARIOS ;;
    *)
      printf 'invalid integration service-scenario decision: %s\n' \
        "$INTEGRATION_RUN_SERVICE_SCENARIOS" >&2
      exit 2
      ;;
  esac
fi

if [ "$describe_suite" = true ] || [ "${INTEGRATION_DESCRIBE_ONLY:-0}" = 1 ]; then
  printf 'suite=%s tags=%s playbook=%s scenarios=%s\n' \
    "$suite" "$suite_tags" "$playbook" "$run_service_scenarios"
  exit 0
fi

emit_lifecycle_plan() {
  printf '%s\n' converge
  printf '%s\n' success
}

if [ "$observe_lifecycle" = true ]; then
  emit_lifecycle_plan
  exit 0
fi

if [ "$consume_lifecycle" = true ]; then
  lifecycle_script_dir=$(CDPATH= cd -P "$(dirname "$0")" && pwd -P)
  . "$lifecycle_script_dir/integration_lifecycle.sh"
  consume_integration_lifecycle_plan \
    "$0" --observe-lifecycle --suite "$suite"
  exit $?
fi

# Service images the suite will need, keyed by the site.yml role tag that
# converges them.
#
# The keys are the role tags from site.yml and the values the service directories
# from services/manifest.yml. They coincide everywhere except paperless, whose
# role is paperless_ngx and whose directory is paperless-ngx. Keyed by tag rather
# than by suite because smoke and idempotence-check accept --tags, and CI narrows
# them to the changed service: pulling the whole tree for a one-service run would
# cost several gigabytes of runner disk and download for nothing.
#
# tests/policy_ci_test.rb asserts this covers every implemented service exactly
# once and names only real site.yml tags, so it cannot drift from the manifest.
service_image_sources='
ntfy ntfy
beszel beszel
dozzle dozzle
audiobookshelf audiobookshelf
komga komga
jellyfin jellyfin
immich immich
paperless paperless-ngx
arr arr
downloaders downloaders
kapowarr kapowarr
pinchflat pinchflat
'

# Retry budget for a registry that refuses. These ceilings bound all shell
# arithmetic even when CI environment variables or registry diagnostics are
# malformed or hostile.
image_pull_attempt_limit=10
image_pull_delay_limit=300
image_pull_wait_limit=375

bounded_integer() {
  LC_ALL=C awk -v value="$1" -v fallback="$2" -v minimum="$3" \
    -v maximum="$4" '
    function digits_greater(left, right, digit_index, left_digit, right_digit) {
      for (digit_index = 1; digit_index <= length(left); digit_index++) {
        left_digit = substr(left, digit_index, 1)
        right_digit = substr(right, digit_index, 1)
        if (left_digit > right_digit) return 1
        if (left_digit < right_digit) return 0
      }
      return 0
    }

    BEGIN {
      if (value !~ /^[0-9]+$/) {
        print fallback
        exit
      }
      sub(/^0+/, "", value)
      if (value == "") value = "0"

      if (length(value) > length(maximum) ||
          (length(value) == length(maximum) &&
           digits_greater(value, maximum))) {
        print maximum
        exit
      }
      if (length(value) < length(minimum) ||
          (length(value) == length(minimum) &&
           digits_greater(minimum, value))) {
        print minimum
        exit
      }
      print value
    }
  '
}

image_pull_attempts=$(bounded_integer "${INTEGRATION_IMAGE_PULL_ATTEMPTS:-6}" \
  6 2 "$image_pull_attempt_limit")
image_pull_delay=$(bounded_integer "${INTEGRATION_IMAGE_PULL_DELAY:-5}" \
  5 1 "$image_pull_delay_limit")
image_pull_max_delay=$(bounded_integer "${INTEGRATION_IMAGE_PULL_MAX_DELAY:-60}" \
  60 1 "$image_pull_delay_limit")
[ "$image_pull_max_delay" -ge "$image_pull_delay" ] ||
  image_pull_max_delay=$image_pull_delay

pull_error=
prepull_list=

cleanup_pull_error() {
  if [ -n "$pull_error" ]; then
    rm -f "$pull_error" || true
    pull_error=
  fi
}

cleanup_prepull_list() {
  if [ -n "$prepull_list" ]; then
    rm -f "$prepull_list" || true
    prepull_list=
  fi
}

retry_after_seconds() {
  LC_ALL=C awk '
    function value_exceeds(value, limit, whole, fraction, digit_index, value_digit, limit_digit) {
      split(value, parts, ".")
      whole = parts[1]
      fraction = parts[2]
      sub(/^0+/, "", whole)
      if (whole == "") whole = "0"
      if (length(whole) > length(limit)) return 1
      if (length(whole) < length(limit)) return 0
      for (digit_index = 1; digit_index <= length(whole); digit_index++) {
        value_digit = substr(whole, digit_index, 1)
        limit_digit = substr(limit, digit_index, 1)
        if (value_digit > limit_digit) return 1
        if (value_digit < limit_digit) return 0
      }
      return fraction ~ /[1-9]/
    }

    {
      # Case-insensitive, and tolerant of a space before the colon, so the hint
      # is still read if the daemon ever echoes an HTTP-style "Retry-After".
      # A stricter match would turn this whole parser into dead code silently.
      if (!match($0, /[Rr][Ee][Tt][Rr][Yy]-[Aa][Ff][Tt][Ee][Rr][[:space:]]*:/)) next
      token = substr($0, RSTART + RLENGTH)
      sub(/^[[:space:]]*/, "", token)
      sub(/[,[:space:]].*$/, "", token)

      unit = ""
      if (token ~ /ns$/) unit = "ns"
      else if (token ~ /us$/) unit = "us"
      else if (token ~ /µs$/) unit = "µs"
      else if (token ~ /ms$/) unit = "ms"
      else if (token ~ /s$/) unit = "s"
      else if (token ~ /m$/) unit = "m"

      value = unit == "" ? token : substr(token, 1, length(token) - length(unit))
      if (value !~ /^[0-9]+([.][0-9]+)?$/) next

      limit = "300"
      if (unit == "ns") limit = "300000000000"
      else if (unit == "us" || unit == "µs") limit = "300000000"
      else if (unit == "ms") limit = "300000"
      else if (unit == "m") limit = "5"
      if (value_exceeds(value, limit)) {
        print 300
        exit
      }

      seconds = value + 0
      if (unit == "ns") seconds /= 1000000000
      else if (unit == "us" || unit == "µs") seconds /= 1000000
      else if (unit == "ms") seconds /= 1000
      else if (unit == "m") seconds *= 60

      rounded = int(seconds)
      if (seconds > rounded) rounded++
      if (seconds > 0 && rounded < 1) rounded = 1
      print rounded
      exit
    }
  '
}

image_pull_jitter() {
  jitter_base=$1
  jitter_limit=$((jitter_base / 4))
  [ "$jitter_limit" -ge 1 ] || jitter_limit=1
  jitter_entropy=$(od -An -N4 -tu4 /dev/urandom 2>/dev/null | tr -d ' ')
  case $jitter_entropy in
    ''|*[!0123456789]*) jitter_entropy=$$ ;;
  esac
  LC_ALL=C awk -v entropy="$jitter_entropy" -v limit="$jitter_limit" '
    BEGIN {
      remainder = 0
      for (digit_index = 1; digit_index <= length(entropy); digit_index++) {
        remainder = (remainder * 10 + substr(entropy, digit_index, 1)) % limit
      }
      print remainder + 1
    }
  '
}

pull_image() {
  pull_target=$1
  pull_attempt=1
  pull_delay=$image_pull_delay
  pull_error=$(mktemp "${TMPDIR:-/tmp}/nas-platform-pull-error.XXXXXX") || pull_error=
  if [ -z "$pull_error" ]; then
    # Without it every `docker pull` would redirect to "" and fail without
    # running, burning the whole attempt budget of sleeps to report a refusal
    # that never happened.
    printf 'could not create a pull diagnostic file under %s\n' \
      "${TMPDIR:-/tmp}" >&2
    return 1
  fi
  while :; do
    if docker pull "$pull_target" 2> "$pull_error"; then
      cat "$pull_error" >&2
      rm -f "$pull_error"
      pull_error=
      return 0
    fi
    cat "$pull_error" >&2
    if [ "$pull_attempt" -ge "$image_pull_attempts" ]; then
      rm -f "$pull_error"
      pull_error=
      printf 'could not pull %s in %s attempt(s)\n' \
        "$pull_target" "$pull_attempt" >&2
      return 1
    fi
    retry_after=$(retry_after_seconds < "$pull_error")
    retry_delay=$pull_delay
    case $retry_after in
      ''|*[!0123456789]*) ;;
      *)
        # A registry hint lengthens the wait but does not escape the ceiling the
        # local ladder obeys. Honouring "retry-after: 5m" literally would sleep
        # roughly thirty-one minutes across the default budget for a single
        # image, and the Actions timeout would kill the job with no diagnostic
        # -- strictly worse than reporting the refusal ourselves.
        retry_after=$(bounded_integer "$retry_after" 0 0 "$image_pull_max_delay")
        [ "$retry_after" -le "$retry_delay" ] || retry_delay=$retry_after
        ;;
    esac
    jitter=$(image_pull_jitter "$retry_delay")
    retry_delay=$((retry_delay + jitter))
    [ "$retry_delay" -le "$image_pull_wait_limit" ] ||
      retry_delay=$image_pull_wait_limit
    printf 'pull of %s failed, retrying in %ss (attempt %s of %s)\n' \
      "$pull_target" "$retry_delay" "$pull_attempt" "$image_pull_attempts" >&2
    sleep "$retry_delay"
    pull_attempt=$((pull_attempt + 1))
    if [ "$pull_delay" -gt $((image_pull_max_delay / 2)) ]; then
      pull_delay=$image_pull_max_delay
    else
      pull_delay=$((pull_delay * 2))
    fi
    : > "$pull_error"
  done
}

suite_pull_images() {
  printf '%s\n' "$service_image_sources" | while read -r service_tag service_dir; do
    [ -n "$service_tag" ] || continue
    # An empty tag list means the whole play runs, so every implemented service
    # converges and every image is needed.
    if [ -n "$suite_tags" ]; then
      case ",$suite_tags," in
        *",$service_tag,"*) ;;
        *)
          case "$suite:$service_tag" in
            bindery:ntfy|bindery:audiobookshelf|bindery:jellyfin|\
            trailarr:ntfy|trailarr:audiobookshelf|trailarr:jellyfin|\
            seerr:ntfy|seerr:audiobookshelf|seerr:jellyfin) ;;
            *) continue ;;
          esac
          ;;
      esac
    fi
    # Explicit rather than left to set -e: the caller reads this function's
    # status with `|| status=$?`, and POSIX suspends errexit for everything
    # inside an AND-OR list -- including a function body. Without the exit, an
    # unreadable compose.yml would be skipped and the suite would converge
    # images that were never pre-pulled.
    sed -n 's/^[[:space:]]*image:[[:space:]]*//p' \
      "$repo_dir/services/$service_dir/compose.yml" || exit 1
  done
}

# Warms the daemon's image cache before anything converges.
#
# Every image in services/*/compose.yml is digest-pinned, so once a layer set is
# local the play's own `docker compose up` reaches no registry at all. That is
# what makes this the honest retry point: the pull otherwise happens inside
# community.docker.docker_compose_v2, which reports a registry refusal as a
# module failure that aborts the play, and no Ansible retry keyword reaches into
# the module's own pull. Observed on PR #84, where ghcr.io answered
# "toomanyrequests: retry-after: 218.093us, allowed: 44000/minute" during
# "Deploy Immich" and failed two suites that a re-run passed unchanged.
#
# Pulling from here is also what lets a registry login matter at all. The Docker
# CLI reads its own credentials and sends them to the daemon per request rather
# than the daemon holding them, and the plays run in a throwaway controller
# container whose CLI has no credential store, so a pull issued from in there is
# anonymous however the runner logged in. This one is issued by the runner's own
# CLI, and every later pull finds the layers already local.
#
# Failing here fails the suite, deliberately: the point is to survive a transient
# refusal, not to hide a registry that is genuinely unreachable.
prepull_images() {
  # The controller image is a Docker Hub pull every suite makes, and Docker Hub's
  # anonymous allowance is the stricter of the two. No login covers it, so the
  # retry is all this pull gets.
  pull_image "$runner_image" || return 1
  # `for candidate in $(suite_pull_images | sort -u)` would take its status from
  # sort, and #!/bin/sh has no pipefail to fix that. A missing
  # services/<dir>/compose.yml aborts the enumeration's `while` subshell under
  # set -e, sort still succeeds on the truncated list, and every image after the
  # gap is silently never pre-pulled -- so it gets pulled inside
  # docker_compose_v2 instead, which is exactly the registry refusal this
  # function exists to absorb. Materialize the list first and refuse the suite if
  # producing it failed.
  prepull_list=$(mktemp "${TMPDIR:-/tmp}/nas-platform-prepull.XXXXXX") ||
    prepull_list=
  if [ -z "$prepull_list" ]; then
    printf 'could not create an image enumeration file under %s\n' \
      "${TMPDIR:-/tmp}" >&2
    return 1
  fi
  prepull_enumeration_status=0
  suite_pull_images > "$prepull_list" || prepull_enumeration_status=$?
  if [ "$prepull_enumeration_status" -ne 0 ]; then
    cleanup_prepull_list
    printf 'could not enumerate the images the %s suite needs (status %s)\n' \
      "$suite" "$prepull_enumeration_status" >&2
    return 1
  fi
  prepull_targets=$(sort -u "$prepull_list")
  cleanup_prepull_list
  for pull_candidate in $prepull_targets; do
    # Dozzle's alert relay runs on the same image as the controller, so skipping
    # it here saves a second registry round trip on every suite that includes it.
    if [ "$pull_candidate" != "$runner_image" ]; then
      pull_image "$pull_candidate" || return 1
    fi
  done
}

# Pull-only mode exists so tests/integration_suite_test.sh can drive the retry
# against a stub docker without building a sandbox. It shares the code path the
# real run uses rather than re-implementing it.
trap 'cleanup_pull_error; cleanup_prepull_list' EXIT
trap 'exit 130' HUP INT TERM

if [ "${INTEGRATION_PREPULL_ONLY:-0}" = 1 ]; then
  prepull_status=0
  prepull_images || prepull_status=$?
  exit "$prepull_status"
fi

. "$repo_dir/tests/sandbox_cleanup.sh"
. "$repo_dir/tests/integration_lock.sh"

# Bind sources must be valid for the Docker daemon as well as this container. On
# macOS TMPDIR lives under /private, which Docker Desktop shares by default; on
# Linux the daemon shares the host filesystem, so /tmp is correct.
temporary_parent=${TMPDIR:-/tmp}
temporary_parent=${temporary_parent%/}
temporary_parent=$(CDPATH= cd -P "$temporary_parent" && pwd -P)
sandbox=

derive_integration_project_namespace() {
  integration_namespace_sandbox=$1
  integration_suffix=${integration_namespace_sandbox##*.}
  integration_suffix=$(printf '%s' "$integration_suffix" |
    tr '[:upper:]' '[:lower:]')
  integration_project_namespace=nas-platform-integration-$integration_suffix
  case $integration_project_namespace in
    nas-platform-integration-[a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9]) ;;
    *)
      printf 'invalid integration sandbox suffix: %s\n' \
        "$integration_suffix" >&2
      return 2
      ;;
  esac
  printf '%s\n' "$integration_project_namespace"
}

acquire_integration_lock "$temporary_parent"

cleanup_integration_on_exit() {
  integration_exit_status=$?
  trap - EXIT HUP INT TERM
  cleanup_pull_error
  cleanup_prepull_list
  if [ -n "$sandbox" ] && ! cleanup_sandbox "$sandbox"; then
    [ "$integration_exit_status" -ne 0 ] || integration_exit_status=1
  fi
  if ! release_integration_lock; then
    [ "$integration_exit_status" -ne 0 ] || integration_exit_status=1
  fi
  exit "$integration_exit_status"
}

trap cleanup_integration_on_exit EXIT
trap 'exit 130' HUP INT TERM
sandbox=$(mktemp -d "$temporary_parent/nas-platform-integration.XXXXXX")
chmod 0700 "$sandbox"
sandbox_host_owner_uid=$(id -u)
ruby -e '
  sandbox = File.stat(ARGV.fetch(0))
  expected_uid = Integer(ARGV.fetch(1), 10)
  abort "integration sandbox owner differs" unless sandbox.uid == expected_uid
  abort "integration sandbox mode differs" unless (sandbox.mode & 0o777) == 0o700
' "$sandbox" "$sandbox_host_owner_uid"
integration_project_namespace=$(derive_integration_project_namespace "$sandbox")

mkdir -p "$sandbox/volume1/Docker" "$sandbox/volume2" "$sandbox/repo" \
  "$sandbox/fixtures" "$sandbox/reports" \
  "$sandbox/private/var/folders/path fixture"
# Only the two directories bind-mounted for arbitrary service fixture UIDs are
# writable across identities. The namespace root remains owner-only, so other
# host users cannot traverse or rename any validated child.
chmod 0777 "$sandbox/fixtures" "$sandbox/reports"
ln -s "$sandbox/private/var" "$sandbox/var"

# Keep the real-service root genuinely fresh. Stale replacement and manifest
# merge behavior use separate roots below so neither scenario masks the other.
expected_release_id=$(git -C "$repo_dir" rev-parse HEAD)
active_release_dir="$sandbox/volume1/Docker/nas-platform/releases/$expected_release_id"
test ! -e "$sandbox/volume1/Docker/nas-platform"

# Deliberately stale deployment state, including both legacy `current` content
# and an inactive same-SHA release. Convergence must replace all of it without
# giving the full service lane a pre-existing deployment root.
stale_docker_root="$sandbox/stale-root/Docker"
stale_deploy_root="$stale_docker_root/nas-platform"
stale_release_dir="$stale_deploy_root/releases/$expected_release_id"
mkdir -p "$stale_deploy_root/current/services/ntfy" \
  "$stale_release_dir/services/ntfy" \
  "$stale_release_dir/services/undeclared"
printf '%s\n' legacy-current-compose > \
  "$stale_deploy_root/current/services/ntfy/compose.yml"
printf '%s\n' stale-same-sha-compose > \
  "$stale_release_dir/services/ntfy/compose.yml"
# A platform override the integration bundle never renders: the run deploys the
# canonical and integration files, so a Mac override left in the release is
# target-only content that convergence must delete.
printf '%s\n' target-only-override > \
  "$stale_release_dir/services/ntfy/compose.mac.yml"
printf '%s\n' undeclared-service > \
  "$stale_release_dir/services/undeclared/compose.yml"

# A minimal committed controller checkout proves canonical+platform image merge
# behavior through the actual deployment role and manifest template. It is not
# part of the production service inventory and its override cannot be consumed
# by the real service deployment.
manifest_controller="$sandbox/manifest-controller"
manifest_docker_root="$sandbox/manifest-root/Docker"
manifest_media_root="$sandbox/manifest-root/media"
mkdir -p "$manifest_controller/config" "$manifest_controller/roles" \
  "$manifest_controller/services/demo" \
  "$manifest_docker_root" "$manifest_media_root"
cp "$repo_dir/config/media-acquisition.yml" \
  "$manifest_controller/config/media-acquisition.yml"
cp -R "$repo_dir/roles/deployment_bundle" "$manifest_controller/roles/"
mkdir -p "$manifest_controller/services/dozzle" "$manifest_controller/services/immich"
cp "$repo_dir/services/dozzle/alert_relay.py" \
  "$manifest_controller/services/dozzle/alert_relay.py"
cp "$repo_dir/services/immich/classify_restore.py" \
  "$manifest_controller/services/immich/classify_restore.py"
cat > "$manifest_controller/services/manifest.yml" <<'EOF'
---
services:
  - name: demo
    role: demo
    status: implemented
EOF
cat > "$manifest_controller/services/demo/compose.yml" <<'EOF'
---
services:
  app:
    image: example.invalid/app:1@sha256:1111111111111111111111111111111111111111111111111111111111111111
  retained:
    image: example.invalid/retained:1@sha256:2222222222222222222222222222222222222222222222222222222222222222
EOF
cat > "$manifest_controller/services/demo/compose.fixture.yml" <<'EOF'
---
services:
  app:
    image: example.invalid/app:2@sha256:3333333333333333333333333333333333333333333333333333333333333333
  added:
    image: example.invalid/added:1@sha256:4444444444444444444444444444444444444444444444444444444444444444
EOF
cat > "$manifest_controller/manifest-fixture.yml" <<'EOF'
---
- name: Deploy an isolated manifest merge fixture
  hosts: localhost
  connection: local
  gather_facts: true
  pre_tasks:
    - name: Validate isolated controller checkout
      ansible.builtin.include_role:
        name: deployment_bundle
        tasks_from: controller
  roles:
    - role: deployment_bundle
  vars:
    platform_kind: nas
    platform_compose_kind: fixture
    deployment_bundle_test_mode: true
    platform_deploy_root: "{{ nas_docker_root }}/nas-platform"
    platform_release_dir: "{{ platform_deploy_root }}/releases/{{ platform_release_id }}"
    platform_current_dir: "{{ platform_deploy_root }}/current"
    platform_runtime_dir: "{{ platform_deploy_root }}/runtime"
EOF
git -C "$manifest_controller" init -q
git -C "$manifest_controller" config user.name 'NAS platform integration'
git -C "$manifest_controller" config user.email 'integration@example.invalid'
git -C "$manifest_controller" add .
git -C "$manifest_controller" commit -qm 'isolated manifest fixture'
manifest_fixture_sha=$(git -C "$manifest_controller" rev-parse HEAD)

create_controller_symlink_fixture() {
  fixture_name=$1
  symlink_kind=$2
  fixture_root="$sandbox/controller-$fixture_name"
  outside_root="$sandbox/controller-$fixture_name-outside"
  mkdir -p "$fixture_root/config" "$fixture_root/roles" \
    "$fixture_root/services/demo" "$outside_root"
  cp "$repo_dir/config/media-acquisition.yml" \
    "$fixture_root/config/media-acquisition.yml"
  cp -R "$repo_dir/roles/deployment_bundle" "$fixture_root/roles/"

  if [ "$symlink_kind" = manifest ]; then
    cat > "$outside_root/manifest.yml" <<'EOF'
---
services:
  - name: demo
    role: demo
    status: implemented
EOF
    ln -s "$outside_root/manifest.yml" "$fixture_root/services/manifest.yml"
  else
    cat > "$fixture_root/services/manifest.yml" <<'EOF'
---
services:
  - name: demo
    role: demo
    status: implemented
EOF
  fi

  cat > "$fixture_root/services/demo/compose.yml" <<'EOF'
---
services:
  demo:
    image: example.invalid/demo:1@sha256:5555555555555555555555555555555555555555555555555555555555555555
EOF
  if [ "$symlink_kind" = override ]; then
    cat > "$outside_root/compose.fixture.yml" <<'EOF'
---
services:
  demo:
    devices: [/dev/null:/dev/null]
EOF
    ln -s "$outside_root/compose.fixture.yml" \
      "$fixture_root/services/demo/compose.fixture.yml"
  fi

  cat > "$fixture_root/controller-input-test.yml" <<EOF
---
- name: Refuse unsafe controller inputs before target mutation
  hosts: localhost
  connection: local
  gather_facts: true
  pre_tasks:
    - name: Validate controller checkout cleanliness
      ansible.builtin.include_role:
        name: deployment_bundle
        tasks_from: controller
    - name: Validate controller input identity
      ansible.builtin.include_role:
        name: deployment_bundle
        tasks_from: inputs
  tasks:
    - name: Mutate target after validation
      ansible.builtin.copy:
        content: mutated
        dest: $sandbox/controller-$fixture_name-target
        mode: "0600"
  vars:
    platform_kind: nas
    platform_compose_kind: fixture
    deployment_bundle_test_mode: true
EOF
  git -C "$fixture_root" init -q
  git -C "$fixture_root" config user.name 'NAS platform integration'
  git -C "$fixture_root" config user.email 'integration@example.invalid'
  git -C "$fixture_root" add .
  git -C "$fixture_root" commit -qm "committed $symlink_kind symlink fixture"
  printf '%s\n' mutated-after-commit >> "$outside_root"/*
}

create_controller_symlink_fixture manifest manifest
create_controller_symlink_fixture override override

# Always give the container an isolated checkout at the same HEAD, then overlay
# the working files so integration-only dirty-controller tests retain their
# exact meaning. The isolated copy is also the only place where CI replaces the
# committed deployment vault with its generated ephemeral fixture.
controller_mount=$sandbox/repo
git clone --quiet --no-local --no-checkout "$repo_dir" "$controller_mount"
git -C "$controller_mount" checkout -q --detach "$expected_release_id"
tar -C "$repo_dir" -cf - --exclude .git . | tar -C "$controller_mount" -xf -

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

printf 'sandbox: %s\n' "$sandbox"

# Services reach one another across published host ports, so they need an address
# for the daemon's host that resolves inside a container. Docker Desktop supplies
# host.docker.internal; a Linux daemon does not, and the service containers are
# started by Compose rather than by this script, so they cannot be given the name
# through --add-host. Use the default bridge gateway there, which every container
# can route to and which the published ports listen on.
if docker info --format '{{.OperatingSystem}}' 2>/dev/null | grep -qi 'docker desktop'; then
  nas_address=host.docker.internal
else
  nas_address=$(docker network inspect bridge \
    --format '{{ (index .IPAM.Config 0).Gateway }}') ||
    { printf 'could not resolve the Docker host address\n' >&2; exit 1; }
  [ -n "$nas_address" ] ||
    { printf 'Docker host address resolved empty\n' >&2; exit 1; }
fi
printf 'host address: %s\n' "$nas_address"

# Ahead of the fixture seeding and the controller container, so every registry
# read the run makes happens under the retry rather than half of them.
prepull_images

paperless_fixture_preseeded=false
komga_fixture_preseeded=false
jellyfin_fixture_preseeded=false
case "$suite:$run_service_scenarios" in
  audiobookshelf:true|arr:true|downloaders:true|bindery:true|\
  trailarr:true|seerr:true|full:true)
    env \
      PLATFORM_MEDIA_ROOT="$sandbox/volume2" \
      PLATFORM_REPORT_ROOT="$sandbox/reports" \
      PLATFORM_AUDIOBOOKSHELF_PORT=13378 \
      "$repo_dir/tests/contracts/audiobookshelf.sh" seed-fixture-only
    ;;
esac
case "$suite:$run_service_scenarios" in
  paperless:true|full:true)
    env \
      PLATFORM_MEDIA_ROOT="$sandbox/volume2" \
      PLATFORM_REPORT_ROOT="$sandbox/reports" \
      PLATFORM_PAPERLESS_PORT=8000 \
      "$repo_dir/tests/contracts/paperless.sh" seed-fixture-only
    paperless_fixture_preseeded=true
    ;;
esac
case "$suite:$run_service_scenarios" in
  komga:true|full:true)
    env \
      PLATFORM_MEDIA_ROOT="$sandbox/volume2" \
      PLATFORM_REPORT_ROOT="$sandbox/reports" \
      "$repo_dir/tests/contracts/komga.sh" seed-fixture-only
    komga_fixture_preseeded=true
    ;;
esac
case "$suite:$run_service_scenarios" in
  jellyfin:true|arr:true|downloaders:true|bindery:true|\
  trailarr:true|seerr:true|full:true)
    env \
      PLATFORM_KIND=integration \
      PLATFORM_DOCKER_ROOT="$sandbox/volume1/Docker" \
      PLATFORM_MEDIA_ROOT="$sandbox/volume2" \
      PLATFORM_REPORT_ROOT="$sandbox/reports" \
      "$repo_dir/tests/contracts/jellyfin.sh" seed-fixture-only
    jellyfin_fixture_preseeded=true
    ;;
esac

docker run --rm \
  --network host \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$controller_mount":/repo \
  `# Mounted at its own path so the storage roots resolve identically inside` \
  `# this container and on the Docker daemon's host.` \
  -v "$sandbox":"$sandbox" \
  -e ANSIBLE_CONFIG=/repo/ansible.cfg \
  -e PLATFORM_NAS_ADDRESS="$nas_address" \
  `# The sandbox reaches published services at the same address it is` \
  `# administered through, so the two coordinates coincide here. Stated` \
  `# explicitly because the inventory no longer infers one from the other.` \
  -e PLATFORM_PUBLIC_HOST="$nas_address" \
  -e INTEGRATION_SUITE="$suite" \
  -e INTEGRATION_TAGS="$suite_tags" \
  -e INTEGRATION_RUN_SERVICE_SCENARIOS="$run_service_scenarios" \
  -e MEDIA_CONTROL_COLLISION_IMAGE="$runner_image" \
  -e PLATFORM_PAPERLESS_FIXTURE_PRESEEDED="$paperless_fixture_preseeded" \
  -e PLATFORM_KOMGA_FIXTURE_PRESEEDED="$komga_fixture_preseeded" \
  -e PLATFORM_JELLYFIN_FIXTURE_PRESEEDED="$jellyfin_fixture_preseeded" \
  -w /repo \
  "$runner_image" \
  sh -eu -c "
    apk add --no-cache --quiet docker-cli docker-cli-compose git tar openssl \
      apache2-utils openssh-client '$ruby_package' '$curl_package' >/dev/null
    pip install --quiet --no-input 'ansible-core==$ansible_core_version' \
      'requests==$requests_version'
    ansible-galaxy collection install -r /repo/requirements.yml >/dev/null

    # This container runs as root while the sandbox belongs to whoever started
    # the harness, so git refuses to read the controller checkout as a dubious
    # ownership. Docker Desktop hides this by remapping ownership; a Linux CI
    # runner does not. The exception is scoped to this throwaway container and
    # never reaches the caller's git configuration.
    git config --global --add safe.directory '*'

    suite_is() {
      [ "\$INTEGRATION_SUITE" = full ] || [ "\$INTEGRATION_SUITE" = "\$1" ]
    }

    playbook=\$1
    shift

    vault_directory='$sandbox/nas-platform-vault.000000'
    vault_file=\"\$vault_directory/vault.yml\"
    vault_password_file=\"\$vault_directory/password\"
    mkdir \"\$vault_directory\"
    chmod 0700 \"\$vault_directory\"
    TMPDIR='$sandbox' /repo/tests/generate-ephemeral-vault.sh \
      --output \"\$vault_file\" --password-file \"\$vault_password_file\"

    fixture_input_directory='$sandbox/protected-inputs'
    fixture_vars_file=\"\$fixture_input_directory/immich-fixture-vars.yml\"
    fixture_vault_view=\"\$fixture_input_directory/.immich-vault-view.yml\"
    mkdir \"\$fixture_input_directory\"
    chmod 0700 \"\$fixture_input_directory\"
    cleanup_fixture_vault_view() {
      rm -f \"\$fixture_vault_view\"
    }
    trap cleanup_fixture_vault_view EXIT
    umask 077
    ANSIBLE_VAULT_PASSWORD_FILE=\"\$vault_password_file\" ansible-vault view \
      \"\$vault_file\" > \"\$fixture_vault_view\"
    install -m 0600 /dev/null \"\$fixture_vars_file\"
    ruby /repo/tests/mac/generate-immich-fixture-vars.rb \
      \"\$fixture_vars_file\" /repo/inventory/group_vars/all/main.yml \
      < \"\$fixture_vault_view\"
    chmod 0600 \"\$fixture_vars_file\"
    rm -f \"\$fixture_vault_view\"

    cleanup_vault() {
      TMPDIR='$sandbox' /repo/tests/generate-ephemeral-vault.sh --cleanup \
        \"\$vault_directory\"
    }

    test -f /repo/inventory/group_vars/all/vault.yml
    test ! -L /repo/inventory/group_vars/all/vault.yml
    install -m 0600 \"\$vault_file\" /repo/inventory/group_vars/all/vault.yml
    export ANSIBLE_VAULT_PASSWORD_FILE=\"\$vault_password_file\"

    if suite_is foundation; then
    PLATFORM_DOCKER_ROOT='$sandbox/var/folders/path fixture/missing/Docker' \
    PLATFORM_MEDIA_ROOT='$sandbox/var/folders/path fixture/missing/media' \
    EXPECTED_PLATFORM_DOCKER_ROOT='$sandbox/private/var/folders/path fixture/missing/Docker' \
    EXPECTED_PLATFORM_MEDIA_ROOT='$sandbox/private/var/folders/path fixture/missing/media' \
      ansible-playbook -i inventory/mac.yml tests/mac_inventory_path_test.yml
    printf 'MAC_PATH_CANONICAL\n'

    if PLATFORM_DOCKER_ROOT='$sandbox/var/folders/path fixture/../escape/Docker' \
       PLATFORM_MEDIA_ROOT='$sandbox/var/folders/path fixture/missing/media' \
       EXPECTED_PLATFORM_DOCKER_ROOT='$sandbox/private/var/folders/escape/Docker' \
       EXPECTED_PLATFORM_MEDIA_ROOT='$sandbox/private/var/folders/path fixture/missing/media' \
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
      -e platform_kind=nas -e platform_compose_kind=nas
    git -C '$controller_test_dir' checkout -q -- .

    printf '%s\n' untracked > '$controller_test_dir/services/untracked.yml'
    assert_dirty_refused DIRTY_UNTRACKED_REFUSED \
      'Controller checkout differs from Git HEAD' \
      -e platform_kind=nas -e platform_compose_kind=nas
    rm '$controller_test_dir/services/untracked.yml'

    printf '%s\n' dirty >> \
      '$controller_test_dir/roles/deployment_bundle/templates/manifest.yml.j2'
    assert_dirty_refused DIRTY_MANIFEST_TEMPLATE_REFUSED \
      'Controller checkout differs from Git HEAD' \
      -e platform_kind=nas -e platform_compose_kind=nas
    git -C '$controller_test_dir' checkout -q -- .

    printf '%s\n' '# dirty arbitrary controller file' >> '$controller_test_playbook'
    assert_dirty_refused DIRTY_ARBITRARY_CONTROLLER_FILE_REFUSED \
      'Controller checkout differs from Git HEAD' \
      -e platform_kind=nas -e platform_compose_kind=nas
    git -C '$controller_test_dir' checkout -q -- .

    printf '%s\n' dirty >> '$controller_test_dir/services/ntfy/compose.yml'
    assert_dirty_refused DIRTY_PRODUCTION_BYPASS_REFUSED \
      'requires explicit deployment_bundle_test_mode' \
      -e platform_kind=nas \
      -e platform_compose_kind=integration \
      -e deployment_bundle_allow_dirty_controller=true

    rm -f '$controller_test_target'
    if ! ansible-playbook -i localhost, '$controller_test_playbook' \
        -e platform_kind=nas \
        -e platform_compose_kind=integration \
        -e platform_beszel_agent_kind=portable \
        -e deployment_bundle_test_mode=true \
        -e deployment_bundle_allow_dirty_controller=true \
        >/tmp/dirty-controller-integration.txt 2>&1; then
      cat /tmp/dirty-controller-integration.txt >&2
      exit 1
    fi
    test -f '$controller_test_target'
    printf 'DIRTY_INTEGRATION_ACCEPTED\n'
    git -C '$controller_test_dir' checkout -q -- .
    fi

    integration_media_usenet_enabled=false
    integration_media_adopt_existing=false
    case "\$INTEGRATION_SUITE" in
      arr|downloaders)
        integration_media_usenet_enabled=true
        integration_media_adopt_existing=true
        ;;
    esac

    run_play() {
      ansible-playbook \
        -i inventory/local.yml \
        --vault-password-file \"\$vault_password_file\" \
        -e @\"\$vault_file\" \
        -e @\"\$fixture_vars_file\" \
        -e platform_vault_file=\"\$vault_file\" \
        -e nas_docker_root=$sandbox/volume1/Docker \
        -e nas_media_root=$sandbox/volume2 \
        -e platform_compose_kind=integration \
        -e platform_project_name=\"$integration_project_namespace\" \
        -e arr_platform_project_name=\"$integration_project_namespace\" \
        -e downloaders_platform_project_name=\"$integration_project_namespace\" \
        -e platform_beszel_agent_kind=portable \
        -e media_usenet_enabled="\$integration_media_usenet_enabled" \
        -e media_acquisition_adopt_existing_libraries="\$integration_media_adopt_existing" \
        -e deployment_bundle_test_mode=true \
        -e deployment_bundle_allow_dirty_controller=true \
        \"\$playbook\" \"\$@\"
    }

    enabled_idempotence_recap_is_clean() {
      idempotence_recap_file=\$1
      idempotence_escape=\$(printf '\033')
      sed \"s/\${idempotence_escape}\\[[0-9;]*[[:alpha:]]//g\" \
        \"\$idempotence_recap_file\" |
        awk '
          /^PLAY RECAP[[:space:]]+\*+[[:space:]]*$/ {
            recap_count++
            in_recap = 1
            next
          }
          in_recap && \$1 == \"nas\" && \$2 == \":\" {
            target_count++
            valid = 1
            delete seen
            delete value
            for (field = 3; field <= NF; field++) {
              parts = split(\$field, pair, \"=\")
              if (parts != 2 || pair[1] == \"\" || pair[2] !~ /^[0-9]+\$/) {
                valid = 0
                continue
              }
              if (seen[pair[1]]++) {
                valid = 0
              }
              value[pair[1]] = pair[2]
            }
            target_clean = valid &&
              seen[\"changed\"] == 1 && value[\"changed\"] == \"0\" &&
              seen[\"unreachable\"] == 1 && value[\"unreachable\"] == \"0\" &&
              seen[\"failed\"] == 1 && value[\"failed\"] == \"0\"
          }
          END {
            exit !(recap_count == 1 && target_count == 1 && target_clean)
          }
        '
    }

    run_enabled_idempotence() {
      idempotence_tags=\$1
      idempotence_output=/tmp/media-acquisition-idempotence.txt
      if ! run_play --tags "\$idempotence_tags" \
          >"\$idempotence_output" 2>&1; then
        cat "\$idempotence_output" >&2
        printf '%s\n' \
          'enabled media acquisition convergence did not complete' >&2
        exit 1
      fi
      if ! enabled_idempotence_recap_is_clean "\$idempotence_output"; then
        cat "\$idempotence_output" >&2
        printf '%s\n' \
          'enabled media acquisition convergence was not idempotent' >&2
        exit 1
      fi
    }

    run_beszel_contract() {
      env \
        PLATFORM_KIND=integration \
        PLATFORM_CONTRACT_VAULT_FILE=\"\$vault_file\" \
        PLATFORM_CONTRACT_VAULT_PASSWORD_FILE=\"\$vault_password_file\" \
        PLATFORM_DOCKER_ROOT='$sandbox/volume1/Docker' \
        PLATFORM_MEDIA_ROOT='$sandbox/volume2' \
        PLATFORM_FIXTURE_ROOT='$sandbox/fixtures' \
        PLATFORM_REPORT_ROOT='$sandbox/reports' \
        /repo/tests/contracts/beszel.sh \"\$1\"
    }

    run_dozzle_contract() {
      env \
        PLATFORM_KIND=integration \
        PLATFORM_CONTRACT_VAULT_FILE=\"\$vault_file\" \
        PLATFORM_CONTRACT_VAULT_PASSWORD_FILE=\"\$vault_password_file\" \
        PLATFORM_DOCKER_ROOT='$sandbox/volume1/Docker' \
        PLATFORM_MEDIA_ROOT='$sandbox/volume2' \
        PLATFORM_FIXTURE_ROOT='$sandbox/fixtures' \
        PLATFORM_REPORT_ROOT='$sandbox/reports' \
        /repo/tests/contracts/dozzle.sh \"\$@\"
    }

    run_audiobookshelf_contract() {
      env \
        PLATFORM_KIND=integration \
        PLATFORM_CONTRACT_VAULT_FILE=\"\$vault_file\" \
        PLATFORM_CONTRACT_VAULT_PASSWORD_FILE=\"\$vault_password_file\" \
        PLATFORM_DOCKER_ROOT='$sandbox/volume1/Docker' \
        PLATFORM_MEDIA_ROOT='$sandbox/volume2' \
        PLATFORM_FIXTURE_ROOT='$sandbox/fixtures' \
        PLATFORM_REPORT_ROOT='$sandbox/reports' \
        PLATFORM_AUDIOBOOKSHELF_PORT=13378 \
        PLATFORM_PROJECT_NAME=$integration_project_namespace \
        PLATFORM_AUDIOBOOKSHELF_CONTAINER=$integration_project_namespace-audiobookshelf \
        /repo/tests/contracts/audiobookshelf.sh \"\$@\"
    }

    run_komga_contract() {
      env \
        PLATFORM_KIND=integration \
        PLATFORM_CONTRACT_VAULT_FILE=\"\$vault_file\" \
        PLATFORM_CONTRACT_VAULT_PASSWORD_FILE=\"\$vault_password_file\" \
        PLATFORM_MEDIA_ROOT='$sandbox/volume2' \
        PLATFORM_REPORT_ROOT='$sandbox/reports' \
        PLATFORM_KOMGA_RUNTIME_CONTEXT=base \
        PLATFORM_PROJECT_NAME=$integration_project_namespace \
        /repo/tests/contracts/komga.sh \"\$@\"
    }

    run_kapowarr_contract() {
      env \
        PLATFORM_KIND=integration \
        PLATFORM_CONTRACT_VAULT_FILE=\"\$vault_file\" \
        PLATFORM_CONTRACT_VAULT_PASSWORD_FILE=\"\$vault_password_file\" \
        PLATFORM_DOCKER_ROOT='$sandbox/volume1/Docker' \
        PLATFORM_MEDIA_ROOT='$sandbox/volume2' \
        PLATFORM_REPORT_ROOT='$sandbox/reports' \
        PLATFORM_PROJECT_NAME=$integration_project_namespace \
        /repo/tests/contracts/kapowarr.sh \"\$@\"
    }

    run_pinchflat_contract() {
      env \
        PLATFORM_KIND=integration \
        PLATFORM_CONTRACT_VAULT_FILE=\"\$vault_file\" \
        PLATFORM_CONTRACT_VAULT_PASSWORD_FILE=\"\$vault_password_file\" \
        PLATFORM_DOCKER_ROOT='$sandbox/volume1/Docker' \
        PLATFORM_MEDIA_ROOT='$sandbox/volume2' \
        PLATFORM_REPORT_ROOT='$sandbox/reports' \
        PLATFORM_PROJECT_NAME=$integration_project_namespace \
        /repo/tests/contracts/pinchflat.sh \"\$@\"
    }

    run_jellyfin_contract() {
      env \
        PLATFORM_KIND=integration \
        PLATFORM_CONTRACT_VAULT_FILE=\"\$vault_file\" \
        PLATFORM_CONTRACT_VAULT_PASSWORD_FILE=\"\$vault_password_file\" \
        PLATFORM_DOCKER_ROOT='$sandbox/volume1/Docker' \
        PLATFORM_MEDIA_ROOT='$sandbox/volume2' \
        PLATFORM_REPORT_ROOT='$sandbox/reports' \
        PLATFORM_JELLYFIN_CONTAINER=$integration_project_namespace-jellyfin \
        /repo/tests/contracts/jellyfin.sh \"\$@\"
    }

    run_immich_contract() {
      env \
        PLATFORM_KIND=integration \
        PLATFORM_CONTRACT_VAULT_FILE=\"\$vault_file\" \
        PLATFORM_CONTRACT_VAULT_PASSWORD_FILE=\"\$vault_password_file\" \
        PLATFORM_DOCKER_ROOT='$sandbox/volume1/Docker' \
        PLATFORM_MEDIA_ROOT='$sandbox/volume2' \
        PLATFORM_FIXTURE_ROOT='$sandbox/fixtures' \
        PLATFORM_REPORT_ROOT='$sandbox/reports' \
        PLATFORM_MAC_FIXTURE_VARS_FILE=\"\$fixture_vars_file\" \
        PLATFORM_IMMICH_SERVER_CONTAINER=$integration_project_namespace-immich-server \
        PLATFORM_IMMICH_MACHINE_LEARNING_CONTAINER=$integration_project_namespace-immich-machine-learning \
        PLATFORM_IMMICH_REDIS_CONTAINER=$integration_project_namespace-immich-redis \
        PLATFORM_IMMICH_POSTGRES_CONTAINER=$integration_project_namespace-immich-postgres \
        /repo/tests/contracts/immich.sh \"\$@\"
    }

    run_immich_clean_restore() {
      immich_runtime='$sandbox/volume1/Docker/nas-platform/runtime/services/immich/.env'
      immich_release='$sandbox/volume1/Docker/nas-platform/current/services/immich'
      immich_postgres='$sandbox/volume1/Docker/immich/postgres'
      immich_quarantine='$sandbox/reports/immich-postgres-quarantine'
      immich_stale_redis_key=nas-platform-restore-stale
      test ! -e "\$immich_quarantine"
      redis_seed_result=\$(docker compose --project-name $integration_project_namespace-immich \
        --env-file "\$immich_runtime" \
        -f "\$immich_release/compose.yml" \
        -f "\$immich_release/compose.integration.yml" \
        exec -T redis redis-cli --raw set "\$immich_stale_redis_key" stale)
      test "\$redis_seed_result" = OK
      docker compose --project-name $integration_project_namespace-immich \
        --env-file "\$immich_runtime" \
        -f "\$immich_release/compose.yml" \
        -f "\$immich_release/compose.integration.yml" \
        stop immich-server immich-machine-learning database
      docker compose --project-name $integration_project_namespace-immich \
        --env-file "\$immich_runtime" \
        -f "\$immich_release/compose.yml" \
        -f "\$immich_release/compose.integration.yml" \
        rm -f database
      test -d "\$immich_postgres"
      test ! -L "\$immich_postgres"
      mv "\$immich_postgres" "\$immich_quarantine"
      mkdir -m 0755 "\$immich_postgres"

      run_play --tags immich
      redis_stale_count=\$(docker compose --project-name $integration_project_namespace-immich \
        --env-file "\$immich_runtime" \
        -f "\$immich_release/compose.yml" \
        -f "\$immich_release/compose.integration.yml" \
        exec -T redis redis-cli --raw exists "\$immich_stale_redis_key")
      test "\$redis_stale_count" = 0
      run_immich_contract clean-restore-assert
      test ! -e '$sandbox/volume1/Docker/immich/.restore-failed'

      # Piping into tee would hand the pipeline tee's status, and this shell has
      # no pipefail: a play that died would arrive at the recap grep below as if
      # it had merely printed nothing.
      immich_clean_restore_status=0
      run_play --tags immich >/tmp/immich-clean-restore-second.txt 2>&1 ||
        immich_clean_restore_status=\$?
      cat /tmp/immich-clean-restore-second.txt
      if [ \"\$immich_clean_restore_status\" -ne 0 ]; then
        printf 'IMMICH CLEAN RESTORE REPLAY FAILED: status %s\n' \
          \"\$immich_clean_restore_status\" >&2
        exit 1
      fi
      grep -qE 'changed=0 .*failed=0 ' /tmp/immich-clean-restore-second.txt
      run_immich_contract clean-restore-assert
      printf 'IMMICH_CLEAN_RESTORE_IDEMPOTENT\n'
    }

    run_immich_restore_negative_matrix() {
      immich_server_before=\$(docker inspect --format '{{.Id}}:{{.State.StartedAt}}' $integration_project_namespace-immich-server)
      immich_database_before=\$(docker inspect --format '{{.Id}}:{{.State.StartedAt}}' $integration_project_namespace-immich-postgres)

      # One root, and one bundle render for all five scenarios. Each scenario
      # already asserts its own storage sha is unchanged across its play, which is
      # the proof that no scenario mutates the tree, so a pristine root each time
      # only bought five more renders of the same bundle at 66s apiece.
      scenario_root='$sandbox/reports/immich-negative'
      test ! -e \"\$scenario_root\"
      mkdir -m 0755 \"\$scenario_root\"
      mkdir -m 0755 \"\$scenario_root/docker\" \"\$scenario_root/media\"

      run_play \
        -e nas_docker_root=\"\$scenario_root/docker\" \
        -e nas_media_root=\"\$scenario_root/media\" \
        -e platform_project_name=$integration_project_namespace-negative \
        --tags host_prep,deployment_bundle

      postgres_root=\"\$scenario_root/docker/immich/postgres\"
      originals_root=\"\$scenario_root/media/Immich/upload\"
      backup_root=\"\$scenario_root/media/Immich-backups/database\"
      marker=\"\$scenario_root/docker/immich/.restore-failed\"

      for scenario in no-backup corrupt-newest ambiguous-newest unsafe-permissions prior-marker; do
        # The fixtures are the only state that would carry between scenarios, and
        # each expected failure is derived from exactly them: a backup left behind
        # would make unsafe-permissions report ambiguous-newest-backup, and would
        # stop no-backup from ever seeing an empty directory.
        rm -rf \"\$backup_root\" \"\$marker\"
        mkdir -p \"\$postgres_root\" \"\$originals_root\" \"\$backup_root\"
        printf 'negative-matrix-original\n' > \"\$originals_root/asset.jpg\"
        expected_failure=

        case \$scenario in
          no-backup)
            expected_failure=missing-safe-backup
            ;;
          corrupt-newest)
            printf 'SELECT 1;\n' | gzip -c > \
              \"\$backup_root/immich-db-backup-20260814T010000-v3.1.0-pg14.19.sql.gz\"
            printf 'not-a-gzip-stream\n' > \
              \"\$backup_root/immich-db-backup-20260815T010000-v3.1.0-pg14.19.sql.gz\"
            expected_failure=unsafe-newest-backup
            ;;
          ambiguous-newest)
            printf 'SELECT 1;\n' | gzip -c > \
              \"\$backup_root/immich-db-backup-20260815T010000-v3.1.0-pg14.19.sql.gz\"
            printf 'SELECT 2;\n' | gzip -c > \
              \"\$backup_root/immich-db-backup-20260815T010000-v3.1.1-pg14.20.sql.gz\"
            expected_failure=ambiguous-newest-backup
            ;;
          unsafe-permissions)
            printf 'SELECT 1;\n' | gzip -c > \
              \"\$backup_root/immich-db-backup-20260815T010000-v3.1.0-pg14.19.sql.gz\"
            chmod 0666 \
              \"\$backup_root/immich-db-backup-20260815T010000-v3.1.0-pg14.19.sql.gz\"
            expected_failure=unsafe-newest-backup
            ;;
          prior-marker)
            printf '{\"version\":1,\"stage\":\"database-restore\"}\n' > \"\$marker\"
            chmod 0600 \"\$marker\"
            expected_failure=previous-failed-restore
            ;;
        esac

        storage_before=\$(tar -C \"\$scenario_root\" -cf - docker/immich media | sha256sum)
        output=/tmp/immich-negative-\$scenario.txt
        if run_play \
            -e nas_docker_root=\"\$scenario_root/docker\" \
            -e nas_media_root=\"\$scenario_root/media\" \
            -e platform_project_name=$integration_project_namespace-negative \
            --tags immich >\"\$output\" 2>&1; then
          cat \"\$output\" >&2
          printf 'IMMICH NEGATIVE RESTORE SCENARIO SUCCEEDED: %s\n' \"\$scenario\" >&2
          exit 1
        fi
        grep -qF \"\$expected_failure\" \"\$output\"
        if grep -qF \"\$scenario_root\" \"\$output\" || \
           grep -qF 'immich-db-backup-20260815T010000' \"\$output\" || \
           grep -qF 'TASK [immich : Restore and verify the Immich database]' \"\$output\" || \
           grep -qF 'TASK [immich : Deploy Immich]' \"\$output\" || \
           grep -qF 'TASK [immich : Create the vault Immich administrator]' \"\$output\"; then
          cat \"\$output\" >&2
          printf 'IMMICH NEGATIVE RESTORE BOUNDARY FAILED: %s\n' \"\$scenario\" >&2
          exit 1
        fi
        /repo/tests/assert-no-vault-secrets.rb \
          \"\$vault_file\" \"\$vault_password_file\" \"\$output\"
        storage_after=\$(tar -C \"\$scenario_root\" -cf - docker/immich media | sha256sum)
        test \"\$storage_after\" = \"\$storage_before\"
        test \"\$(docker inspect --format '{{.Id}}:{{.State.StartedAt}}' $integration_project_namespace-immich-server)\" = \
          \"\$immich_server_before\"
        test \"\$(docker inspect --format '{{.Id}}:{{.State.StartedAt}}' $integration_project_namespace-immich-postgres)\" = \
          \"\$immich_database_before\"
      done

      existing_backup='$sandbox/volume2/Immich-backups/database/'\
'immich-db-backup-20260816T010000-v3.1.0-pg14.19.sql.gz'
      existing_quarantine='$sandbox/reports/immich-existing-newer-backup.quarantine'
      test ! -e \"\$existing_backup\"
      test ! -e \"\$existing_quarantine\"
      printf 'newer-backup-must-not-be-read\n' > \"\$existing_backup\"
      existing_backup_before=\$(sha256sum \"\$existing_backup\")
      run_play --tags immich > /tmp/immich-existing-database-backup.txt 2>&1
      test \"\$(sha256sum \"\$existing_backup\")\" = \"\$existing_backup_before\"
      test ! -e '$sandbox/volume1/Docker/immich/.restore-failed'
      test \"\$(docker inspect --format '{{.Id}}:{{.State.StartedAt}}' $integration_project_namespace-immich-server)\" = \
        \"\$immich_server_before\"
      run_immich_contract clean-restore-assert
      mv \"\$existing_backup\" \"\$existing_quarantine\"
      printf 'IMMICH_EXISTING_DATABASE_BACKUP_IGNORED\n'

      run_immich_contract run
      printf 'IMMICH_NEGATIVE_RESTORE_MATRIX_OK\n'
    }

    run_paperless_contract() {
      env \
        PLATFORM_KIND=integration \
        PLATFORM_CONTRACT_VAULT_FILE=\"\$vault_file\" \
        PLATFORM_CONTRACT_VAULT_PASSWORD_FILE=\"\$vault_password_file\" \
        PLATFORM_DOCKER_ROOT='$sandbox/volume1/Docker' \
        PLATFORM_MEDIA_ROOT='$sandbox/volume2' \
        PLATFORM_REPORT_ROOT='$sandbox/reports' \
        PLATFORM_PAPERLESS_WEBSERVER_CONTAINER=$integration_project_namespace-paperless-webserver \
        /repo/tests/contracts/paperless.sh \"\$@\"
    }

    run_paperless_snapshot() {
      env \
        PLATFORM_KIND=integration \
        PLATFORM_CONTRACT_VAULT_FILE=\"\$vault_file\" \
        PLATFORM_CONTRACT_VAULT_PASSWORD_FILE=\"\$vault_password_file\" \
        PLATFORM_DOCKER_ROOT='$sandbox/volume1/Docker' \
        PLATFORM_MEDIA_ROOT='$sandbox/volume2' \
        PLATFORM_PAPERLESS_WEBSERVER_CONTAINER=$integration_project_namespace-paperless-webserver \
        PLATFORM_PAPERLESS_POSTGRES_CONTAINER=$integration_project_namespace-paperless-postgres \
        PLATFORM_PAPERLESS_REDIS_CONTAINER=$integration_project_namespace-paperless-redis \
        /repo/tests/mac/snapshot-paperless.sh \"\$@\"
    }

    run_verify_only() {
      PLATFORM_VAULT_FILE=\"\$vault_file\" ansible-playbook \
        -i inventory/local.yml \
        --vault-password-file \"\$vault_password_file\" \
        -e @\"\$vault_file\" \
        -e platform_vault_file=\"\$vault_file\" \
        -e nas_docker_root=$sandbox/volume1/Docker \
        -e nas_media_root=$sandbox/volume2 \
        -e platform_compose_kind=integration \
        -e platform_project_name=\"$integration_project_namespace\" \
        -e platform_beszel_agent_kind=portable \
        -e deployment_bundle_test_mode=true \
        -e deployment_bundle_allow_dirty_controller=true \
        /repo/verify.yml \
        --tags platform_verify_beszel
    }

    run_dozzle_verify_only() {
      PLATFORM_VAULT_FILE=\"\$vault_file\" ansible-playbook \
        -i inventory/local.yml \
        --vault-password-file \"\$vault_password_file\" \
        -e @\"\$vault_file\" \
        -e platform_vault_file=\"\$vault_file\" \
        -e nas_docker_root=$sandbox/volume1/Docker \
        -e nas_media_root=$sandbox/volume2 \
        -e platform_compose_kind=integration \
        -e platform_project_name=\"$integration_project_namespace\" \
        -e platform_beszel_agent_kind=portable \
        -e deployment_bundle_test_mode=true \
        -e deployment_bundle_allow_dirty_controller=true \
        /repo/verify.yml \
        --tags platform_verify_dozzle
    }

    run_audiobookshelf_verify_only() {
      PLATFORM_VAULT_FILE=\"\$vault_file\" ansible-playbook \
        -i inventory/local.yml \
        --vault-password-file \"\$vault_password_file\" \
        -e @\"\$vault_file\" \
        -e platform_vault_file=\"\$vault_file\" \
        -e nas_docker_root=$sandbox/volume1/Docker \
        -e nas_media_root=$sandbox/volume2 \
        -e platform_compose_kind=integration \
        -e platform_project_name=\"$integration_project_namespace\" \
        -e platform_beszel_agent_kind=portable \
        -e deployment_bundle_test_mode=true \
        -e deployment_bundle_allow_dirty_controller=true \
        /repo/verify.yml \
        --tags platform_verify_audiobookshelf
    }

    run_arr_verify_only() {
      PLATFORM_VAULT_FILE="\$vault_file" ansible-playbook \
        -i inventory/local.yml \
        --vault-password-file "\$vault_password_file" \
        -e @"\$vault_file" \
        -e platform_vault_file="\$vault_file" \
        -e nas_docker_root=$sandbox/volume1/Docker \
        -e nas_media_root=$sandbox/volume2 \
        -e platform_compose_kind=integration \
        -e platform_project_name=\"$integration_project_namespace\" \
        -e platform_beszel_agent_kind=portable \
        -e deployment_bundle_test_mode=true \
        -e deployment_bundle_allow_dirty_controller=true \
        -e media_usenet_enabled=true \
        /repo/verify.yml \
        --tags platform_verify_arr
    }

    run_downloaders_verify_only() {
      PLATFORM_VAULT_FILE="\$vault_file" ansible-playbook \
        -i inventory/local.yml \
        --vault-password-file "\$vault_password_file" \
        -e @"\$vault_file" \
        -e platform_vault_file="\$vault_file" \
        -e nas_docker_root=$sandbox/volume1/Docker \
        -e nas_media_root=$sandbox/volume2 \
        -e platform_compose_kind=integration \
        -e platform_project_name=\"$integration_project_namespace\" \
        -e platform_beszel_agent_kind=portable \
        -e deployment_bundle_test_mode=true \
        -e deployment_bundle_allow_dirty_controller=true \
        -e media_usenet_enabled=true \
        /repo/verify.yml \
        --tags platform_verify_downloaders
    }

    run_kapowarr_verify_only() {
      PLATFORM_VAULT_FILE="\$vault_file" ansible-playbook \
        -i inventory/local.yml \
        --vault-password-file "\$vault_password_file" \
        -e @"\$vault_file" \
        -e platform_vault_file="\$vault_file" \
        -e nas_docker_root=$sandbox/volume1/Docker \
        -e nas_media_root=$sandbox/volume2 \
        -e platform_compose_kind=integration \
        -e platform_project_name=\"$integration_project_namespace\" \
        -e platform_beszel_agent_kind=portable \
        -e deployment_bundle_test_mode=true \
        -e deployment_bundle_allow_dirty_controller=true \
        /repo/verify.yml \
        --tags platform_verify_kapowarr
    }

    run_pinchflat_verify_only() {
      PLATFORM_VAULT_FILE="\$vault_file" ansible-playbook \
        -i inventory/local.yml \
        --vault-password-file "\$vault_password_file" \
        -e @"\$vault_file" \
        -e platform_vault_file="\$vault_file" \
        -e nas_docker_root=$sandbox/volume1/Docker \
        -e nas_media_root=$sandbox/volume2 \
        -e platform_compose_kind=integration \
        -e platform_project_name=\"$integration_project_namespace\" \
        -e platform_beszel_agent_kind=portable \
        -e deployment_bundle_test_mode=true \
        -e deployment_bundle_allow_dirty_controller=true \
        /repo/verify.yml \
        --tags platform_verify_pinchflat
    }

    converge_media_acquisition_reader_prerequisites() {
      run_play --tags host_prep,deployment_bundle,ntfy,audiobookshelf,jellyfin
    }

    run_media_acquisition_foundation_verify() {
      PLATFORM_VAULT_FILE="\$vault_file" ansible-playbook \
        -i inventory/local.yml \
        --vault-password-file "\$vault_password_file" \
        -e @"\$vault_file" \
        -e platform_vault_file="\$vault_file" \
        -e nas_docker_root=$sandbox/volume1/Docker \
        -e nas_media_root=$sandbox/volume2 \
        -e platform_compose_kind=integration \
        -e platform_project_name=\"$integration_project_namespace\" \
        -e platform_beszel_agent_kind=portable \
        -e deployment_bundle_test_mode=true \
        -e deployment_bundle_allow_dirty_controller=true \
        /repo/verify.yml \
        --tags platform_verify_media_acquisition_foundation
    }

    assert_controller_symlink_refused() {
      evidence=\$1
      fixture_name=\$2
      expected_path=\$3
      expected_reason=\$4
      fixture_root='$sandbox/controller-'\$fixture_name
      outside_root='$sandbox/controller-'\$fixture_name'-outside'
      target='$sandbox/controller-'\$fixture_name'-target'
      expected_refusal=\"Unsafe controller bundle input \$fixture_root/\$expected_path: \$expected_reason\"
      before_outside=\$(tar -C \"\$outside_root\" -cf - . | sha256sum | cut -d' ' -f1)
      rm -f \"\$target\"

      if ansible-playbook -i localhost, \
          \"\$fixture_root/controller-input-test.yml\" \
          >/tmp/controller-input-refusal.txt 2>&1; then
        cat /tmp/controller-input-refusal.txt >&2
        printf 'UNSAFE CONTROLLER INPUT ACCEPTED: %s\n' \"\$evidence\" >&2
        exit 1
      fi
      if ! grep -qF \"\$expected_refusal\" /tmp/controller-input-refusal.txt || \
         [ -e \"\$target\" ] || \
         [ \"\$(tar -C \"\$outside_root\" -cf - . | sha256sum | cut -d' ' -f1)\" != \
           \"\$before_outside\" ]; then
        cat /tmp/controller-input-refusal.txt >&2
        printf 'CONTROLLER INPUT REFUSAL MUTATED STATE: %s\n' \"\$evidence\" >&2
        exit 1
      fi
      printf '%s\n' \"\$evidence\"
      printf 'CONTROLLER_SYMLINK_TARGET_UNCHANGED\n'
    }

    if suite_is foundation; then
    assert_controller_symlink_refused CONTROLLER_MANIFEST_SYMLINK_REFUSED \
      manifest services/manifest.yml 'must be a regular non-symlink file'
    assert_controller_symlink_refused CONTROLLER_OVERRIDE_SYMLINK_REFUSED \
      override services/demo/compose.fixture.yml 'must be a regular non-symlink file'

    assert_symlink_refused() {
      evidence=\$1
      docker_root=\$2
      guarded_link=\$3
      outside_root=\$4
      pointer_path=\$docker_root/nas-platform/current
      target_marker=\$docker_root/nas-platform/target-mutated
      before_outside=\$(tar -C \"\$outside_root\" -cf - . | sha256sum | cut -d' ' -f1)
      before_guard=\$(readlink \"\$guarded_link\")
      before_pointer=absent
      if [ -L \"\$pointer_path\" ]; then
        before_pointer=\$(readlink \"\$pointer_path\")
      fi

      if run_play -e nas_docker_root=\"\$docker_root\" --tags preflight \
          >/tmp/symlink-refusal.txt 2>&1; then
        cat /tmp/symlink-refusal.txt >&2
        printf 'SYMLINK ESCAPE ACCEPTED: %s\n' \"\$evidence\" >&2
        exit 1
      fi
      if ! grep -qF 'Unsafe deployment target' /tmp/symlink-refusal.txt; then
        cat /tmp/symlink-refusal.txt >&2
        printf 'SYMLINK ESCAPE FAILED FOR WRONG REASON: %s\n' \"\$evidence\" >&2
        exit 1
      fi

      after_outside=\$(tar -C \"\$outside_root\" -cf - . | sha256sum | cut -d' ' -f1)
      after_pointer=absent
      if [ -L \"\$pointer_path\" ]; then
        after_pointer=\$(readlink \"\$pointer_path\")
      fi
      if [ \"\$before_outside\" != \"\$after_outside\" ] || \
         [ \"\$(readlink \"\$guarded_link\")\" != \"\$before_guard\" ] || \
         [ \"\$before_pointer\" != \"\$after_pointer\" ] || \
         [ -e \"\$target_marker\" ]; then
        printf 'SYMLINK ESCAPE MUTATED STATE: %s\n' \"\$evidence\" >&2
        exit 1
      fi
      printf '%s\n' \"\$evidence\"
      printf 'SYMLINK_ESCAPE_STATE_UNCHANGED\n'
    }

    old_release=0000000000000000000000000000000000000001

    docker_link='$sandbox/symlink-docker-root'
    docker_outside='$sandbox/symlink-outside/docker-root'
    mkdir -p \"\$docker_outside/nas-platform/releases/\$old_release\"
    ln -s \"\$docker_outside/nas-platform/releases/\$old_release\" \
      \"\$docker_outside/nas-platform/current\"
    printf sentinel > \"\$docker_outside/sentinel\"
    ln -s \"\$docker_outside\" \"\$docker_link\"
    assert_symlink_refused SYMLINK_DOCKER_ROOT_REFUSED \
      \"\$docker_link\" \"\$docker_link\" \"\$docker_outside\"

    deploy_root='$sandbox/symlink-deploy/Docker'
    deploy_outside='$sandbox/symlink-outside/deploy-root'
    mkdir -p \"\$deploy_root\" \"\$deploy_outside/releases/\$old_release\"
    ln -s \"\$deploy_outside/releases/\$old_release\" \"\$deploy_outside/current\"
    printf sentinel > \"\$deploy_outside/sentinel\"
    ln -s \"\$deploy_outside\" \"\$deploy_root/nas-platform\"
    assert_symlink_refused SYMLINK_DEPLOY_ROOT_REFUSED \
      \"\$deploy_root\" \"\$deploy_root/nas-platform\" \"\$deploy_outside\"

    releases_root='$sandbox/symlink-releases/Docker'
    releases_outside='$sandbox/symlink-outside/releases-root'
    mkdir -p \"\$releases_root/nas-platform\" \"\$releases_outside/\$old_release\"
    printf sentinel > \"\$releases_outside/sentinel\"
    ln -s \"\$releases_outside\" \"\$releases_root/nas-platform/releases\"
    ln -s \"\$releases_root/nas-platform/releases/\$old_release\" \
      \"\$releases_root/nas-platform/current\"
    assert_symlink_refused SYMLINK_RELEASES_REFUSED \
      \"\$releases_root\" \"\$releases_root/nas-platform/releases\" \"\$releases_outside\"

    runtime_root='$sandbox/symlink-runtime/Docker'
    runtime_outside='$sandbox/symlink-outside/runtime-root'
    mkdir -p \"\$runtime_root/nas-platform/releases/\$old_release\" \"\$runtime_outside\"
    printf sentinel > \"\$runtime_outside/sentinel\"
    ln -s \"\$runtime_outside\" \"\$runtime_root/nas-platform/runtime\"
    ln -s \"\$runtime_root/nas-platform/releases/\$old_release\" \
      \"\$runtime_root/nas-platform/current\"
    assert_symlink_refused SYMLINK_RUNTIME_REFUSED \
      \"\$runtime_root\" \"\$runtime_root/nas-platform/runtime\" \"\$runtime_outside\"

    runtime_service_root='$sandbox/symlink-runtime-service/Docker'
    runtime_service_outside='$sandbox/symlink-outside/runtime-service'
    runtime_service_link=\"\$runtime_service_root/nas-platform/runtime/services/ntfy\"
    runtime_service_pointer=\"\$runtime_service_root/nas-platform/current\"
    mkdir -p \"\$runtime_service_root/nas-platform/runtime/services\" \
      \"\$runtime_service_root/nas-platform/releases/\$old_release\" \
      \"\$runtime_service_outside\"
    chmod 0700 \"\$runtime_service_outside\"
    printf sentinel > \"\$runtime_service_outside/user-data\"
    ln -s \"\$runtime_service_outside\" \"\$runtime_service_link\"
    ln -s \"\$runtime_service_root/nas-platform/releases/\$old_release\" \
      \"\$runtime_service_pointer\"
    runtime_service_checksum=\$(sha256sum \"\$runtime_service_outside/user-data\" | cut -d' ' -f1)
    runtime_service_pointer_before=\$(readlink \"\$runtime_service_pointer\")
    if run_play -e nas_docker_root=\"\$runtime_service_root\" --tags deployment_bundle \
        >/tmp/runtime-service-symlink.txt 2>&1; then
      cat /tmp/runtime-service-symlink.txt >&2
      printf 'RUNTIME SERVICE SYMLINK ACCEPTED\n' >&2
      exit 1
    fi
    if ! grep -qF 'Unsafe deployment target' /tmp/runtime-service-symlink.txt || \
       [ \"\$(readlink \"\$runtime_service_link\")\" != \"\$runtime_service_outside\" ] || \
       [ \"\$(stat -c %a \"\$runtime_service_outside\")\" != 700 ] || \
       [ \"\$(sha256sum \"\$runtime_service_outside/user-data\" | cut -d' ' -f1)\" != \
         \"\$runtime_service_checksum\" ] || \
       [ \"\$(readlink \"\$runtime_service_pointer\")\" != \
         \"\$runtime_service_pointer_before\" ]; then
      cat /tmp/runtime-service-symlink.txt >&2
      printf 'RUNTIME SERVICE SYMLINK MUTATED STATE\n' >&2
      exit 1
    fi
    printf 'RUNTIME_SERVICE_SYMLINK_REFUSED\n'
    printf 'RUNTIME_SERVICE_SYMLINK_PRESERVED\n'

    ancestor_parent='$sandbox/symlink-ancestor'
    ancestor_outside='$sandbox/symlink-outside/root-ancestor'
    mkdir -p \"\$ancestor_parent\" \
      \"\$ancestor_outside/Docker/nas-platform/releases/\$old_release\"
    printf sentinel > \"\$ancestor_outside/sentinel\"
    ln -s \"\$ancestor_outside/Docker/nas-platform/releases/\$old_release\" \
      \"\$ancestor_outside/Docker/nas-platform/current\"
    ln -s \"\$ancestor_outside\" \"\$ancestor_parent/link\"
    assert_symlink_refused SYMLINK_ROOT_ANCESTOR_REFUSED \
      \"\$ancestor_parent/link/Docker\" \"\$ancestor_parent/link\" \"\$ancestor_outside\"

    probe_root='$sandbox/symlink-probe/Docker'
    probe_outside='$sandbox/symlink-outside/probe-root'
    mkdir -p \"\$probe_root\" \"\$probe_outside/target\"
    printf sentinel > \"\$probe_outside/target/sentinel\"
    ln -s \"\$probe_outside/target\" \
      \"\$probe_root/.nas-platform-preflight-probe\"
    assert_symlink_refused SYMLINK_PREFLIGHT_PROBE_REFUSED \
      \"\$probe_root\" \"\$probe_root/.nas-platform-preflight-probe\" \"\$probe_outside\"

    existing_probe='$sandbox/volume1/Docker/.nas-platform-preflight-probe'
    mkdir -p \"\$existing_probe\"
    printf sentinel > \"\$existing_probe/user-data\"
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
    if [ \"\$(cat \"\$existing_probe/user-data\")\" != sentinel ]; then
      printf 'EXISTING PREFLIGHT PROBE CONTENT MUTATED\n' >&2
      exit 1
    fi
    printf 'EXISTING_PREFLIGHT_PROBE_PRESERVED\n'
    rm -rf \"\$existing_probe\"

    # An interrupted run leaves the probe directory behind empty. That is the
    # role's own debris, not pre-existing data, so preflight must reclaim it
    # instead of locking every later converge out of the deployment root.
    mkdir -p \"\$existing_probe\"
    if ! run_play --tags preflight >/tmp/interrupted-probe.txt 2>&1; then
      cat /tmp/interrupted-probe.txt >&2
      printf 'INTERRUPTED PREFLIGHT PROBE NOT RECLAIMED\n' >&2
      exit 1
    fi
    if [ -e \"\$existing_probe\" ]; then
      printf 'INTERRUPTED PREFLIGHT PROBE SURVIVED\n' >&2
      exit 1
    fi
    printf 'INTERRUPTED_PREFLIGHT_PROBE_RECLAIMED\n'

    if [ \"\$(cat '$stale_deploy_root/current/services/ntfy/compose.yml')\" = \
         legacy-current-compose ] && \
       [ \"\$(cat '$stale_release_dir/services/ntfy/compose.yml')\" = \
         stale-same-sha-compose ] && \
       [ -f '$stale_release_dir/services/ntfy/compose.mac.yml' ] && \
       [ -f '$stale_release_dir/services/undeclared/compose.yml' ]; then
      printf 'STALE_ROOT_SEEDED\n'
    else
      printf 'STALE ROOT FIXTURE INCOMPLETE\n' >&2
      exit 1
    fi

    run_play -e nas_docker_root='$stale_docker_root' --tags deployment_bundle
    stale_current='$stale_deploy_root/current'
    if [ ! -L \"\$stale_current\" ] || \
       [ \"\$(readlink \"\$stale_current\")\" != '$stale_release_dir' ] || \
       ! cmp -s /repo/services/ntfy/compose.yml \
         '$stale_release_dir/services/ntfy/compose.yml' || \
       [ \"\$(sha256sum /repo/services/ntfy/compose.yml | cut -d' ' -f1)\" != \
         \"\$(sha256sum '$stale_release_dir/services/ntfy/compose.yml' | cut -d' ' -f1)\" ]; then
      printf 'STALE BUNDLE WAS NOT REPLACED EXACTLY\n' >&2
      exit 1
    fi
    printf 'STALE_BUNDLE_REPLACED\n'
    if [ -e '$stale_release_dir/services/ntfy/compose.mac.yml' ] || \
       [ -e '$stale_release_dir/services/undeclared' ]; then
      printf 'STALE TARGET-ONLY CONTENT SURVIVED\n' >&2
      exit 1
    fi
    printf 'STALE_BUNDLE_CLEAN\n'
    ruby /repo/tests/verify_deployment_manifest.rb \
      '$stale_release_dir/manifest.yml' \
      /repo /repo/services/manifest.yml nas integration '$expected_release_id'
    printf 'STALE_MANIFEST_EXACT\n'

    ansible-playbook -i localhost, \
      '$manifest_controller/manifest-fixture.yml' \
      -e nas_docker_root='$manifest_docker_root' \
      -e nas_media_root='$manifest_media_root' \
      -e platform_release_id='$manifest_fixture_sha'
    ruby /repo/tests/verify_deployment_manifest.rb \
      '$manifest_docker_root/nas-platform/current/manifest.yml' \
      '$manifest_controller' '$manifest_controller/services/manifest.yml' \
      nas fixture '$manifest_fixture_sha' require-image-merge
    printf 'ISOLATED_IMAGE_MERGE_EXACT\n'

    # The preceding scenarios must not create or seed the real-service target.
    test ! -e '$sandbox/volume1/Docker/nas-platform'

    fi

    run_selected_play() {
      if [ -n "\$INTEGRATION_TAGS" ]; then
        run_play --tags \"\$INTEGRATION_TAGS\" \"\$@\"
      elif [ "\$#" -eq 0 ]; then
        run_play
      else
        run_play \"\$@\"
      fi
    }

    perform_initial_converge() {
      if [ -z "\$INTEGRATION_TAGS" ] && [ "\$#" -eq 0 ]; then
    run_play
      else
        run_selected_play "\$@"
      fi
    }

    if lifecycle_plan=\$(
      /repo/tests/integration.sh --consume-lifecycle --suite "\$INTEGRATION_SUITE"
    ); then
      :
    else
      lifecycle_status=\$?
      printf 'integration lifecycle validation failed with status %s\n' \
        "\$lifecycle_status" >&2
      exit "\$lifecycle_status"
    fi

    lifecycle_success=false
    while IFS= read -r lifecycle_event; do
      case \$lifecycle_event in
        converge)
          perform_initial_converge "\$@"
          integration_media_adopt_existing=false
          ;;
        success)
          lifecycle_success=true
          ;;
        *)
          printf 'unexpected integration lifecycle event: %s\n' \
            "\$lifecycle_event" >&2
          exit 1
          ;;
      esac
    done <<EOF
\$lifecycle_plan
EOF
    [ "\$lifecycle_success" = true ] || {
      printf '%s\n' 'integration lifecycle ended before success' >&2
      exit 1
    }
    printf 'FRESH_ROOT_OK: clean deployment root converged\n'

    if cmp -s \
      /repo/services/ntfy/compose.yml \
      '$sandbox/volume1/Docker/nas-platform/current/services/ntfy/compose.yml'; then
      printf 'BUNDLE OWNED: target compose matches controller source\n'
    else
      printf 'BUNDLE STALE: target compose does not match controller source\n' >&2
      exit 1
    fi

    ruby /repo/tests/verify_deployment_manifest.rb \
      '$sandbox/volume1/Docker/nas-platform/current/manifest.yml' \
      /repo /repo/services/manifest.yml nas integration '$expected_release_id'

    case "\$INTEGRATION_SUITE" in
      bindery|trailarr|seerr)
        /repo/tests/contracts/"\$INTEGRATION_SUITE"-foundation.sh static
        converge_media_acquisition_reader_prerequisites
        run_media_acquisition_foundation_verify
        printf 'MEDIA_ACQUISITION_FOUNDATION_RUNTIME_VERIFIED\n'
        cleanup_vault
        exit 0
        ;;
    esac

    if [ "\$INTEGRATION_SUITE" = arr ]; then
      /repo/tests/media_control_network_collision_test.sh live
      /repo/tests/contracts/arr.sh static
      run_arr_verify_only
      run_enabled_idempotence arr
      run_play --tags arr --check --diff
      printf 'ARR_PHASE1_RUNTIME_VERIFIED\n'
      cleanup_vault
      exit 0
    fi

    if [ "\$INTEGRATION_SUITE" = downloaders ]; then
      /repo/tests/contracts/arr.sh static
      /repo/tests/contracts/downloaders.sh static
      run_arr_verify_only
      run_downloaders_verify_only
      run_enabled_idempotence arr,downloaders
      run_play --tags arr,downloaders --check --diff
      printf 'DOWNLOADERS_PHASE1_RUNTIME_VERIFIED\n'
      cleanup_vault
      exit 0
    fi

    if [ "\$INTEGRATION_SUITE" = kapowarr ]; then
      /repo/tests/contracts/kapowarr.sh static
      run_kapowarr_contract run
      run_kapowarr_verify_only
      run_enabled_idempotence kapowarr
      run_play --tags kapowarr --check --diff
      printf 'KAPOWARR_PHASE2_RUNTIME_VERIFIED\n'
      cleanup_vault
      exit 0
    fi

    if [ "\$INTEGRATION_SUITE" = pinchflat ]; then
      /repo/tests/contracts/pinchflat.sh static
      run_pinchflat_contract run
      run_pinchflat_verify_only
      run_enabled_idempotence pinchflat
      run_play --tags pinchflat --check --diff
      printf 'PINCHFLAT_PHASE2_RUNTIME_VERIFIED\n'
      cleanup_vault
      exit 0
    fi

    if [ "\$INTEGRATION_SUITE" = smoke ]; then
      cleanup_vault
      exit 0
    fi

    # Bundle drift and symlink refusal are properties of deployment_bundle and of
    # the target validator in the always-tagged pre_tasks, not of any one service:
    # ntfy, beszel and audiobookshelf are only the vehicles. Every suite used to
    # re-prove them, six playbook invocations for 3m37s, on five critical paths at
    # once. foundation owns them now because it already exists to prove deployment
    # integrity and converges deployment_bundle alone, so it is the cheapest place
    # to pay for them once.
    if [ "\$INTEGRATION_SUITE" = foundation ] || [ "\$INTEGRATION_SUITE" = full ]; then
    assert_selective_compose_refused() {
      service=\$1
      evidence=\$2
      selective_compose='$active_release_dir/services/'\$service'/compose.yml'
      selective_outside='$sandbox/symlink-outside/selective-'\$service
      selective_pointer='$sandbox/volume1/Docker/nas-platform/current'
      mkdir -p \"\$selective_outside\"
      printf '%s\n' outside-safe > \"\$selective_outside/compose.yml\"
      outside_checksum=\$(sha256sum \"\$selective_outside/compose.yml\" | cut -d' ' -f1)
      pointer_before=\$(readlink \"\$selective_pointer\")
      rm \"\$selective_compose\"
      ln -s \"\$selective_outside/compose.yml\" \"\$selective_compose\"
      if run_play --tags \"\$service\" >/tmp/selective-compose.txt 2>&1; then
        cat /tmp/selective-compose.txt >&2
        printf 'SELECTIVE COMPOSE SYMLINK ACCEPTED: %s\n' \"\$service\" >&2
        exit 1
      fi
      if ! grep -qF 'Unsafe deployment target' /tmp/selective-compose.txt || \
         [ \"\$(readlink \"\$selective_compose\")\" != \"\$selective_outside/compose.yml\" ] || \
         [ \"\$(sha256sum \"\$selective_outside/compose.yml\" | cut -d' ' -f1)\" != \
           \"\$outside_checksum\" ] || \
         [ \"\$(readlink \"\$selective_pointer\")\" != \"\$pointer_before\" ]; then
        cat /tmp/selective-compose.txt >&2
        printf 'SELECTIVE COMPOSE SYMLINK MUTATED STATE: %s\n' \"\$service\" >&2
        exit 1
      fi
      printf '%s\n' \"\$evidence\"
      printf 'SYMLINK_ESCAPE_STATE_UNCHANGED\n'
      rm \"\$selective_compose\"
      cp /repo/services/\"\$service\"/compose.yml \"\$selective_compose\"
      chmod 0644 \"\$selective_compose\"
    }

    assert_selective_compose_refused ntfy SYMLINK_NTFY_COMPOSE_REFUSED
    assert_selective_compose_refused beszel SYMLINK_BESZEL_COMPOSE_REFUSED
    assert_selective_compose_refused audiobookshelf SYMLINK_AUDIOBOOKSHELF_COMPOSE_REFUSED

    assert_active_drift_refused() {
      evidence=\$1
      active_compose='$active_release_dir/services/ntfy/compose.yml'
      current_pointer='$sandbox/volume1/Docker/nas-platform/current'
      before_checksum=\$(sha256sum \"\$active_compose\" | cut -d' ' -f1)
      before_mode=\$(stat -c %a \"\$active_compose\")
      before_owner=\$(stat -c %u:%g \"\$active_compose\")
      before_pointer=\$(readlink \"\$current_pointer\")

      if run_play --tags deployment_bundle >/tmp/active-drift.txt 2>&1; then
        cat /tmp/active-drift.txt >&2
        printf 'ACTIVE DRIFT ACCEPTED: %s\n' \"\$evidence\" >&2
        exit 1
      fi
      if ! grep -qF 'differs from the controller bundle' /tmp/active-drift.txt || \
         [ \"\$(sha256sum \"\$active_compose\" | cut -d' ' -f1)\" != \"\$before_checksum\" ] || \
         [ \"\$(stat -c %a \"\$active_compose\")\" != \"\$before_mode\" ] || \
         [ \"\$(stat -c %u:%g \"\$active_compose\")\" != \"\$before_owner\" ] || \
         [ \"\$(readlink \"\$current_pointer\")\" != \"\$before_pointer\" ]; then
        cat /tmp/active-drift.txt >&2
        printf 'ACTIVE DRIFT WAS NOT PRESERVED: %s\n' \"\$evidence\" >&2
        exit 1
      fi
      printf '%s\n' \"\$evidence\"
      printf 'ACTIVE_DRIFT_PRESERVED\n'
    }

    printf '%s\n' drift >> '$active_release_dir/services/ntfy/compose.yml'
    assert_active_drift_refused ACTIVE_BYTE_DRIFT_REFUSED
    cp /repo/services/ntfy/compose.yml '$active_release_dir/services/ntfy/compose.yml'
    chmod 0644 '$active_release_dir/services/ntfy/compose.yml'

    chmod 0755 '$active_release_dir/services/ntfy/compose.yml'
    assert_active_drift_refused ACTIVE_MODE_DRIFT_REFUSED
    chmod 0644 '$active_release_dir/services/ntfy/compose.yml'

    chown 123:456 '$active_release_dir/services/ntfy/compose.yml'
    assert_active_drift_refused ACTIVE_OWNERSHIP_DRIFT_REFUSED
    chown 0:0 '$active_release_dir/services/ntfy/compose.yml'
    fi

    # foundation converges deployment_bundle and nothing else, so there are no
    # service scenarios below for it to run.
    if [ "\$INTEGRATION_SUITE" = foundation ]; then
      cleanup_vault
      exit 0
    fi

    if [ "\$INTEGRATION_RUN_SERVICE_SCENARIOS" = true ] && suite_is beszel; then
      run_beszel_contract verify
      printf 'BESZEL_INITIAL_CONTRACT_OK\n'

      run_beszel_contract drift
      run_beszel_contract drift-verify
      beszel_env_checksum_before_check=\$(sha256sum \
        '$sandbox/volume1/Docker/nas-platform/runtime/services/beszel/.env' | cut -d' ' -f1)
      if ! run_play --tags beszel --check --diff \
          >/tmp/beszel-drifted-check.txt 2>&1; then
        cat /tmp/beszel-drifted-check.txt >&2
        exit 1
      fi
      cat /tmp/beszel-drifted-check.txt
      for webhook_sentinel in sentinel-user sentinel-password sentinel-query-key example.invalid; do
        if grep -qF "\$webhook_sentinel" /tmp/beszel-drifted-check.txt; then
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
      beszel_env_checksum_after_check=\$(sha256sum \
        '$sandbox/volume1/Docker/nas-platform/runtime/services/beszel/.env' | cut -d' ' -f1)
      if [ "\$beszel_env_checksum_before_check" != "\$beszel_env_checksum_after_check" ]; then
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
        "\$vault_file" "\$vault_password_file" /tmp/beszel-verify-drift.txt
      for webhook_sentinel in sentinel-user sentinel-password sentinel-query-key example.invalid; do
        if grep -qF "\$webhook_sentinel" /tmp/beszel-verify-drift.txt; then
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
        grep -qF "\$duplicate_id" /tmp/beszel-duplicate.txt || {
          printf 'BESZEL DUPLICATE FAILURE OMITTED RECORD ID\n' >&2
          exit 1
        }
      done < '$sandbox/reports/beszel-duplicate-ids.txt'
      /repo/tests/assert-no-vault-secrets.rb \
        "\$vault_file" "\$vault_password_file" /tmp/beszel-duplicate.txt
      printf 'BESZEL_DUPLICATE_REFUSED_WITH_IDS\n'
      run_beszel_contract remove-duplicate
      run_play --tags beszel
      run_beszel_contract verify

      run_beszel_contract wrong-owner
      if run_play --tags beszel >/tmp/beszel-wrong-owner.txt 2>&1; then
        printf 'BESZEL WRONG-OWNER IDENTITY ACCEPTED\n' >&2
        exit 1
      fi
      tail -n +2 '$sandbox/reports/beszel-duplicate-ids.txt' | while IFS= read -r wrong_owner_id; do
        grep -qF "\$wrong_owner_id" /tmp/beszel-wrong-owner.txt || {
          printf 'BESZEL WRONG-OWNER FAILURE OMITTED RECORD ID\n' >&2
          exit 1
        }
      done
      /repo/tests/assert-no-vault-secrets.rb \
        "\$vault_file" "\$vault_password_file" /tmp/beszel-wrong-owner.txt
      printf 'BESZEL_WRONG_OWNER_REFUSED_WITH_IDS\n'
      run_beszel_contract remove-duplicate
      run_play --tags beszel
      run_beszel_contract verify

      run_play -e platform_beszel_agent_available=false --tags beszel
      if docker ps -a --format '{{.Names}}' | \
          grep -Eq '^('$integration_project_namespace'-beszel-agent-intel|'$integration_project_namespace'-beszel-agent-portable)$'; then
        printf 'BESZEL CAPABILITY-FALSE LEFT A MANAGED AGENT\n' >&2
        exit 1
      fi
      printf 'BESZEL_CAPABILITY_FALSE_REMOVED_AGENT\n'
      run_play --tags beszel
      run_beszel_contract verify

    fi

    if [ "\$INTEGRATION_RUN_SERVICE_SCENARIOS" = true ] && suite_is dozzle; then

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
        \"\$vault_file\" \"\$vault_password_file\" \
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
        \"\$vault_file\" \"\$vault_password_file\" \
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
          \"\$vault_file\" \"\$vault_password_file\" /tmp/dozzle-check-mixed.txt
        cat /tmp/dozzle-check-mixed.txt >&2
        run_dozzle_contract check-mixed-recover
        exit 1
      fi
      /repo/tests/assert-no-vault-secrets.rb \
        \"\$vault_file\" \"\$vault_password_file\" /tmp/dozzle-check-mixed.txt
      grep -qE 'changed=[1-9][0-9]* .*failed=0 ' /tmp/dozzle-check-mixed.txt
      run_dozzle_contract assert-check-mixed-output /tmp/dozzle-check-mixed.txt
      run_dozzle_contract check-mixed-unchanged
      if run_dozzle_verify_only >/tmp/dozzle-check-mixed-verify.txt 2>&1; then
        printf 'DOZZLE VERIFY-ONLY ACCEPTED MIXED CHECK-MODE DRIFT\n' >&2
        exit 1
      fi
      /repo/tests/assert-no-vault-secrets.rb \
        \"\$vault_file\" \"\$vault_password_file\" /tmp/dozzle-check-mixed-verify.txt
      run_play --tags dozzle
      run_dozzle_contract verify
      run_dozzle_contract check-mixed-cleanup
      printf 'DOZZLE_CHECK_MIXED_PLANNED_IMMUTABLE_AND_REPAIRED\n'

      run_dozzle_contract check-missing-create
      if ! run_play --tags dozzle --check --diff >/tmp/dozzle-check-missing.txt 2>&1; then
        /repo/tests/assert-no-vault-secrets.rb \
          \"\$vault_file\" \"\$vault_password_file\" /tmp/dozzle-check-missing.txt
        cat /tmp/dozzle-check-missing.txt >&2
        exit 1
      fi
      /repo/tests/assert-no-vault-secrets.rb \
        \"\$vault_file\" \"\$vault_password_file\" /tmp/dozzle-check-missing.txt
      grep -qE 'changed=[1-9][0-9]* .*failed=0 ' /tmp/dozzle-check-missing.txt
      run_dozzle_contract assert-check-missing-output /tmp/dozzle-check-missing.txt
      run_dozzle_contract check-missing-unchanged
      if run_dozzle_verify_only >/tmp/dozzle-check-missing-verify.txt 2>&1; then
        printf 'DOZZLE VERIFY-ONLY ACCEPTED MISSING CHECK-MODE STATE\n' >&2
        exit 1
      fi
      /repo/tests/assert-no-vault-secrets.rb \
        \"\$vault_file\" \"\$vault_password_file\" /tmp/dozzle-check-missing-verify.txt
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

    fi

    if [ "\$INTEGRATION_RUN_SERVICE_SCENARIOS" = true ] && suite_is audiobookshelf; then

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
        \"\$vault_file\" \"\$vault_password_file\" \
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
          \"\$vault_file\" \"\$vault_password_file\" \
          /tmp/audiobookshelf-check-repair.txt
        cat /tmp/audiobookshelf-check-repair.txt >&2
        exit 1
      fi
      /repo/tests/assert-no-vault-secrets.rb \
        \"\$vault_file\" \"\$vault_password_file\" \
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
        \"\$vault_file\" \"\$vault_password_file\" \
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
        \"\$vault_file\" \"\$vault_password_file\" \
        /tmp/audiobookshelf-verify-drift.txt
      run_play --tags audiobookshelf
      run_audiobookshelf_contract run
      printf 'AUDIOBOOKSHELF_DRIFT_REPAIRED\n'

      run_audiobookshelf_contract check-missing-seed
      if ! run_play --tags audiobookshelf --check --diff \
          >/tmp/audiobookshelf-check-missing.txt 2>&1; then
        /repo/tests/assert-no-vault-secrets.rb \
          \"\$vault_file\" \"\$vault_password_file\" \
          /tmp/audiobookshelf-check-missing.txt
        cat /tmp/audiobookshelf-check-missing.txt >&2
        exit 1
      fi
      /repo/tests/assert-no-vault-secrets.rb \
        \"\$vault_file\" \"\$vault_password_file\" \
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
        \"\$vault_file\" \"\$vault_password_file\" \
        /tmp/audiobookshelf-check-missing-verify.txt
      run_play --tags audiobookshelf
      run_audiobookshelf_contract check-missing-cleanup
      run_audiobookshelf_contract run
      printf 'AUDIOBOOKSHELF_CHECK_CREATE_PLANNED_IMMUTABLE\n'

      run_audiobookshelf_contract seed-progress
      docker compose --project-name $integration_project_namespace-audiobookshelf \
        --env-file '$sandbox/volume1/Docker/nas-platform/runtime/services/audiobookshelf/.env' \
        -f '$sandbox/volume1/Docker/nas-platform/current/services/audiobookshelf/compose.yml' \
        -f '$sandbox/volume1/Docker/nas-platform/current/services/audiobookshelf/compose.integration.yml' \
        up -d --force-recreate --wait
      run_audiobookshelf_contract assert-persistence
      printf 'AUDIOBOOKSHELF_RECREATE_PERSISTENCE_OK\n'

    fi

    if [ "\$INTEGRATION_RUN_SERVICE_SCENARIOS" = true ] && suite_is komga; then
      run_komga_contract seed
      if [ "\$INTEGRATION_SUITE" = komga ]; then
        run_komga_contract run
      fi
    fi

    if [ "\$INTEGRATION_RUN_SERVICE_SCENARIOS" = true ] && suite_is jellyfin; then
      run_jellyfin_contract seed
      if [ "\$INTEGRATION_SUITE" = jellyfin ]; then
        run_jellyfin_contract run
      fi
    fi

    if [ "\$INTEGRATION_RUN_SERVICE_SCENARIOS" = true ] && suite_is immich; then
      if [ "\$INTEGRATION_SUITE" = immich ]; then
        run_immich_contract clean-restore-seed
        run_immich_clean_restore
        run_immich_restore_negative_matrix
        run_immich_contract run
      fi
    fi

    if [ "\$INTEGRATION_RUN_SERVICE_SCENARIOS" = true ] && suite_is paperless; then
      run_paperless_contract seed
      mkdir -m 0700 '$sandbox/reports/paperless-coordinated-snapshot'
      run_paperless_snapshot drill '$sandbox/reports/paperless-coordinated-snapshot'
      run_paperless_contract assert-persistence
      docker compose --project-name $integration_project_namespace-paperless \
        --env-file '$sandbox/volume1/Docker/nas-platform/runtime/services/paperless-ngx/.env' \
        -f '$sandbox/volume1/Docker/nas-platform/current/services/paperless-ngx/compose.yml' \
        -f '$sandbox/volume1/Docker/nas-platform/current/services/paperless-ngx/compose.integration.yml' \
        up -d --force-recreate --wait
      run_paperless_contract assert-persistence
    fi
      # The full lane avoids the CPU-machine-learning seed contract because it
      # would add an 800 MB external model download. The Immich suite owns the
      # narrower upload/backup fixture that proves database recovery without
      # waiting for generated assets or inference.

    if [ "\$INTEGRATION_SUITE" = full ] && \
       [ "\$INTEGRATION_RUN_SERVICE_SCENARIOS" = true ]; then
      env \
        PLATFORM_KIND=integration \
        PLATFORM_CONTRACT_VAULT_FILE=\"\$vault_file\" \
        PLATFORM_CONTRACT_VAULT_PASSWORD_FILE=\"\$vault_password_file\" \
        PLATFORM_DOCKER_ROOT='$sandbox/volume1/Docker' \
        PLATFORM_MEDIA_ROOT='$sandbox/volume2' \
        PLATFORM_FIXTURE_ROOT='$sandbox/fixtures' \
        PLATFORM_REPORT_ROOT='$sandbox/reports' \
        PLATFORM_JELLYFIN_CONTAINER=$integration_project_namespace-jellyfin \
        PLATFORM_PROJECT_NAME=$integration_project_namespace \
        PLATFORM_AUDIOBOOKSHELF_CONTAINER=$integration_project_namespace-audiobookshelf \
        PLATFORM_IMMICH_SERVER_CONTAINER=$integration_project_namespace-immich-server \
        PLATFORM_IMMICH_MACHINE_LEARNING_CONTAINER=$integration_project_namespace-immich-machine-learning \
        PLATFORM_IMMICH_REDIS_CONTAINER=$integration_project_namespace-immich-redis \
        PLATFORM_IMMICH_POSTGRES_CONTAINER=$integration_project_namespace-immich-postgres \
        PLATFORM_PAPERLESS_WEBSERVER_CONTAINER=$integration_project_namespace-paperless-webserver \
        ruby /repo/tests/run_contracts.rb --execute
      run_audiobookshelf_contract authentication-session-cleanup
    fi

    if suite_is idempotence-check; then
    printf '\n=== phase 2: asserting idempotence ===\n'
    # Not piped into tee: the pipeline would report tee's status, and this shell
    # has no pipefail. A play that died would reach the recap check below with
    # whatever partial output it managed to print.
    idempotence_status=0
    run_selected_play "\$@" >/tmp/second.txt 2>&1 || idempotence_status=\$?
    cat /tmp/second.txt
    if [ \"\$idempotence_status\" -ne 0 ]; then
      printf 'NOT IDEMPOTENT: second run failed with status %s\n' \
        \"\$idempotence_status\" >&2
      exit 1
    fi
    # Must also require failed=0: a run that changed nothing because it died
    # early is not idempotent, and an earlier version of this check passed on it.
    if grep -qE 'changed=0 ' /tmp/second.txt && grep -qE 'failed=0 ' /tmp/second.txt; then
      printf 'IDEMPOTENT: second run changed nothing\n'
    else
      printf 'NOT IDEMPOTENT: second run reported changes\n' >&2
      exit 1
    fi
    printf '\n=== phase 3: asserting --check --diff works ===\n'
    if run_selected_play "\$@" --check --diff; then
      printf 'CHECK MODE OK: dry run completed\n'
    else
      printf 'CHECK MODE BROKEN: dry run failed\n' >&2
      exit 1
    fi
    fi
    cleanup_vault
  " integration-run "$playbook" "$@"
