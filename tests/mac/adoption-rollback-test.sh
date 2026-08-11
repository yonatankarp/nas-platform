#!/bin/sh
set -eu
set +x
umask 077

test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
rollback=$test_dir/adoption-rollback.sh

fail() {
  printf 'adoption rollback test failed: %s\n' "$1" >&2
  exit 1
}

[ -x "$rollback" ] || fail 'rollback helper is absent or not executable'
test_parent=$(mktemp -d "${TMPDIR:-/tmp}/adoption-rollback-test.XXXXXX")
test_parent=$(CDPATH= cd -- "$test_parent" && pwd -P)
trap '/usr/bin/find "$test_parent" -type d -exec chmod u+rwx {} +; /usr/bin/find "$test_parent" -depth -delete' EXIT HUP INT TERM
chmod 0700 "$test_parent"

bin=$test_parent/bin
legacy_root=$test_parent/legacy-checkout
reviewed_overrides=$test_parent/reviewed-overrides
mkdir -m 0700 "$bin" "$legacy_root" "$reviewed_overrides"
cp "$test_dir"/legacy-overrides/*.yml "$reviewed_overrides/"
chmod 0600 "$reviewed_overrides"/*.yml
log=$test_parent/operations.log
: > "$log"

cat > "$bin/snapshot" <<'SH'
#!/bin/sh
set -eu
case $1 in
  rollback-binding)
    baseline_digest=$(shasum -a 256 "$PLATFORM_MAC_SANDBOX/snapshot/pre-cutover/baseline.json" | awk '{print $1}')
    printf '{"binding_sha256":"%s","baseline_sha256":"%s","git_revision":"%s","legacy_commit":"%s"}\n' \
      "$(printf %064d 0 | tr 0 c)" "$baseline_digest" "$FAKE_GIT_REVISION" \
      '400f03f276ae1bb69f5460c175b9fb923d620f1a'
    ;;
  restore)
    printf 'restore %s %s\n' "$PLATFORM_MAC_SANDBOX" "$PLATFORM_ADOPTION_ROLLBACK_ROOT" >> "$FAKE_LOG"
    marker=$PLATFORM_ADOPTION_ROLLBACK_ROOT/.nas-platform-mac-owned
    [ -f "$marker" ]
    grep -qx "project=$PLATFORM_ADOPTION_ROLLBACK_PROJECT" "$marker"
    grep -qx 'namespace=rollback' "$marker"
    [ "$PLATFORM_ADOPTION_ROLLBACK_ROOT" != "$PLATFORM_MAC_SANDBOX" ]
    cp -R "$PLATFORM_MAC_SANDBOX/snapshot/pre-cutover/state/legacy" \
      "$PLATFORM_ADOPTION_ROLLBACK_ROOT/legacy"
    cp "$PLATFORM_MAC_SANDBOX/snapshot/pre-cutover/baseline.json" \
      "$PLATFORM_ADOPTION_ROLLBACK_ROOT/pre-cutover-baseline.json"
    chmod 0400 "$PLATFORM_ADOPTION_ROLLBACK_ROOT/pre-cutover-baseline.json"
    ;;
  *) exit 91 ;;
esac
SH

cat > "$bin/render" <<'SH'
#!/bin/sh
set -eu
[ "$1" = render ]
printf 'render %s %s\n' "$PLATFORM_MAC_SANDBOX" "$PLATFORM_PROJECT_NAME" >> "$FAKE_LOG"
mkdir -m 0700 "$PLATFORM_MAC_SANDBOX/legacy-env"
for service in audiobookshelf beszel dozzle immich jellyfin komga ntfy paperless-ngx tinymediamanager; do
  printf 'SAFE=value\n' > "$PLATFORM_MAC_SANDBOX/legacy-env/$service.env"
  chmod 0600 "$PLATFORM_MAC_SANDBOX/legacy-env/$service.env"
done
binding_sha=$(ruby -rdigest -rjson - "$PLATFORM_MAC_SANDBOX/legacy-env" <<'RUBY'
root = ARGV.fetch(0)
services = %w[audiobookshelf beszel dozzle immich jellyfin komga ntfy paperless-ngx tinymediamanager]
bytes = "#{JSON.generate("schema" => 1, "services" => services.to_h { |service|
  [service, Digest::SHA256.file(File.join(root, "#{service}.env")).hexdigest]
})}\n"
File.write(File.join(root, ".binding.json"), bytes, mode: "wx", perm: 0o400)
print Digest::SHA256.hexdigest(bytes)
RUBY
)
printf 'Legacy adoption render binding: %s\n' "$binding_sha"
if [ "${FAKE_PREOPEN_MUTATION:-}" = environment ]; then
  printf 'MUTATED=value\n' >> "$PLATFORM_MAC_SANDBOX/legacy-env/audiobookshelf.env"
fi
SH

cat > "$bin/baseline" <<'SH'
#!/bin/sh
set -eu
output=
while [ "$#" -gt 0 ]; do
  if [ "$1" = --output ]; then output=$2; shift 2; else shift; fi
done
for service in audiobookshelf beszel dozzle immich jellyfin komga ntfy paperless-ngx tinymediamanager; do
  printf 'probe %s\n' "$service" >> "$FAKE_LOG"
done
cp "$FAKE_BASELINE" "$output"
chmod 0600 "$output"
SH

cat > "$bin/git" <<'SH'
#!/bin/sh
set -eu
[ "$1" = -C ] && [ "$3" = cat-file ] && [ "$4" = blob ]
repository=$2
object=$5
path=${object#*:}
if [ "$repository" = "$FAKE_LEGACY_ROOT" ]; then
  cat "$FAKE_LEGACY_ROOT/$path"
  if [ "${FAKE_PREOPEN_MUTATION:-}" = base ] &&
      [ "$path" = "$FAKE_PREOPEN_BASE_PATH" ]; then
    printf 'mutated: true\n' >> "$FAKE_LEGACY_ROOT/$path"
  fi
else
  [ "${object%%:*}" = "$FAKE_GIT_REVISION" ]
  cat "$FAKE_REPO_DIR/$path"
  if [ "${FAKE_PREOPEN_MUTATION:-}" = override ] &&
      [ "$(basename -- "$path")" = audiobookshelf.yml ]; then
    printf 'mutated: true\n' >> "$FAKE_OVERRIDE_ROOT/audiobookshelf.yml"
  fi
fi
SH

cat > "$bin/docker" <<'SH'
#!/bin/sh
set -eu
printf 'docker' >> "$FAKE_LOG"
for argument in "$@"; do printf ' %s' "$argument" >> "$FAKE_LOG"; done
printf '\n' >> "$FAKE_LOG"
[ -z "${FAKE_CLEANUP_DISCOVERY_FAILURE:-}" ] || {
  case "$FAKE_CLEANUP_DISCOVERY_FAILURE:$*" in
    'ps:ps -a --format '*) exit 95 ;;
    'network:network ls --format '*) exit 95 ;;
    'volume:volume ls --format '*) exit 95 ;;
  esac
  case " $* " in
    *' ps -a --format '*|*' network ls --format '*|*' volume ls --format '*) exit 0 ;;
    *' -aq --filter '*|*' -q --filter '*) exit 0 ;;
    ' rm -f '*|' network rm '*|' volume rm '*) exit 0 ;;
    ' run --rm -i -v '*)
      mount=$5
      parent=${mount%:/sandbox-parent}
      shift 8
      /usr/bin/find "$parent/$1" -type d -exec chmod u+rwx {} +
      /usr/bin/find "$parent/$1" -depth -delete
      exit 0
      ;;
  esac
}
[ -z "${FAKE_CLEANUP_SUCCESS:-}" ] || {
  case " $* " in
    *' ps -a --format '*|*' network ls --format '*|*' volume ls --format '*)
      for cleanup_project in $FAKE_CLEANUP_PROJECTS; do
        printf '%s-beszel\n%s-legacy-immich\n' "$cleanup_project" "$cleanup_project"
      done
      exit 0
      ;;
    *' -aq --filter label=com.docker.compose.project='*|*' -q --filter label=com.docker.compose.project='*)
      label=
      for argument in "$@"; do
        case $argument in label=com.docker.compose.project=*) label=${argument#label=com.docker.compose.project=} ;; esac
      done
      printf 'id-%s-%s\n' "$1" "$(printf '%s' "$label" | tr -c 'A-Za-z0-9' '-')"
      exit 0
      ;;
    ' rm -f '*|' network rm '*|' volume rm '*) exit 0 ;;
    ' run --rm -i -v '*)
      mount=$5
      parent=${mount%:/sandbox-parent}
      shift 8
      name=$1
      /usr/bin/find "$parent/$name" -type d -exec chmod u+rwx {} +
      /usr/bin/find "$parent/$name" -depth -delete
      exit 0
      ;;
  esac
}
[ -z "${FAKE_CLEANUP_UNKNOWN:-}" ] || {
  case " $* " in
    *' ps -a --format '*) printf '%s-unknown\n' "$FAKE_CLEANUP_UNKNOWN"; exit 0 ;;
    *' network ls --format '*|*' volume ls --format '*) exit 0 ;;
  esac
}
[ "$1" = compose ] || exit 92
project=
previous=
for argument in "$@"; do
  [ "$previous" != --project-name ] || project=$argument
  previous=$argument
done
service=${project##*-legacy-}
case " $* " in
  *' config --format json '*)
    printf '{"services":{"%s":{"image":"example/%s@sha256:%s","volumes":[]}}}\n' \
      "$service" "$service" "$(printf %064d 0 | tr 0 c)"
    ;;
  *' config --images '*)
    if [ "${FAKE_IMAGE_MISMATCH:-}" = "$service" ]; then
      printf 'hostile/%s@sha256:%s\n' "$service" "$(printf %064d 0 | tr 0 d)"
    elif [ "$service" = immich ]; then
      printf 'example/shared@sha256:%s\n' "$(printf %064d 0 | tr 0 e)"
      printf 'example/immich@sha256:%s\n' "$(printf %064d 0 | tr 0 c)"
      printf 'example/shared@sha256:%s\n' "$(printf %064d 0 | tr 0 e)"
    else
      printf 'example/%s@sha256:%s\n' "$service" "$(printf %064d 0 | tr 0 c)"
    fi
    ;;
  *' up --detach '*)
    if [ "${FAKE_LIVE_INPUT_MUTATION:-}" = 1 ]; then
      case " $* " in
        *"$FAKE_LIVE_LEGACY_ROOT"*|*"$FAKE_LIVE_OVERRIDE_ROOT"*|*'/legacy-env/'*) exit 96 ;;
      esac
    fi
    for path in \
      legacy/immich/data legacy/immich/thumbs legacy/immich/encoded-video \
      legacy/immich/profile legacy/immich/backups legacy/immich/model-cache legacy/immich/postgres \
      legacy/paperless-ngx/redis legacy/paperless-ngx/postgres legacy/paperless-ngx/data \
      legacy/paperless-ngx/export legacy/paperless-ngx/tessdata/heb.traineddata \
      legacy/paperless-ngx/media legacy/paperless-ngx/consume; do
      [ -e "$PLATFORM_MAC_SANDBOX/$path" ] || exit 93
    done
    [ "${FAKE_UP_FAILURE:-}" != "$service" ] || exit 94
    ;;
esac
SH
chmod 0755 "$bin/snapshot" "$bin/render" "$bin/baseline" "$bin/git" "$bin/docker"

services='audiobookshelf beszel dozzle immich jellyfin komga ntfy paperless-ngx tinymediamanager'
for service in $services; do
  legacy_path=$(ruby -ryaml -e '
    entry = YAML.safe_load_file(ARGV[0], aliases: false).fetch("services").find { |item| item.fetch("name") == ARGV[1] }
    print entry.fetch("legacy_path")
  ' "$test_dir/../../services/manifest.yml" "$service")
  mkdir -p "$legacy_root/$(dirname -- "$legacy_path")"
  printf 'services: {}\n' > "$legacy_root/$legacy_path"
done
audiobookshelf_legacy_path=$(ruby -ryaml -e '
  entry = YAML.safe_load_file(ARGV[0], aliases: false).fetch("services").find { |item| item.fetch("name") == "audiobookshelf" }
  print entry.fetch("legacy_path")
' "$test_dir/../../services/manifest.yml")

sandbox=$test_parent/nas-platform-mac.Abc123
mkdir -m 0700 "$sandbox"
project=nas-platform-mac-abc123
printf 'schema=1\nproject=%s\n' "$project" > "$sandbox/.nas-platform-mac-owned"
chmod 0600 "$sandbox/.nas-platform-mac-owned"
mkdir -p "$sandbox/snapshot/pre-cutover/state/legacy"
for path in \
  immich/data immich/thumbs immich/encoded-video immich/profile immich/backups \
  immich/model-cache immich/postgres paperless-ngx/redis paperless-ngx/postgres \
  paperless-ngx/data paperless-ngx/export paperless-ngx/media paperless-ngx/consume; do
  mkdir -p "$sandbox/snapshot/pre-cutover/state/legacy/$path"
  printf 'snapshot-%s\n' "$path" > "$sandbox/snapshot/pre-cutover/state/legacy/$path/state"
done
mkdir -p "$sandbox/snapshot/pre-cutover/state/legacy/paperless-ngx/tessdata"
printf 'snapshot-model\n' > "$sandbox/snapshot/pre-cutover/state/legacy/paperless-ngx/tessdata/heb.traineddata"
for service in audiobookshelf beszel dozzle jellyfin komga ntfy tinymediamanager; do
  mkdir -p "$sandbox/snapshot/pre-cutover/state/legacy/$service/state"
  printf 'snapshot-%s\n' "$service" > "$sandbox/snapshot/pre-cutover/state/legacy/$service/state/value"
done

baseline=$sandbox/snapshot/pre-cutover/baseline.json
ruby -rjson - "$baseline" <<'RUBY'
services = %w[audiobookshelf beszel dozzle immich jellyfin komga ntfy paperless-ngx tinymediamanager]
images = services.to_h { |service| [service, ["example/#{service}@sha256:#{'c' * 64}"]] }
images["immich"] = [
  "example/immich@sha256:#{'c' * 64}",
  "example/shared@sha256:#{'e' * 64}",
  "example/shared@sha256:#{'e' * 64}"
]
File.write(ARGV.fetch(0), JSON.generate(
  "legacy_commit" => "400f03f276ae1bb69f5460c175b9fb923d620f1a",
  "legacy_images" => images, "services" => {}
))
RUBY
chmod 0400 "$baseline"
cp "$baseline" "$sandbox/baseline.json"
chmod 0600 "$sandbox/baseline.json"
report_root=$test_parent/reports
mkdir -m 0700 "$report_root"
printf '{}\n' > "$report_root/phase-input.json"
chmod 0600 "$report_root/phase-input.json"

tree_digest() {
  ruby -rdigest - "$1" <<'RUBY'
root = File.realpath(ARGV.fetch(0))
digest = Digest::SHA256.new
Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).sort.each do |path|
  next if [".", ".."].include?(File.basename(path))
  relative = path.delete_prefix("#{root}/")
  stat = File.lstat(path)
  digest << relative << "\0" << stat.mode.to_s << "\0"
  digest << File.binread(path) if stat.file?
end
puts digest.hexdigest
RUBY
}

run_rollback() {
  env PATH="$bin:$PATH" FAKE_LOG="$log" FAKE_BASELINE="$baseline" \
    FAKE_LEGACY_ROOT="$legacy_root" FAKE_REPO_DIR="$test_dir/../.." \
    FAKE_GIT_REVISION="$(git -C "$test_dir/../.." rev-parse HEAD)" \
    FAKE_OVERRIDE_ROOT="$reviewed_overrides" FAKE_PREOPEN_BASE_PATH="$audiobookshelf_legacy_path" \
    PLATFORM_MAC_TMPDIR="$test_parent" PLATFORM_MAC_SANDBOX="$sandbox" \
    PLATFORM_PROJECT_NAME="$project" PLATFORM_ADOPTION_ENABLED=true \
    PLATFORM_ADOPTION_ROOT="$sandbox" \
    PLATFORM_ADOPTION_MARKER="$(printf %064d 0 | tr 0 c)" \
    PLATFORM_REPORT_ROOT="$report_root" PLATFORM_LEGACY_ROOT="$legacy_root" \
    PLATFORM_ADOPTION_ROLLBACK_SELF_TEST=1 \
    PLATFORM_ADOPTION_ROLLBACK_SNAPSHOT_COMMAND="$bin/snapshot" \
    PLATFORM_ADOPTION_ROLLBACK_BASELINE_COMMAND="$bin/baseline" \
    PLATFORM_ADOPTION_ROLLBACK_RENDER_COMMAND="$bin/render" \
    PLATFORM_ADOPTION_ROLLBACK_OVERRIDE_ROOT="$reviewed_overrides" "$@" "$rollback"
}

sandbox_before=$(tree_digest "$sandbox")
run_rollback > "$test_parent/success.out"
[ "$(tree_digest "$sandbox")" = "$sandbox_before" ] || fail 'successful rollback changed cutover state'
rollback_project=$(sed -n 's/^Legacy adoption rollback: \([^ ]*\) evidence.*/\1/p' "$test_parent/success.out")
[ -n "$rollback_project" ] || fail 'rollback project was not reported'
rollback_root=$(find "$test_parent" -maxdepth 1 -type d -name 'nas-platform-mac.??????' \
  ! -path "$sandbox" -exec sh -c 'grep -qx namespace=rollback "$1/.nas-platform-mac-owned" && printf "%s\n" "$1"' sh {} \;)
