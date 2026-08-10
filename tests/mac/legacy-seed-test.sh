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
  *' ps --status running --services '*)
    printf '%s\n' one
    [ "${FAKE_PS_INCOMPLETE:-0}" = 1 ] || printf '%s\n' two
    ;;
esac
SH
chmod 0700 "$fake_bin/docker"

run_compose() {
  env PATH="$fake_bin:$PATH" FAKE_COMMAND_LOG="$log" \
    FAKE_PS_INCOMPLETE="${FAKE_PS_INCOMPLETE:-0}" \
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

if run_compose unknown config >/dev/null 2>&1; then
  fail 'unknown legacy service was accepted'
fi
if run_compose beszel exec >/dev/null 2>&1; then
  fail 'unknown legacy action was accepted'
fi
if FAKE_PS_INCOMPLETE=1 run_compose beszel ps >/dev/null 2>&1; then
  fail 'partially running legacy project passed the health gate'
fi
unset FAKE_PS_INCOMPLETE
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
esac
case " $* " in
  *' --tags ntfy '*)
    start=
    previous=
    for argument in "$@"; do
      [ "$previous" != --start-at-task ] || start=$argument
      previous=$argument
    done
    ruby -ryaml - "$FAKE_REPO_DIR/roles/ntfy/tasks/main.yml" "$start" <<'RUBY' || exit 31
tasks, start = ARGV
entries = YAML.safe_load_file(tasks, aliases: false)
start_index = entries.index { |task| task["name"] == start }
managed_index = entries.index { |task| task["name"] == "Resolve declarative ntfy managed-user provisioning" }
abort unless start_index && managed_index && start_index <= managed_index
prefix = entries[start_index..managed_index].to_s
%w[ntfy_prior_provisioned_users ntfy_existing_user_records ntfy_authoritative_absence_established].each do |fact|
  abort unless prefix.include?(fact)
end
RUBY
    : > "${FAKE_NTFY_PREREQUISITES_MARKER:?}"
    ;;
  *' --tags tinymediamanager '*)
    start=
    previous=
    for argument in "$@"; do
      [ "$previous" != --start-at-task ] || start=$argument
      previous=$argument
    done
    ruby -ryaml - "$FAKE_REPO_DIR/roles/tinymediamanager/tasks/main.yml" "$start" <<'RUBY' || exit 32
tasks, start = ARGV
entries = YAML.safe_load_file(tasks, aliases: false)
start_index = entries.index { |task| task["name"] == start }
abort unless start_index
suffix = entries[start_index..].to_s
required = [
  "vault_tinymediamanager_password",
  "Read the installed tinyMediaManager VNC password environment",
  "Require the installed tinyMediaManager VNC password"
]
required.each { |value| abort unless suffix.include?(value) }
RUBY
    : > "${FAKE_TMM_CREDENTIAL_MARKER:?}"
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
cat > "$sandbox/fake-fixtures.sh" <<'SH'
#!/bin/sh
printf 'fixtures.sh\t%s\n' "$*" >> "${FAKE_COMMAND_LOG:?}"
for capability in media books photos documents; do
  printf 'fixture-capability\t%s\n' "$capability" >> "$FAKE_COMMAND_LOG"
done
SH
chmod 0700 "$fake_bin/ansible-playbook" "$fake_bin/ansible-vault" "$fake_bin/git" \
  "$sandbox/fake-fixtures.sh"

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
    PLATFORM_FIXTURES_HELPER="$sandbox/fake-fixtures.sh" \
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

: > "$log"
env PATH="$fake_bin:$PATH" FAKE_COMMAND_LOG="$log" FAKE_PARITY_DOCUMENT="$parity_document" \
  PLATFORM_MAC_TMPDIR="$temporary_root" PLATFORM_LEGACY_ROOT="$legacy_root" \
  NAS_INFRASTRUCTURE_DIR="$legacy_root" PLATFORM_MAC_SANDBOX="$sandbox" \
  PLATFORM_PROJECT_NAME=nas-platform-mac-lgcy42 \
  PLATFORM_MAC_PARITY_VAULT_FILE="$parity_vault" \
  PLATFORM_MAC_PARITY_VAULT_PASSWORD_FILE="$parity_password" \
  "$test_dir/adoption.sh" legacy-deploy >/dev/null
