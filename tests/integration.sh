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
runner_image=docker.io/library/python:3.14-alpine@sha256:c6ead215bfd31f1e433d968853b7a769989117115b728874824e6c0a27cb96fc
# Fuzzy `~` rather than `=`: apk's `=` requires the distro revision, so a
# packaging-only bump from -r0 to -r1 drops the pinned version out of the index
# and every suite fails at sandbox setup with "unable to select packages". `~`
# pins the upstream version and accepts any revision of it. Dropping the
# revision is also what lets Renovate track these, since repology reports
# Alpine versions without one.
ruby_package='ruby~3.4.9'
curl_package='curl~8.21.0'

# Where the pre-built controller toolchain is published. The image is the five
# pins above plus tests/integration.Dockerfile and requirements.yml, already
# installed, so a suite starts converging instead of spending a minute of every
# lane re-running apk, pip and ansible-galaxy against three registries. Not a
# precondition for anything: every path below falls back to installing them in a
# bare base image, which is what this script did before the image existed.
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
bindery bindery
kapowarr kapowarr
pinchflat pinchflat
trailarr trailarr
seerr seerr
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

# A refusal worth sleeping on. Docker Hub and ghcr.io both answer pressure with
# "toomanyrequests", usually carrying a retry-after hint; both answer an image
# that is not there, or that this caller may not read, with "denied" or "not
# found". The distinction only matters for the toolchain image, whose absence is
# the ordinary case on a developer's machine: retrying it would spend the whole
# ladder in sleeps to rediscover a 404.
refusal_is_rate_limited() {
  LC_ALL=C grep -qiE 'toomanyrequests|too many requests|retry-after' "$1"
}

pull_image() {
  pull_target=$1
  # When true, only a rate-limit refusal is retried and anything else fails at
  # once. The caller is expected to have somewhere else to go.
  pull_transient_only=${2:-false}
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
          # The seerr lane carries the shared media-acquisition foundation
          # proof as well as its own service, and that converges audiobookshelf
          # -- the second reader the foundation verifies -- which its own tags
          # have no reason to name.
          case "$suite:$service_tag" in
            seerr:audiobookshelf) ;;
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
  # Which image the controller runs from, and whether the toolchain is already
  # in it, is decided before anything is pulled: it changes both what this
  # function pulls and what the container has to install.
  resolve_controller_image || return 1
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
  resolve_collision_image || return 1
  for pull_candidate in $prepull_targets; do
    # Whatever the controller runs from is already local, so skipping it here
    # saves a second registry round trip. On the toolchain path that is a ghcr.io
    # image no service uses, and the base python image stops being pulled at all
    # -- except by the three lanes that converge Dozzle, whose alert relay runs
    # on it as a service in its own right.
    if [ "$pull_candidate" != "$controller_image" ]; then
      pull_image "$pull_candidate" || return 1
    fi
  done
}

# Everything the controller image is built from, as one byte stream. The tag is
# a digest of it, so a bumped pin, an edited Dockerfile or a new collection is a
# different image rather than a stale one wearing the right name -- which is the
# whole reason nothing here needs invalidating by hand.
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

# Only linux/amd64 is published, because only the CI runners are that. Naming the
# daemon's architecture in the tag is what makes an Apple Silicon machine miss
# cleanly and build its own native image, instead of pulling an amd64 controller
# and running every play under emulation.
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

# The build context is exactly the two files the digest covers. Handing docker
# the checkout instead would ship .git, every service definition and every
# fixture to the daemon on a build that reads two files.
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

# Chooses what the controller container starts from, in falling order of cost:
# an image already on this daemon, the published one, one built here, and
# finally the bare base image with the toolchain installed inside the run. Only
# the last of those touches Docker Hub on a lane that converges no python
# service, which is the whole point.
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

# The media-control collision fixture starts its endpoints with --pull=never and
# refuses an image that is not digest-pinned, so it needs a reference that is both
# already local and named by digest. The controller image is local by
# construction but not always named that way, so the two properties are resolved
# separately here rather than assumed to coincide:
#
#   base-image fallback  the reference is the digest-pinned pin itself
#   pulled toolchain     the daemon knows its registry digest, and using it costs
#                        nothing this run has not already spent
#   built toolchain      a locally built image has no registry digest at all, so
#                        the fixture falls back to the base image -- which that
#                        path has already pulled, or pulls here
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

# Pull-only mode exists so tests/integration_suite_test.sh can drive the retry
# against a stub docker without building a sandbox. It shares the code path the
# real run uses rather than re-implementing it.
trap 'cleanup_pull_error; cleanup_prepull_list; cleanup_toolchain_context' EXIT
trap 'exit 130' HUP INT TERM

# Reports the image the suites on this daemon would run from, so the workflow
# that publishes it and the harness that consumes it cannot disagree about which
# tag that is.
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

# The sandbox teardown runs a container of its own on the way out, and every
# lane reaches it. Left pointing at the base image it would put a Docker Hub
# pull back on the exit path of every lane and cancel out the saving the
# toolchain image exists for; the controller image is local by construction and
# carries the same python.
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
  `# The sandbox reaches published services at the same address it is` \
  `# administered through, so the two coordinates coincide here. Stated` \
  `# explicitly because the inventory no longer infers one from the other.` \
  -e PLATFORM_PUBLIC_HOST="$nas_address" \
  `# The launcher library is a real file rather than text pasted into the` \
  `# controller argument, so the two values it needs cross the boundary as` \
  `# environment rather than as interpolation.` \
  -e PLATFORM_INTEGRATION_SANDBOX="$sandbox" \
  -e PLATFORM_INTEGRATION_PROJECT_NAMESPACE="$integration_project_namespace" \
  -e INTEGRATION_SUITE="$suite" \
  -e INTEGRATION_TAGS="$suite_tags" \
  -e INTEGRATION_RUN_SERVICE_SCENARIOS="$run_service_scenarios" \
  -e MEDIA_CONTROL_COLLISION_IMAGE="$collision_image" \
  -e INTEGRATION_TOOLCHAIN_PREINSTALLED="$toolchain_preinstalled" \
  -e PLATFORM_PAPERLESS_FIXTURE_PRESEEDED="$paperless_fixture_preseeded" \
  -e PLATFORM_KOMGA_FIXTURE_PRESEEDED="$komga_fixture_preseeded" \
  -e PLATFORM_JELLYFIN_FIXTURE_PRESEEDED="$jellyfin_fixture_preseeded" \
  `# The controller is a file rather than text pasted into an argument, so` \
  `# everything the launcher used to interpolate into it crosses as environment` \
  `# instead. Two roots meet in that program and neither may be inferred from` \
  `# where the file sits: /repo is the checkout under test, which is the copy at` \
  `# the sandbox path below rather than the calling workstation checkout, while` \
  `# the sandbox is the disposable tree the plays deploy into.` \
  -e CONTROLLER_REPO_DIR=/repo \
  -e CONTROLLER_SANDBOX="$sandbox" \
  -e CONTROLLER_PROJECT_NAMESPACE="$integration_project_namespace" \
  -e CONTROLLER_RUBY_PACKAGE="$ruby_package" \
  -e CONTROLLER_CURL_PACKAGE="$curl_package" \
  -e CONTROLLER_ANSIBLE_CORE_VERSION="$ansible_core_version" \
  -e CONTROLLER_REQUESTS_VERSION="$requests_version" \
  `# Both of these are a git rev-parse the launcher already ran against the` \
  `# right tree. Recomputing either inside the container would run git against` \
  `# /repo, which is the copy, and go wrong without saying so.` \
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
