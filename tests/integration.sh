#!/bin/sh
# Runs the plays against a disposable sandbox instead of the NAS. Ansible runs in a
# Linux container so the plays meet a real /proc/mounts, numeric uid/gid and Docker.
#
# Usage: tests/integration.sh [--suite NAME [--tags TAGS]] [playbook] [ansible arguments]
set -eu

ansible_core_version=2.21.4
# community.docker.docker_container_info imports requests on the managed host;
# the disposable controller is that host for the local inventory.
requests_version=2.34.2
runner_image=docker.io/library/python:3.14-alpine@sha256:2e740b2c28a426e74f11396c05e38afb3191acced75045b8d62df573c1dc8ce8
# `~` rather than `=`: apk's `=` needs the distro revision, so an -r0 to -r1 bump
# drops the pin out of the index. It also lets Renovate track it via repology.
ruby_package='ruby~3.4.9'
curl_package='curl~8.22.0'

# The pre-built controller toolchain (the pins above, the Dockerfile and
# requirements.yml). Optional: every path falls back to installing them in the base image.
toolchain_repository=${INTEGRATION_TOOLCHAIN_REPOSITORY:-ghcr.io/yonatankarp/nas-platform-controller}
toolchain_dockerfile=tests/integration.Dockerfile

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

# Suites are data in tests/ci/suites.conf, which tests/ci/classify_changes.rb reads too.
repo_dir=$(CDPATH= cd -P "$(dirname "$0")/.." && pwd -P)
suite_table=$repo_dir/tests/ci/suites.conf
if [ ! -f "$suite_table" ]; then
  printf 'missing integration suite table: %s\n' "$suite_table" >&2
  exit 2
fi

# Sets suite_names, suite_known and fixed_tags for suite $1. Reads in the current
# shell rather than a pipeline so a malformed row can exit.
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
    smoke|upgrade|idempotence-check) ;;
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

# Upgrade-lane inputs: the service to repin and the BASE branch's pin of it. An env
# input because the suites job checks out at depth 1 and has no base to read.
# Refused rather than clamped: the value reaches `docker pull` and compose.yml.
upgrade_service=${INTEGRATION_UPGRADE_SERVICE:-}
upgrade_base_image=${INTEGRATION_UPGRADE_BASE_IMAGE:-}

# Subjects are derived from tests/contracts/<svc>-upgrade.rb, as classify_changes.rb does.
upgrade_subject_program=$repo_dir/tests/contracts/$upgrade_service-upgrade.rb

if [ -n "$upgrade_base_image" ]; then
  upgrade_base_digest=${upgrade_base_image##*@sha256:}
  upgrade_base_name=${upgrade_base_image%@sha256:*}
  upgrade_base_valid=true
  case $upgrade_base_image in
    *@sha256:*) ;;
    *) upgrade_base_valid=false ;;
  esac
  [ "${#upgrade_base_digest}" -eq 64 ] || upgrade_base_valid=false
  case $upgrade_base_digest in
    *[!0123456789abcdef]*) upgrade_base_valid=false ;;
  esac
  case $upgrade_base_name in
    *:*) ;;
    *) upgrade_base_valid=false ;;
  esac
  case $upgrade_base_name in
    *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._/:-]*)
      upgrade_base_valid=false
      ;;
  esac
  [ "$upgrade_base_valid" = true ] || {
    printf 'invalid integration upgrade base image: %s\n' "$upgrade_base_image" >&2
    exit 2
  }
fi

if [ -n "$upgrade_service" ]; then
  case $upgrade_service in
    ''|*[!abcdefghijklmnopqrstuvwxyz0123456789-]*)
      printf 'invalid integration upgrade service: %s\n' "$upgrade_service" >&2
      exit 2
      ;;
  esac
  [ -f "$repo_dir/services/$upgrade_service/compose.yml" ] || {
    printf 'unknown integration upgrade service: %s\n' "$upgrade_service" >&2
    exit 2
  }
  [ -f "$upgrade_subject_program" ] || {
    printf 'integration upgrade service %s has no seed-and-verify program\n' "$upgrade_service" >&2
    exit 2
  }
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
          smoke|upgrade|idempotence-check)
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

