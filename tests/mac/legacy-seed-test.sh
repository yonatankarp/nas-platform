#!/bin/sh
set -eu
set +x
umask 077

test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_dir=$(CDPATH= cd -- "$test_dir/../.." && pwd -P)
compose=$test_dir/legacy-compose.sh
seed=$test_dir/legacy-seed.sh
temporary_input=$(mktemp -d "${TMPDIR:-/tmp}/nas-platform-legacy-seed.XXXXXX")
temporary_root=$(CDPATH= cd -- "$temporary_input" && pwd -P)

cleanup() {
  test_status=$?
  trap - EXIT HUP INT TERM
  if [ -d "$temporary_root" ] && [ ! -L "$temporary_root" ]; then
    /usr/bin/find "$temporary_root" -depth -delete
  fi
  exit "$test_status"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}
tab=$(printf '\t')

[ -x "$compose" ] || fail 'legacy Compose helper is absent or not executable'
[ -x "$seed" ] || fail 'legacy seed helper is absent or not executable'
ruby -ryaml - "$test_dir/legacy-role-seed.yml" <<'RUBY' || fail 'legacy role seed entrypoints differ'
play = YAML.safe_load_file(ARGV.fetch(0), aliases: false).fetch(0)
roles = play.fetch("roles")
expected = {
  "ntfy" => "ntfy", "beszel" => "beszel", "dozzle" => "dozzle",
  "audiobookshelf" => "audiobookshelf", "komga" => "komga",
  "jellyfin" => "jellyfin", "immich" => "immich", "paperless_ngx" => "paperless",
  "tinymediamanager" => "tinymediamanager"
}
actual = roles.to_h do |entry|
  raise unless entry.is_a?(Hash) && entry.fetch("tags").length == 1
  [entry.fetch("role"), entry.fetch("tags").fetch(0)]
end
raise unless actual == expected
RUBY

legacy_root=$temporary_root/'nas infrastructure "quoted"'
sandbox=$temporary_root/nas-platform-mac.LgCy42
fake_bin=$temporary_root/bin
log=$temporary_root/commands.log
mkdir -m 0700 "$legacy_root" "$sandbox" "$fake_bin" "$sandbox/legacy-env"
printf 'schema=1\nproject=nas-platform-mac-lgcy42\n' > "$sandbox/.nas-platform-mac-owned"
chmod 0600 "$sandbox/.nas-platform-mac-owned"

ruby -ryaml -rfileutils - "$repo_dir/services/manifest.yml" "$legacy_root" "$sandbox" <<'RUBY'
manifest, root, sandbox = ARGV
YAML.safe_load_file(manifest, aliases: false).fetch("services").each do |service|
  path = File.join(root, service.fetch("legacy_path"))
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, "services: {}\n")
  File.write(File.join(sandbox, "legacy-env", "#{service.fetch('name')}.env"), "CANARY=protected-value\n")