[ -n "$rollback_root" ] && [ "$rollback_root" != "$sandbox" ] || fail 'fresh rollback sandbox is absent'
[ "$(sed -n 's/^project=//p' "$rollback_root/.nas-platform-mac-owned")" = "$rollback_project" ] ||
  fail 'rollback marker and project differ'
grep -Fqx "render $rollback_root $rollback_project" "$log" ||
  fail 'parity rendering did not receive the rollback sandbox and project'

up_count=$(grep -c ' up --detach ' "$log")
stop_count=$(grep -c ' stop$' "$log")
[ "$up_count" -eq 9 ] && [ "$stop_count" -eq 9 ] || fail 'all nine rollback projects were not started and stopped'
for service in $services; do
  grep -Fq -- "--project-name $rollback_project-legacy-$service" "$log" ||
    fail "$service did not use the rollback legacy namespace"
  [ "$(grep -c "^probe $service$" "$log")" -eq 1 ] || fail "$service rollback probe did not run exactly once"
done
if grep -Fq -- "--project-name $project-" "$log"; then
  fail 'rollback reused a cutover project namespace'
fi
first_up=$(grep -n ' up --detach ' "$log" | sed -n '1s/:.*//p')
restore_line=$(grep -n '^restore ' "$log" | sed -n '1s/:.*//p')
probe_line=$(grep -n '^probe ' "$log" | sed -n '1s/:.*//p')
stop_line=$(grep -n ' stop$' "$log" | sed -n '1s/:.*//p')
[ "$restore_line" -lt "$first_up" ] && [ "$first_up" -lt "$probe_line" ] &&
  [ "$probe_line" -lt "$stop_line" ] || fail 'restore/start/probe/stop ordering differs'