# The event plan tests/integration_lifecycle.sh validates. The upgrade lane ends in
# `stop` so the head container's exit code is read (#781).
emit_lifecycle_plan() {
  if [ "$suite" = upgrade ]; then
    printf '%s\n' converge
    printf '%s\n' seed
    printf '%s\n' repin
    printf '%s\n' converge
    printf '%s\n' verify
    printf '%s\n' stop
    printf '%s\n' success
    return 0
  fi
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

# Required only once the suite runs; the queries above answer without them.
if [ "$suite" = upgrade ]; then
  # An explicit `if`, not `A && B || C` (SC2015).
  if [ -z "$upgrade_service" ] || [ -z "$upgrade_base_image" ]; then
    printf 'the upgrade suite requires INTEGRATION_UPGRADE_SERVICE and INTEGRATION_UPGRADE_BASE_IMAGE\n' >&2
    exit 2
  fi
fi

# Service images keyed by site.yml role tag, then services/ directory (only paperless
# differs). Keyed by tag so a --tags run pulls only what it converges.
# tests/policy_ci_test.rb holds this to the manifest.
service_image_sources='
beszel beszel
dozzle dozzle
audiobookshelf audiobookshelf
komga komga
jellyfin jellyfin
immich immich
paperless paperless-ngx
nextcloud nextcloud
arr arr
downloaders downloaders
bindery bindery
kapowarr kapowarr
pinchflat pinchflat
trailarr trailarr
seerr seerr
vaultwarden vaultwarden
karakeep karakeep
'

# Ceilings that bound all shell arithmetic even on malformed or hostile input.
image_pull_attempt_limit=10
image_pull_delay_limit=300
image_pull_wait_limit=375
# Pre-pull concurrency. Width recovers per-request latency, not bandwidth, so raising
# it buys little and worsens the burst rate at the registries.
image_pull_width_limit=8

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

# Ten attempts (~7 min) because ghcr.io rate limits outlasted six (#762).
image_pull_attempts=$(bounded_integer "${INTEGRATION_IMAGE_PULL_ATTEMPTS:-10}" \
  10 2 "$image_pull_attempt_limit")
image_pull_delay=$(bounded_integer "${INTEGRATION_IMAGE_PULL_DELAY:-5}" \
  5 1 "$image_pull_delay_limit")
image_pull_max_delay=$(bounded_integer "${INTEGRATION_IMAGE_PULL_MAX_DELAY:-60}" \
  60 1 "$image_pull_delay_limit")
image_pull_width=$(bounded_integer "${INTEGRATION_IMAGE_PULL_WIDTH:-4}" \
  4 1 "$image_pull_width_limit")
[ "$image_pull_max_delay" -ge "$image_pull_delay" ] ||
  image_pull_max_delay=$image_pull_delay

pull_error=
prepull_list=
prepull_results=

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

# Removed by the EXIT trap so an interrupted pull leaves nothing under TMPDIR.
cleanup_prepull_results() {
  if [ -n "$prepull_results" ]; then
    rm -rf "$prepull_results" || true
    prepull_results=
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
      # Case-insensitive and space-tolerant so an HTTP-style "Retry-After" still
      # matches; a stricter match would silently make this parser dead code.
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

# A refusal worth sleeping on. Only this is retried for the optional toolchain
# image, whose 404 is ordinary on a developer machine.
refusal_is_rate_limited() {
  LC_ALL=C grep -qiE 'toomanyrequests|too many requests|retry-after' "$1"
}

pull_image() {
  pull_target=$1
  # When true, only a rate-limit refusal is retried.
  pull_transient_only=${2:-false}
  pull_attempt=1
  pull_delay=$image_pull_delay
  pull_error=$(mktemp "${TMPDIR:-/tmp}/nas-platform-pull-error.XXXXXX") || pull_error=
  if [ -z "$pull_error" ]; then
    # Without the file every pull fails unrun and burns the whole retry budget.
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
    if [ "$pull_transient_only" = true ] && ! refusal_is_rate_limited "$pull_error"; then
      rm -f "$pull_error"
      pull_error=
      return 1
    fi
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
        # A registry hint may lengthen the wait but never past the local ceiling,
        # or the Actions timeout kills the job with no diagnostic.
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
  # The upgrade base image is in no compose.yml. Printed BEFORE the loop: a trailing
  # command would replace this function's status and hide a truncated enumeration.
  # Gated on the suite because every matrix leg carries the upgrade inputs.
  if [ "$suite" = upgrade ] && [ -n "$upgrade_base_image" ]; then
    printf '%s\n' "$upgrade_base_image"
  fi
  printf '%s\n' "$service_image_sources" | while read -r service_tag service_dir; do
    [ -n "$service_tag" ] || continue
    # An empty tag list means the whole play runs, so every implemented service
    # converges and every image is needed.
    if [ -n "$suite_tags" ]; then
      case ",$suite_tags," in
        *",$service_tag,"*) ;;
        *)
          # The seerr lane's foundation proof also converges audiobookshelf.
          case "$suite:$service_tag" in
            seerr:audiobookshelf) ;;
            *) continue ;;
          esac
          ;;
      esac
    fi
    # Explicit exit: the caller's `|| status=$?` suspends set -e in this body.
    sed -n 's/^[[:space:]]*image:[[:space:]]*//p' \
      "$repo_dir/services/$service_dir/compose.yml" || exit 1
  done
}