end
RUBY
chmod 0600 "$sandbox"/legacy-env/*.env

cat > "$fake_bin/docker" <<'SH'
#!/bin/sh
printf 'docker' >> "${FAKE_COMMAND_LOG:?}"
for argument in "$@"; do printf '\t%s' "$argument" >> "$FAKE_COMMAND_LOG"; done
printf '\n' >> "$FAKE_COMMAND_LOG"
case " $* " in
  *' config --services '*) printf '%s\n' one two ;;
  *' ps --format {{.Label "com.docker.compose.project"}} '*)
    [ -z "${FAKE_RESTARTED_PROJECT:-}" ] || printf '%s\n' "$FAKE_RESTARTED_PROJECT"
    ;;
  *' ps --all --format json '*)
    case ${FAKE_PS_STATE:-healthy} in
      healthy) printf '%s\n' '[{"Service":"one","State":"running","Health":"healthy"},{"Service":"two","State":"running","Health":""}]' ;;
      unhealthy) printf '%s\n' '[{"Service":"one","State":"running","Health":"unhealthy"},{"Service":"two","State":"running","Health":""}]' ;;
      starting) printf '%s\n' '[{"Service":"one","State":"running","Health":"starting"},{"Service":"two","State":"running","Health":""}]' ;;
      exited) printf '%s\n' '[{"Service":"one","State":"exited","Health":""},{"Service":"two","State":"running","Health":""}]' ;;
      missing) printf '%s\n' '[{"Service":"one","State":"running","Health":"healthy"}]' ;;
      duplicate) printf '%s\n' '[{"Service":"one","State":"running","Health":"healthy"},{"Service":"one","State":"running","Health":"healthy"},{"Service":"two","State":"running","Health":""}]' ;;
      unexpected) printf '%s\n' '[{"Service":"one","State":"running","Health":"healthy"},{"Service":"two","State":"running","Health":""},{"Service":"three","State":"running","Health":""}]' ;;
    esac
    ;;
esac
SH
chmod 0700 "$fake_bin/docker"

run_compose() {
  env PATH="$fake_bin:$PATH" FAKE_COMMAND_LOG="$log" \
    FAKE_PS_STATE="${FAKE_PS_STATE:-healthy}" \
    PLATFORM_MAC_TMPDIR="$temporary_root" PLATFORM_LEGACY_ROOT="$legacy_root" \
    PLATFORM_MAC_SANDBOX="$sandbox" \
    PLATFORM_PROJECT_NAME=nas-platform-mac-lgcy42 "$compose" "$@"
}

services='audiobookshelf beszel dozzle immich jellyfin komga ntfy paperless-ngx tinymediamanager'
: > "$log"
for service in $services; do
  run_compose "$service" config
done
[ "$(wc -l < "$log" | tr -d ' ')" -eq 9 ] || fail 'Compose config did not cover nine services'
for service in $services; do
  grep -F "--project-name${tab}nas-platform-mac-lgcy42-legacy-$service" "$log" >/dev/null 2>&1 ||
    grep -F "nas-platform-mac-lgcy42-legacy-$service" "$log" >/dev/null ||
    fail "legacy project is absent for $service"
  grep -F "$sandbox/legacy-env/$service.env" "$log" >/dev/null ||
    fail "rendered environment is absent for $service"
  grep -F "$test_dir/legacy-overrides/$service.yml" "$log" >/dev/null ||
    fail "reviewed override is absent for $service"
done
run_compose beszel ps || fail 'healthy structured legacy project was rejected'

if run_compose unknown config >/dev/null 2>&1; then
  fail 'unknown legacy service was accepted'
fi
if run_compose beszel exec >/dev/null 2>&1; then
  fail 'unknown legacy action was accepted'
fi
for rejected_state in unhealthy starting exited missing duplicate unexpected; do
  if FAKE_PS_STATE=$rejected_state run_compose beszel ps >/dev/null 2>&1; then
    fail "$rejected_state legacy project passed the health gate"
  fi
done
unset FAKE_PS_STATE
if env PATH="$fake_bin:$PATH" FAKE_COMMAND_LOG="$log" PLATFORM_MAC_TMPDIR="$temporary_root" \
    PLATFORM_LEGACY_ROOT="$legacy_root" PLATFORM_MAC_SANDBOX="$sandbox" \
    PLATFORM_PROJECT_NAME=unowned-project "$compose" beszel config >/dev/null 2>&1; then
  fail 'project name differing from the owned sandbox marker was accepted'
fi

: > "$log"
run_compose beszel stop
run_compose beszel down
if grep -E -- '--volumes|(^|[[:space:]])-v([[:space:]]|$)|(^|[[:space:]])(find|delete|rm)([[:space:]]|$)' \
    "$log" >/dev/null; then
  fail 'legacy stop/down requested volumes or bind deletion'
fi

cat > "$fake_bin/ansible-playbook" <<'SH'
#!/bin/sh
printf 'ansible-playbook' >> "${FAKE_COMMAND_LOG:?}"
for argument in "$@"; do printf '\t%s' "$argument" >> "$FAKE_COMMAND_LOG"; done
printf '\n' >> "$FAKE_COMMAND_LOG"
case " $* " in
  *legacy-render.yml*)
    root=
    for argument in "$@"; do
      case $argument in legacy_env_root=*) root=${argument#legacy_env_root=} ;; esac
    done
    [ -n "$root" ] || exit 2
    mkdir -m 0700 "$root"
    for service in audiobookshelf beszel dozzle immich jellyfin komga ntfy paperless-ngx tinymediamanager; do
      printf '%s\n' 'CANARY=protected-value' > "$root/$service.env"
      chmod 0600 "$root/$service.env"
    done
    exit 0
    ;;
  *legacy-beszel-key.yml*)
    hub_root=
    for argument in "$@"; do
      case $argument in beszel_legacy_hub_root=*) hub_root=${argument#beszel_legacy_hub_root=} ;; esac
    done
    [ -n "$hub_root" ] || exit 33
    printf '%s\n' 'disposable-beszel-private-key' > "$hub_root/id_ed25519"
    chmod 0600 "$hub_root/id_ed25519"
    exit 0
    ;;
esac
case " $* " in
  *' --tags '*)
    tag=
    current=
    runtime=
    previous=
    for argument in "$@"; do
      [ "$argument" != --start-at-task ] || exit 30
      [ "$previous" != --tags ] || tag=$argument
      case $argument in
        platform_current_dir=*) current=${argument#platform_current_dir=} ;;
        platform_runtime_dir=*) runtime=${argument#platform_runtime_dir=} ;;
      esac
      previous=$argument
    done
    [ -n "$tag" ] && [ -n "$current" ] && [ -n "$runtime" ] || exit 31
    case $tag in paperless) slug=paperless-ngx ;; *) slug=$tag ;; esac
    [ -f "$current/services/$slug/compose.yml" ] &&
      [ -f "$current/services/$slug/compose.mac.yml" ] || exit 32
    mkdir -m 0700 -p "$runtime/services/$slug"
    printf '%s\n' "SERVICE=$slug" > "$runtime/services/$slug/.env"
    chmod 0600 "$runtime/services/$slug/.env"
    [ "$tag" != ntfy ] || : > "${FAKE_NTFY_PREREQUISITES_MARKER:?}"
    [ "$tag" != tinymediamanager ] || : > "${FAKE_TMM_CREDENTIAL_MARKER:?}"
    ;;
esac
case " $* " in
  *" ${FAKE_SEED_FAIL_LABEL:-never-match} "*) exit 29 ;;
esac
SH
cat > "$fake_bin/ansible-vault" <<'SH'
#!/bin/sh
[ "${1-}" = view ] || exit 2
cat "${FAKE_PARITY_DOCUMENT:?}"
SH
cat > "$fake_bin/git" <<'SH'
#!/bin/sh
case " $* " in
  *' remote get-url origin '*) printf '%s\n' 'https://github.com/yonatankarp/nas-infrastructure.git' ;;
  *' rev-parse --show-toplevel '*) printf '%s\n' "${PLATFORM_LEGACY_ROOT:?}" ;;
  *' rev-parse HEAD '*) printf '%s\n' '400f03f276ae1bb69f5460c175b9fb923d620f1a' ;;
  *' status --porcelain=v1 --untracked-files=all '*) ;;
  *' ls-files --error-unmatch -- '*) for argument in "$@"; do path=$argument; done; printf '%s\n' "$path" ;;
  *' ls-files -v -- '*) for argument in "$@"; do path=$argument; done; printf 'H %s\n' "$path" ;;
  *' cat-file blob HEAD:'*)
    for argument in "$@"; do object=$argument; done
    cat "${PLATFORM_LEGACY_ROOT:?}/${object#HEAD:}"
    ;;
  *' ls-tree HEAD -- '*) for argument in "$@"; do path=$argument; done; printf '100644 blob %040d\t%s\n' 0 "$path" ;;
  *) exit 2 ;;
esac
SH
cat > "$sandbox/fake-fixture-driver.sh" <<'SH'
#!/bin/sh
service=$1
mode=$2
project=${PLATFORM_FIXTURE_COMPOSE_PROJECT:?}
[ "$project" = "${PLATFORM_PROJECT_NAME:?}-legacy-$service" ] || exit 41
case $service:$mode in
  audiobookshelf:seed-progress)
    [ "$PLATFORM_AUDIOBOOKSHELF_MEDIA_LIBRARY" = "$PLATFORM_MAC_SANDBOX/legacy/audiobookshelf/media" ] || exit 42
    [ "$PLATFORM_FIXTURE_COMPOSE_SERVICE" = audiobookshelf ] || exit 43
    ;;
  komga:seed)
    [ "$PLATFORM_KOMGA_LIBRARY_PATH" = "$PLATFORM_MAC_SANDBOX/legacy/komga/library" ] || exit 44
    [ "$PLATFORM_FIXTURE_COMPOSE_SERVICE" = komga ] || exit 45
    ;;
  tinymediamanager:seed)
    [ "$PLATFORM_TINYMEDIAMANAGER_MOVIES_ROOT" = "$PLATFORM_MAC_SANDBOX/legacy/tinymediamanager/movies" ] || exit 46
    [ "$PLATFORM_TINYMEDIAMANAGER_SERIES_ROOT" = "$PLATFORM_MAC_SANDBOX/legacy/tinymediamanager/series" ] || exit 47
    [ "$PLATFORM_TINYMEDIAMANAGER_SETTINGS_ROOT" = "$PLATFORM_MAC_SANDBOX/legacy/tinymediamanager/data/data" ] || exit 48
    [ "$PLATFORM_TINYMEDIAMANAGER_CONTAINER" = "$project-tinymediamanager-1" ] || exit 49
    ;;
  jellyfin:seed)
    [ "$PLATFORM_JELLYFIN_MEDIA_ROOT" = "$PLATFORM_MAC_SANDBOX/legacy/jellyfin/media" ] || exit 50
    [ "$PLATFORM_JELLYFIN_CONTAINER" = "$project-jellyfin-1" ] || exit 51
    ;;
  immich:seed)
    [ "$PLATFORM_IMMICH_UPLOAD_ROOT" = "$PLATFORM_MAC_SANDBOX/legacy/immich/data/upload" ] || exit 52
    [ "$PLATFORM_IMMICH_THUMBNAIL_ROOT" = "$PLATFORM_MAC_SANDBOX/legacy/immich/thumbs" ] || exit 53
    [ "$PLATFORM_IMMICH_SERVER_CONTAINER" = "$project-immich-server-1" ] || exit 54
    [ "$PLATFORM_IMMICH_POSTGRES_CONTAINER" = "$project-database-1" ] || exit 55
    ;;
  paperless-ngx:seed)
    [ "$PLATFORM_PAPERLESS_CONSUME_ROOT" = "$PLATFORM_MAC_SANDBOX/legacy/paperless-ngx/consume" ] || exit 56
    [ "$PLATFORM_PAPERLESS_EXPORT_ROOT" = "$PLATFORM_MAC_SANDBOX/legacy/paperless-ngx/export" ] || exit 57
    [ "$PLATFORM_PAPERLESS_WEBSERVER_CONTAINER" = "$project-webserver-1" ] || exit 58
    ;;
  *) exit 59 ;;
esac
printf 'legacy-fixture\t%s\t%s\t%s\t%s\n' "$service" "$mode" "$project" \
  "$PLATFORM_FIXTURE_COMPOSE_SERVICE" >> "${FAKE_COMMAND_LOG:?}"
SH
chmod 0700 "$fake_bin/ansible-playbook" "$fake_bin/ansible-vault" "$fake_bin/git" \
  "$sandbox/fake-fixture-driver.sh"

: > "$log"
if env PATH="$fake_bin:$PATH" FAKE_COMMAND_LOG="$log" \
  FAKE_RESTARTED_PROJECT=nas-platform-mac-lgcy42-legacy-audiobookshelf \
  PLATFORM_MAC_TMPDIR="$temporary_root" PLATFORM_LEGACY_ROOT="$legacy_root" \
  NAS_INFRASTRUCTURE_DIR="$legacy_root" PLATFORM_MAC_SANDBOX="$sandbox" \
  PLATFORM_PROJECT_NAME=nas-platform-mac-lgcy42 PLATFORM_REPORT_ROOT="$sandbox/report" \
  "$test_dir/adoption.sh" snapshot >"$temporary_root/snapshot-restart-output" 2>&1; then
  fail 'restarted legacy project was accepted immediately before snapshot copy'
fi
[ "$(grep -c "$(printf '\t')stop$" "$log")" -eq 9 ] ||
  fail 'legacy restart regression did not first stop all nine projects'
grep -F 'legacy projects restarted before snapshot copy' "$temporary_root/snapshot-restart-output" >/dev/null ||
  fail 'legacy restart regression emitted wrong diagnostic'

run_seed() {
  env PATH="$fake_bin:$PATH" FAKE_COMMAND_LOG="$log" \
    FAKE_REPO_DIR="$repo_dir" \
    FAKE_NTFY_PREREQUISITES_MARKER="$temporary_root/ntfy-prerequisites" \
    FAKE_TMM_CREDENTIAL_MARKER="$temporary_root/tmm-credential" \
    PLATFORM_MAC_TMPDIR="$temporary_root" PLATFORM_LEGACY_ROOT="$legacy_root" \
    PLATFORM_MAC_SANDBOX="$sandbox" \
    PLATFORM_PROJECT_NAME=nas-platform-mac-lgcy42 \
    PLATFORM_MAC_VAULT_FILE="$temporary_root/deployment-vault.yml" \
    PLATFORM_MAC_VAULT_PASSWORD_FILE="$temporary_root/deployment-password" \
    PLATFORM_MAC_FIXTURE_VARS_FILE="$temporary_root/immich-fixture-vars.yml" \
    PLATFORM_LEGACY_FIXTURE_DRIVER="$sandbox/fake-fixture-driver.sh" \
    PLATFORM_AUDIOBOOKSHELF_PORT=31001 PLATFORM_BESZEL_PORT=31002 \
    PLATFORM_DOZZLE_PORT=31003 PLATFORM_IMMICH_PORT=31004 PLATFORM_JELLYFIN_PORT=31005 \
    PLATFORM_KOMGA_PORT=31006 PLATFORM_NTFY_PORT=31007 PLATFORM_PAPERLESS_PORT=31008 \
    PLATFORM_TINYMEDIAMANAGER_WEB_PORT=31009 PLATFORM_TINYMEDIAMANAGER_API_PORT=31010 \
    "$seed" "$@"
}
printf '%s\n%s\n' '$ANSIBLE_VAULT;1.1;AES256' 'tmm-secret-canary' \
  > "$temporary_root/deployment-vault.yml"
printf '%s\n' disposable > "$temporary_root/deployment-password"
chmod 0600 "$temporary_root/deployment-vault.yml" "$temporary_root/deployment-password"
printf '%s\n' 'immich_managed_user_preference_profile_by_email: {}' \
  > "$temporary_root/immich-fixture-vars.yml"
chmod 0600 "$temporary_root/immich-fixture-vars.yml"

parity_document=$temporary_root/parity-document.yml
ruby -ryaml - "$repo_dir/config/portainer-parity.yml" "$parity_document" <<'RUBY'
mapping, output = ARGV
contract = YAML.safe_load_file(mapping, aliases: false)
stacks = contract.fetch("stacks").to_h do |service, values|
  [service, values.keys.to_h { |key| [key, "protected-value"] }]
end
File.write(output, YAML.dump({
  "schema" => 1,
  "legacy_commit" => contract.fetch("legacy_commit"),
  "stacks" => stacks
}))
RUBY
parity_vault=$temporary_root/parity-vault.yml
parity_password=$temporary_root/parity-password
printf '%s\n' '$ANSIBLE_VAULT;1.1;AES256' > "$parity_vault"
printf '%s\n' disposable > "$parity_password"
chmod 0600 "$parity_vault" "$parity_password"

unhealthy_sandbox=$temporary_root/nas-platform-mac.Unhl42
mkdir -m 0700 "$unhealthy_sandbox"
printf 'schema=1\nproject=nas-platform-mac-unhl42\n' > "$unhealthy_sandbox/.nas-platform-mac-owned"
chmod 0600 "$unhealthy_sandbox/.nas-platform-mac-owned"
: > "$log"
if env PATH="$fake_bin:$PATH" FAKE_COMMAND_LOG="$log" FAKE_PARITY_DOCUMENT="$parity_document" \
    FAKE_PS_STATE=unhealthy PLATFORM_MAC_TMPDIR="$temporary_root" \
    PLATFORM_LEGACY_ROOT="$legacy_root" NAS_INFRASTRUCTURE_DIR="$legacy_root" \
    PLATFORM_MAC_SANDBOX="$unhealthy_sandbox" PLATFORM_PROJECT_NAME=nas-platform-mac-unhl42 \
    PLATFORM_MAC_PARITY_VAULT_FILE="$parity_vault" \
    PLATFORM_MAC_PARITY_VAULT_PASSWORD_FILE="$parity_password" \
    PLATFORM_MAC_VAULT_FILE="$temporary_root/deployment-vault.yml" \
    PLATFORM_MAC_VAULT_PASSWORD_FILE="$temporary_root/deployment-password" \
    "$test_dir/adoption.sh" legacy-deploy >/dev/null 2>&1; then
  fail 'unhealthy containers after Compose up passed legacy deployment'
fi
grep -q "${tab}up${tab}--detach${tab}--wait${tab}--wait-timeout${tab}600$" "$log" ||
  fail 'unhealthy-after-up test did not reach Compose deployment'
if grep '^ansible-playbook' "$log" | grep -Ev 'legacy-(render|beszel-key)\.yml' >/dev/null; then
  fail 'service seeding began after an unhealthy deployment'
fi

: > "$log"
env PATH="$fake_bin:$PATH" FAKE_COMMAND_LOG="$log" FAKE_PARITY_DOCUMENT="$parity_document" \
  PLATFORM_MAC_TMPDIR="$temporary_root" PLATFORM_LEGACY_ROOT="$legacy_root" \
  NAS_INFRASTRUCTURE_DIR="$legacy_root" PLATFORM_MAC_SANDBOX="$sandbox" \
  PLATFORM_PROJECT_NAME=nas-platform-mac-lgcy42 \
  PLATFORM_MAC_PARITY_VAULT_FILE="$parity_vault" \
  PLATFORM_MAC_PARITY_VAULT_PASSWORD_FILE="$parity_password" \
  PLATFORM_MAC_VAULT_FILE="$temporary_root/deployment-vault.yml" \
  PLATFORM_MAC_VAULT_PASSWORD_FILE="$temporary_root/deployment-password" \
  "$test_dir/adoption.sh" legacy-deploy >/dev/null
[ -f "$sandbox/legacy/paperless-ngx/tessdata/heb.traineddata" ] ||
  fail 'legacy deployment did not prepare the file-backed Paperless bind'
[ ! -L "$sandbox/legacy/paperless-ngx/tessdata/heb.traineddata" ] ||
  fail 'legacy deployment prepared an unsafe Paperless bind'
render_line=$(grep -n 'legacy-render.yml' "$log" | head -n 1 | cut -d: -f1)
first_config=$(grep -n "${tab}config${tab}--quiet$" "$log" | head -n 1 | cut -d: -f1)
last_config=$(grep -n "${tab}config${tab}--quiet$" "$log" | tail -n 1 | cut -d: -f1)
first_up=$(grep -n "${tab}up${tab}--detach${tab}--wait${tab}--wait-timeout${tab}600$" "$log" | head -n 1 | cut -d: -f1)
beszel_key_line=$(grep -n 'legacy-beszel-key.yml' "$log" | head -n 1 | cut -d: -f1)
last_up=$(grep -n "${tab}up${tab}--detach${tab}--wait${tab}--wait-timeout${tab}600$" "$log" | tail -n 1 | cut -d: -f1)
first_health=$(grep -n "${tab}ps${tab}--all${tab}--format${tab}json$" "$log" | head -n 1 | cut -d: -f1)
[ "$render_line" -lt "$first_config" ] && [ "$last_config" -lt "$beszel_key_line" ] && \
  [ "$beszel_key_line" -lt "$first_up" ] && \
  [ "$last_up" -lt "$first_health" ] || fail 'runtime legacy deployment ordering differs'
[ -f "$sandbox/legacy/beszel/hub/id_ed25519" ] &&
  [ ! -L "$sandbox/legacy/beszel/hub/id_ed25519" ] &&
  [ "$(ruby -e 'printf "%o", File.stat(ARGV.fetch(0)).mode & 0777' "$sandbox/legacy/beszel/hub/id_ed25519")" = 600 ] ||
  fail 'Beszel deployment key was not safely installed before first start'
[ "$(grep "${tab}config${tab}--quiet$" "$log" | wc -l | tr -d ' ')" -eq 9 ] ||
  fail 'runtime deployment did not validate nine Compose projects'
[ "$(grep "${tab}up${tab}--detach${tab}--wait${tab}--wait-timeout${tab}600$" "$log" | wc -l | tr -d ' ')" -eq 9 ] ||
  fail 'runtime deployment did not start and wait for nine Compose projects'
[ "$(sed -n 's/.*--project-name\tnas-platform-mac-lgcy42-legacy-\([^[:space:]]*\).*/\1/p' "$log" | sort -u | wc -l | tr -d ' ')" -eq 9 ] ||
  fail 'runtime deployment project names are not unique'