for fault in before-restore after-restore; do
  : > "$log"
  if run_rollback PLATFORM_ADOPTION_ROLLBACK_FAULT="$fault" >/dev/null 2>&1; then
    fail "$fault fault was accepted"
  fi
  [ "$(tree_digest "$sandbox")" = "$sandbox_before" ] || fail "$fault fault changed cutover state"
done

: > "$log"
if run_rollback FAKE_UP_FAILURE=immich >/dev/null 2>&1; then
  fail 'rollback accepted a partial project start failure'
fi
[ "$(grep -c ' up --detach ' "$log")" -eq 4 ] || fail 'partial start fixture did not reach Immich'
[ "$(grep -c ' stop$' "$log")" -eq 4 ] || fail 'partial start did not stop every attempted project'
failed_project=$(grep ' up --detach ' "$log" | tail -1 | sed -n 's/.*--project-name \([^ ]*\).*/\1/p')
grep -F -- "--project-name $failed_project" "$log" | grep -q ' stop$' ||
  fail 'failed project namespace was not stopped'
[ "$(tree_digest "$sandbox")" = "$sandbox_before" ] || fail 'partial start failure changed cutover state'

: > "$log"
run_rollback FAKE_LIVE_INPUT_MUTATION=1 FAKE_LIVE_LEGACY_ROOT="$legacy_root" \
  FAKE_LIVE_OVERRIDE_ROOT="$reviewed_overrides" >/dev/null ||
  fail 'transient live Compose input mutation reached rollback execution'
