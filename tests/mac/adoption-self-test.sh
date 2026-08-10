#!/bin/sh
set -eu
set +x
umask 077

test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_dir=$(CDPATH= cd -- "$test_dir/../.." && pwd -P)
coordinator=$test_dir/adoption.sh
temporary_input=$(mktemp -d "${TMPDIR:-/tmp}/nas-platform-adoption-inputs.XXXXXX")
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

[ -x "$coordinator" ] || fail 'adoption coordinator is absent or not executable'

legacy_root=$temporary_root/nas-infrastructure
mkdir -p "$legacy_root/.git"
ruby -ryaml -rfileutils - "$repo_dir/services/manifest.yml" "$legacy_root" <<'RUBY'
manifest = YAML.safe_load_file(ARGV.fetch(0))
manifest.fetch("services").each do |service|
  path = File.join(ARGV.fetch(1), service.fetch("legacy_path"))
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, "services: {}\n")
end
RUBY

fake_bin=$temporary_root/bin
mkdir -m 0700 "$fake_bin"
log=$temporary_root/commands.log
cat > "$fake_bin/git" <<'SH'
#!/bin/sh
printf 'git %s\n' "$*" >> "${FAKE_COMMAND_LOG:?}"
case " $* " in
  *' status --porcelain=v1 --untracked-files=all ')
    [ "${FAKE_GIT_DIRTY:-0}" = 0 ] || printf '%s\n' ' M compose/dirty.yml'
    ;;
  *' remote get-url origin ')
    printf '%s\n' "${FAKE_GIT_ORIGIN:-https://github.com/yonatankarp/nas-infrastructure.git}"
    ;;
  *' rev-parse --show-toplevel ')
    printf '%s\n' "${FAKE_GIT_TOPLEVEL:-${NAS_INFRASTRUCTURE_DIR:?}}"
    ;;
  *' rev-parse HEAD ')
    printf '%s\n' "${FAKE_GIT_COMMIT:-400f03f276ae1bb69f5460c175b9fb923d620f1a}"
    ;;
  *' ls-files -v -- '*)
    path=
    for argument in "$@"; do path=$argument; done
    printf '%s %s\n' "${FAKE_GIT_INDEX_TAG:-H}" "$path"
    ;;
  *' cat-file blob HEAD:'*)
    object=
    for argument in "$@"; do object=$argument; done
    path=${object#HEAD:}
    if [ "$path" = "${FAKE_GIT_CONTENT_MISMATCH:-}" ]; then
      printf '%s\n' 'services: changed'
    else
      cat "${NAS_INFRASTRUCTURE_DIR:?}/$path"
    fi
    ;;
  *' ls-tree HEAD -- '*)
    path=
    for argument in "$@"; do path=$argument; done
    printf '%s blob %040d\t%s\n' "${FAKE_GIT_HEAD_MODE:-100644}" 0 "$path"
    ;;
  *' ls-files --error-unmatch -- '*)
    path=
    for argument in "$@"; do path=$argument; done
    [ "$path" != "${FAKE_GIT_UNTRACKED:-}" ] || exit 1
    printf '%s\n' "$path"
    ;;
  *) exit 2 ;;
esac
SH
cat > "$fake_bin/docker" <<'SH'
#!/bin/sh
printf 'docker %s\n' "$*" >> "${FAKE_COMMAND_LOG:?}"
[ "$*" = version ] || exit 2
[ "${FAKE_DOCKER_FAIL:-0}" = 0 ]
SH
cat > "$fake_bin/ansible-playbook" <<'SH'
#!/bin/sh
printf 'ansible-playbook %s\n' "$*" >> "${FAKE_COMMAND_LOG:?}"
case " $* " in
  *' --vault-password-file '*' -e @'*' -e legacy_env_root='*' -e legacy_expected_commit='*) ;;
  *) exit 2 ;;
esac
case ${FAKE_PARITY_MODE:-valid} in
  valid) ;;
  schema|commit|services) exit 1 ;;
  *) exit 2 ;;