unowned=$temporary_root/unowned
mkdir -m 0700 "$unowned"
if env PATH="$fake_bin:$PATH" FAKE_COMMAND_LOG="$log" PLATFORM_LEGACY_ROOT="$legacy_root" \
    PLATFORM_MAC_TMPDIR="$temporary_root" PLATFORM_MAC_SANDBOX="$unowned" \
    PLATFORM_PROJECT_NAME=nas-platform-mac-lgcy42 \
    PLATFORM_MAC_VAULT_FILE="$temporary_root/deployment-vault.yml" \
    PLATFORM_MAC_VAULT_PASSWORD_FILE="$temporary_root/deployment-password" "$seed" \
    >/dev/null 2>&1; then
  fail 'unowned sandbox was accepted for legacy seeding'
fi
[ ! -e "$unowned/legacy-seed-runtime" ] || fail 'legacy seeding wrote into an unowned sandbox'

external_seed_root=$temporary_root/external-seed-root
mkdir -m 0700 "$external_seed_root"
ln -s "$external_seed_root" "$sandbox/legacy/nas-platform"
if run_seed >/dev/null 2>&1; then
  fail 'symlinked legacy seed runtime was accepted'
fi
[ ! -e "$external_seed_root/current" ] || fail 'legacy seeding escaped through a runtime symlink'
unlink "$sandbox/legacy/nas-platform"