if grep ' up --detach ' "$log" | grep -Eq "${legacy_root}|${reviewed_overrides}|/legacy-env/"; then
  fail 'rollback up reopened a live Compose input path'
fi
[ "$(tree_digest "$sandbox")" = "$sandbox_before" ] || fail 'live input mutation changed cutover state'

for preopen_mutation in base override environment; do
  cp "$test_dir/legacy-overrides/audiobookshelf.yml" "$reviewed_overrides/audiobookshelf.yml"
  chmod 0600 "$reviewed_overrides/audiobookshelf.yml"
  printf 'services: {}\n' > "$legacy_root/$audiobookshelf_legacy_path"
  : > "$log"
  if run_rollback FAKE_PREOPEN_MUTATION="$preopen_mutation" >/dev/null 2>&1; then
    fail "rollback accepted a $preopen_mutation input replaced before descriptor binding"
  fi
  [ "$(grep -c ' up --detach ' "$log" || true)" -eq 0 ] ||
    fail "$preopen_mutation input mutation started rollback containers"
  [ "$(tree_digest "$sandbox")" = "$sandbox_before" ] ||
    fail "$preopen_mutation input mutation changed cutover state"
done

: > "$log"
if run_rollback FAKE_IMAGE_MISMATCH=immich >/dev/null 2>&1; then
  fail 'rollback accepted an image different from the baseline'