[ -f "$sandbox/legacy/paperless-ngx/tessdata/heb.traineddata" ] ||
  fail 'legacy deployment did not prepare the file-backed Paperless bind'
[ ! -L "$sandbox/legacy/paperless-ngx/tessdata/heb.traineddata" ] ||
  fail 'legacy deployment prepared an unsafe Paperless bind'
render_line=$(grep -n 'legacy-render.yml' "$log" | head -n 1 | cut -d: -f1)
first_config=$(grep -n "${tab}config${tab}--quiet$" "$log" | head -n 1 | cut -d: -f1)
last_config=$(grep -n "${tab}config${tab}--quiet$" "$log" | tail -n 1 | cut -d: -f1)
first_up=$(grep -n "${tab}up${tab}--detach${tab}--wait${tab}--wait-timeout${tab}600$" "$log" | head -n 1 | cut -d: -f1)
last_up=$(grep -n "${tab}up${tab}--detach${tab}--wait${tab}--wait-timeout${tab}600$" "$log" | tail -n 1 | cut -d: -f1)
first_health=$(grep -n "${tab}ps${tab}--status${tab}running${tab}--services$" "$log" | head -n 1 | cut -d: -f1)
[ "$render_line" -lt "$first_config" ] && [ "$last_config" -lt "$first_up" ] && \
  [ "$last_up" -lt "$first_health" ] || fail 'runtime legacy deployment ordering differs'
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
ln -s "$external_seed_root" "$sandbox/legacy-seed-runtime"
if run_seed >/dev/null 2>&1; then
  fail 'symlinked legacy seed runtime was accepted'
fi
[ ! -e "$external_seed_root/current" ] || fail 'legacy seeding escaped through a runtime symlink'
unlink "$sandbox/legacy-seed-runtime"

seed_output=$temporary_root/seed-output
run_seed > "$seed_output"
[ -f "$temporary_root/ntfy-prerequisites" ] ||
  fail 'ntfy prerequisite state was not established before provisioning'
[ -f "$sandbox/legacy-seed-runtime/runtime/services/ntfy/.env" ] ||
  fail 'ntfy ownership inspection had no prior declarative environment'
[ -f "$temporary_root/tmm-credential" ] ||
  fail 'tinyMediaManager vault credential interface was not invoked'
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
fixture_line=$(grep -n '^fixtures.sh' "$log" | cut -d: -f1)
last_health_gate=$(grep -n "${tab}ps${tab}--status${tab}running${tab}--services$" "$log" |
  tail -n 1 | cut -d: -f1)
first_service_seed=$(grep -n '^ansible-playbook' "$log" | grep -v 'legacy-render.yml' |
  head -n 1 | cut -d: -f1)
last_service_seed=$(grep -n '^ansible-playbook' "$log" | tail -n 1 | cut -d: -f1)
[ "$last_health_gate" -lt "$first_service_seed" ] ||
  fail 'service seeding began before the deployment health gates completed'
[ "$last_service_seed" -lt "$fixture_line" ] ||
  fail 'fixture helper ran before every service seed action completed'
grep -q '^fixtures.sh[[:space:]]seed$' "$log" || fail 'existing fixture helper was not reused'
for capability in media books photos documents; do
  grep -q "^fixture-capability[[:space:]]$capability$" "$log" ||
    fail "$capability fixture capability was not seeded"
done
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
if grep -F 'fixtures.sh' "$log" >/dev/null; then
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
    PLATFORM_FIXTURES_HELPER="$sandbox/fake-fixtures.sh" \
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
if grep -F 'fixtures.sh' "$log" >/dev/null; then
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