seed_output=$temporary_root/seed-output
run_seed > "$seed_output"
grep -F "@$temporary_root/immich-fixture-vars.yml" "$log" >/dev/null ||
  fail 'legacy managed-user seeding omitted the protected Immich fixture policy'
[ -f "$temporary_root/ntfy-prerequisites" ] ||
  fail 'ntfy prerequisite state was not established before provisioning'
[ -f "$sandbox/legacy/nas-platform/runtime/services/ntfy/.env" ] ||
  fail 'ntfy ownership inspection had no prior declarative environment'
[ -f "$temporary_root/tmm-credential" ] ||
  fail 'tinyMediaManager vault credential interface was not invoked'
for prerequisite_service in beszel paperless-ngx; do
  [ -f "$sandbox/legacy/nas-platform/current/services/$prerequisite_service/compose.yml" ] &&
    [ -f "$sandbox/legacy/nas-platform/current/services/$prerequisite_service/compose.mac.yml" ] ||
    fail "$prerequisite_service exact legacy Compose prerequisites were not staged"
  [ -s "$sandbox/legacy/nas-platform/runtime/services/$prerequisite_service/.env" ] ||
    fail "$prerequisite_service role environment prerequisite was not rendered"
done
grep -qx 'legacy-seed: audiobookshelf/users' "$seed_output" ||
  fail 'seed output omitted a service/capability label'