# Warms the image cache under a retry: a refusal inside docker_compose_v2 aborts the
# play and no Ansible retry reaches it. Also the only pull carrying the runner's
# registry login. A registry that stays unreachable still fails the suite.
prepull_images() {
  # Resolved first: it changes what is pulled and what the container installs.
  resolve_controller_image || return 1
  # Materialized first: #!/bin/sh has no pipefail, so `$(... | sort -u)` would hide
  # a truncated enumeration and skip the rest of the pre-pull.
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
  resolve_collision_image || return 1
  prepull_results=$(mktemp -d "${TMPDIR:-/tmp}/nas-platform-prepull-results.XXXXXX") ||
    prepull_results=
  if [ -z "$prepull_results" ]; then
    printf 'could not create a pre-pull result directory under %s\n' \
      "${TMPDIR:-/tmp}" >&2
    return 1
  fi
  prepull_launched=0
  prepull_batch=0
  prepull_drained=0
  prepull_failed=0
  for pull_candidate in $prepull_targets; do
    # Already local. On the toolchain path the base python image is then pulled
    # only by lanes converging Dozzle, whose alert relay runs on it.
    if [ "$pull_candidate" = "$controller_image" ]; then
      continue
    fi
    prepull_launched=$((prepull_launched + 1))
    # One subshell per image so each retry ladder has private state; the trap
    # removes the child's own file. A signal trap, not EXIT: dash runs no EXIT
    # handler on an untrapped SIGTERM. Output is replayed in order below.
    (
      trap 'cleanup_pull_error; exit 130' HUP INT TERM
      prepull_child_status=0
      pull_image "$pull_candidate" || prepull_child_status=$?
      printf '%s\n' "$prepull_child_status" \
        > "$prepull_results/status.$prepull_launched"
    ) > "$prepull_results/out.$prepull_launched" \
      2> "$prepull_results/err.$prepull_launched" &
    prepull_batch=$((prepull_batch + 1))
    [ "$prepull_batch" -ge "$image_pull_width" ] || continue
    wait
    prepull_batch=0
    drain_prepull_batch || prepull_failed=1
    # A batch carrying a refusal is the last one launched.
    [ "$prepull_failed" -eq 0 ] || break
  done
  wait
  drain_prepull_batch || prepull_failed=1
  cleanup_prepull_results
  [ "$prepull_failed" -eq 0 ] || return 1
}