esac
root=
extra_vars=
for argument in "$@"; do
  case $argument in
    @*) extra_vars=${argument#@} ;;
    legacy_env_root=*) root=${argument#legacy_env_root=} ;;
  esac
done
[ -n "$root" ] || exit 2
[ "$(sed -n '1p' "$extra_vars")" = '$ANSIBLE_VAULT;1.1;AES256' ] || exit 3
[ "$extra_vars" = "$(sed -n '1p' "${FAKE_PARITY_VIEW_LOG:?}")" ] || exit 3
[ "$extra_vars" != "${PLATFORM_MAC_PARITY_VAULT_FILE:?}" ] || exit 3
cmp -s "$extra_vars" "$PLATFORM_MAC_PARITY_VAULT_FILE" || exit 3
snapshot_mode=$(stat -f '%Lp' "$extra_vars" 2>/dev/null || stat -c '%a' "$extra_vars")
[ "$snapshot_mode" = 400 ] || exit 3
mkdir -m 0700 "$root"
for service in audiobookshelf beszel dozzle immich jellyfin komga ntfy paperless-ngx tinymediamanager; do
  printf 'A=%s\nDOLLAR=$$safe\n' "${FAKE_RENDER_CANARY:?}" > "$root/$service.env"
  chmod 0600 "$root/$service.env"
done
SH
cat > "$fake_bin/ansible-vault" <<'SH'
#!/bin/sh
[ "${1-}" = view ] || exit 2
for argument in "$@"; do vault_path=$argument; done
printf '%s\n' "$vault_path" > "${FAKE_PARITY_VIEW_LOG:?}"
cat "${FAKE_PARITY_FIXTURE_ROOT:?}/${FAKE_PARITY_MODE:-valid}.yml"
SH
chmod 0700 "$fake_bin/git" "$fake_bin/docker" "$fake_bin/ansible-playbook" \
  "$fake_bin/ansible-vault"

sandbox=$temporary_root/nas-platform-mac.AdT123
mkdir -m 0700 "$sandbox"
printf 'schema=1\nproject=%s\n' nas-platform-mac-adt123 > "$sandbox/.nas-platform-mac-owned"
chmod 0600 "$sandbox/.nas-platform-mac-owned"
parity_vault=$temporary_root/parity.yml
parity_password=$temporary_root/parity-password
printf '%s\n' '$ANSIBLE_VAULT;1.1;AES256' > "$parity_vault"
printf '%s\n' disposable > "$parity_password"
chmod 0600 "$parity_vault" "$parity_password"
fake_parity_fixtures=$temporary_root/fake-parity
fake_parity_view_log=$temporary_root/fake-parity-view.log
mkdir -m 0700 "$fake_parity_fixtures"
ruby -ryaml - "$repo_dir/config/portainer-parity.yml" "$fake_parity_fixtures" <<'RUBY'
mapping = YAML.safe_load_file(ARGV.fetch(0))
root = ARGV.fetch(1)
stacks = mapping.fetch("stacks").to_h do |stack, rules|
  [stack, rules.keys.to_h { |key| [key, "value-secret-canary"] }]
end
valid = {"schema" => 1, "legacy_commit" => mapping.fetch("legacy_commit"), "stacks" => stacks}
fixtures = {
  "valid" => valid,
  "schema" => valid.merge("schema" => 2),
  "commit" => valid.merge("legacy_commit" => "0" * 40),
  "services" => valid.merge("stacks" => stacks.reject { |name, _values| name == "komga" }),
}
fixtures.each { |name, document| File.write(File.join(root, "#{name}.yml"), YAML.dump(document)) }
RUBY

run_coordinator() {
  env PATH="$fake_bin:$PATH" FAKE_COMMAND_LOG="$log" FAKE_RENDER_CANARY='value-secret-canary' \
    FAKE_PARITY_FIXTURE_ROOT="$fake_parity_fixtures" FAKE_PARITY_VIEW_LOG="$fake_parity_view_log" \
    PLATFORM_MAC_TMPDIR="$temporary_root" \
    NAS_INFRASTRUCTURE_DIR="$legacy_root" PLATFORM_MAC_SANDBOX="$sandbox" \
    PLATFORM_MAC_PARITY_VAULT_FILE="$parity_vault" \
    PLATFORM_MAC_PARITY_VAULT_PASSWORD_FILE="$parity_password" \
    "$coordinator" "$@"
}

expect_failure() {
  label=$1
  expected=$2
  shift 2
  output=$temporary_root/output
  if "$@" > "$output" 2>&1; then
    fail "$label was accepted"
  fi
  if ! grep -F "$expected" "$output" >/dev/null; then
    actual=$(sed -n '1p' "$output")
    fail "$label emitted the wrong diagnostic: ${actual:-none}"
  fi
  if grep -F value-secret-canary "$output" >/dev/null; then
    fail "$label leaked a rendered value"
  fi
}

expect_failure 'missing legacy checkout' 'NAS_INFRASTRUCTURE_DIR is required' \
  env PATH="$fake_bin:$PATH" FAKE_COMMAND_LOG="$log" "$coordinator" preflight
legacy_link=$temporary_root/legacy-link
ln -s "$legacy_root" "$legacy_link"
expect_failure 'symlink legacy checkout' 'legacy checkout must not be a symlink' \
  env PATH="$fake_bin:$PATH" FAKE_COMMAND_LOG="$log" NAS_INFRASTRUCTURE_DIR="$legacy_link" \
    PLATFORM_MAC_SANDBOX="$sandbox" "$coordinator" preflight
expect_failure 'dirty legacy checkout' 'legacy checkout must be clean' \
  env FAKE_GIT_DIRTY=1 PATH="$fake_bin:$PATH" FAKE_COMMAND_LOG="$log" \
    NAS_INFRASTRUCTURE_DIR="$legacy_root" PLATFORM_MAC_SANDBOX="$sandbox" \
    "$coordinator" preflight
expect_failure 'wrong legacy origin' 'legacy checkout origin differs from manifest' \
  env FAKE_GIT_ORIGIN=https://github.com/example/wrong.git PATH="$fake_bin:$PATH" \
    FAKE_COMMAND_LOG="$log" NAS_INFRASTRUCTURE_DIR="$legacy_root" \
    PLATFORM_MAC_SANDBOX="$sandbox" "$coordinator" preflight
expect_failure 'nested legacy repository path' 'NAS_INFRASTRUCTURE_DIR is not the repository root' \
  env FAKE_GIT_TOPLEVEL="$temporary_root/other-repository" PATH="$fake_bin:$PATH" \
    FAKE_COMMAND_LOG="$log" NAS_INFRASTRUCTURE_DIR="$legacy_root" \
    PLATFORM_MAC_SANDBOX="$sandbox" "$coordinator" preflight
expect_failure 'wrong legacy commit' 'legacy checkout commit differs from manifest' \
  env FAKE_GIT_COMMIT=0000000000000000000000000000000000000000 PATH="$fake_bin:$PATH" \
    FAKE_COMMAND_LOG="$log" NAS_INFRASTRUCTURE_DIR="$legacy_root" \
    PLATFORM_MAC_SANDBOX="$sandbox" "$coordinator" preflight
expect_failure 'untracked legacy compose' 'legacy compose file is not tracked' \
  env FAKE_GIT_UNTRACKED=compose/komga/compose.yml PATH="$fake_bin:$PATH" \
    FAKE_COMMAND_LOG="$log" NAS_INFRASTRUCTURE_DIR="$legacy_root" \
    PLATFORM_MAC_SANDBOX="$sandbox" "$coordinator" preflight
expect_failure 'hidden modified legacy compose' 'legacy compose file has unsafe index flags' \
  env FAKE_GIT_INDEX_TAG=h PATH="$fake_bin:$PATH" FAKE_COMMAND_LOG="$log" \
    NAS_INFRASTRUCTURE_DIR="$legacy_root" PLATFORM_MAC_SANDBOX="$sandbox" \
    "$coordinator" preflight
expect_failure 'legacy compose bytes hidden from status' 'legacy compose file differs from HEAD' \
  env FAKE_GIT_CONTENT_MISMATCH=compose/komga/compose.yml PATH="$fake_bin:$PATH" \
    FAKE_COMMAND_LOG="$log" NAS_INFRASTRUCTURE_DIR="$legacy_root" \
    PLATFORM_MAC_SANDBOX="$sandbox" "$coordinator" preflight
expect_failure 'legacy compose mode hidden from status' 'legacy compose mode differs from HEAD' \
  env FAKE_GIT_HEAD_MODE=100755 PATH="$fake_bin:$PATH" FAKE_COMMAND_LOG="$log" \
    NAS_INFRASTRUCTURE_DIR="$legacy_root" PLATFORM_MAC_SANDBOX="$sandbox" \
    "$coordinator" preflight
expect_failure 'Docker readiness failure' 'Docker is unavailable' \
  env FAKE_DOCKER_FAIL=1 PATH="$fake_bin:$PATH" FAKE_COMMAND_LOG="$log" \
    NAS_INFRASTRUCTURE_DIR="$legacy_root" PLATFORM_MAC_SANDBOX="$sandbox" \
    "$coordinator" preflight

missing_path=$legacy_root/compose/komga/compose.yml
mv "$missing_path" "$missing_path.saved"
expect_failure 'missing legacy compose' 'legacy compose file is unavailable' run_coordinator preflight
mv "$missing_path.saved" "$missing_path"
legacy_target=$legacy_root/compose/komga/compose-target.yml
mv "$missing_path" "$legacy_target"
ln -s compose-target.yml "$missing_path"
expect_failure 'symlink legacy compose' 'legacy compose file is unavailable' run_coordinator preflight
unlink "$missing_path"
mv "$legacy_target" "$missing_path"

: > "$log"
run_coordinator preflight >/dev/null
remote_line=$(grep -n 'remote get-url origin' "$log" | cut -d: -f1)
root_line=$(grep -n 'rev-parse --show-toplevel' "$log" | cut -d: -f1)
commit_line=$(grep -n 'rev-parse HEAD' "$log" | cut -d: -f1)
status_line=$(grep -n 'status --porcelain' "$log" | cut -d: -f1)
docker_line=$(grep -n '^docker version$' "$log" | cut -d: -f1)
[ "$remote_line" -lt "$root_line" ] && [ "$root_line" -lt "$commit_line" ] && \
  [ "$commit_line" -lt "$status_line" ] && \
  [ "$status_line" -lt "$docker_line" ] || fail 'preflight command ordering differs'

for mode in schema commit services; do
  expect_failure "parity $mode" 'legacy parity rendering failed' \
    env FAKE_PARITY_MODE="$mode" PATH="$fake_bin:$PATH" FAKE_COMMAND_LOG="$log" \
      FAKE_RENDER_CANARY='value-secret-canary' FAKE_PARITY_FIXTURE_ROOT="$fake_parity_fixtures" \
      FAKE_PARITY_VIEW_LOG="$fake_parity_view_log" NAS_INFRASTRUCTURE_DIR="$legacy_root" \
      PLATFORM_MAC_TMPDIR="$temporary_root" \
      PLATFORM_MAC_SANDBOX="$sandbox" PLATFORM_MAC_PARITY_VAULT_FILE="$parity_vault" \
      PLATFORM_MAC_PARITY_VAULT_PASSWORD_FILE="$parity_password" "$coordinator" render
done

printf '%s\n' 'schema: 1' > "$parity_vault"
expect_failure 'plaintext parity document' 'parity vault must be encrypted' run_coordinator render
printf '%s\n' '$ANSIBLE_VAULT;1.1;AES256' > "$parity_vault"

: > "$log"
render_output=$temporary_root/render-output
if ! run_coordinator render > "$render_output" 2>&1; then
  fail 'ansible-playbook did not receive the validated encrypted parity snapshot'
fi
grep -F value-secret-canary "$render_output" >/dev/null && fail 'render output leaked a value'
rendered=$(/usr/bin/find "$sandbox/legacy-env" -type f -name '*.env' | wc -l | tr -d ' ')
[ "$rendered" = 9 ] || fail 'render did not create the exact nine-service set'
docker_line=$(grep -n '^docker version$' "$log" | tail -n 1 | cut -d: -f1)
ansible_line=$(grep -n '^ansible-playbook ' "$log" | tail -n 1 | cut -d: -f1)
[ "$docker_line" -lt "$ansible_line" ] || fail 'render ran before preflight completed'
for file in "$sandbox"/legacy-env/*.env; do
  mode=$(stat -f '%Lp' "$file" 2>/dev/null || stat -c '%a' "$file")
  [ "$mode" = 600 ] || fail 'rendered legacy environment mode differs'
  grep -F 'DOLLAR=$$safe' "$file" >/dev/null || fail 'Compose dollar escaping differs'
done

ruby -ryaml - "$test_dir/legacy-render.yml" "$test_dir/templates/legacy-env.j2" <<'RUBY'
play = YAML.safe_load_file(ARGV.fetch(0))
render_play = play.fetch(0)
tasks = render_play.fetch("tasks")
raise "render tasks can expose values" unless tasks.all? { |task| task["no_log"] == true }

source = File.read(ARGV.fetch(1))
raise "template does not sort entries" unless source.include?("sort(attribute='key')")
raise "template does not escape Compose dollars" unless source.include?("replace('$', '$$')")
RUBY

printf '%s\n' 'Mac adoption inputs: pinned checkout and parity rendering hold'