grep -qx 'legacy-seed: audiobookshelf/administrator' "$seed_output" ||
  fail 'seed output omitted a primary-administrator capability label'
grep -qx 'legacy-seed: fixtures/media-books-photos-documents' "$seed_output" ||
  fail 'seed output omitted the fixture capability label'
if grep -E 'protected-value|tmm-secret-canary' "$seed_output" "$log" >/dev/null; then
  fail 'seed output disclosed a protected value'
fi
for service in audiobookshelf beszel dozzle immich jellyfin komga ntfy paperless-ngx; do
  administrator_line=$(grep -n "legacy-seed: $service/administrator$" "$seed_output" | cut -d: -f1)
  users_line=$(grep -n "legacy-seed: $service/users$" "$seed_output" | cut -d: -f1)
  [ "$administrator_line" -lt "$users_line" ] ||
    fail "allowlisted $service users were seeded before its primary administrator"
done
fixture_line=$(grep -n '^legacy-fixture' "$log" | head -n 1 | cut -d: -f1)
last_health_gate=$(grep -n "${tab}ps${tab}--all${tab}--format${tab}json$" "$log" |
  tail -n 1 | cut -d: -f1)
first_service_seed=$(grep -n '^ansible-playbook' "$log" | grep -Ev 'legacy-(render|beszel-key)\.yml' |
  head -n 1 | cut -d: -f1)