# Replays the children's output in launch order. A missing status is a refusal.
drain_prepull_batch() {
  prepull_drain_status=0
  while [ "$prepull_drained" -lt "$prepull_launched" ]; do
    prepull_drained=$((prepull_drained + 1))
    [ ! -f "$prepull_results/out.$prepull_drained" ] ||
      cat "$prepull_results/out.$prepull_drained"
    [ ! -f "$prepull_results/err.$prepull_drained" ] ||
      cat "$prepull_results/err.$prepull_drained" >&2
    if [ "$(cat "$prepull_results/status.$prepull_drained" 2>/dev/null)" != 0 ]; then
      prepull_drain_status=1
    fi
  done
  return "$prepull_drain_status"
}

# Everything the controller image is built from. The tag is its digest, so nothing
# needs invalidating by hand.
toolchain_digest_stream() {
  printf '%s\n' "$runner_image" "$ansible_core_version" "$requests_version" \
    "$ruby_package" "$curl_package"
  cat "$repo_dir/$toolchain_dockerfile" "$repo_dir/requirements.yml"
}

# Alpine's base image ships none of these, and macOS ships only shasum, so the
# digest is taken with whichever of the three the caller actually has.
sha256_stream() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | cut -d' ' -f1
  else
    openssl dgst -sha256 | sed 's/.*[ =]//'
  fi
}

# Only linux/amd64 is published. The arch in the tag makes Apple Silicon miss cleanly
# and build natively rather than run under emulation.
toolchain_platform() {
  toolchain_arch=$(docker version --format '{{.Server.Arch}}' 2>/dev/null) ||
    toolchain_arch=
  case $toolchain_arch in
    ''|*[!abcdefghijklmnopqrstuvwxyz0123456789]*) toolchain_arch=unknown ;;
  esac
  printf '%s' "$toolchain_arch"
}

toolchain_reference=

resolve_toolchain_reference() {
  [ -z "$toolchain_reference" ] || return 0
  toolchain_digest=$(toolchain_digest_stream | sha256_stream | cut -c1-32) ||
    return 1
  # A digest tool that answered with a diagnostic instead of a hash would
  # otherwise become a tag, and every run would then miss on a different one.
  case $toolchain_digest in
    ''|*[!0123456789abcdef]*)
      printf 'could not digest the controller toolchain inputs\n' >&2
      return 1
      ;;
  esac
  if [ "${#toolchain_digest}" -ne 32 ]; then
    printf 'the controller toolchain digest is the wrong width\n' >&2
    return 1
  fi
  toolchain_reference=$toolchain_repository:$(toolchain_platform)-$toolchain_digest
}

toolchain_context=

cleanup_toolchain_context() {
  if [ -n "$toolchain_context" ]; then
    rm -rf -- "$toolchain_context" || true
    toolchain_context=
  fi
}

# The build context is just the two digested files, not the checkout.
build_toolchain_image() {
  resolve_toolchain_reference || return 1
  toolchain_context=$(mktemp -d "${TMPDIR:-/tmp}/nas-platform-toolchain.XXXXXX") ||
    toolchain_context=
  if [ -z "$toolchain_context" ]; then
    printf 'could not create a toolchain build context under %s\n' \
      "${TMPDIR:-/tmp}" >&2
    return 1
  fi
  toolchain_build_status=0
  cp "$repo_dir/$toolchain_dockerfile" "$toolchain_context/Dockerfile" &&
    cp "$repo_dir/requirements.yml" "$toolchain_context/requirements.yml" &&
    docker build \
      --build-arg "CONTROLLER_BASE_IMAGE=$runner_image" \
      --build-arg "ANSIBLE_CORE_VERSION=$ansible_core_version" \
      --build-arg "REQUESTS_VERSION=$requests_version" \
      --build-arg "RUBY_PACKAGE=$ruby_package" \
      --build-arg "CURL_PACKAGE=$curl_package" \
      --tag "$toolchain_reference" "$toolchain_context" >&2 ||
    toolchain_build_status=$?
  cleanup_toolchain_context
  return "$toolchain_build_status"
}