fi
[ "$(grep -c ' up --detach ' "$log" || true)" -eq 0 ] || fail 'image mismatch started rollback containers'
[ "$(tree_digest "$sandbox")" = "$sandbox_before" ] || fail 'image mismatch changed cutover state'

expected_labels=$test_parent/expected-labels
for owned_project in "$project" "$rollback_project"; do
  for suffix in beszel ntfy dozzle audiobookshelf komga tinymediamanager jellyfin immich paperless; do
    printf '%s-%s\n' "$owned_project" "$suffix"
  done
  for service in $services; do
    printf '%s-legacy-%s\n' "$owned_project" "$service"
  done
done > "$expected_labels"
actual_labels=$test_parent/actual-labels
for owned_project in "$project" "$rollback_project"; do
  PLATFORM_MAC_CLEANUP_PROJECT_SELF_TEST=1 "$test_dir/cleanup.sh" \
    --self-test-projects "$owned_project" </dev/null
done > "$actual_labels"
cmp -s "$expected_labels" "$actual_labels" || fail 'cleanup project label sets differ'
if printf '%s-unknown\n' "$project" | PLATFORM_MAC_CLEANUP_PROJECT_SELF_TEST=1 \
    "$test_dir/cleanup.sh" --self-test-projects "$project" >/dev/null 2>&1; then
  fail 'cleanup accepted an unknown related Compose project'