last_service_seed=$(grep -n '^ansible-playbook' "$log" | tail -n 1 | cut -d: -f1)
[ "$last_health_gate" -lt "$first_service_seed" ] ||
  fail 'service seeding began before the deployment health gates completed'
[ "$last_service_seed" -lt "$fixture_line" ] ||
  fail 'fixture helper ran before every service seed action completed'
for expected_fixture in \
  'audiobookshelf seed-progress audiobookshelf' \
  'komga seed komga' \
  'tinymediamanager seed tinymediamanager' \
  'jellyfin seed jellyfin' \
  'immich seed immich-server' \
  'paperless-ngx seed webserver'; do
  set -- $expected_fixture
  grep -q "^legacy-fixture[[:space:]]$1[[:space:]]$2[[:space:]]nas-platform-mac-lgcy42-legacy-$1[[:space:]]$3$" "$log" ||
    fail "$1 legacy fixture did not target its exact project and service"
done

cp "$test_dir/lib.sh" "$sandbox/lib.sh"
wrong_root_adapter=$sandbox/legacy-fixtures-wrong-root.sh
sed 's#/legacy/audiobookshelf/media"#/legacy/audiobookshelf/wrong"#' \
  "$test_dir/legacy-fixtures.sh" > "$wrong_root_adapter"