# Controller image, cheapest first: local, published, built here, else the base
# image with the toolchain installed in the run.
controller_image=$runner_image
toolchain_preinstalled=false

resolve_controller_image() {
  controller_image=$runner_image
  toolchain_preinstalled=false

  # The escape hatch for bisecting a failure against the pre-image behaviour.
  if [ "${INTEGRATION_TOOLCHAIN:-auto}" = off ]; then
    pull_image "$runner_image" || return 1
    return 0
  fi

  resolve_toolchain_reference || return 1
  if docker image inspect "$toolchain_reference" >/dev/null 2>&1 ||
     pull_image "$toolchain_reference" true; then
    controller_image=$toolchain_reference
    toolchain_preinstalled=true
    return 0
  fi

  printf 'no controller toolchain at %s; using the base image instead\n' \
    "$toolchain_reference" >&2
  pull_image "$runner_image" || return 1
  # Pull-only mode exists to exercise the registry ladder, so it stops here
  # rather than spending a minute building an image it will never run.
  [ "${INTEGRATION_PREPULL_ONLY:-0}" != 1 ] || return 0
  if build_toolchain_image; then
    controller_image=$toolchain_reference
    toolchain_preinstalled=true
  else
    printf 'could not build the controller toolchain; installing it in the run\n' >&2
  fi
}

# The collision fixture needs an image both local and named by digest. A locally
# built toolchain has no registry digest, so it falls back to the base image.
collision_image=
resolve_collision_image() {
  collision_image=$controller_image
  case $collision_image in
    *@sha256:*) return 0 ;;
  esac
  collision_digest=$(docker image inspect \
    --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' \
    "$controller_image" 2>/dev/null) || collision_digest=
  case $collision_digest in
    *@sha256:*)
      collision_image=$collision_digest
      return 0
      ;;
  esac
  pull_image "$runner_image" || return 1
  collision_image=$runner_image
}

# Publishes the image the suites pull. Runs in CI only: a build here is
# linux/amd64 because the runner is, and the tag says so.
publish_toolchain_image() {
  resolve_toolchain_reference || return 1
  if docker buildx imagetools inspect "$toolchain_reference" >/dev/null 2>&1; then
    printf '%s is already published\n' "$toolchain_reference" >&2
    return 0
  fi
  pull_image "$runner_image" || return 1
  build_toolchain_image || return 1
  docker push "$toolchain_reference" >&2 || return 1
  printf 'published %s\n' "$toolchain_reference" >&2
}

# Pull-only mode lets tests/integration_suite_test.sh drive the retry against a stub docker.
trap 'cleanup_pull_error; cleanup_prepull_list; cleanup_prepull_results; cleanup_toolchain_context' EXIT
trap 'exit 130' HUP INT TERM

# Reports the toolchain tag, so the publishing workflow and the harness agree on it.
if [ "${INTEGRATION_TOOLCHAIN_REFERENCE_ONLY:-0}" = 1 ]; then
  reference_status=0
  resolve_toolchain_reference || reference_status=$?
  [ "$reference_status" -ne 0 ] || printf '%s\n' "$toolchain_reference"
  exit "$reference_status"
fi

if [ "${INTEGRATION_TOOLCHAIN_PUBLISH:-0}" = 1 ]; then
  publish_status=0
  publish_toolchain_image || publish_status=$?
  exit "$publish_status"
fi