fi

owned_before=$(find "$test_parent" -maxdepth 1 -type d -name 'nas-platform-mac.??????' | sort)
: > "$log"
if PATH="$bin:$PATH" FAKE_LOG="$log" FAKE_CLEANUP_UNKNOWN="$project" \
    PLATFORM_MAC_TMPDIR="$test_parent" "$test_dir/cleanup.sh" "$sandbox" >/dev/null 2>&1; then
  fail 'cleanup accepted an unknown source-related Compose project'
fi
owned_after=$(find "$test_parent" -maxdepth 1 -type d -name 'nas-platform-mac.??????' | sort)
[ "$owned_after" = "$owned_before" ] || fail 'cleanup partially deleted an owned namespace before refusal'
if grep -Eq '^docker (rm|network rm|volume rm|run) ' "$log"; then
  fail 'cleanup mutated Docker resources before unknown-project refusal'
fi

for discovery_failure in ps network volume; do
  owned_before=$(find "$test_parent" -maxdepth 1 -type d -name 'nas-platform-mac.??????' | sort)
  : > "$log"
  if PATH="$bin:$PATH" FAKE_LOG="$log" \
      FAKE_CLEANUP_DISCOVERY_FAILURE="$discovery_failure" PLATFORM_MAC_TMPDIR="$test_parent" \
      "$test_dir/cleanup.sh" "$sandbox" >/dev/null 2>&1; then
    fail "cleanup accepted a failed $discovery_failure discovery"
  fi
  owned_after=$(find "$test_parent" -maxdepth 1 -type d -name 'nas-platform-mac.??????' | sort)
  [ "$owned_after" = "$owned_before" ] || fail "$discovery_failure discovery failure deleted an owned namespace"
  if grep -Eq '^docker (rm|network rm|volume rm|run) ' "$log"; then
    fail "$discovery_failure discovery failure mutated resources"
  fi