chmod 0700 "$wrong_root_adapter"
if env FAKE_COMMAND_LOG="$log" PLATFORM_MAC_TMPDIR="$temporary_root" \
    PLATFORM_MAC_SANDBOX="$sandbox" PLATFORM_PROJECT_NAME=nas-platform-mac-lgcy42 \
    PLATFORM_LEGACY_FIXTURE_DRIVER="$sandbox/fake-fixture-driver.sh" \
    "$wrong_root_adapter" seed >/dev/null 2>&1; then
  fail 'legacy fixture adapter accepted a wrong reviewed bind root'
fi
wrong_project_adapter=$sandbox/legacy-fixtures-wrong-project.sh
sed 's/PLATFORM_PROJECT_NAME-legacy-/PLATFORM_PROJECT_NAME-wrong-/' \
  "$test_dir/legacy-fixtures.sh" > "$wrong_project_adapter"
chmod 0700 "$wrong_project_adapter"
if env FAKE_COMMAND_LOG="$log" PLATFORM_MAC_TMPDIR="$temporary_root" \
    PLATFORM_MAC_SANDBOX="$sandbox" PLATFORM_PROJECT_NAME=nas-platform-mac-lgcy42 \
    PLATFORM_LEGACY_FIXTURE_DRIVER="$sandbox/fake-fixture-driver.sh" \
    "$wrong_project_adapter" seed >/dev/null 2>&1; then
  fail 'legacy fixture adapter accepted a wrong Compose project identifier'