if [ "${INTEGRATION_PREPULL_ONLY:-0}" = 1 ]; then
  prepull_status=0
  prepull_images || prepull_status=$?
  exit "$prepull_status"
fi

cleanup_sandbox_repo_dir=$repo_dir
. "$repo_dir/tests/sandbox_cleanup.sh"
. "$repo_dir/tests/integration_lock.sh"

# Bind sources must be valid on the daemon host too: macOS TMPDIR is under /private,
# which Docker Desktop shares by default.
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
  cleanup_prepull_results
  cleanup_toolchain_context
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

# Deliberately stale deployment state that convergence must replace.
stale_docker_root="$sandbox/stale-root/Docker"
stale_deploy_root="$stale_docker_root/nas-platform"
stale_release_dir="$stale_deploy_root/releases/$expected_release_id"
mkdir -p "$stale_deploy_root/current/services/beszel" \
  "$stale_release_dir/services/beszel" \
  "$stale_release_dir/services/undeclared"
printf '%s\n' legacy-current-compose > \
  "$stale_deploy_root/current/services/beszel/compose.yml"
printf '%s\n' stale-same-sha-compose > \
  "$stale_release_dir/services/beszel/compose.yml"
# A Mac override left in the release is target-only content convergence must delete.
printf '%s\n' target-only-override > \
  "$stale_release_dir/services/beszel/compose.mac.yml"
printf '%s\n' undeclared-service > \
  "$stale_release_dir/services/undeclared/compose.yml"

# An isolated checkout proving canonical+platform image merge through the real
# deployment role; not part of the production inventory.
manifest_controller="$sandbox/manifest-controller"
manifest_docker_root="$sandbox/manifest-root/Docker"
manifest_media_root="$sandbox/manifest-root/media"
mkdir -p "$manifest_controller/config" "$manifest_controller/roles" \
  "$manifest_controller/services/demo" \
  "$manifest_docker_root" "$manifest_media_root"
cp "$repo_dir/config/media-acquisition.yml" \
  "$manifest_controller/config/media-acquisition.yml"
cp "$repo_dir/config/managed-user-capabilities.yml" \
  "$manifest_controller/config/managed-user-capabilities.yml"
cp -R "$repo_dir/roles/deployment_bundle" "$manifest_controller/roles/"
mkdir -p "$manifest_controller/services/dozzle" "$manifest_controller/services/downloaders" \
  "$manifest_controller/services/immich" "$manifest_controller/services/kapowarr"
cp "$repo_dir/services/dozzle/alert_relay.py" \
  "$manifest_controller/services/dozzle/alert_relay.py"
cp "$repo_dir/services/downloaders/clamav_gate.py" \
  "$manifest_controller/services/downloaders/clamav_gate.py"
cp "$repo_dir/services/immich/classify_restore.py" \
  "$manifest_controller/services/immich/classify_restore.py"
cp "$repo_dir/services/kapowarr/tasks.py" \
  "$manifest_controller/services/kapowarr/tasks.py"
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
  cp "$repo_dir/config/managed-user-capabilities.yml" \
    "$fixture_root/config/managed-user-capabilities.yml"
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

# An isolated clone at HEAD with the working files overlaid. Also the only place CI
# swaps in the ephemeral vault fixture.
controller_mount=$sandbox/repo
git clone --quiet --no-local --no-checkout "$repo_dir" "$controller_mount"
git -C "$controller_mount" checkout -q --detach "$expected_release_id"
tar -C "$repo_dir" -cf - --exclude .git . | tar -C "$controller_mount" -xf -

# Each refusal also proves the controller guard runs before any target mutation.
controller_test_dir="$sandbox/controller-checkout"
controller_test_playbook="$controller_test_dir/dirty-controller-test.yml"
controller_test_target="$sandbox/dirty-controller-target"
controller_test_sentinel="$sandbox/dirty-controller-sentinel"
mkdir -p "$controller_test_dir/services/beszel" "$controller_test_dir/roles"
cp "$repo_dir/services/manifest.yml" "$controller_test_dir/services/manifest.yml"
cp "$repo_dir/services/beszel/compose.yml" "$controller_test_dir/services/beszel/compose.yml"
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