done

vault_sentinel=$test_parent/external-vault
report_sentinel=$test_parent/external-report
legacy_sentinel=$legacy_root/external-sentinel
printf 'vault-sentinel\n' > "$vault_sentinel"
printf 'report-sentinel\n' > "$report_sentinel"
printf 'legacy-sentinel\n' > "$legacy_sentinel"
external_before=$(shasum -a 256 "$vault_sentinel" "$report_sentinel" "$legacy_sentinel")
owned_before=$(find "$test_parent" -maxdepth 1 -type d -name 'nas-platform-mac.??????' | sort)
cleanup_projects=$(printf '%s\n' "$owned_before" | while IFS= read -r owned_root; do
  sed -n 's/^project=//p' "$owned_root/.nas-platform-mac-owned"
done | tr '\n' ' ')
owned_count=$(printf '%s\n' "$owned_before" | grep -c .)
: > "$log"
PATH="$bin:$PATH" FAKE_LOG="$log" FAKE_CLEANUP_SUCCESS=1 \
  FAKE_CLEANUP_PROJECTS="$cleanup_projects" PLATFORM_MAC_TMPDIR="$test_parent" \
  "$test_dir/cleanup.sh" "$sandbox"
[ -z "$(find "$test_parent" -maxdepth 1 -type d -name 'nas-platform-mac.??????' -print -quit)" ] ||
  fail 'cleanup did not remove source and rollback sandboxes'
[ "$(grep -c '^docker rm -f ' "$log")" -eq $((owned_count * 18)) ] ||
  fail 'cleanup did not remove each owned container exactly once'
[ "$(grep -c '^docker network rm ' "$log")" -eq $((owned_count * 18)) ] ||
  fail 'cleanup did not remove each owned network exactly once'
[ "$(grep -c '^docker volume rm ' "$log")" -eq $((owned_count * 18)) ] ||
  fail 'cleanup did not remove each owned volume exactly once'
[ "$(shasum -a 256 "$vault_sentinel" "$report_sentinel" "$legacy_sentinel")" = "$external_before" ] ||
  fail 'cleanup changed external vault, report, or legacy checkout evidence'

grep -Fq 'tests/mac/adoption-rollback-test.sh' "$test_dir/../../.github/workflows/ci.yml" ||
  fail 'required CI does not execute the rollback rehearsal gate'

printf 'adoption rollback: isolation properties hold\n'