fi
ruby -rjson - "$log" <<'RUBY'
File.foreach(ARGV.fetch(0)) do |line|
  line.split("\t").grep(/\A\{.*_compose_files/).each do |argument|
    document = JSON.parse(argument)
    paths = document.values.fetch(0)
    raise "unsafe Compose file transport" unless document.keys.fetch(0).end_with?("_compose_files") &&
      paths.length == 2 && paths.all? { |path| path.is_a?(String) }
  end
end
RUBY

: > "$log"
if FAKE_SEED_FAIL_LABEL=dozzle run_seed > "$seed_output" 2>&1; then
  fail 'seed command failure was ignored'
fi
if grep -F 'legacy-fixture' "$log" >/dev/null; then
  fail 'fixture seeding continued after service seed failure'
fi

report_root=$sandbox.reports
state_input=$report_root/phase-input.json
mkdir -m 0700 "$report_root"
printf 'schema=1\nsandbox=%s\n' "$(basename -- "$sandbox")" \
  > "$report_root/.nas-platform-mac-report-owned"
chmod 0600 "$report_root/.nas-platform-mac-report-owned"
git_revision=400f03f276ae1bb69f5460c175b9fb923d620f1a
vault_checksum=$(shasum -a 256 "$temporary_root/deployment-vault.yml" | awk '{print $1}')
parity_checksum=$(shasum -a 256 "$parity_vault" | awk '{print $1}')
"$test_dir/report.rb" --init "$state_input" --lane adoption \
  --sandbox-id "$(basename -- "$sandbox")" --git-revision "$git_revision" \
  --vault-checksum "$vault_checksum" --project-name nas-platform-mac-lgcy42 \
  --beszel-port 31002 --ntfy-port 31007 --dozzle-port 31003 \
  --audiobookshelf-port 31001 --komga-port 31006 \
  --tinymediamanager-web-port 31009 --tinymediamanager-api-port 31010 \
  --jellyfin-port 31005 --immich-port 31004 --paperless-port 31008 \
  --parity-vault-checksum "$parity_checksum" \
  --legacy-commit 400f03f276ae1bb69f5460c175b9fb923d620f1a
"$test_dir/report.rb" --record "$state_input" --phase preflight --status passed
"$test_dir/report.rb" --record "$state_input" --phase legacy-deploy --status passed

run_runner_phase() {
  runner_phase=$1
  env PATH="$fake_bin:$PATH" FAKE_COMMAND_LOG="$log" FAKE_REPO_DIR="$repo_dir" \
    FAKE_NTFY_PREREQUISITES_MARKER="$temporary_root/runner-ntfy-prerequisites" \
    FAKE_TMM_CREDENTIAL_MARKER="$temporary_root/runner-tmm-credential" \
    FAKE_PARITY_DOCUMENT="$parity_document" FAKE_SEED_FAIL_LABEL=dozzle \
    PLATFORM_LEGACY_FIXTURE_DRIVER="$sandbox/fake-fixture-driver.sh" \
    PLATFORM_MAC_TMPDIR="$temporary_root" PLATFORM_LEGACY_ROOT="$legacy_root" \
    NAS_INFRASTRUCTURE_DIR="$legacy_root" \
    "$test_dir/run.sh" --lane adoption \
      --vault-file "$temporary_root/deployment-vault.yml" \
      --vault-password-file "$temporary_root/deployment-password" \
      --parity-vault-file "$parity_vault" --parity-vault-password-file "$parity_password" \
      --phase "$runner_phase" --sandbox "$sandbox"
}

: > "$log"
runner_output=$temporary_root/runner-output
if run_runner_phase legacy-seed > "$runner_output" 2>&1; then
  fail 'runner accepted a failing legacy seed phase'
fi
legacy_seed_status=$(ruby -rjson -e '
  phase = JSON.parse(File.read(ARGV.fetch(0))).fetch("phases").find do |entry|
    entry["name"] == "legacy-seed"
  end
  print phase.fetch("status")
' "$state_input")
[ "$legacy_seed_status" = failed ] || fail 'runner did not record failed legacy seed status'
if grep -F 'legacy-fixture' "$log" >/dev/null; then
  fail 'runner reached fixtures after a failed service seed'
fi

for blocked_phase in capture-baseline snapshot cutover; do
  if run_runner_phase "$blocked_phase" > "$runner_output" 2>&1; then
    fail "$blocked_phase ran after failed legacy seeding"
  fi
  grep -F "phase $blocked_phase requires passed phase legacy-seed" "$runner_output" >/dev/null ||
    fail "$blocked_phase was rejected for the wrong reason"
done

printf '%s\n' 'Legacy seed orchestration: ordering, isolation, failure propagation, and redaction hold'