# Linux daemons lack host.docker.internal and Compose-started containers get no
# --add-host, so use the bridge gateway the published ports listen on.
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

# Teardown reuses the local controller image, avoiding a Docker Hub pull per lane.
cleanup_sandbox_image=$controller_image

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
  `# The sandbox is published and administered at the same address.` \
  -e PLATFORM_PUBLIC_HOST="$nas_address" \
  -e PLATFORM_INTEGRATION_SANDBOX="$sandbox" \
  -e PLATFORM_INTEGRATION_PROJECT_NAMESPACE="$integration_project_namespace" \
  -e INTEGRATION_SUITE="$suite" \
  -e INTEGRATION_TAGS="$suite_tags" \
  `# Upgrade-lane inputs; empty for every other lane.` \
  -e INTEGRATION_UPGRADE_SERVICE="$upgrade_service" \
  -e INTEGRATION_UPGRADE_BASE_IMAGE="$upgrade_base_image" \
  -e INTEGRATION_RUN_SERVICE_SCENARIOS="$run_service_scenarios" \
  -e MEDIA_CONTROL_COLLISION_IMAGE="$collision_image" \
  -e INTEGRATION_TOOLCHAIN_PREINSTALLED="$toolchain_preinstalled" \
  -e PLATFORM_PAPERLESS_FIXTURE_PRESEEDED="$paperless_fixture_preseeded" \
  -e PLATFORM_KOMGA_FIXTURE_PRESEEDED="$komga_fixture_preseeded" \
  -e PLATFORM_JELLYFIN_FIXTURE_PRESEEDED="$jellyfin_fixture_preseeded" \
  `# /repo is the sandbox copy under test, not the workstation checkout.` \
  -e CONTROLLER_REPO_DIR=/repo \
  -e CONTROLLER_SANDBOX="$sandbox" \
  -e CONTROLLER_PROJECT_NAMESPACE="$integration_project_namespace" \
  -e CONTROLLER_RUBY_PACKAGE="$ruby_package" \
  -e CONTROLLER_CURL_PACKAGE="$curl_package" \
  -e CONTROLLER_ANSIBLE_CORE_VERSION="$ansible_core_version" \
  -e CONTROLLER_REQUESTS_VERSION="$requests_version" \
  `# Computed by the launcher: git against /repo, the copy, would be wrong.` \
  -e CONTROLLER_EXPECTED_RELEASE_ID="$expected_release_id" \
  -e CONTROLLER_MANIFEST_FIXTURE_SHA="$manifest_fixture_sha" \
  -e CONTROLLER_ACTIVE_RELEASE_DIR="$active_release_dir" \
  -e CONTROLLER_STALE_DOCKER_ROOT="$stale_docker_root" \
  -e CONTROLLER_STALE_DEPLOY_ROOT="$stale_deploy_root" \
  -e CONTROLLER_STALE_RELEASE_DIR="$stale_release_dir" \
  -e CONTROLLER_MANIFEST_CONTROLLER="$manifest_controller" \
  -e CONTROLLER_MANIFEST_DOCKER_ROOT="$manifest_docker_root" \
  -e CONTROLLER_MANIFEST_MEDIA_ROOT="$manifest_media_root" \
  -e CONTROLLER_TEST_DIR="$controller_test_dir" \
  -e CONTROLLER_TEST_PLAYBOOK="$controller_test_playbook" \
  -e CONTROLLER_TEST_TARGET="$controller_test_target" \
  -e CONTROLLER_TEST_SENTINEL="$controller_test_sentinel" \
  -w /repo \
  "$controller_image" \
  sh /repo/tests/integration_controller.sh "$playbook" "$@"
